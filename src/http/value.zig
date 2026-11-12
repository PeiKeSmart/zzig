//! Web 通用值模型（对齐 C# `object` 与 Razor `@Model.X` 的取值/文本化语义）。
//!
//! 为什么新增（先检索结论）：
//! - `zzig.json` 是 jsmn 词法 + 按 key 查询的流式工具（`JsonQuery.getString/getInt/getBool`，
//!   每次调用重新解析，不建值树），无法承载「视图模型 → 路径访问 → 渲染」；
//! - `zzig.xml` 是 XML DOM，与 JSON 模型不通用；
//! - 视图/控制器/参数绑定三处都需要同一套树结构，故单独收口在本文件（避免各模块各写一份）。
//!
//! 口径（对齐 C#）：
//! - 文本化：`bool` → `True`/`False`；整型无小数；`null` → 空串；
//! - 集合/对象文本化退化为 JSON（C# 会打印类型名，对页面无意义，这里取可用值）；
//! - 数字比较跨类型（`1` 与 `1.0` 相等），字符串 `==` 按字节比较；
//! - HTML 转义只处理 `& < > " '`（UTF-8 原样保留；不追求与 `HtmlEncoder.Default` 逐字节一致的
//!   全字符探测口径——那是 DH.RustBase 的 C# 互操作需求，本项目无此约束）。

const std = @import("std");

/// 对象字段（保序；视图模型字段通常很少，线性查找比哈希更省内存）。
pub const Field = struct {
    name: []const u8,
    value: Value,
};

/// 视图/动作通用值。
pub const Value = union(enum) {
    null,
    boolean: bool,
    integer: i64,
    number: f64,
    string: []const u8,
    list: []const Value,
    object: []const Field,

    /// 取对象字段（先精确、再忽略大小写；列表可按数字下标取）。
    pub fn get(self: Value, name: []const u8) ?Value {
        switch (self) {
            .object => |fields| {
                for (fields) |f| {
                    if (std.mem.eql(u8, f.name, name)) return f.value;
                }
                for (fields) |f| {
                    if (std.ascii.eqlIgnoreCase(f.name, name)) return f.value;
                }
                return null;
            },
            .list => |items| {
                const index = std.fmt.parseInt(usize, name, 10) catch return null;
                return if (index < items.len) items[index] else null;
            },
            else => return null,
        }
    }

    /// 按下标取列表元素。
    pub fn at(self: Value, index: usize) ?Value {
        switch (self) {
            .list => |items| return if (index < items.len) items[index] else null,
            else => return null,
        }
    }

    /// 是否为空值。
    pub fn isNull(self: Value) bool {
        return self == .null;
    }

    /// 列表长度（非列表为 0）。
    pub fn len(self: Value) usize {
        return switch (self) {
            .list => |items| items.len,
            .object => |fields| fields.len,
            .string => |text| text.len,
            else => 0,
        };
    }

    /// 取布尔（非布尔返回 `null`）。
    pub fn asBool(self: Value) ?bool {
        return switch (self) {
            .boolean => |b| b,
            else => null,
        };
    }

    /// 取整型（浮点取整；字符串按十进制解析）。
    pub fn asInt(self: Value) ?i64 {
        return switch (self) {
            .integer => |i| i,
            .number => |f| @intFromFloat(f),
            .boolean => |b| if (b) 1 else 0,
            .string => |s| std.fmt.parseInt(i64, std.mem.trim(u8, s, " \t\r\n"), 10) catch null,
            else => null,
        };
    }

    /// 取浮点。
    pub fn asFloat(self: Value) ?f64 {
        return switch (self) {
            .integer => |i| @floatFromInt(i),
            .number => |f| f,
            .string => |s| std.fmt.parseFloat(f64, std.mem.trim(u8, s, " \t\r\n")) catch null,
            else => null,
        };
    }

    /// 取字符串视图（非字符串返回 `null`；文本化请用 [`Value.textAlloc`]）。
    pub fn asString(self: Value) ?[]const u8 {
        return switch (self) {
            .string => |s| s,
            else => null,
        };
    }

    /// 文本化（对齐 C# `ToString()` 的可读子集）。**总是返回新分配**，调用方按分配器释放。
    pub fn textAlloc(self: Value, allocator: std.mem.Allocator) ![]const u8 {
        return switch (self) {
            .null => allocator.dupe(u8, ""),
            .boolean => |b| allocator.dupe(u8, if (b) "True" else "False"),
            .integer => |i| std.fmt.allocPrint(allocator, "{d}", .{i}),
            .number => |f| std.fmt.allocPrint(allocator, "{d}", .{f}),
            .string => |s| allocator.dupe(u8, s),
            .list, .object => self.jsonAlloc(allocator),
        };
    }

    /// 文本化 + HTML 转义（视图隐式输出的默认行为，防 XSS）。
    pub fn htmlAlloc(self: Value, allocator: std.mem.Allocator) ![]const u8 {
        const text = try self.textAlloc(allocator);
        defer allocator.free(text);
        return escapeHtmlAlloc(allocator, text);
    }

    /// 序列化为 JSON（对象/数组/标量通用；字符串按 JSON 规则转义）。
    pub fn jsonAlloc(self: Value, allocator: std.mem.Allocator) ![]const u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        try writeJson(self, &out.writer);
        return out.toOwnedSlice();
    }

    /// 从 JSON 文本解析（对象/数组/标量；深度上限 64）。
    pub fn parse(allocator: std.mem.Allocator, text: []const u8) ParseError!Value {
        var parser = JsonParser{ .src = text, .allocator = allocator };
        parser.skipSpace();
        const value = try parser.parseValue(0);
        parser.skipSpace();
        if (parser.pos != text.len) return error.InvalidJson;
        return value;
    }
};

