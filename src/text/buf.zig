//! 字符串缓冲小工具：统一用 `std.Io.Writer.Allocating` 做零碎拼接。
//!
//! 之所以不直接用 `std.ArrayList(u8)` + `std.fmt.allocPrint`：后者每段格式化都要一次
//! 临时分配；拼接 SQL、日志行、协议报文等热路径上，统一走可增长的 writer 更省。

const std = @import("std");

pub const Buf = struct {
    alloc: std.Io.Writer.Allocating,

    pub fn init(gpa: std.mem.Allocator) Buf {
        return .{ .alloc = .init(gpa) };
    }

    pub fn deinit(self: *Buf) void {
        self.alloc.deinit();
    }

    /// 追加原始字节。
    pub fn add(self: *Buf, bytes: []const u8) !void {
        try self.alloc.writer.writeAll(bytes);
    }

    /// 追加一个字节。
    pub fn addByte(self: *Buf, byte: u8) !void {
        try self.alloc.writer.writeByte(byte);
    }

    /// 格式化追加（`{s}`/`{d}`/`{f}` 等）。
    pub fn fmt(self: *Buf, comptime f: []const u8, args: anytype) !void {
        try self.alloc.writer.print(f, args);
    }

    /// 取走结果（调用方负责 free）。
    pub fn toOwnedSlice(self: *Buf) ![]u8 {
        return self.alloc.toOwnedSlice();
    }

    /// 已写入内容的切片（不转移所有权）。
    pub fn slice(self: *Buf) []const u8 {
        return self.alloc.written();
    }
};

test "Buf 基本拼接" {
    var b = Buf.init(std.testing.allocator);
    defer b.deinit();
    try b.add("SELECT ");
    try b.fmt("{d}", .{42});
    try b.add(" FROM t");
    try std.testing.expectEqualStrings("SELECT 42 FROM t", b.slice());
}
