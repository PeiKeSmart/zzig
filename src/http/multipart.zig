//! `multipart/form-data` 解析（**只做最小可用集**：切段 + 解析每个 part 的头）。
//!
//! 用途：面板里的文件上传（导入 Excel、上传头像）。不做的：嵌套 multipart、`Content-Transfer-Encoding`、
//! 流式解析（整个 body 已在内存里时才用；超大文件请用流式上传接口）。
//!
//! ```zig
//! const parts = try multipart.parseAlloc(arena, req.headers_content_type, req.body);
//! for (parts) |p| {
//!     if (std.mem.eql(u8, p.name, "file")) {
//!         // p.filename / p.content_type / p.data（借用 body，不复制）
//!     }
//! }
//! ```

const std = @import("std");

pub const Error = error{
    /// `Content-Type` 里没有 `boundary=`
    MissingBoundary,
    /// 不是 multipart/form-data
    NotMultipart,
    /// 段格式不合法（缺空行分隔等）
    MalformedPart,
};

pub const Part = struct {
    /// 表单字段名（`Content-Disposition: form-data; name="x"`）
    name: []const u8 = "",
    /// 文件名（上传文件才有）
    filename: ?[]const u8 = null,
    /// part 自己的 Content-Type（一般只有文件才有）
    content_type: []const u8 = "",
    /// 内容（**借用传入的 body**，不复制）
    data: []const u8 = "",
};

/// 从 `Content-Type` 取 boundary（支持带引号与不带引号）。
pub fn boundaryOf(content_type: []const u8) ?[]const u8 {
    if (!std.ascii.startsWithIgnoreCase(content_type, "multipart/form-data")) return null;

    const key = "boundary=";
    const idx = indexOfIgnoreCase(content_type, key) orelse return null;
    var rest = content_type[idx + key.len ..];
    rest = std.mem.trim(u8, rest, " \t");
    if (rest.len == 0) return null;
    if (rest[0] == '"') {
        const end = std.mem.indexOfScalarPos(u8, rest, 1, '"') orelse return null;
        return rest[1..end];
    }
    const end = std.mem.indexOfAny(u8, rest, ";, \t") orelse rest.len;
    return rest[0..end];
}

/// 解析所有 part。返回的切片用 `gpa` 分配，`Part` 里的字符串**借用 `body`**。
pub fn parseAlloc(gpa: std.mem.Allocator, content_type: []const u8, body: []const u8) ![]Part {
    const boundary = boundaryOf(content_type) orelse {
        if (!std.ascii.startsWithIgnoreCase(content_type, "multipart/form-data")) return Error.NotMultipart;
        return Error.MissingBoundary;
    };

    var delim_buf: [256]u8 = undefined;
    if (boundary.len + 2 > delim_buf.len) return Error.MissingBoundary;
    const delim = std.fmt.bufPrint(&delim_buf, "--{s}", .{boundary}) catch return Error.MissingBoundary;

    var parts: std.ArrayListUnmanaged(Part) = .empty;
    errdefer parts.deinit(gpa);

    var pos: usize = 0;
    while (true) {
        const found = std.mem.indexOfPos(u8, body, pos, delim) orelse break;
        var cursor = found + delim.len;
        // 结束标记：`--boundary--`
        if (cursor + 1 < body.len and body[cursor] == '-' and body[cursor + 1] == '-') break;
        // 跳过 boundary 后的 CRLF
        if (std.mem.startsWith(u8, body[cursor..], "\r\n")) cursor += 2 else if (std.mem.startsWith(u8, body[cursor..], "\n")) cursor += 1;

        const next_delim = std.mem.indexOfPos(u8, body, cursor, delim) orelse body.len;
        var segment = body[cursor..next_delim];
        // 去掉段尾的 CRLF（下一个 boundary 之前）
        segment = trimRightCrlf(segment);
        pos = next_delim;

        if (try parsePart(segment)) |part| try parts.append(gpa, part);
    }
    return try parts.toOwnedSlice(gpa);
}

