const std = @import("std");

/// 生成一个随机字符。
///
/// 返回:
/// - 随机生成的字符。
fn RandomChar() u8 {
    const rand = std.crypto.random;
    const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
    return chars[rand.int(u32) % chars.len];
}

/// 生成一个随机字符串。
///
/// 参数:
/// - allocator: 用于分配内存的分配器。
/// - n: 要生成的字符串的长度。
///
/// 返回:
/// - 随机生成的字符串。
pub fn RandomString(allocator: std.mem.Allocator, n: usize) ![]u8 {
    var result = try allocator.alloc(u8, n); // 申请内存分配

    var i: usize = 0;
    while (i < n) : (i += 1) {
        result[i] = RandomChar();
    }

    return result;
}
