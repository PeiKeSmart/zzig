//! BSON 编解码（MongoDB 的文档表示，[bsonspec.org](https://bsonspec.org/spec.html)）。
//!
//! 只做「文档树 ↔ 字节」这一层，不含网络与命令语义（那些在 `mongodb.zig`）。
//!
//! ## 支持的 BSON 类型
//! `double`(0x01)、`string`(0x02)、`document`(0x03)、`array`(0x04)、`binary`(0x05)、
//! `ObjectId`(0x07)、`bool`(0x08)、`UTC datetime`(0x09)、`null`(0x0A)、`regex`(0x0B)、
//! `int32`(0x10)、`timestamp`(0x11)、`int64`(0x12)；其余类型（Decimal128 等）原样保留在 `raw` 里，
//! **不丢数据**，需要时由调用方按 `type_byte` 自己解释。
//!
//! ## 内存归属
//! `parseAlloc` 解出的字符串/数组/子文档**全部复制到传入的 allocator**，因此源缓冲之后可以立刻释放；
//! 传 arena 时随 arena 一起回收。

const std = @import("std");

pub const Element = enum(u8) {
    double = 0x01,
    string = 0x02,
    document = 0x03,
    array = 0x04,
    binary = 0x05,
    undefined = 0x06,
    objectid = 0x07,
    boolean = 0x08,
    datetime = 0x09,
    null = 0x0A,
    regex = 0x0B,
    /// 已废弃的 DBPointer
    dbpointer = 0x0C,
    javascript = 0x0D,
    symbol = 0x0E,
    javascript_scope = 0x0F,
    int32 = 0x10,
    timestamp = 0x11,
    int64 = 0x12,
    decimal128 = 0x13,
    minkey = 0xFF,
    maxkey = 0x7F,
};

pub const Regex = struct {
    pattern: []const u8,
    options: []const u8,
};

pub const Raw = struct {
    type_byte: u8,
    bytes: []const u8,
};

pub const Value = union(enum) {
    null,
    boolean: bool,
    int32: i32,
    int64: i64,
    double: f64,
    string: []const u8,
    binary: []const u8,
    objectid: [12]u8,
    /// UTC 毫秒时间戳
    datetime_ms: i64,
    array: []const Value,
    doc: []const Field,
    regex: Regex,
    timestamp: u64,
    /// 未解释的类型（原样保留）
    raw: Raw,
};

pub const Field = struct {
    name: []const u8,
    value: Value,
};

pub const Error = error{
    /// 文档长度字段与实际不符
    Corrupted,
    /// 类型字节不认识（保守起见不当成正常数据）
    UnsupportedType,
    /// 字符串没有以 `\0` 结束
    Unterminated,
};

// ── 编码 ────────────────────────────────────────────────────────────────────

/// 按 BSON 规范编码一个文档（`fields` 顺序即写入顺序）。返回的切片由 `a` 拥有。
pub fn encodeAlloc(a: std.mem.Allocator, fields: []const Field) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(a);
    try encodeDocInto(a, &out, fields);
    return out.toOwnedSlice(a);
}

fn encodeDocInto(a: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), fields: []const Field) anyerror!void {
    const start = out.items.len;
    try out.appendNTimes(a, 0, 4); // 占位长度

    for (fields) |f| {
        try out.append(a, @backingInt(elementOf(f.value)));
        try appendCString(a, out, f.name);
        try encodeValueInto(a, out, f.value);
    }

    try out.append(a, 0); // 文档结尾
    const total = out.items.len - start;
    std.mem.writeInt(i32, out.items[start..][0..4], @intCast(total), .little);
}

fn elementOf(v: Value) Element {
    return switch (v) {
        .null => .null,
        .boolean => .boolean,
        .int32 => .int32,
        .int64 => .int64,
        .double => .double,
        .string => .string,
        .binary => .binary,
        .objectid => .objectid,
        .datetime_ms => .datetime,
        .array => .array,
        .doc => .document,
        .regex => .regex,
        .timestamp => .timestamp,
        .raw => |r| @fromBackingInt(@intCast(r.type_byte)),
    };
}

fn appendCString(a: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    // 字段名不允许含 0；含了就截断（比写坏整个文档好）
    const end = std.mem.indexOfScalar(u8, s, 0) orelse s.len;
    try out.appendSlice(a, s[0..end]);
    try out.append(a, 0);
}

fn appendString(a: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), s: []const u8) !void {
    const end = std.mem.indexOfScalar(u8, s, 0) orelse s.len;
    try out.appendNTimes(a, 0, 4);
    const start = out.items.len - 4;
    try out.appendSlice(a, s[0..end]);
    try out.append(a, 0);
    std.mem.writeInt(i32, out.items[start..][0..4], @intCast(end + 1), .little);
}

