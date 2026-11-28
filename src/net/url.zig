//! URL 查询串编解码（表单/接口通用）。
//! 各项目此前各写一份 `percentEncode`/`queryRaw`，这里统一。

const std = @import("std");

pub fn encode(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    const hex = "0123456789ABCDEF";
    for (s) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => try out.append(allocator, c),
        else => {
            try out.append(allocator, '%');
            try out.append(allocator, hex[(c >> 4) & 0xF]);
            try out.append(allocator, hex[c & 0xF]);
        },
    };
    return out.toOwnedSlice(allocator);
}

pub fn decode(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, s.len);

    var i: usize = 0;
    while (i < s.len) {
        const c = s[i];
        if (c == '+') {
            try out.append(allocator, ' ');
            i += 1;
            continue;
        }
        if (c == '%') {
            if (i + 2 >= s.len) return error.InvalidUrlEncoding;
            const hi = std.fmt.charToDigit(s[i + 1], 16) catch return error.InvalidUrlEncoding;
            const lo = std.fmt.charToDigit(s[i + 2], 16) catch return error.InvalidUrlEncoding;
            try out.append(allocator, (hi << 4) | lo);
            i += 3;
            continue;
        }
        try out.append(allocator, c);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

/// 取查询串中的原始值（未解码）。
pub fn queryRaw(query: []const u8, key: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], key)) return pair[eq + 1 ..];
    }
    return null;
}

/// 取 `scheme://host[:port]` 这一段（**原样切片，不分配**）；不是 http/https 绝对地址就返回 `null`。
///
/// 用途：CSP 里只写 origin（`connect-src https://api.example.com`），
/// 以及「把配置里的探测地址收敛成同源白名单」这类场景。
pub fn origin(text: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const scheme_len: usize = if (std.ascii.startsWithIgnoreCase(trimmed, "https://"))
        8
    else if (std.ascii.startsWithIgnoreCase(trimmed, "http://"))
        7
    else
        return null;
    const rest = trimmed[scheme_len..];
    var end: usize = rest.len;
    for (rest, 0..) |ch, i| {
        if (ch == '/' or ch == '?' or ch == '#' or ch == ' ' or ch == ';') {
            end = i;
            break;
        }
    }
    if (end == 0) return null;
    return trimmed[0 .. scheme_len + end];
}

const testing = std.testing;

test "url: 编解码往返" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const raw = "中文 目录/a+b&c.txt";
    const enc = try encode(a, raw);
    try testing.expect(std.mem.indexOfScalar(u8, enc, '%') != null);
    try testing.expectEqualStrings(raw, try decode(a, enc));
}

test "url: queryRaw" {
    try testing.expectEqualStrings("x%2Fy", queryRaw("a=1&p=x%2Fy&z=2", "p").?);
    try testing.expect(queryRaw("a=1", "p") == null);
}

test "url: origin 只取 scheme://host[:port]，非绝对地址返回 null" {
    try testing.expectEqualStrings("https://a.example.com", origin("https://a.example.com/x?y=1").?);
    try testing.expectEqualStrings("http://127.0.0.1:18090", origin("  http://127.0.0.1:18090/ipv4  ").?);
    // 大小写**原样保留**（切片不分配）；CSP 的 scheme/host 本就大小写不敏感
    try testing.expectEqualStrings("HTTPS://a.example.com", origin("HTTPS://a.example.com").?);
    try testing.expect(origin("/relative/path") == null);
    try testing.expect(origin("https://") == null);
}
