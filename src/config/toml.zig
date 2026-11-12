//! TOML 子集：解析为通用表 + 反射解码到结构体。
//!
//! 只覆盖配置场景需要的语法（不做完整 TOML 规范）：
//! - `#` 注释、`key = value`、点号键 `a.b = 1`；
//! - 字符串（`"..."` 转义 / `'...'` 原样）、整数、布尔、数组（可嵌套）；
//! - `[table]` 与 `[[array-of-tables]]`；
//! - 解码时忽略未知键，结构体缺省字段用默认值。
//!
//! 用途：需要运维手写注释的配置（对齐 DH.RustBase 的 TomlConfig 思路）。

const std = @import("std");

pub const Value = union(enum) {
    string: []const u8,
    integer: i64,
    boolean: bool,
    array: []Value,
    table: *Table,
};

pub const Table = std.StringHashMapUnmanaged(Value);

pub const Error = error{ InvalidToml, OutOfMemory };

pub fn parse(allocator: std.mem.Allocator, text: []const u8) Error!*Table {
    var p = Parser{ .a = allocator, .s = text };
    return p.parseRoot();
}

pub fn decode(comptime T: type, allocator: std.mem.Allocator, table: *Table) !T {
    return decodeValue(T, allocator, .{ .table = table });
}

fn decodeValue(comptime T: type, a: std.mem.Allocator, v: Value) !T {
    return switch (@typeInfo(T)) {
        .bool => v.boolean,
        .int => @intCast(v.integer),
        .@"struct" => blk: {
            const info = @typeInfo(T).@"struct";
            const t = v.table;
            var out: T = .{};
            inline for (info.field_names, info.field_types) |name, FT| {
                if (t.get(name)) |fv| {
                    @field(out, name) = try decodeValue(FT, a, fv);
                }
            }
            break :blk out;
        },
        .pointer => |p| blk: {
            if (p.size != .slice) @compileError("TOML 只支持切片字段");
            const C = p.child;
            if (C == u8) break :blk v.string;
            if (v != .array) return error.InvalidToml;
            const out = try a.alloc(C, v.array.len);
            for (v.array, 0..) |item, i| out[i] = try decodeValue(C, a, item);
            break :blk out;
        },
        else => @compileError("TOML 不支持的类型: " ++ @typeName(T)),
    };
}