fn encodeValueInto(a: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), v: Value) anyerror!void {
    switch (v) {
        .null => {},
        .boolean => |b| try out.append(a, if (b) 1 else 0),
        .int32 => |i| {
            try out.appendNTimes(a, 0, 4);
            std.mem.writeInt(i32, out.items[out.items.len - 4 ..][0..4], i, .little);
        },
        .int64 => |i| {
            try out.appendNTimes(a, 0, 8);
            std.mem.writeInt(i64, out.items[out.items.len - 8 ..][0..8], i, .little);
        },
        .double => |f| {
            try out.appendNTimes(a, 0, 8);
            std.mem.writeInt(u64, out.items[out.items.len - 8 ..][0..8], @bitCast(f), .little);
        },
        .string => |s| try appendString(a, out, s),
        .binary => |bytes| {
            try out.appendNTimes(a, 0, 5); // len(4) + subtype(1)
            const start = out.items.len - 5;
            try out.appendSlice(a, bytes);
            std.mem.writeInt(i32, out.items[start..][0..4], @intCast(bytes.len), .little);
            out.items[start + 4] = 0x00; // generic binary
        },
        .objectid => |id| try out.appendSlice(a, &id),
        .datetime_ms => |ms| {
            try out.appendNTimes(a, 0, 8);
            std.mem.writeInt(i64, out.items[out.items.len - 8 ..][0..8], ms, .little);
        },
        .array => |items| {
            // 数组就是一个「键为 "0","1",... 的文档」
            const start = out.items.len;
            try out.appendNTimes(a, 0, 4);
            var num_buf: [20]u8 = undefined;
            for (items, 0..) |item, i| {
                try out.append(a, @backingInt(elementOf(item)));
                const key = std.fmt.bufPrint(&num_buf, "{d}", .{i}) catch "0";
                try appendCString(a, out, key);
                try encodeValueInto(a, out, item);
            }
            try out.append(a, 0);
            std.mem.writeInt(i32, out.items[start..][0..4], @intCast(out.items.len - start), .little);
        },
        .doc => |fields| try encodeDocInto(a, out, fields),
        .regex => |r| {
            try appendCString(a, out, r.pattern);
            try appendCString(a, out, r.options);
        },
        .timestamp => |ts| {
            try out.appendNTimes(a, 0, 8);
            std.mem.writeInt(u64, out.items[out.items.len - 8 ..][0..8], ts, .little);
        },
        .raw => |r| try out.appendSlice(a, r.bytes),
    }
}

// ── 解码 ────────────────────────────────────────────────────────────────────

/// 解出一个文档；`consumed` 返回实际吃掉的字节数（OP_MSG 里一帧可能有多段）。
pub fn parseOneAlloc(a: std.mem.Allocator, bytes: []const u8, consumed: *usize) ![]const Field {
    if (bytes.len < 5) return Error.Corrupted;
    const len = std.mem.readInt(i32, bytes[0..4], .little);
    if (len < 5) return Error.Corrupted;
    const total: usize = @intCast(len);
    if (total > bytes.len) return Error.Corrupted;
    if (bytes[total - 1] != 0) return Error.Corrupted;

    var p = Parser{ .a = a, .bytes = bytes[0..total], .pos = 4 };
    const fields = try p.parseDocBody();
    consumed.* = total;
    return fields;
}

/// 解出一个文档，要求**恰好**用完整个切片（BSON 单文档场景）。
pub fn parseAlloc(a: std.mem.Allocator, bytes: []const u8) ![]const Field {
    var consumed: usize = 0;
    const fields = try parseOneAlloc(a, bytes, &consumed);
    if (consumed != bytes.len) return Error.Corrupted;
    return fields;
}

