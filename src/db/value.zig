//! 通用数据库值模型：字段值的运行时表示（对应 .NET 的 `Object` 字段值与 `DbType` 转换）。
//!
//! 与 ORM 无关，任何需要“读库 → 统一值 → 映射到语言类型”的场景都可直接用：
//! - **不拥有内存**：`text` / `blob` 是借用切片，生命周期由调用方（通常是查询结果 arena）保证；
//! - `decimal` / `datetime` 是值类型，按需转文本（XCode/ISO 风格 7 位小数秒）；
//! - 不做“列类型 → 标准值”的规整，那是 ORM 层按模型列类型做的事。

const std = @import("std");
const Decimal = @import("../number/decimal.zig").Decimal;
const DateTime = @import("../time/datetime.zig").DateTime;

pub const Value = union(enum) {
    null,
    boolean: bool,
    int: i64,
    float: f64,
    decimal: Decimal,
    text: []const u8,
    blob: []const u8,
    datetime: DateTime,

    pub fn isNull(self: Value) bool {
        return self == .null;
    }

    /// 转整数（数值直接转换，文本尝试解析）。
    pub fn asI64(self: Value) ?i64 {
        return switch (self) {
            .boolean => |v| if (v) 1 else 0,
            .int => |v| v,
            .float => |v| @intFromFloat(v),
            .decimal => |v| v.toI64(),
            .text => |v| std.fmt.parseInt(i64, std.mem.trim(u8, v, " \t\r\n"), 10) catch null,
            else => null,
        };
    }

    pub fn asI32(self: Value) ?i32 {
        const v = self.asI64() orelse return null;
        if (v > std.math.maxInt(i32) or v < std.math.minInt(i32)) return null;
        return @intCast(v);
    }

    pub fn asI16(self: Value) ?i16 {
        const v = self.asI64() orelse return null;
        if (v > std.math.maxInt(i16) or v < std.math.minInt(i16)) return null;
        return @intCast(v);
    }

    pub fn asU8(self: Value) ?u8 {
        const v = self.asI64() orelse return null;
        if (v < 0 or v > std.math.maxInt(u8)) return null;
        return @intCast(v);
    }

    pub fn asF64(self: Value) ?f64 {
        return switch (self) {
            .boolean => |v| if (v) 1.0 else 0.0,
            .int => |v| @floatFromInt(v),
            .float => |v| v,
            .decimal => |v| v.toF64(),
            .text => |v| std.fmt.parseFloat(f64, std.mem.trim(u8, v, " \t\r\n")) catch null,
            else => null,
        };
    }

    pub fn asF32(self: Value) ?f32 {
        const v = self.asF64() orelse return null;
        return @floatCast(v);
    }

    /// 转布尔（0/1、true/false、yes/no、y/n 均可）。
    pub fn asBool(self: Value) ?bool {
        return switch (self) {
            .boolean => |v| v,
            .int => |v| v != 0,
            .float => |v| v != 0.0,
            .text => |v| blk: {
                const t = std.mem.trim(u8, v, " \t\r\n");
                if (std.ascii.eqlIgnoreCase(t, "1") or std.ascii.eqlIgnoreCase(t, "true") or
                    std.ascii.eqlIgnoreCase(t, "yes") or std.ascii.eqlIgnoreCase(t, "y")) break :blk true;
                if (std.ascii.eqlIgnoreCase(t, "0") or std.ascii.eqlIgnoreCase(t, "false") or
                    std.ascii.eqlIgnoreCase(t, "no") or std.ascii.eqlIgnoreCase(t, "n")) break :blk false;
                break :blk null;
            },
            else => null,
        };
    }

    /// 转十进制（文本按原样解析，保持精度）。
    pub fn asDecimal(self: Value) ?Decimal {
        return switch (self) {
            .decimal => |v| v,
            .int => |v| Decimal{ .mantissa = v, .scale = 0 },
            .float => |v| blk: {
                var buf: [64]u8 = undefined;
                const text = std.fmt.bufPrint(&buf, "{d}", .{v}) catch break :blk null;
                break :blk Decimal.parse(text) catch null;
            },
            .boolean => |v| Decimal{ .mantissa = if (v) 1 else 0, .scale = 0 },
            .text => |v| Decimal.parse(v) catch null,
            else => null,
        };
    }

    /// 转时间（DateTime 直接返回；文本按 XCode 格式解析）。
    pub fn asDatetime(self: Value) ?DateTime {
        return switch (self) {
            .datetime => |v| v,
            .text => |v| DateTime.parse(v) catch null,
            else => null,
        };
    }

    /// 文本引用（仅 `text` 直接可用）。
    pub fn asText(self: Value) ?[]const u8 {
        return switch (self) {
            .text => |v| v,
            else => null,
        };
    }

    /// 二进制引用。
    pub fn asBlob(self: Value) ?[]const u8 {
        return switch (self) {
            .blob => |v| v,
            else => null,
        };
    }

    /// 转文本（日志/展示用；Null 输出空串）。
    pub fn toTextAlloc(self: Value, gpa: std.mem.Allocator) ![]u8 {
        return switch (self) {
            .null => gpa.dupe(u8, ""),
            .boolean => |v| gpa.dupe(u8, if (v) "1" else "0"),
            .int => |v| std.fmt.allocPrint(gpa, "{d}", .{v}),
            .float => |v| std.fmt.allocPrint(gpa, "{d}", .{v}),
            .decimal => |v| v.formatAlloc(gpa),
            .text => |v| gpa.dupe(u8, v),
            .blob => |v| std.fmt.allocPrint(gpa, "[blob {d} 字节]", .{v.len}),
            .datetime => |v| v.formatAlloc(gpa),
        };
    }

    /// 渲染为 SQL 字面量（仅用于 `DEFAULT` 等无法参数化的场景；业务查询一律参数绑定）。
    pub fn toSqlLiteralAlloc(self: Value, gpa: std.mem.Allocator) ![]u8 {
        return switch (self) {
            .null => gpa.dupe(u8, "NULL"),
            .boolean => |v| gpa.dupe(u8, if (v) "1" else "0"),
            .int => |v| std.fmt.allocPrint(gpa, "{d}", .{v}),
            .float => |v| std.fmt.allocPrint(gpa, "{d}", .{v}),
            .decimal => |v| v.formatAlloc(gpa),
            .text => |v| {
                var buf: std.ArrayList(u8) = .empty;
                errdefer buf.deinit(gpa);
                try buf.append(gpa, '\'');
                for (v) |c| {
                    if (c == '\'') try buf.append(gpa, '\'');
                    try buf.append(gpa, c);
                }
                try buf.append(gpa, '\'');
                return buf.toOwnedSlice(gpa);
            },
            .blob => |v| {
                var buf: std.ArrayList(u8) = .empty;
                errdefer buf.deinit(gpa);
                try buf.appendSlice(gpa, "X'");
                for (v) |byte| {
                    var tmp: [2]u8 = undefined;
                    _ = std.fmt.bufPrint(&tmp, "{X:0>2}", .{byte}) catch unreachable;
                    try buf.appendSlice(gpa, &tmp);
                }
                try buf.append(gpa, '\'');
                return buf.toOwnedSlice(gpa);
            },
            .datetime => |v| {
                const text = try v.formatAlloc(gpa);
                defer gpa.free(text);
                return std.fmt.allocPrint(gpa, "'{s}'", .{text});
            },
        };
    }
};