/// JSON 解析错误。
pub const ParseError = error{ InvalidJson, OutOfMemory };

/// 构造：空值。
pub fn ofNull() Value {
    return .null;
}

/// 构造：布尔。
pub fn ofBool(value: bool) Value {
    return .{ .boolean = value };
}

/// 构造：整数。
pub fn ofInt(value: i64) Value {
    return .{ .integer = value };
}

/// 构造：浮点。
pub fn ofFloat(value: f64) Value {
    return .{ .number = value };
}

/// 构造：字符串（**不复制**，调用方保证生命周期；页面模型请用 [`ObjectBuilder`]）。
pub fn ofString(text: []const u8) Value {
    return .{ .string = text };
}

/// 构造：列表（**不复制**，调用方保证生命周期；页面模型请用 [`ObjectBuilder`]）。
pub fn ofList(items: []const Value) Value {
    return .{ .list = items };
}

/// 构造：对象（**不复制**，调用方保证生命周期；页面模型请用 [`ObjectBuilder`]）。
pub fn ofObject(fields: []const Field) Value {
    return .{ .object = fields };
}

/// 构造：字段。
pub fn field(name: []const u8, value: Value) Field {
    return .{ .name = name, .value = value };
}

/// arena 版字符串值（复制内容）。
pub fn strAlloc(arena: std.mem.Allocator, text: []const u8) !Value {
    return .{ .string = try arena.dupe(u8, text) };
}

/// arena 版列表值（复制元素数组；元素内部的字符串若来自栈，仍需自行 [`strAlloc`]）。
pub fn listAlloc(arena: std.mem.Allocator, items: []const Value) !Value {
    return .{ .list = try arena.dupe(Value, items) };
}

