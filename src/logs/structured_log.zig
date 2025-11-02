const std = @import("std");

/// 结构化日志等级
pub const Level = enum {
    debug,
    info,
    warn,
    @"error",

    pub fn toString(self: Level) []const u8 {
        return switch (self) {
            .debug => "DEBUG",
            .info => "INFO",
            .warn => "WARN",
            .@"error" => "ERROR",
        };
    }
};

/// 结构化日志字段
pub const Field = struct {
    key: []const u8,
    value: Value,

    pub const Value = union(enum) {
        string: []const u8,
        int: i64,
        uint: u64,
        float: f64,
        bool: bool,
        null: void,
    };
};

/// 结构化日志构建器
///
/// # 特性
/// - JSON 格式输出
/// - 零分配模式（固定缓冲区）
/// - 类型安全的字段添加
/// - 自动时间戳和来源信息
///
/// # 示例
/// ```zig
/// var builder = StructuredLog.init(allocator, .info);
/// try builder.addString("user", "alice");
/// try builder.addInt("age", 25);
/// try builder.addFloat("score", 95.5);
/// const json = try builder.build();
/// defer allocator.free(json);
/// ```
pub const StructuredLog = struct {
    allocator: std.mem.Allocator,
    level: Level,
    message: ?[]const u8,
    fields: std.ArrayList(Field),
    timestamp: i64,

    pub fn init(allocator: std.mem.Allocator, level: Level) StructuredLog {
        return .{
            .allocator = allocator,
            .level = level,
            .message = null,
            .fields = .{}, // ✅ Zig 0.15.2 空字面量初始化
            .timestamp = std.time.milliTimestamp(),
        };
    }

    pub fn deinit(self: *StructuredLog) void {
        self.fields.deinit(self.allocator); // ✅ 传入 allocator
    }

    /// 设置日志消息
    pub fn setMessage(self: *StructuredLog, msg: []const u8) void {
        self.message = msg;
    }

    /// 添加字符串字段
    pub fn addString(self: *StructuredLog, key: []const u8, value: []const u8) !void {
        try self.fields.append(self.allocator, .{ // ✅ 传入 allocator
            .key = key,
            .value = .{ .string = value },
        });
    }

    /// 添加整数字段
    pub fn addInt(self: *StructuredLog, key: []const u8, value: i64) !void {
        try self.fields.append(self.allocator, .{ // ✅ 传入 allocator
            .key = key,
            .value = .{ .int = value },
        });
    }

    /// 添加无符号整数字段
    pub fn addUInt(self: *StructuredLog, key: []const u8, value: u64) !void {
        try self.fields.append(self.allocator, .{ // ✅ 传入 allocator
            .key = key,
            .value = .{ .uint = value },
        });
    }

    /// 添加浮点数字段
    pub fn addFloat(self: *StructuredLog, key: []const u8, value: f64) !void {
        try self.fields.append(self.allocator, .{ // ✅ 传入 allocator
            .key = key,
            .value = .{ .float = value },
        });
    }

    /// 添加布尔字段
    pub fn addBool(self: *StructuredLog, key: []const u8, value: bool) !void {
        try self.fields.append(self.allocator, .{ // ✅ 传入 allocator
            .key = key,
            .value = .{ .bool = value },
        });
    }

    /// 添加 null 字段
    pub fn addNull(self: *StructuredLog, key: []const u8) !void {
        try self.fields.append(self.allocator, .{ // ✅ 传入 allocator
            .key = key,
            .value = .{ .null = {} },
        });
    }

    /// 构建 JSON 字符串
    ///
    /// # 返回
    /// 返回的字符串需要手动释放：`allocator.free(json);`
    pub fn build(self: *const StructuredLog) ![]u8 {
        var buf: std.ArrayList(u8) = .{}; // ✅ Zig 0.15.2 空字面量
        errdefer buf.deinit(self.allocator); // ✅ 传入 allocator

        const writer = buf.writer(self.allocator); // ✅ 传入 allocator

        try writer.writeAll("{");

        // 时间戳
        try writer.print("\"timestamp\":{},", .{self.timestamp});

        // 日志等级
        try writer.print("\"level\":\"{s}\",", .{self.level.toString()});

        // 消息
        if (self.message) |msg| {
            try writer.writeAll("\"message\":\"");
            try writeEscapedString(writer, msg);
            try writer.writeAll("\",");
        }

        // 自定义字段
        for (self.fields.items, 0..) |field, i| {
            try writer.print("\"{s}\":", .{field.key});

            switch (field.value) {
                .string => |s| {
                    try writer.writeAll("\"");
                    try writeEscapedString(writer, s);
                    try writer.writeAll("\"");
                },
                .int => |v| try writer.print("{}", .{v}),
                .uint => |v| try writer.print("{}", .{v}),
                .float => |v| try writer.print("{d:.2}", .{v}),
                .bool => |v| try writer.writeAll(if (v) "true" else "false"),
                .null => try writer.writeAll("null"),
            }

            if (i < self.fields.items.len - 1) {
                try writer.writeAll(",");
            }
        }

        try writer.writeAll("}");

        return buf.toOwnedSlice(self.allocator); // ✅ 传入 allocator
    }

    /// JSON 转义字符串
    fn writeEscapedString(writer: anytype, s: []const u8) !void {
        for (s) |c| {
            switch (c) {
                '"' => try writer.writeAll("\\\""),
                '\\' => try writer.writeAll("\\\\"),
                '\n' => try writer.writeAll("\\n"),
                '\r' => try writer.writeAll("\\r"),
                '\t' => try writer.writeAll("\\t"),
                0...8, 11, 12, 14...31 => try writer.print("\\u{x:0>4}", .{c}), // ✅ 排除 \n \r \t
                else => try writer.writeByte(c),
            }
        }
    }
};