fn parsePart(segment: []const u8) !?Part {
    if (segment.len == 0) return null;

    const header_end = std.mem.indexOf(u8, segment, "\r\n\r\n") orelse
        std.mem.indexOf(u8, segment, "\n\n") orelse return null;
    const header_len = if (std.mem.indexOf(u8, segment, "\r\n\r\n")) |i| i else header_end;
    const header = segment[0..header_len];
    const data_start = if (std.mem.startsWith(u8, segment[header_len..], "\r\n\r\n")) header_len + 4 else header_len + 2;

    var part = Part{ .data = segment[data_start..] };

    var it = std.mem.splitScalar(u8, header, '\n');
    while (it.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r");
        if (line.len == 0) continue;
        if (std.ascii.startsWithIgnoreCase(line, "content-disposition:")) {
            part.name = dispositionParam(line, "name") orelse "";
            part.filename = dispositionParam(line, "filename");
        } else if (std.ascii.startsWithIgnoreCase(line, "content-type:")) {
            part.content_type = std.mem.trim(u8, line["content-type:".len..], " \t");
        }
    }
    if (part.name.len == 0 and part.filename == null) return null;
    return part;
}

/// 从 `Content-Disposition` 行取 `name="x"` / `filename="y"`（也支持不带引号）。
fn dispositionParam(line: []const u8, key: []const u8) ?[]const u8 {
    var pattern_buf: [64]u8 = undefined;
    const pattern = std.fmt.bufPrint(&pattern_buf, "{s}=", .{key}) catch return null;

    const idx = indexOfIgnoreCase(line, pattern) orelse return null;
    var rest = line[idx + pattern.len ..];
    if (rest.len == 0) return null;
    if (rest[0] == '"') {
        const end = std.mem.indexOfScalarPos(u8, rest, 1, '"') orelse return null;
        return rest[1..end];
    }
    const end = std.mem.indexOfAny(u8, rest, ";, \t\r\n") orelse rest.len;
    if (end == 0) return null;
    return rest[0..end];
}

fn trimRightCrlf(text: []const u8) []const u8 {
    var end = text.len;
    while (end > 0 and (text[end - 1] == '\n' or text[end - 1] == '\r')) end -= 1;
    return text[0..end];
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (haystack.len < needle.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

test "multipart：解析文件字段与普通字段" {
    const body =
        "--X\r\n" ++
        "Content-Disposition: form-data; name=\"wheres\"\r\n\r\n" ++
        "abc\r\n" ++
        "--X\r\n" ++
        "Content-Disposition: form-data; name=\"file\"; filename=\"u.xlsx\"\r\n" ++
        "Content-Type: application/vnd.openxmlformats-officedocument.spreadsheetml.sheet\r\n\r\n" ++
        "PK\x03\x04FAKE\r\n" ++
        "--X--\r\n";

    const parts = try parseAlloc(std.testing.allocator, "multipart/form-data; boundary=X", body);
    defer std.testing.allocator.free(parts);

    try std.testing.expectEqual(@as(usize, 2), parts.len);
    try std.testing.expectEqualStrings("wheres", parts[0].name);
    try std.testing.expectEqualStrings("abc", parts[0].data);
    try std.testing.expectEqualStrings("file", parts[1].name);
    try std.testing.expectEqualStrings("u.xlsx", parts[1].filename.?);
    try std.testing.expectEqualStrings("PK\x03\x04FAKE", parts[1].data);
    try std.testing.expect(std.mem.indexOf(u8, parts[1].content_type, "spreadsheetml") != null);
}

test "multipart：boundary 带引号 / 非 multipart 报错" {
    try std.testing.expectEqualStrings("abc123", boundaryOf("multipart/form-data; boundary=\"abc123\"").?);
    try std.testing.expectEqualStrings("abc123", boundaryOf("multipart/form-data; boundary=abc123; charset=utf-8").?);
    try std.testing.expect(boundaryOf("application/json") == null);

    try std.testing.expectError(Error.NotMultipart, parseAlloc(std.testing.allocator, "application/json", "{}"));
}
