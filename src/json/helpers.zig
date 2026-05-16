const std = @import("std");

pub fn unescapeJsonStringAlloc(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try out.ensureTotalCapacityPrecise(allocator, s.len);

    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 5 < s.len and s[i + 1] == 'u') {
            const value =
                (hexVal(s[i + 2]) << 12) |
                (hexVal(s[i + 3]) << 8) |
                (hexVal(s[i + 4]) << 4) |
                hexVal(s[i + 5]);
            const codepoint: u21 = @intCast(value);

            if (codepoint <= 0x7F) {
                try out.append(allocator, @as(u8, @intCast(codepoint)));
            } else if (codepoint <= 0x7FF) {
                try out.append(allocator, 0xC0 | @as(u8, @intCast((codepoint >> 6) & 0x1F)));
                try out.append(allocator, 0x80 | @as(u8, @intCast(codepoint & 0x3F)));
            } else {
                try out.append(allocator, 0xE0 | @as(u8, @intCast((codepoint >> 12) & 0x0F)));
                try out.append(allocator, 0x80 | @as(u8, @intCast((codepoint >> 6) & 0x3F)));
                try out.append(allocator, 0x80 | @as(u8, @intCast(codepoint & 0x3F)));
            }

            i += 5;
        } else {
            try out.append(allocator, s[i]);
        }
    }

    return out.toOwnedSlice(allocator);
}

fn hexVal(c: u8) u21 {
    return switch (c) {
        '0'...'9' => @as(u21, c - '0'),
        'a'...'f' => @as(u21, 10 + c - 'a'),
        'A'...'F' => @as(u21, 10 + c - 'A'),
        else => 0,
    };
}