test "跨类型取值" {
    try std.testing.expectEqual(@as(?i64, 42), (Value{ .int = 42 }).asI64());
    try std.testing.expectEqual(@as(?i64, 42), (Value{ .text = "42" }).asI64());
    try std.testing.expectEqual(@as(?bool, true), (Value{ .boolean = true }).asBool());
    try std.testing.expectEqual(@as(?bool, true), (Value{ .int = 1 }).asBool());
    try std.testing.expectEqual(@as(?bool, true), (Value{ .text = "yes" }).asBool());
    try std.testing.expectEqual(@as(?f64, 1.5), (Value{ .float = 1.5 }).asF64());
    try std.testing.expect((Value{ .null = {} }).asI64() == null);
}

test "十进制保持精度" {
    const v = Value{ .text = "1234567890.123456789" };
    const d = v.asDecimal().?;
    const s = try d.formatAlloc(std.testing.allocator);
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("1234567890.123456789", s);
}

test "SQL 字面量渲染" {
    const lit = try (Value{ .text = "O'Reilly" }).toSqlLiteralAlloc(std.testing.allocator);
    defer std.testing.allocator.free(lit);
    try std.testing.expectEqualStrings("'O''Reilly'", lit);

    const blob = try (Value{ .blob = &[_]u8{ 0x01, 0xAB } }).toSqlLiteralAlloc(std.testing.allocator);
    defer std.testing.allocator.free(blob);
    try std.testing.expectEqualStrings("X'01AB'", blob);

    const nul = try (Value{ .null = {} }).toSqlLiteralAlloc(std.testing.allocator);
    defer std.testing.allocator.free(nul);
    try std.testing.expectEqualStrings("NULL", nul);
}

test "时间值文本化走 XCode 格式" {
    const dt = try DateTime.parse("2026-09-26 18:01:02.1230000");
    const v = Value{ .datetime = dt };
    const s = try v.toTextAlloc(std.testing.allocator);
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings("2026-09-26 18:01:02.1230000", s);
}
