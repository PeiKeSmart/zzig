//! GUID / UUID 生成（对应 C# `Guid.NewGuid()` 的常用形态）。
//!
//! 生成 **RFC 4122 version 4（随机）**的小写带连字符 36 位文本：`xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx`。
//!
//! 为什么放公共库而不是各项目各写一份：
//! - 以前只有 `SqlServer uniqueidentifier` 那种场景才用得到，现在 `DataType.Guid` 全仓都在用；
//! - 版本位/变体位写错（少写 `4` 或让变体落在 `0x0-0x7`）肉眼看不出来，但会让 GUID 在
//!   某些库/工具里被判为非法值 —— 这类细节只应该有一个实现。
//!
//! 随机源用 **CSPRNG**（`std.Random.IoSource`，底层是操作系统的安全随机）：
//! GUID 常被当作不可猜测的对外标识，用时间/计数器拼出来的会被预测。
//!
//! 注：Zig 0.17 已移除 `std.crypto.random`，统一走 `std.Random.IoSource`
//! （与 `zzig/random/randoms.zig` 同一口径）；需要可复现时用 `guidWithRandomAlloc` 注入随机源。

const std = @import("std");

/// 操作系统的安全随机源。
fn csprng() std.Random {
    const io_source = std.Random.IoSource{ .io = std.Io.Threaded.global_single_threaded.io() };
    return io_source.interface();
}

/// 生成 36 位小写 GUID 文本（调用方 free）。
pub fn guidAlloc(allocator: std.mem.Allocator) ![]u8 {
    return guidWithRandomAlloc(allocator, csprng());
}

/// 同 `guidAlloc`，但随机源由调用方给（测试/可复现场景用）。
pub fn guidWithRandomAlloc(allocator: std.mem.Allocator, rand: std.Random) ![]u8 {
    var bytes: [16]u8 = undefined;
    rand.bytes(&bytes);
    return formatAlloc(allocator, bytes);
}

/// 把 16 字节按 v4 规则写进文本缓冲（供批量场景复用缓冲，避免每条一次分配）。
///
/// 输入既可以是随机字节，也可以是自定义字节；version/variant 位会被**改写**成 v4 规范值。
pub fn guidInto(out: *[36]u8, bytes: [16]u8) []const u8 {
    var b = bytes;
    // version 4：第 7 字节高 4 位 = 0100
    b[6] = (b[6] & 0x0f) | 0x40;
    // variant RFC 4122：第 9 字节高 2 位 = 10
    b[8] = (b[8] & 0x3f) | 0x80;

    const hex = "0123456789abcdef";
    var pos: usize = 0;
    for (b, 0..) |byte, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            out[pos] = '-';
            pos += 1;
        }
        out[pos] = hex[byte >> 4];
        out[pos + 1] = hex[byte & 0x0f];
        pos += 2;
    }
    return out[0..36];
}

/// 同 `guidInto`，但结果用自己的 allocator 分配（调用方 free）。
pub fn formatAlloc(allocator: std.mem.Allocator, bytes: [16]u8) ![]u8 {
    var buf: [36]u8 = undefined;
    const text = guidInto(&buf, bytes);
    return allocator.dupe(u8, text);
}

/// 是否是「像样的」GUID 文本：36 位、位置 8/13/18/23 是 `-`、其余是十六进制（大小写都收）。
///
/// 用于校验外部传入的值（如配置文件、请求参数），不解析成 16 字节。
pub fn isValid(text: []const u8) bool {
    if (text.len != 36) return false;
    for (text, 0..) |c, i| {
        switch (i) {
            8, 13, 18, 23 => if (c != '-') return false,
            else => if (!std.ascii.isHex(c)) return false,
        }
    }
    return true;
}

test "GUID v4：36 位、连字符位置、version 4、variant 合法" {
    const a = std.testing.allocator;
    const g = try guidAlloc(a);
    defer a.free(g);

    try std.testing.expectEqual(@as(usize, 36), g.len);
    try std.testing.expect(isValid(g));
    // 小写
    for (g) |c| try std.testing.expect(!std.ascii.isUpper(c));
    // version 位：第 15 个字符（首个 group 后的第一位）必须是 '4'
    try std.testing.expectEqual(@as(u8, '4'), g[14]);
    // variant 位：第 20 个字符 ∈ {8,9,a,b}
    try std.testing.expect(std.mem.indexOfScalar(u8, "89ab", g[19]) != null);
}

test "GUID v4：即使输入字节的 version/variant 位是脏的，也会被改写成规范值" {
    var buf: [36]u8 = undefined;
    const text = guidInto(&buf, @splat(0xff));
    try std.testing.expectEqualStrings("ffffffff-ffff-4fff-bfff-ffffffffffff", text);
    try std.testing.expect(isValid(text));
}

test "GUID：两次生成不重复；非法文本校验" {
    const a = std.testing.allocator;
    const g1 = try guidAlloc(a);
    defer a.free(g1);
    const g2 = try guidAlloc(a);
    defer a.free(g2);
    try std.testing.expect(!std.mem.eql(u8, g1, g2));

    try std.testing.expect(!isValid(""));
    try std.testing.expect(!isValid("not-a-guid"));
    try std.testing.expect(!isValid("ffffffff-ffff-4fff-bfff-fffffffffff")); // 35 位
    try std.testing.expect(isValid("FFFFFFFF-FFFF-4FFF-BFFF-FFFFFFFFFFFF")); // 大写也认
}