/// 零分配结构化日志（固定缓冲区）
///
/// # 特性
/// - 不依赖堆分配
/// - 固定缓冲区大小（默认 4KB）
/// - 适用于嵌入式或实时系统
///
/// # 限制
/// - 字段数量上限: 32
/// - 单个字符串最大长度: 256
/// - 总输出大小: 4096 字节
pub const StructuredLogZeroAlloc = struct {
    level: Level,
    message: [256]u8,
    message_len: usize,
    fields: [32]FieldZeroAlloc,
    field_count: usize,
    timestamp: i64,

    const FieldZeroAlloc = struct {
        key: [64]u8,
        key_len: usize,
        value: ValueZeroAlloc,
    };

    const ValueZeroAlloc = union(enum) {
        string: struct {
            data: [256]u8,
            len: usize,
        },
        int: i64,
        uint: u64,
        float: f64,
        bool: bool,
        null: void,
    };

    pub fn init(level: Level) StructuredLogZeroAlloc {
        return .{
            .level = level,
            .message = undefined,
            .message_len = 0,
            .fields = undefined,
            .field_count = 0,
            .timestamp = std.time.milliTimestamp(),
        };
    }

    pub fn setMessage(self: *StructuredLogZeroAlloc, msg: []const u8) void {
        self.message_len = @min(msg.len, 256);
        @memcpy(self.message[0..self.message_len], msg[0..self.message_len]);
    }

    pub fn addString(self: *StructuredLogZeroAlloc, key: []const u8, value: []const u8) !void {
        if (self.field_count >= 32) return error.TooManyFields;

        var field = &self.fields[self.field_count];
        field.key_len = @min(key.len, 64);
        @memcpy(field.key[0..field.key_len], key[0..field.key_len]);

        const val_len = @min(value.len, 256);
        field.value = .{
            .string = .{
                .data = undefined,
                .len = val_len,
            },
        };
        @memcpy(field.value.string.data[0..val_len], value[0..val_len]);

        self.field_count += 1;
    }

    pub fn addInt(self: *StructuredLogZeroAlloc, key: []const u8, value: i64) !void {
        if (self.field_count >= 32) return error.TooManyFields;

        var field = &self.fields[self.field_count];
        field.key_len = @min(key.len, 64);
        @memcpy(field.key[0..field.key_len], key[0..field.key_len]);
        field.value = .{ .int = value };

        self.field_count += 1;
    }

    /// 构建 JSON 到固定缓冲区
    pub fn buildToBuffer(self: *const StructuredLogZeroAlloc, buffer: []u8) ![]const u8 {
        var stream = std.io.fixedBufferStream(buffer);
        const writer = stream.writer();

        try writer.writeAll("{");
        try writer.print("\"timestamp\":{},", .{self.timestamp});
        try writer.print("\"level\":\"{s}\"", .{self.level.toString()});

        if (self.message_len > 0) {
            try writer.writeAll(",\"message\":\"");
            try StructuredLog.writeEscapedString(writer, self.message[0..self.message_len]);
            try writer.writeAll("\"");
        }

        for (self.fields[0..self.field_count]) |field| {
            try writer.print(",\"{s}\":", .{field.key[0..field.key_len]});

            switch (field.value) {
                .string => |s| {
                    try writer.writeAll("\"");
                    try StructuredLog.writeEscapedString(writer, s.data[0..s.len]);
                    try writer.writeAll("\"");
                },
                .int => |v| try writer.print("{}", .{v}),
                .uint => |v| try writer.print("{}", .{v}),
                .float => |v| try writer.print("{d:.2}", .{v}),
                .bool => |v| try writer.writeAll(if (v) "true" else "false"),
                .null => try writer.writeAll("null"),
            }
        }

        try writer.writeAll("}");
        return stream.getWritten();
    }
};

// ========== 单元测试 ==========

test "StructuredLog - JSON 构建" {
    const allocator = std.testing.allocator;
    var log = StructuredLog.init(allocator, .info);
    defer log.deinit();

    log.setMessage("用户登录成功");
    try log.addString("user", "alice");
    try log.addInt("age", 25);
    try log.addBool("is_admin", true);

    const json = try log.build();
    defer allocator.free(json);

    // 验证 JSON 包含关键字段
    try std.testing.expect(std.mem.indexOf(u8, json, "\"level\":\"INFO\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"user\":\"alice\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"age\":25") != null);
}

test "StructuredLogZeroAlloc - 零分配模式" {
    var log = StructuredLogZeroAlloc.init(.warn);
    log.setMessage("内存警告");
    try log.addString("module", "allocator");
    try log.addInt("used_mb", 512);

    var buffer: [2048]u8 = undefined;
    const json = try log.buildToBuffer(&buffer);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"level\":\"WARN\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"module\":\"allocator\"") != null);
}