const Parser = struct {
    a: std.mem.Allocator,
    s: []const u8,
    i: usize = 0,
    line: usize = 1,

    fn parseRoot(self: *Parser) Error!*Table {
        const root = try self.newTable();
        var current = root;

        while (true) {
            self.skipBlankAndComments();
            if (self.i >= self.s.len) break;

            if (self.s[self.i] == '[') {
                current = try self.parseHeader(root);
            } else {
                try self.parseKeyValue(current);
            }
        }
        return root;
    }

    fn newTable(self: *Parser) Error!*Table {
        const t = try self.a.create(Table);
        t.* = .empty;
        return t;
    }

    fn skipBlankAndComments(self: *Parser) void {
        while (self.i < self.s.len) {
            const c = self.s[self.i];
            if (c == ' ' or c == '\t' or c == '\r') {
                self.i += 1;
            } else if (c == '\n') {
                self.i += 1;
                self.line += 1;
            } else if (c == '#') {
                while (self.i < self.s.len and self.s[self.i] != '\n') self.i += 1;
            } else break;
        }
    }

    fn skipInlineSpace(self: *Parser) void {
        while (self.i < self.s.len and (self.s[self.i] == ' ' or self.s[self.i] == '\t' or self.s[self.i] == '\r')) self.i += 1;
    }

    fn parseHeader(self: *Parser, root: *Table) Error!*Table {
        const is_array = std.mem.startsWith(u8, self.s[self.i..], "[[");
        self.i += if (is_array) 2 else 1;

        var segs: [32][]const u8 = undefined;
        const n = try self.parseKeyPath(&segs);
        self.skipInlineSpace();
        const close = if (is_array) "]]" else "]";
        if (!std.mem.startsWith(u8, self.s[self.i..], close)) return error.InvalidToml;
        self.i += close.len;

        if (!is_array) {
            return self.descend(root, segs[0..n]);
        }

        const parent = if (n > 1) try self.descend(root, segs[0 .. n - 1]) else root;
        const key = segs[n - 1];
        const t = try self.newTable();
        if (parent.getPtr(key)) |slot| {
            if (slot.* != .array) return error.InvalidToml;
            const old = slot.array;
            const grown = try self.a.alloc(Value, old.len + 1);
            @memcpy(grown[0..old.len], old);
            grown[old.len] = .{ .table = t };
            slot.* = .{ .array = grown };
        } else {
            const arr = try self.a.alloc(Value, 1);
            arr[0] = .{ .table = t };
            try parent.put(self.a, key, .{ .array = arr });
        }
        return t;
    }

    fn descend(self: *Parser, root: *Table, segs: []const []const u8) Error!*Table {
        var cur = root;
        for (segs) |seg| {
            if (cur.getPtr(seg)) |slot| {
                switch (slot.*) {
                    .table => |t| cur = t,
                    .array => |arr| {
                        if (arr.len == 0) return error.InvalidToml;
                        cur = arr[arr.len - 1].table;
                    },
                    else => return error.InvalidToml,
                }
            } else {
                const t = try self.newTable();
                try cur.put(self.a, seg, .{ .table = t });
                cur = t;
            }
        }
        return cur;
    }

    fn parseKeyValue(self: *Parser, table: *Table) Error!void {
        var segs: [32][]const u8 = undefined;
        const n = try self.parseKeyPath(&segs);
        self.skipInlineSpace();
        if (self.i >= self.s.len or self.s[self.i] != '=') return error.InvalidToml;
        self.i += 1;
        self.skipInlineSpace();

        const v = try self.parseValue();
        self.skipInlineSpace();
        if (self.i < self.s.len and self.s[self.i] == '#') {
            while (self.i < self.s.len and self.s[self.i] != '\n') self.i += 1;
        }
        if (self.i < self.s.len and self.s[self.i] != '\n') return error.InvalidToml;

        const target = if (n > 1) try self.descend(table, segs[0 .. n - 1]) else table;
        try target.put(self.a, segs[n - 1], v);
    }

    fn parseKeyPath(self: *Parser, out: *[32][]const u8) Error!usize {
        var n: usize = 0;
        while (true) {
            self.skipInlineSpace();
            if (n >= out.len) return error.InvalidToml;
            out[n] = try self.parseKey();
            n += 1;
            self.skipInlineSpace();
            if (self.i < self.s.len and self.s[self.i] == '.') {
                self.i += 1;
                continue;
            }
            break;
        }
        return n;
    }

    fn parseKey(self: *Parser) Error![]const u8 {
        if (self.i >= self.s.len) return error.InvalidToml;
        if (self.s[self.i] == '"' or self.s[self.i] == '\'') return self.parseString();

        const start = self.i;
        while (self.i < self.s.len) : (self.i += 1) {
            const c = self.s[self.i];
            if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-') continue;
            break;
        }
        if (self.i == start) return error.InvalidToml;
        return self.s[start..self.i];
    }

    fn parseValue(self: *Parser) Error!Value {
        if (self.i >= self.s.len) return error.InvalidToml;
        const c = self.s[self.i];
        if (c == '"' or c == '\'') return .{ .string = try self.parseString() };
        if (c == '[') return self.parseArray();

        const start = self.i;
        while (self.i < self.s.len and self.s[self.i] != '\n' and self.s[self.i] != '#' and self.s[self.i] != ',' and self.s[self.i] != ']') self.i += 1;
        const raw = std.mem.trim(u8, self.s[start..self.i], " \t\r");
        if (raw.len == 0) return error.InvalidToml;
        if (std.mem.eql(u8, raw, "true")) return .{ .boolean = true };
        if (std.mem.eql(u8, raw, "false")) return .{ .boolean = false };

        var buf: [64]u8 = undefined;
        var len: usize = 0;
        for (raw) |ch| {
            if (ch == '_') continue;
            if (len >= buf.len) return error.InvalidToml;
            buf[len] = ch;
            len += 1;
        }
        const num = std.fmt.parseInt(i64, buf[0..len], 10) catch return error.InvalidToml;
        return .{ .integer = num };
    }

    fn parseArray(self: *Parser) Error!Value {
        self.i += 1; // '['
        var list: std.ArrayList(Value) = .empty;
        defer list.deinit(self.a);

        while (true) {
            self.skipInlineSpace();
            if (self.i < self.s.len and self.s[self.i] == '\n') {
                self.i += 1;
                self.line += 1;
                continue;
            }
            if (self.i < self.s.len and self.s[self.i] == '#') {
                while (self.i < self.s.len and self.s[self.i] != '\n') self.i += 1;
                continue;
            }
            if (self.i >= self.s.len) return error.InvalidToml;
            if (self.s[self.i] == ']') {
                self.i += 1;
                break;
            }
            try list.append(self.a, try self.parseValue());
            self.skipInlineSpace();
            if (self.i < self.s.len and self.s[self.i] == ',') {
                self.i += 1;
                continue;
            }
            if (self.i < self.s.len and self.s[self.i] == ']') {
                self.i += 1;
                break;
            }
            return error.InvalidToml;
        }
        return .{ .array = try list.toOwnedSlice(self.a) };
    }

    fn parseString(self: *Parser) Error![]const u8 {
        const quote = self.s[self.i];
        self.i += 1;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.a);

        while (self.i < self.s.len) {
            const c = self.s[self.i];
            self.i += 1;
            if (c == quote) return out.toOwnedSlice(self.a);
            if (c == '\n') return error.InvalidToml;
            if (quote == '"' and c == '\\') {
                if (self.i >= self.s.len) return error.InvalidToml;
                const e = self.s[self.i];
                self.i += 1;
                switch (e) {
                    'n' => try out.append(self.a, '\n'),
                    'r' => try out.append(self.a, '\r'),
                    't' => try out.append(self.a, '\t'),
                    '"' => try out.append(self.a, '"'),
                    '\\' => try out.append(self.a, '\\'),
                    else => return error.InvalidToml,
                }
                continue;
            }
            try out.append(self.a, c);
        }
        return error.InvalidToml;
    }
};

