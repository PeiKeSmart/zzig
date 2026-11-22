//! TOML 模板渲染（带注释）—— 让程序生成的配置文件自带逐字段说明。
//!
//! 为什么需要它：Zig 运行期**拿不到** `///` 文档注释（`std.builtin.Type.StructField`
//! 只有 `name` / `type` / `default_value_ptr` / `is_comptime` / `alignment`，没有 doc），
//! 所以做不到 Rust `toml_edit` + derive 那种「写注释即得注释」。可行且更好的做法是
//! **声明表驱动**：注释与键值写在同一条记录里，由本模块统一渲染，从而
//!   - 新增字段时「忘写注释」一眼可见（同一条字面量里 doc 空着很突兀）；
//!   - `# ` 前缀、分组空行、列表格式、字符串转义全项目一致，不用各写一遍。
//!
//! 用法：
//! ```zig
//! const t = zzig.config.toml_template;
//! const items = [_]t.Item{
//!     .{ .key = "enable", .doc = &.{"总开关（false = 旁路）"}, .value = .{ .boolean = true } },
//!     .{ .key = "mode", .doc = &.{ "运行模式", "adminApi | publicSite" }, .value = .{ .string = "adminApi" } },
//!     .{ .key = "sensitivePrefixes", .value = .{ .string_list = &.{"/admin"} } },
//! };
//! const text = try t.render(a, .{ .header = &.{"Pek.XYZ 配置"} }, &items);
//! ```
//!
//! 只负责**生成**（首次落盘 / 面板导出），不做解析；解析见 `zzig.config.toml`。

const std = @import("std");

/// 一个 TOML 值（渲染成合法 TOML 字面量）。
pub const Value = union(enum) {
    boolean: bool,
    integer: i64,
    float: f64,
    /// 字符串（自动加引号并转义 `"` `\` 与控制字符）
    string: []const u8,
    /// 字符串数组（元素自动加引号并转义）
    string_list: []const []const u8,
    /// 原样输出：调用方自行保证是合法 TOML 值文本（如 `[]`、内联表）
    raw: []const u8,
};

/// 一条配置项。
pub const Item = struct {
    /// 键名（原样输出，不做大小写转换）
    key: []const u8,
    /// 注释（每行一个元素，渲染时自动加 `# `；空元素渲染成单独一个 `#`）
    doc: []const []const u8 = &.{},
    value: Value,
    /// 是否在本条之前输出空行（`null` = 有注释就空行，没注释就紧跟上一行）
    blank_before: ?bool = null,
};

/// 渲染选项。
pub const Options = struct {
    /// 文件头注释（每行一个元素）
    header: []const []const u8 = &.{},
    /// 头部之后是否输出空行
    blank_after_header: bool = true,
    /// 同一 `key` 出现多次时是否允许（默认允许：TOML 里后出现的坏值会覆盖，但模板不该依赖它）
    trailing_newline: bool = true,
};

/// 把声明表渲染成 TOML 文本（调用方负责 `free`）。
pub fn render(a: std.mem.Allocator, opts: Options, items: []const Item) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);

    if (opts.header.len > 0) {
        try writeComment(&out, a, opts.header);
        if (opts.blank_after_header) try out.append(a, '\n');
    }

    for (items, 0..) |item, i| {
        const want_blank = item.blank_before orelse (item.doc.len > 0);
        if (want_blank and (i > 0 or opts.header.len > 0 and !opts.blank_after_header)) {
            try out.append(a, '\n');
        }
        try writeComment(&out, a, item.doc);
        try out.appendSlice(a, item.key);
        try out.appendSlice(a, " = ");
        try writeValue(&out, a, item.value);
        try out.append(a, '\n');
    }

    if (opts.trailing_newline and out.items.len > 0 and out.items[out.items.len - 1] != '\n') {
        try out.append(a, '\n');
    }
    return out.toOwnedSlice(a);
}

/// 渲染一组注释行（每行自动 `# ` 前缀；空串 → 单个 `#`，即空注释行）。
pub fn writeComment(out: *std.ArrayList(u8), a: std.mem.Allocator, doc: []const []const u8) !void {
    for (doc) |line| {
        const text = std.mem.trimEnd(u8, line, " \t");
        if (text.len == 0) {
            try out.appendSlice(a, "#\n");
        } else {
            try out.appendSlice(a, "# ");
            try out.appendSlice(a, text);
            try out.append(a, '\n');
        }
    }
}

