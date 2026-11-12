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
