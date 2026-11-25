//! C# `DGResult` 的 JSON 兼容输出（**字段名 / 大小写 / 空值 / 缩进逐字节对齐**）。
//!
//! 适用：任何要与 C#（`Pek.AspNetCore\Models\DGResult.cs`）**共用同一套调用方**的接口。
//! 典型场景：C# 站点改成 Zig 重写后，其它业务系统（或其它站点页面）仍按原来的字段名解析，
//! 一旦 Zig 回小写驼峰（`zzig.web.jsonResult` 的默认形态）就会全体解析失败。
//!
//! ## C# 那边到底输出什么（实测，不是猜）
//!
//! C# 侧（如 `591-tools/src/IPV6/Program.cs`）显式配了：
//!
//! ```csharp
//! .AddJsonOptions(options => {
//!     options.JsonSerializerOptions.PropertyNamingPolicy = null; // 禁用驼峰，保留原始属性名称
//!     options.JsonSerializerOptions.WriteIndented = true;
//!     options.JsonSerializerOptions.PropertyNameCaseInsensitive = true;
//! });
//! ```
//!
//! `DGResult.ExecuteResultAsync` 返回的匿名对象是
//! `{ Code, Message, OperationTime, Data, ExtData, Id, ErrCode }`，于是实际响应（.NET 11 实测）：
//!
//! ```json
//! {
//!   "Code": 1,
//!   "Message": null,
//!   "OperationTime": "2026-11-25T14:03:05.1234567+08:00",
//!   "Data": [
//!     {
//!       "Ip": "203.0.113.7",
//!       "Type": "IPv4",
//!       "SourceHeader": "X-Forwarded-For",
//!       "FromForwardedHeader": true
//!     }
//!   ],
//!   "ExtData": null,
//!   "Id": "0f8fad5b-d9cb-469f-a165-70867728950e",
//!   "ErrCode": 0
//! }
//! ```
//!
//! ## 固定规则（单测逐条锁住）
//!
//! - 字段顺序 `Code, Message, OperationTime, Data, ExtData, Id, ErrCode`；
//! - `Message` / `ExtData` 为 null 时**照样输出**（`DefaultIgnoreCondition` 默认 Never）；
//! - 2 空格缩进、`": "` 分隔、`\n` 换行（**不是** `\r\n`）；空数组输出 `[]`；
//! - 字符串按 `JavaScriptEncoder.Default` 转义：`"` `\` `+` `<` `>` `&` `'` 与控制字符、
//!   以及**全部非 ASCII**（中文 → `\uXXXX`，非 BMP → UTF-16 代理对），十六进制**大写**；
//! - `Code` 取 `StateCode` 的整数值：成功 = **1**（`Ok`）、失败 = **2**（`Fail`）——
//!   注意**不是** `zzig.web.jsonResult` 的 0/1；
//! - `OperationTime` = `DateTime.Now` 的 ISO8601：7 位小数秒**裁剪尾零**，小数恰为零时
//!   连小数点一起省略（`2026-11-25T14:03:05+08:00`）；
//! - `Id` = 小写带连字符的 GUID v4（`Guid.NewGuid().ToString()`）。
//!
//! ## 用法
//!
//! ```zig
//! // data 是**已按层级写好**的 JSON 片段（"Data": 之后的部分，相对缩进 0 起算）
//! return zzig.DGResult.responseWith(arena, zzig.DGResult.state_ok, null, data, .{
//!     .utc_offset_seconds = 8 * 3600, // 与 C# 中国服务器一致；不填则用系统本地偏移
//! });
//! ```

const std = @import("std");
const builtin = @import("builtin");
const compat = @import("../compat.zig");
const guid = @import("../string/guid.zig");
const router = @import("router.zig");
const DateTime = @import("../time/datetime.zig").DateTime;

/// C# `StateCode.Ok` = 1。
pub const state_ok: i64 = 1;
/// C# `StateCode.Fail` = 2。
pub const state_fail: i64 = 2;