const Parser = struct {
    a: std.mem.Allocator,
    bytes: []const u8,
    pos: usize,

    fn parseDocBody(self: *Parser) anyerror![]const Field {
        var list: std.ArrayListUnmanaged(Field) = .empty;
        while (true) {
            if (self.pos >= self.bytes.len) return Error.Corrupted;
            const type_byte = self.bytes[self.pos];
            self.pos += 1;
            if (type_byte == 0) break; // 文档结尾

            const name = try self.readCString();
            const value = try self.parseValue(type_byte);
            try list.append(self.a, .{ .name = name, .value = value });
        }
        return list.toOwnedSlice(self.a);
    }

    fn readCString(self: *Parser) ![]const u8 {
        const start = self.pos;
        while (self.pos < self.bytes.len and self.bytes[self.pos] != 0) self.pos += 1;
        if (self.pos >= self.bytes.len) return Error.Unterminated;
        const s = self.bytes[start..self.pos];
        self.pos += 1; // 跳过 \0
        return self.a.dupe(u8, s);
    }

    fn readBytes(self: *Parser, n: usize) ![]const u8 {
        if (self.pos + n > self.bytes.len) return Error.Corrupted;
        const s = self.bytes[self.pos .. self.pos + n];
        self.pos += n;
        return s;
    }

    fn readInt(self: *Parser, comptime T: type) !T {
        const raw = try self.readBytes(@sizeOf(T));
        return std.mem.readInt(T, raw[0..@sizeOf(T)], .little);
    }

    fn parseValue(self: *Parser, type_byte: u8) anyerror!Value {
        const el: Element = std.enums.fromInt(Element, type_byte) orelse {
            // 不认识：保守报错（调用方可以退化成 raw，但那需要知道长度，做不到）
            return Error.UnsupportedType;
        };
        return switch (el) {
            .double => .{ .double = @bitCast(try self.readInt(u64)) },
            .string => blk: {
                const len = try self.readInt(i32);
                if (len <= 0) return Error.Corrupted;
                const raw = try self.readBytes(@intCast(len));
                if (raw[raw.len - 1] != 0) return Error.Unterminated;
                break :blk .{ .string = try self.a.dupe(u8, raw[0 .. raw.len - 1]) };
            },
            .document => blk: {
                const sub = try self.readSubDoc();
                var p = Parser{ .a = self.a, .bytes = sub, .pos = 4 };
                break :blk .{ .doc = try p.parseDocBody() };
            },
            .array => blk: {
                const sub = try self.readSubDoc();
                var p = Parser{ .a = self.a, .bytes = sub, .pos = 4 };
                const fields = try p.parseDocBody();
                const items = try self.a.alloc(Value, fields.len);
                for (fields, 0..) |f, i| items[i] = f.value;
                break :blk .{ .array = items };
            },
            .binary => blk: {
                const len = try self.readInt(i32);
                if (len < 0) return Error.Corrupted;
                const subtype_raw = try self.readBytes(1);
                const data = try self.readBytes(@intCast(len));
                // subtype 0x00 = 通用二进制；其它 subtype 也按字节返回（语义暂不区分）
                _ = subtype_raw;
                break :blk .{ .binary = try self.a.dupe(u8, data) };
            },
            .undefined => .null,
            .null => .null,
            .objectid => blk: {
                const raw = try self.readBytes(12);
                var id: [12]u8 = undefined;
                @memcpy(&id, raw);
                break :blk .{ .objectid = id };
            },
            .boolean => blk: {
                const b = try self.readBytes(1);
                break :blk .{ .boolean = b[0] != 0 };
            },
            .datetime => .{ .datetime_ms = try self.readInt(i64) },
            .regex => .{ .regex = .{ .pattern = try self.readCString(), .options = try self.readCString() } },
            .int32 => .{ .int32 = try self.readInt(i32) },
            .timestamp => .{ .timestamp = try self.readInt(u64) },
            .int64 => .{ .int64 = try self.readInt(i64) },
            .decimal128 => blk: {
                const raw = try self.readBytes(16);
                break :blk .{ .raw = .{ .type_byte = type_byte, .bytes = try self.a.dupe(u8, raw) } };
            },
            else => Error.UnsupportedType,
        };
    }

    fn readSubDoc(self: *Parser) ![]const u8 {
        if (self.pos + 4 > self.bytes.len) return Error.Corrupted;
        const len = std.mem.readInt(i32, self.bytes[self.pos..][0..4], .little);
        if (len < 5) return Error.Corrupted;
        const total: usize = @intCast(len);
        if (self.pos + total > self.bytes.len) return Error.Corrupted;
        const sub = self.bytes[self.pos .. self.pos + total];
        self.pos += total;
        return sub;
    }
};

// ── 取值辅助 ────────────────────────────────────────────────────────────────

/// 按名字取字段（后出现的覆盖先出现的，与 BSON 语义一致）。
pub fn get(fields: []const Field, name: []const u8) ?Value {
    var found: ?Value = null;
    for (fields) |f| {
        if (std.mem.eql(u8, f.name, name)) found = f.value;
    }
    return found;
}