/// 渲染一个值。
pub fn writeValue(out: *std.ArrayList(u8), a: std.mem.Allocator, value: Value) !void {
    switch (value) {
        .boolean => |b| try out.appendSlice(a, if (b) "true" else "false"),
        .integer => |n| try out.print(a, "{d}", .{n}),
        .float => |f| try out.print(a, "{d}", .{f}),
        .string => |s| try writeString(out, a, s),
        .string_list => |list| {
            try out.append(a, '[');
            for (list, 0..) |s, i| {
                if (i > 0) try out.appendSlice(a, ", ");
                try writeString(out, a, s);
            }
            try out.append(a, ']');
        },
        .raw => |text| try out.appendSlice(a, text),
    }
}

/// 写一个带引号且转义的 TOML 字符串。
///
/// 必须转义：`"`（提前结束）、`\`（变成转义序列）；控制字符（< 0x20）用 `\u00XX`。
/// 不转义就会出现「值里带一个反斜杠，整份配置解析失败」这类最难查的问题。
pub fn writeString(out: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) !void {
    try out.append(a, '"');
    for (s) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(a, "\\\""),
            '\\' => try out.appendSlice(a, "\\\\"),
            '\n' => try out.appendSlice(a, "\\n"),
            '\r' => try out.appendSlice(a, "\\r"),
            '\t' => try out.appendSlice(a, "\\t"),
            else => {
                if (ch < 0x20) {
                    try out.print(a, "\\u{X:0>4}", .{ch});
                } else {
                    try out.append(a, ch);
                }
            },
        }
    }
    try out.append(a, '"');
}

/// 便捷构造：布尔项。
pub fn boolItem(key: []const u8, doc: []const []const u8, v: bool) Item {
    return .{ .key = key, .doc = doc, .value = .{ .boolean = v } };
}

/// 便捷构造：整数项。
pub fn intItem(key: []const u8, doc: []const []const u8, v: i64) Item {
    return .{ .key = key, .doc = doc, .value = .{ .integer = v } };
}

/// 便捷构造：字符串项。
pub fn strItem(key: []const u8, doc: []const []const u8, v: []const u8) Item {
    return .{ .key = key, .doc = doc, .value = .{ .string = v } };
}

/// 便捷构造：字符串数组项。
pub fn listItem(key: []const u8, doc: []const []const u8, v: []const []const u8) Item {
    return .{ .key = key, .doc = doc, .value = .{ .string_list = v } };
}

test "渲染：注释 + 分组空行 + 各类值" {
    const a = std.testing.allocator;
    const items = [_]Item{
        .{ .key = "enable", .doc = &.{"总开关"}, .value = .{ .boolean = true } },
        .{ .key = "mode", .doc = &.{ "运行模式", "adminApi | publicSite" }, .value = .{ .string = "adminApi" } },
        listItem("skip", &.{"跳过前缀"}, &.{ "/api", "/pek" }),
        intItem("limit", &.{}, 300),
    };
    const text = try render(a, .{ .header = &.{ "Pek.X 配置", "第二行" } }, &items);
    defer a.free(text);

    try std.testing.expectEqualStrings(
        \\# Pek.X 配置
        \\# 第二行
        \\
        \\# 总开关
        \\enable = true
        \\
        \\# 运行模式
        \\# adminApi | publicSite
        \\mode = "adminApi"
        \\
        \\# 跳过前缀
        \\skip = ["/api", "/pek"]
        \\limit = 300
        \\
    , text);
}

test "渲染：字符串转义" {
    const a = std.testing.allocator;
    const items = [_]Item{
        .{ .key = "path", .value = .{ .string = "C:\\Data\\x\"y" } },
        .{ .key = "ctrl", .value = .{ .string = "a\x01b" } },
    };
    const text = try render(a, .{}, &items);
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"C:\\\\Data\\\\x\\\"y\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\\u0001") != null);
}

test "渲染：空注释行与 raw 值" {
    const a = std.testing.allocator;
    const items = [_]Item{
        .{ .key = "empty", .value = .{ .raw = "[]" } },
        .{ .key = "docs", .doc = &.{ "", "下一行" }, .value = .{ .raw = "[]" }, .blank_before = true },
    };
    const text = try render(a, .{}, &items);
    defer a.free(text);
    try std.testing.expectEqualStrings(
        \\empty = []
        \\
        \\#
        \\# 下一行
        \\docs = []
        \\
    , text);
}