/// 响应选项。
pub const Options = struct {
    /// `OperationTime` 的时区偏移（秒）。`null` = 系统本地时区
    /// （Windows 精确到夏令时；其它平台返回 0 —— Zig 标准库没有时区数据库）。
    ///
    /// 要与 C# 中国服务器输出一致时显式传 `8 * 3600`。
    utc_offset_seconds: ?i64 = null,
    /// `Id` 的随机源所在 io（**建议传**：与 `main.zig` 生成密钥同一份 `init.io`）。
    ///
    /// ★ 不传时退化为「时间戳 + 进程内计数器」的 GUID，**不要用在安全场景**。
    /// 为什么不能默认用 `Guid.guidAlloc`：它内部用 `std.Io.Threaded.global_single_threaded`，
    /// 而 HTTP 请求跑在工作线程/协程上 —— `http/server.zig:1012` 明确写着
    /// 「global_single_threaded 跨线程会 panic」。2026-11-25 线上（Linux musl）
    /// 症状就是：一请求 `/api/client-ip` 连接立刻被关（nginx 502）。
    io: ?std.Io = null,
    /// 覆盖 `OperationTime` 文本（一般只在测试里用）。
    operation_time: ?[]const u8 = null,
    /// 覆盖 `Id`（一般只在测试里用）。
    id: ?[]const u8 = null,
};

/// 进程内兜底计数器（无 io 时保证 Id 在本进程内唯一）。
var fallback_id: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

/// 生成 `Id`。
///
/// - 有 `io` → 真随机 GUID v4（`std.Random.IoSource`）；
/// - 无 `io` → 纳秒时间戳 + 进程内计数器，仍是 GUID v4 文本，仅作标识。
fn idAlloc(arena: std.mem.Allocator, io: ?std.Io) ![]u8 {
    if (io) |handle| {
        const source = std.Random.IoSource{ .io = handle };
        return guid.guidWithRandomAlloc(arena, source.interface());
    }
    var bytes: [16]u8 = undefined;
    const stamp: i64 = @intCast(@max(compat.nanoTimestamp(), 0));
    std.mem.writeInt(u64, bytes[0..8], @bitCast(stamp), .little);
    std.mem.writeInt(u64, bytes[8..16], fallback_id.fetchAdd(1, .monotonic), .little);
    return guid.formatAlloc(arena, bytes);
}

/// 按 `JavaScriptEncoder.Default` 的规则写一个 JSON 字符串（含首尾引号）。
pub fn writeString(w: *std.Io.Writer, text: []const u8) !void {
    try w.writeByte('"');
    var index: usize = 0;
    while (index < text.len) {
        const byte = text[index];
        if (byte < 0x80) {
            switch (byte) {
                '"' => try w.writeAll("\\u0022"),
                '\\' => try w.writeAll("\\\\"),
                '+' => try w.writeAll("\\u002B"),
                '<' => try w.writeAll("\\u003C"),
                '>' => try w.writeAll("\\u003E"),
                '&' => try w.writeAll("\\u0026"),
                '\'' => try w.writeAll("\\u0027"),
                0x08 => try w.writeAll("\\b"),
                0x0C => try w.writeAll("\\f"),
                '\n' => try w.writeAll("\\n"),
                '\r' => try w.writeAll("\\r"),
                '\t' => try w.writeAll("\\t"),
                else => if (byte < 0x20) {
                    try w.print("\\u{X:0>4}", .{byte});
                } else {
                    try w.writeByte(byte);
                },
            }
            index += 1;
            continue;
        }

        // 非 ASCII：BMP 一个 `\uXXXX`，超 BMP 两个代理。
        const length = std.unicode.utf8ByteSequenceLength(byte) catch {
            // 非法 UTF-8 字节：System.Text.Json 会抛异常，这里退化成原字节（不该发生）。
            try w.writeByte(byte);
            index += 1;
            continue;
        };
        if (index + length > text.len) {
            try w.writeByte(byte);
            index += 1;
            continue;
        }
        const code_point = std.unicode.utf8Decode(text[index .. index + length]) catch {
            try w.writeByte(byte);
            index += 1;
            continue;
        };
        if (code_point <= 0xFFFF) {
            try w.print("\\u{X:0>4}", .{code_point});
        } else {
            const value: u32 = code_point - 0x10000;
            const high: u16 = @intCast(0xD800 + (value >> 10));
            const low: u16 = @intCast(0xDC00 + (value & 0x3FF));
            try w.print("\\u{X:0>4}\\u{X:0>4}", .{ high, low });
        }
        index += length;
    }
    try w.writeByte('"');
}

