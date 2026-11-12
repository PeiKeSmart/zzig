//! 哈希小工具（十六进制输出 + 常量时间比较）。

const std = @import("std");

pub fn hexLower(out: []u8, bytes: []const u8) []u8 {
    const hex = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[i * 2] = hex[(b >> 4) & 0xF];
        out[i * 2 + 1] = hex[b & 0xF];
    }
    return out[0 .. bytes.len * 2];
}

pub fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    var out: [64]u8 = undefined;
    _ = hexLower(&out, &digest);
    return out;
}

/// 常量时间字符串比较（令牌/签名用；长度不同直接返回 false）。
pub fn constantTimeEql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    var diff: u8 = 0;
    for (a, b) |x, y| diff |= x ^ y;
    return diff == 0;
}

const testing = std.testing;

test "hash: sha256Hex 与常量时间比较" {
    try testing.expectEqualStrings(
        "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
        &sha256Hex(""),
    );
    try testing.expect(constantTimeEql("abcd", "abcd"));
    try testing.expect(!constantTimeEql("abcd", "abce"));
    try testing.expect(!constantTimeEql("ab", "abc"));
}