/// 页面模型构造器：**所有字段名与列表数组都复制进 arena**。
///
/// 为什么需要：动作函数返回后栈帧失效，而 `ofObject(&local_fields)` 这类写法会留下悬垂切片
/// （现象是页面输出空串或乱码数字）。用本构造器即可从结构上避免。
///
/// ```zig
/// var model = value.ObjectBuilder.init(c.arena);
/// try model.str("Title", "首页");
/// try model.put("Count", .{ .integer = 3 });
/// try model.list("Items", items.items);
/// return zzig.web.viewResult(model.finish());
/// ```
pub const ObjectBuilder = struct {
    arena: std.mem.Allocator,
    fields: std.ArrayList(Field) = .empty,

    /// 以请求 arena 创建。
    pub fn init(arena: std.mem.Allocator) ObjectBuilder {
        return .{ .arena = arena };
    }

    /// 写入字段（字段名复制进 arena）。
    pub fn put(self: *ObjectBuilder, name: []const u8, value: Value) !void {
        try self.fields.append(self.arena, .{ .name = try self.arena.dupe(u8, name), .value = value });
    }

    /// 写入字符串字段（内容复制进 arena）。
    pub fn str(self: *ObjectBuilder, name: []const u8, text: []const u8) !void {
        try self.put(name, .{ .string = try self.arena.dupe(u8, text) });
    }

    /// 写入整数字段。
    pub fn int(self: *ObjectBuilder, name: []const u8, number: i64) !void {
        try self.put(name, .{ .integer = number });
    }

    /// 写入布尔字段。
    pub fn boolean(self: *ObjectBuilder, name: []const u8, flag: bool) !void {
        try self.put(name, .{ .boolean = flag });
    }

    /// 写入列表字段（数组复制进 arena）。
    pub fn list(self: *ObjectBuilder, name: []const u8, items: []const Value) !void {
        try self.put(name, .{ .list = try self.arena.dupe(Value, items) });
    }

    /// 完成（返回的对象字段数组已由 arena 承载）。
    pub fn finish(self: *ObjectBuilder) Value {
        return .{ .object = self.fields.items };
    }
};

/// 值相等（跨 `integer`/`number` 数值比较；类型不同且不可比较时为 false）。
pub fn eql(a: Value, b: Value) bool {
    return switch (a) {
        .null => b == .null,
        .boolean => |x| switch (b) {
            .boolean => |y| x == y,
            else => false,
        },
        .integer, .number => switch (b) {
            .integer, .number => (a.asFloat() orelse return false) == (b.asFloat() orelse return false),
            else => false,
        },
        .string => |x| switch (b) {
            .string => |y| std.mem.eql(u8, x, y),
            else => false,
        },
        .list => |x| switch (b) {
            .list => |y| blk: {
                if (x.len != y.len) break :blk false;
                for (x, y) |xi, yi| {
                    if (!eql(xi, yi)) break :blk false;
                }
                break :blk true;
            },
            else => false,
        },
        .object => |x| switch (b) {
            .object => |y| blk: {
                if (x.len != y.len) break :blk false;
                for (x) |f| {
                    const other = b.get(f.name) orelse break :blk false;
                    if (!eql(f.value, other)) break :blk false;
                }
                break :blk true;
            },
            else => false,
        },
    };
}

/// 数值比较（两侧都能转浮点时返回值，否则 `null`）。
pub fn compare(a: Value, b: Value) ?std.math.Order {
    if (a == .string and b == .string) return std.mem.order(u8, a.string, b.string);
    const x: f64 = switch (a) {
        .integer => |i| @floatFromInt(i),
        .number => |f| f,
        else => return null,
    };
    const y: f64 = switch (b) {
        .integer => |i| @floatFromInt(i),
        .number => |f| f,
        else => return null,
    };
    return std.math.order(x, y);
}

/// HTML 转义（`& < > " '`）。
pub fn escapeHtmlAlloc(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeEscapedHtml(&out.writer, text);
    return out.toOwnedSlice();
}

/// 写入 HTML 转义文本。
pub fn writeEscapedHtml(writer: *std.Io.Writer, text: []const u8) !void {
    for (text) |c| switch (c) {
        '&' => try writer.writeAll("&amp;"),
        '<' => try writer.writeAll("&lt;"),
        '>' => try writer.writeAll("&gt;"),
        '"' => try writer.writeAll("&quot;"),
        '\'' => try writer.writeAll("&#39;"),
        else => try writer.writeByte(c),
    };
}