/// 系统本地时区偏移（秒）。
///
/// Windows 用 `GetTimeZoneInformation`（含夏令时 `DaylightBias`）；
/// 其它平台返回 0 —— Zig 标准库没有时区数据库，**不能猜**。
/// 需要固定偏移的业务请显式给 [`Options.utc_offset_seconds`]。
pub fn localOffsetSeconds() i64 {
    if (builtin.os.tag != .windows) return 0;

    const SYSTEMTIME = extern struct {
        wYear: u16,
        wMonth: u16,
        wDayOfWeek: u16,
        wDay: u16,
        wHour: u16,
        wMinute: u16,
        wSecond: u16,
        wMilliseconds: u16,
    };
    const TIME_ZONE_INFORMATION = extern struct {
        Bias: i32,
        StandardName: [32]u16,
        StandardDate: SYSTEMTIME,
        StandardBias: i32,
        DaylightName: [32]u16,
        DaylightDate: SYSTEMTIME,
        DaylightBias: i32,
    };
    const GetTimeZoneInformation = struct {
        extern "kernel32" fn GetTimeZoneInformation(lpTimeZoneInformation: *TIME_ZONE_INFORMATION) callconv(.winapi) u32;
    }.GetTimeZoneInformation;

    var tz: TIME_ZONE_INFORMATION = undefined;
    // 返回 2 = 夏令时生效，需同时减去 DaylightBias
    const rc = GetTimeZoneInformation(&tz);
    var bias: i64 = tz.Bias;
    if (rc == 2) bias += tz.DaylightBias;
    // Bias 是「UTC = 本地 + Bias（分钟）」，所以偏移要取反
    return -bias * 60;
}

/// 当前时间的 C# `DateTime.Now` 文本：`2026-11-25T14:03:05.1234567+08:00`。
pub fn operationTimeAlloc(arena: std.mem.Allocator, offset_seconds: i64) ![]const u8 {
    const ns = compat.nanoTimestamp();
    const offset_ns: i128 = @as(i128, offset_seconds) * std.time.ns_per_s;
    const local_ns = ns + offset_ns;
    const seconds: i64 = @intCast(@divFloor(local_ns, std.time.ns_per_s));
    const frac_ns: u64 = @intCast(@mod(local_ns, std.time.ns_per_s));
    const dt = DateTime.fromUnixSeconds(seconds);

    // C# `DateTime` 精度是 100ns（ticks），JSON 里是「7 位定宽后裁尾零」。
    const ticks: u32 = @intCast(@divTrunc(frac_ns, 100));
    var frac_buf: [7]u8 = undefined;
    _ = try std.fmt.bufPrint(&frac_buf, "{d:0>7}", .{ticks});
    var frac_len: usize = 7;
    while (frac_len > 0 and frac_buf[frac_len - 1] == '0') frac_len -= 1;

    const abs_offset: u64 = @intCast(if (offset_seconds < 0) -offset_seconds else offset_seconds);
    const offset_hours: u64 = abs_offset / 3600;
    const offset_minutes: u64 = (abs_offset % 3600) / 60;
    const offset_prefix: []const u8 = if (offset_seconds < 0) "-" else "+";

    // 年份转无符号：`{d:0>4}` 对负数会把符号位算进宽度。
    const year: u32 = @intCast(@max(dt.year, 0));
    return if (frac_len > 0)
        std.fmt.allocPrint(
            arena,
            "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{s}{s}{d:0>2}:{d:0>2}",
            .{ year, dt.month, dt.day, dt.hour, dt.minute, dt.second, frac_buf[0..frac_len], offset_prefix, offset_hours, offset_minutes },
        )
    else
        std.fmt.allocPrint(
            arena,
            "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}{s}{d:0>2}:{d:0>2}",
            .{ year, dt.month, dt.day, dt.hour, dt.minute, dt.second, offset_prefix, offset_hours, offset_minutes },
        );
}

/// 构造完整响应体。`data` 是**已按缩进层级写好**的 JSON 片段（`"Data": ` 之后的部分）。
pub fn build(
    arena: std.mem.Allocator,
    code: i64,
    message: ?[]const u8,
    data: []const u8,
    operation_time: []const u8,
    id: []const u8,
) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();

    try out.writer.print("{{\n  \"Code\": {d},\n  \"Message\": ", .{code});
    if (message) |text| try writeString(&out.writer, text) else try out.writer.writeAll("null");
    try out.writer.print(",\n  \"OperationTime\": \"{s}\",\n  \"Data\": {s},\n  \"ExtData\": null,\n  \"Id\": \"{s}\",\n  \"ErrCode\": 0\n}}", .{
        operation_time,
        data,
        id,
    });
    return out.toOwnedSlice();
}

/// 构造完整响应（`OperationTime` = 系统本地时间，`Id` = 随机 GUID v4）。
pub fn response(arena: std.mem.Allocator, code: i64, message: ?[]const u8, data: []const u8) !router.Response {
    return responseWith(arena, code, message, data, .{});
}