pub fn getStr(fields: []const Field, name: []const u8) ?[]const u8 {
    const v = get(fields, name) orelse return null;
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

pub fn getI64(fields: []const Field, name: []const u8) ?i64 {
    const v = get(fields, name) orelse return null;
    return switch (v) {
        .int32 => |i| i,
        .int64 => |i| i,
        .double => |f| @intFromFloat(f),
        else => null,
    };
}

pub fn getF64(fields: []const Field, name: []const u8) ?f64 {
    const v = get(fields, name) orelse return null;
    return switch (v) {
        .int32 => |i| @floatFromInt(i),
        .int64 => |i| @floatFromInt(i),
        .double => |f| f,
        else => null,
    };
}

pub fn getBool(fields: []const Field, name: []const u8) ?bool {
    const v = get(fields, name) orelse return null;
    return switch (v) {
        .boolean => |b| b,
        else => null,
    };
}

pub fn getDoc(fields: []const Field, name: []const u8) ?[]const Field {
    const v = get(fields, name) orelse return null;
    return switch (v) {
        .doc => |d| d,
        else => null,
    };
}

pub fn getArray(fields: []const Field, name: []const u8) ?[]const Value {
    const v = get(fields, name) orelse return null;
    return switch (v) {
        .array => |a| a,
        else => null,
    };
}

// ── 测试 ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "bson 往返：常见类型" {
    const a = testing.allocator;

    const fields = [_]Field{
        .{ .name = "s", .value = .{ .string = "天气 ok" } },
        .{ .name = "i32", .value = .{ .int32 = -7 } },
        .{ .name = "i64", .value = .{ .int64 = 1 << 40 } },
        .{ .name = "d", .value = .{ .double = 1.5 } },
        .{ .name = "b", .value = .{ .boolean = true } },
        .{ .name = "n", .value = .null },
        .{ .name = "id", .value = .{ .objectid = .{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12 } } },
        .{ .name = "dt", .value = .{ .datetime_ms = 1_700_000_000_123 } },
        .{ .name = "bin", .value = .{ .binary = &[_]u8{ 0, 1, 2 } } },
        .{ .name = "arr", .value = .{ .array = &[_]Value{ .{ .int32 = 1 }, .{ .string = "x" } } } },
        .{ .name = "sub", .value = .{ .doc = &[_]Field{.{ .name = "k", .value = .{ .boolean = false } }} } },
        .{ .name = "re", .value = .{ .regex = .{ .pattern = "^a", .options = "i" } } },
        .{ .name = "ts", .value = .{ .timestamp = 42 } },
    };

    const bytes = try encodeAlloc(a, &fields);
    defer a.free(bytes);

    // 长度字段自洽
    try testing.expectEqual(@as(i32, @intCast(bytes.len)), std.mem.readInt(i32, bytes[0..4], .little));

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const back = try parseAlloc(arena.allocator(), bytes);

    try testing.expectEqual(@as(usize, fields.len), back.len);
    try testing.expectEqualStrings("天气 ok", getStr(back, "s").?);
    try testing.expectEqual(@as(i64, -7), getI64(back, "i32").?);
    try testing.expectEqual(@as(i64, 1 << 40), getI64(back, "i64").?);
    try testing.expectEqual(@as(f64, 1.5), getF64(back, "d").?);
    try testing.expectEqual(true, getBool(back, "b").?);
    try testing.expect(get(back, "n").? == .null);
    try testing.expectEqual(@as(u8, 12), get(back, "id").?.objectid[11]);
    try testing.expectEqual(@as(i64, 1_700_000_000_123), get(back, "dt").?.datetime_ms);
    try testing.expectEqual(@as(usize, 3), get(back, "bin").?.binary.len);
    try testing.expectEqual(@as(usize, 2), getArray(back, "arr").?.len);
    try testing.expectEqual(false, getBool(getDoc(back, "sub").?, "k").?);
    try testing.expectEqualStrings("^a", get(back, "re").?.regex.pattern);
    try testing.expectEqual(@as(u64, 42), get(back, "ts").?.timestamp);
}

test "bson 解码：嵌套文档与数组的下标键" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const ar = arena.allocator();

    // 手写一段 BSON：{ "a": { "b": [ 1, "x" ] } }
    const inner_doc = [_]Field{
        .{ .name = "b", .value = .{ .array = &[_]Value{ .{ .int32 = 1 }, .{ .string = "x" } } } },
    };
    const outer = [_]Field{.{ .name = "a", .value = .{ .doc = &inner_doc } }};
    const bytes = try encodeAlloc(a, &outer);
    defer a.free(bytes);

    const back = try parseAlloc(ar, bytes);
    const sub = getDoc(back, "a").?;
    const arr = getArray(sub, "b").?;
    try testing.expectEqual(@as(i32, 1), arr[0].int32);
    try testing.expectEqualStrings("x", arr[1].string);
}

test "bson 解码：坏数据被拒" {
    const a = testing.allocator;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();

    // 长度比实际长
    const bad_len = [_]u8{ 100, 0, 0, 0, 0 };
    try testing.expectError(Error.Corrupted, parseAlloc(arena.allocator(), &bad_len));

    // 长度太短
    const too_short = [_]u8{ 4, 0, 0, 0 };
    try testing.expectError(Error.Corrupted, parseAlloc(arena.allocator(), &too_short));

    // 空切片
    try testing.expectError(Error.Corrupted, parseAlloc(arena.allocator(), ""));
}
