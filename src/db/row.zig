//! 结果集行（各驱动共用）：列名 + 值。
//!
//! 不属于任何驱动，SQLite / MySQL 都返回同一个结构，上层（ORM/查询工具）只认它。
//! **不拥有内存**：`names` / `values` 里的文本与二进制都借用查询结果的 arena，
//! 生命周期由调用方保证（与 `Value` 的约定一致）。

const std = @import("std");
const Value = @import("value.zig").Value;

pub const Row = struct {
    names: []const []const u8 = &.{},
    values: []const Value = &.{},

    /// 按列名取值（ASCII 大小写不敏感，与 C#/Rust 侧一致）。
    pub fn get(self: Row, name: []const u8) ?Value {
        for (self.names, 0..) |n, i| {
            if (std.ascii.eqlIgnoreCase(n, name)) return self.values[i];
        }
        return null;
    }

    /// 按列序号取值（越界返回 null）。
    pub fn at(self: Row, index: usize) ?Value {
        if (index >= self.values.len) return null;
        return self.values[index];
    }
};

test "Row - 按名取值大小写不敏感" {
    const a = std.testing.allocator;
    var names = [_][]const u8{ "Id", "Name" };
    var values = [_]Value{ .{ .int = 1 }, .{ .text = "abc" } };
    const row = Row{ .names = &names, .values = &values };

    try std.testing.expectEqual(@as(i64, 1), row.get("id").?.int);
    try std.testing.expectEqualStrings("abc", row.get("NAME").?.text);
    try std.testing.expectEqual(@as(i64, 1), row.at(0).?.int);
    try std.testing.expect(row.get("nope") == null);
    try std.testing.expect(row.at(9) == null);
    _ = a;
}