/// 构造完整响应（可指定时区偏移 / 覆盖时间与 Id）。
pub fn responseWith(arena: std.mem.Allocator, code: i64, message: ?[]const u8, data: []const u8, options: Options) !router.Response {
    const operation_time = options.operation_time orelse
        try operationTimeAlloc(arena, options.utc_offset_seconds orelse localOffsetSeconds());
    const id = options.id orelse try idAlloc(arena, options.io);
    return router.Response.json(try build(arena, code, message, data, operation_time, id));
}

test "字符串转义：与 System.Text.Json 实测输出逐字节一致" {
    const arena = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    // C# 实测：`"a+b<c>&d'e\"f\\g 中文 😀 \u0001"`
    //   → `"a\u002Bb\u003Cc\u003E\u0026d\u0027e\u0022f\\g \u4E2D\u6587 \uD83D\uDE00 \u0001"`
    try writeString(&out.writer, "a+b<c>&d'e\"f\\g 中文 😀 \x01");
    const text = try out.toOwnedSlice();
    defer arena.free(text);
    try std.testing.expectEqualStrings(
        "\"a\\u002Bb\\u003Cc\\u003E\\u0026d\\u0027e\\u0022f\\\\g \\u4E2D\\u6587 \\uD83D\\uDE00 \\u0001\"",
        text,
    );
}

test "信封：字段顺序、空值、缩进与 C# 一致" {
    const arena = std.testing.allocator;
    const data = "[\n    {\n      \"Ip\": \"203.0.113.7\",\n      \"Type\": \"IPv4\",\n      \"SourceHeader\": \"X-Forwarded-For\",\n      \"FromForwardedHeader\": true\n    }\n  ]";
    const text = try build(arena, state_ok, null, data, "2026-11-25T14:03:05.1234567+08:00", "0f8fad5b-d9cb-469f-a165-70867728950e");
    defer arena.free(text);

    const expected =
        "{\n" ++
        "  \"Code\": 1,\n" ++
        "  \"Message\": null,\n" ++
        "  \"OperationTime\": \"2026-11-25T14:03:05.1234567+08:00\",\n" ++
        "  \"Data\": [\n" ++
        "    {\n" ++
        "      \"Ip\": \"203.0.113.7\",\n" ++
        "      \"Type\": \"IPv4\",\n" ++
        "      \"SourceHeader\": \"X-Forwarded-For\",\n" ++
        "      \"FromForwardedHeader\": true\n" ++
        "    }\n" ++
        "  ],\n" ++
        "  \"ExtData\": null,\n" ++
        "  \"Id\": \"0f8fad5b-d9cb-469f-a165-70867728950e\",\n" ++
        "  \"ErrCode\": 0\n" ++
        "}";
    try std.testing.expectEqualStrings(expected, text);
}

test "失败信封：Message 中文转义 + Data 布尔 + Code=2" {
    const arena = std.testing.allocator;
    const text = try build(arena, state_fail, "来源标识不能为空", "false", "2026-11-25T14:03:05+08:00", "0f8fad5b-d9cb-469f-a165-70867728950e");
    defer arena.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"Code\": 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"Message\": \"\\u6765\\u6E90\\u6807\\u8BC6\\u4E0D\\u80FD\\u4E3A\\u7A7A\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"Data\": false") != null);
}

test "OperationTime：C# DateTime 形态（7 位小数、尾零裁剪、±hh:mm）" {
    const arena = std.testing.allocator;

    const plus8 = try operationTimeAlloc(arena, 8 * 3600);
    defer arena.free(plus8);
    // 25 = `2026-11-25T11:30:36+08:00`；33 = 再带 `.` + 7 位小数
    try std.testing.expect(plus8.len >= 25 and plus8.len <= 33);
    try std.testing.expect(plus8[4] == '-' and plus8[7] == '-');
    try std.testing.expect(plus8[10] == 'T');
    try std.testing.expect(plus8[13] == ':' and plus8[16] == ':');
    try std.testing.expectEqualStrings("+08:00", plus8[plus8.len - 6 ..]);
    const tail = plus8[19 .. plus8.len - 6]; // 秒之后、偏移之前
    if (tail.len > 0) {
        try std.testing.expect(tail[0] == '.');
        try std.testing.expect(tail.len >= 2 and tail.len <= 8); // `.` + 1~7 位
        try std.testing.expect(tail[tail.len - 1] != '0'); // 尾零必须已裁掉
    }

    const minus5 = try operationTimeAlloc(arena, -5 * 3600);
    defer arena.free(minus5);
    try std.testing.expectEqualStrings("-05:00", minus5[minus5.len - 6 ..]);
}