fn writeJson(value: Value, writer: *std.Io.Writer) !void {
    switch (value) {
        .null => try writer.writeAll("null"),
        .boolean => |b| try writer.writeAll(if (b) "true" else "false"),
        .integer => |i| try writer.print("{d}", .{i}),
        .number => |f| try writer.print("{d}", .{f}),
        .string => |s| try writeJsonString(writer, s),
        .list => |items| {
            try writer.writeByte('[');
            for (items, 0..) |item, index| {
                if (index > 0) try writer.writeByte(',');
                try writeJson(item, writer);
            }
            try writer.writeByte(']');
        },
        .object => |fields| {
            try writer.writeByte('{');
            for (fields, 0..) |f, index| {
                if (index > 0) try writer.writeByte(',');
                try writeJsonString(writer, f.name);
                try writer.writeByte(':');
                try writeJson(f.value, writer);
            }
            try writer.writeByte('}');
        },
    }
}

/// 写入 JSON 字符串（含转义）。
pub fn writeJsonString(writer: *std.Io.Writer, text: []const u8) !void {
    try writer.writeByte('"');
    for (text) |c| switch (c) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        0x08 => try writer.writeAll("\\b"),
        0x0C => try writer.writeAll("\\f"),
        else => {
            if (c < 0x20) {
                try writer.print("\\u{x:0>4}", .{c});
            } else {
                try writer.writeByte(c);
            }
        },
    };
    try writer.writeByte('"');
}

// ————— JSON 解析（最小实现：对象/数组/字符串/数字/布尔/null） —————