const testing = std.testing;

test "toml: 基本语法与数组表" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const text =
        \\# 注释
        \\listen = "0.0.0.0"
        \\port = 8610
        \\debug = true
        \\exclude = ["*.tmp", "node_modules"]
        \\
        \\[[servers]]
        \\name = "s1"
        \\url = "http://a:1"
        \\
        \\[[servers]]
        \\name = "s2"
        \\url = "http://b:1"
        \\enabled = false
    ;

    const root = try parse(a, text);

    const Cfg = struct {
        listen: []const u8 = "",
        port: u16 = 0,
        debug: bool = false,
        exclude: []const []const u8 = &.{},
        servers: []const struct {
            name: []const u8 = "",
            url: []const u8 = "",
            enabled: bool = true,
        } = &.{},
    };
    const cfg = try decode(Cfg, a, root);
    try testing.expectEqualStrings("0.0.0.0", cfg.listen);
    try testing.expectEqual(@as(u16, 8610), cfg.port);
    try testing.expect(cfg.debug);
    try testing.expectEqual(@as(usize, 2), cfg.exclude.len);
    try testing.expectEqual(@as(usize, 2), cfg.servers.len);
    try testing.expectEqualStrings("s2", cfg.servers[1].name);
    try testing.expect(!cfg.servers[1].enabled);
    try testing.expect(cfg.servers[0].enabled);
}

test "toml: 点号键与非法输入" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const root = try parse(a, "a.b = 1\n[t]\nx = 2\n");
    try testing.expectEqual(@as(i64, 1), root.get("a").?.table.get("b").?.integer);
    try testing.expectEqual(@as(i64, 2), root.get("t").?.table.get("x").?.integer);

    try testing.expectError(error.InvalidToml, parse(a, "x = "));
    try testing.expectError(error.InvalidToml, parse(a, "x = \"unterminated"));
}