const JsonParser = struct {
    src: []const u8,
    pos: usize = 0,
    allocator: std.mem.Allocator,

    fn peek(self: *JsonParser) ?u8 {
        return if (self.pos < self.src.len) self.src[self.pos] else null;
    }

    fn skipSpace(self: *JsonParser) void {
        while (self.pos < self.src.len) : (self.pos += 1) {
            switch (self.src[self.pos]) {
                ' ', '\t', '\r', '\n' => {},
                else => return,
            }
        }
    }

    fn expect(self: *JsonParser, c: u8) ParseError!void {
        if (self.peek() != c) return error.InvalidJson;
        self.pos += 1;
    }

    fn parseValue(self: *JsonParser, depth: usize) ParseError!Value {
        if (depth > 64) return error.InvalidJson;
        self.skipSpace();
        const c = self.peek() orelse return error.InvalidJson;
        return switch (c) {
            '{' => self.parseObject(depth),
            '[' => self.parseArray(depth),
            '"' => .{ .string = try self.parseString() },
            't' => self.parseKeyword("true", ofBool(true)),
            'f' => self.parseKeyword("false", ofBool(false)),
            'n' => self.parseKeyword("null", ofNull()),
            '-', '0'...'9' => self.parseNumber(),
            else => error.InvalidJson,
        };
    }

    fn parseKeyword(self: *JsonParser, keyword: []const u8, value: Value) ParseError!Value {
        if (self.src.len < self.pos + keyword.len) return error.InvalidJson;
        if (!std.mem.eql(u8, self.src[self.pos .. self.pos + keyword.len], keyword)) return error.InvalidJson;
        self.pos += keyword.len;
        return value;
    }

    fn parseObject(self: *JsonParser, depth: usize) ParseError!Value {
        try self.expect('{');
        var fields: std.ArrayList(Field) = .empty;
        errdefer fields.deinit(self.allocator);

        self.skipSpace();
        if (self.peek() == '}') {
            self.pos += 1;
            return .{ .object = try fields.toOwnedSlice(self.allocator) };
        }

        while (true) {
            self.skipSpace();
            const name = try self.parseString();
            self.skipSpace();
            try self.expect(':');
            const value = try self.parseValue(depth + 1);
            try fields.append(self.allocator, .{ .name = name, .value = value });
            self.skipSpace();
            switch (self.peek() orelse return error.InvalidJson) {
                ',' => self.pos += 1,
                '}' => {
                    self.pos += 1;
                    return .{ .object = try fields.toOwnedSlice(self.allocator) };
                },
                else => return error.InvalidJson,
            }
        }
    }

    fn parseArray(self: *JsonParser, depth: usize) ParseError!Value {
        try self.expect('[');
        var items: std.ArrayList(Value) = .empty;
        errdefer items.deinit(self.allocator);

        self.skipSpace();
        if (self.peek() == ']') {
            self.pos += 1;
            return .{ .list = try items.toOwnedSlice(self.allocator) };
        }

        while (true) {
            const value = try self.parseValue(depth + 1);
            try items.append(self.allocator, value);
            self.skipSpace();
            switch (self.peek() orelse return error.InvalidJson) {
                ',' => self.pos += 1,
                ']' => {
                    self.pos += 1;
                    return .{ .list = try items.toOwnedSlice(self.allocator) };
                },
                else => return error.InvalidJson,
            }
        }
    }

    fn parseString(self: *JsonParser) ParseError![]const u8 {
        try self.expect('"');
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);

        while (true) {
            const c = self.peek() orelse return error.InvalidJson;
            self.pos += 1;
            switch (c) {
                '"' => return out.toOwnedSlice(self.allocator),
                '\\' => {
                    const esc = self.peek() orelse return error.InvalidJson;
                    self.pos += 1;
                    switch (esc) {
                        '"' => try out.append(self.allocator, '"'),
                        '\\' => try out.append(self.allocator, '\\'),
                        '/' => try out.append(self.allocator, '/'),
                        'b' => try out.append(self.allocator, 0x08),
                        'f' => try out.append(self.allocator, 0x0C),
                        'n' => try out.append(self.allocator, '\n'),
                        'r' => try out.append(self.allocator, '\r'),
                        't' => try out.append(self.allocator, '\t'),
                        'u' => {
                            const first = try self.parseHex4();
                            var codepoint: u21 = first;
                            if (first >= 0xD800 and first <= 0xDBFF) {
                                // 高代理：需要紧跟 `\uXXXX` 低代理
                                if (self.src.len < self.pos + 6) return error.InvalidJson;
                                if (self.src[self.pos] != '\\' or self.src[self.pos + 1] != 'u') return error.InvalidJson;
                                self.pos += 2;
                                const second = try self.parseHex4();
                                if (second < 0xDC00 or second > 0xDFFF) return error.InvalidJson;
                                codepoint = 0x10000 + (@as(u21, first - 0xD800) << 10) + (second - 0xDC00);
                            }
                            var buf: [4]u8 = undefined;
                            const size = std.unicode.utf8Encode(codepoint, &buf) catch return error.InvalidJson;
                            try out.appendSlice(self.allocator, buf[0..size]);
                        },
                        else => return error.InvalidJson,
                    }
                },
                else => try out.append(self.allocator, c),
            }
        }
    }

    fn parseHex4(self: *JsonParser) ParseError!u16 {
        if (self.src.len < self.pos + 4) return error.InvalidJson;
        var value: u16 = 0;
        for (self.src[self.pos .. self.pos + 4]) |c| {
            const digit: u16 = switch (c) {
                '0'...'9' => c - '0',
                'a'...'f' => c - 'a' + 10,
                'A'...'F' => c - 'A' + 10,
                else => return error.InvalidJson,
            };
            value = value * 16 + digit;
        }
        self.pos += 4;
        return value;
    }

    fn parseNumber(self: *JsonParser) ParseError!Value {
        const start = self.pos;
        if (self.peek() == '-') self.pos += 1;
        var is_float = false;
        while (self.pos < self.src.len) : (self.pos += 1) {
            switch (self.src[self.pos]) {
                '0'...'9' => {},
                '.', 'e', 'E', '+', '-' => is_float = true,
                else => break,
            }
        }
        if (self.pos == start) return error.InvalidJson;
        const text = self.src[start..self.pos];
        if (is_float) {
            const value = std.fmt.parseFloat(f64, text) catch return error.InvalidJson;
            return .{ .number = value };
        }
        const value = std.fmt.parseInt(i64, text, 10) catch {
            const fallback = std.fmt.parseFloat(f64, text) catch return error.InvalidJson;
            return .{ .number = fallback };
        };
        return .{ .integer = value };
    }
};

const testing = std.testing;

test "value：对象/列表路径取值（大小写宽容）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const model = try Value.parse(a,
        \\{"Title":"面板","Count":3,"Flag":true,"Items":[{"Name":"a"},{"Name":"b"}]}
    );
    try testing.expectEqualStrings("面板", model.get("Title").?.asString().?);
    try testing.expectEqualStrings("面板", model.get("title").?.asString().?);
    try testing.expectEqual(@as(i64, 3), model.get("Count").?.asInt().?);
    try testing.expect(model.get("Flag").?.asBool().?);
    try testing.expectEqualStrings("b", model.get("Items").?.at(1).?.get("Name").?.asString().?);
    try testing.expect(model.get("Missing") == null);
}

test "value：文本化对齐 C#（布尔 True/False、null 空串）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings("True", try ofBool(true).textAlloc(a));
    try testing.expectEqualStrings("False", try ofBool(false).textAlloc(a));
    try testing.expectEqualStrings("", try ofNull().textAlloc(a));
    try testing.expectEqualStrings("42", try ofInt(42).textAlloc(a));
    try testing.expectEqualStrings("1.5", try ofFloat(1.5).textAlloc(a));
}

test "value：HTML 转义" {
    const a = testing.allocator;
    const escaped = try escapeHtmlAlloc(a, "<b a=\"1\">'&</b>");
    defer a.free(escaped);
    try testing.expectEqualStrings("&lt;b a=&quot;1&quot;&gt;&#39;&amp;&lt;/b&gt;", escaped);
}

test "value：JSON 往返（含转义与嵌套）" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const source =
        \\{"a":"x\"y","b":[1,2.5,true,null],"c":{"d":"中\u6587"}}
    ;
    const value = try Value.parse(a, source);
    try testing.expectEqualStrings("x\"y", value.get("a").?.asString().?);
    try testing.expectEqual(@as(usize, 4), value.get("b").?.len());
    try testing.expect(value.get("b").?.at(1).?.asFloat().? == 2.5);
    try testing.expectEqualStrings("中文", value.get("c").?.get("d").?.asString().?);

    const round = try value.jsonAlloc(a);
    const again = try Value.parse(a, round);
    try testing.expect(eql(value, again));
}

test "value：数值跨类型相等" {
    try testing.expect(eql(ofInt(1), ofFloat(1.0)));
    try testing.expect(!eql(ofInt(1), ofString("1")));
    try testing.expect(eql(ofNull(), ofNull()));
}

test "value：ObjectBuilder 复制数据（动作返回后仍可渲染）" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var builder = ObjectBuilder.init(arena);
    {
        // 模拟动作函数里的栈上数据：离开作用域后仍应可用
        var local: [64]u8 = undefined;
        const text = try std.fmt.bufPrint(&local, "第 {d} 项", .{1});
        try builder.str("Title", text);

        var items: std.ArrayList(Value) = .empty;
        try items.append(arena, try strAlloc(arena, text));
        try items.append(arena, try strAlloc(arena, "第二项"));
        try builder.int("Count", @intCast(items.items.len));
        try builder.list("Items", items.items);
    }

    const model = builder.finish();
    try testing.expectEqualStrings("第 1 项", model.get("Title").?.asString().?);
    try testing.expectEqual(@as(i64, 2), model.get("Count").?.asInt().?);
    try testing.expectEqualStrings("第二项", model.get("Items").?.at(1).?.asString().?);
}
