//! 【通用】图形验证码（内存存储 + SVG 渲染，**零第三方依赖**）。
//!
//! 设计取舍：
//! - **触发方式**：默认「失败 N 次后才要求」，正常登录不打扰（由登录控制器判定，见 `require_for_fails`）；
//! - **存储**：进程内表，`id → { 答案, 过期时间 }`，**一次性消费**（校验后立刻删除，防重放）；
//! - **答案不落 Cookie**：Cookie 只带随机 id（`HttpOnly`），答案在内存里比对；
//! - **渲染成 SVG**：Zig 侧没有图像库，SVG 由浏览器渲染字体/干扰线，体积 ~1 KB，效果足够；
//! - **有界**：条目超上限先清过期项，仍超限整表清空（与 `login_guard` 同口径，宁可少拦一次也不能被打爆）。
//!
//! 字符集刻意去掉易混字符（`0/O/1/I/l`），减少「明明输对了却报错」。

const std = @import("std");
const compat = @import("../compat.zig");

pub const Options = struct {
    /// 有效期（秒）
    ttl_seconds: i64 = 300,
    /// 字符数
    length: usize = 4,
    /// 条目上限
    max_entries: usize = 4096,
    /// 渲染方案（`svg` = 浏览器字体，体积小；`gif` = 服务端像素图，
    /// 前端用 `<img src="data:image/gif;base64,...">`；需要其它方案时在 `Renderer` 加分支）
    renderer: Renderer = .svg,
    /// 字符集。默认字母+数字；GIF（七段数码管）只支持 `23456789`，
    /// 使用 GIF 时请显式传 `captcha.digits`。
    charset: []const u8 = charset,
};

/// 验证码���染方案。新增方案 = 加枚举值 + 在 `renderBase64` 里加分支，
/// 存储与校验逻辑完全共用。
pub const Renderer = enum {
    svg,
    gif,

    pub fn mime(self: Renderer) []const u8 {
        return switch (self) {
            .svg => "image/svg+xml",
            .gif => "image/gif",
        };
    }
};

/// 达到多少次失败后才要求验证码（低于封禁阈值：用户 5 / IP 10）。
pub const require_for_fails: u32 = 3;

const charset = "23456789abcdefghjkmnpqrstuvwxyz";
/// GIF 七段数码管可绘制的字符集（去掉 0/1 避免混淆）。
pub const digits = "23456789";

/// 平台安全随机源（Windows `RtlGenRandom` / Linux `getrandom`）。
///
/// 为什么不走 `std.Random.IoSource`：Zig 0.17 的 `std.Io.Threaded` 在测试 runner 里 `random()`
/// 会对 `userdata` 做 alignCast 直接 panic（实测），而且验证码本来就不该依赖业务 io。
fn fillSecure(buf: []u8) void {
    const builtin = @import("builtin");
    switch (builtin.os.tag) {
        .windows => {
            const advapi = struct {
                extern "advapi32" fn SystemFunction036(buffer: [*]u8, len: u32) u8;
            };
            var filled: usize = 0;
            while (filled < buf.len) {
                const chunk: u32 = @intCast(@min(buf.len - filled, 1 << 16));
                if (advapi.SystemFunction036(buf.ptr + filled, chunk) == 0) break;
                filled += chunk;
            }
        },
        .linux => {
            var filled: usize = 0;
            while (filled < buf.len) {
                const rc = std.os.linux.getrandom(buf.ptr + filled, buf.len - filled, 0);
                const signed: isize = @bitCast(rc);
                if (signed <= 0) break;
                filled += @intCast(signed);
            }
        },
        else => {},
    }
}

const SecureSource = struct {
    fn fill(_: *SecureSource, buf: []u8) void {
        fillSecure(buf);
    }
};

var secure_source: SecureSource = .{};

fn csprng() std.Random {
    return std.Random.init(&secure_source, SecureSource.fill);
}

const Entry = struct {
    answer: []u8,
    expires_ms: i64,
};

/// 验证码存储（线程安全）。
pub const Store = struct {
    allocator: std.mem.Allocator,
    mutex: compat.Mutex = .{},
    entries: std.StringHashMapUnmanaged(Entry) = .empty,
    opts: Options = .{},

    pub fn init(allocator: std.mem.Allocator, opts: Options) Store {
        return .{ .allocator = allocator, .opts = opts };
    }

    pub fn deinit(self: *Store) void {
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            self.allocator.free(kv.key_ptr.*);
            self.allocator.free(kv.value_ptr.answer);
        }
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    /// 签发一份验证码：返回 `id`（放 Cookie）与 `answer`（渲染到 SVG）。
    pub fn issue(self: *Store, arena: std.mem.Allocator, now_ms: i64) !Issue {
        return self.issueWithCode(arena, now_ms, null);
    }

    /// 签发一份验证码，可指定固定答案（**仅自动化测试/回归**；生产传 `null`）。
    pub fn issueWithCode(self: *Store, arena: std.mem.Allocator, now_ms: i64, fixed_code: ?[]const u8) !Issue {
        const rand = csprng();
        var code: [16]u8 = undefined;
        const len = @min(self.opts.length, code.len);
        const alphabet = if (self.opts.charset.len > 0) self.opts.charset else charset;
        if (fixed_code) |fixed| {
            const trimmed = std.mem.trim(u8, fixed, " \t\r\n");
            if (trimmed.len == len) {
                @memcpy(code[0..len], trimmed);
            } else {
                for (code[0..len]) |*c| {
                    c.* = std.ascii.toUpper(alphabet[rand.uintLessThan(usize, alphabet.len)]);
                }
            }
        } else {
            for (code[0..len]) |*c| {
                c.* = std.ascii.toUpper(alphabet[rand.uintLessThan(usize, alphabet.len)]);
            }
        }

        var id_bytes: [16]u8 = undefined;
        rand.bytes(&id_bytes);
        // 手写 hex（Zig 0.17 已移除 `std.fmt.fmtSliceHexLower`）
        var id_buf: [32]u8 = undefined;
        const hex_chars = "0123456789abcdef";
        for (id_bytes, 0..) |byte, i| {
            id_buf[i * 2] = hex_chars[byte >> 4];
            id_buf[i * 2 + 1] = hex_chars[byte & 0x0f];
        }
        const id = try arena.dupe(u8, id_buf[0..]);

        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.entries.count() >= self.opts.max_entries) self.evict(now_ms);
        if (self.entries.count() >= self.opts.max_entries) self.clearAllLocked();

        const key = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(key);
        const answer = try self.allocator.dupe(u8, code[0..len]);
        errdefer self.allocator.free(answer);
        try self.entries.put(self.allocator, key, .{
            .answer = answer,
            .expires_ms = now_ms + self.opts.ttl_seconds * 1000,
        });

        return .{ .id = id, .code = try arena.dupe(u8, code[0..len]) };
    }

    /// 一次性校验（大小写不敏感）；无论对错都消费掉该 id，防重放。
    pub fn take(self: *Store, id: []const u8, answer: []const u8, now_ms: i64) bool {
        if (id.len == 0) return false;

        self.mutex.lock();
        defer self.mutex.unlock();

        const removed = self.entries.fetchRemove(id) orelse return false;
        self.allocator.free(removed.key);
        defer self.allocator.free(removed.value.answer);

        if (now_ms > removed.value.expires_ms) return false;
        const trimmed = std.mem.trim(u8, answer, " \t\r\n");
        if (trimmed.len != removed.value.answer.len) return false;
        return std.ascii.eqlIgnoreCase(trimmed, removed.value.answer);
    }

    /// 当前条目数（诊断/测试用）。
    pub fn count(self: *Store) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.entries.count();
    }

    /// C# 口径的可重试校验：匹配且 `consume=true` 时才删除；不匹配**保留**，
    /// 允许用户改输重新提交（与 `DH.SLazyCaptcha` + `AccountController.Login` 一致）。
    pub fn verify(self: *Store, id: []const u8, answer: []const u8, now_ms: i64, consume: bool) bool {
        if (id.len == 0) return false;

        self.mutex.lock();
        defer self.mutex.unlock();

        const entry = self.entries.getEntry(id) orelse return false;
        if (now_ms > entry.value_ptr.expires_ms) {
            const key = entry.key_ptr.*;
            const old = entry.value_ptr.answer;
            _ = self.entries.remove(key);
            self.allocator.free(key);
            self.allocator.free(old);
            return false;
        }

        const trimmed = std.mem.trim(u8, answer, " \t\r\n");
        if (trimmed.len != entry.value_ptr.answer.len) return false;
        if (!std.ascii.eqlIgnoreCase(trimmed, entry.value_ptr.answer)) return false;

        if (consume) {
            const key = entry.key_ptr.*;
            const old = entry.value_ptr.answer;
            _ = self.entries.remove(key);
            self.allocator.free(key);
            self.allocator.free(old);
        }
        return true;
    }

    /// 登录成功后清理（`verify(..., false)` 之后再调，避免口令错时浪费验证码）。
    pub fn remove(self: *Store, id: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.entries.fetchRemove(id)) |removed| {
            self.allocator.free(removed.key);
            self.allocator.free(removed.value.answer);
        }
    }

    // ---- 内部（调用方必须已持锁）----

    fn evict(self: *Store, now_ms: i64) void {
        var doomed: std.ArrayListUnmanaged([]const u8) = .empty;
        defer doomed.deinit(self.allocator);

        var it = self.entries.iterator();
        while (it.next()) |kv| {
            if (now_ms > kv.value_ptr.expires_ms) {
                doomed.append(self.allocator, kv.key_ptr.*) catch break;
            }
        }
        for (doomed.items) |key| {
            if (self.entries.fetchRemove(key)) |removed| {
                self.allocator.free(removed.key);
                self.allocator.free(removed.value.answer);
            }
        }
    }

    fn clearAllLocked(self: *Store) void {
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            self.allocator.free(kv.key_ptr.*);
            self.allocator.free(kv.value_ptr.answer);
        }
        self.entries.clearRetainingCapacity();
    }
};

/// 签发结果：`id` 放 Cookie，`code` 用于渲染。
pub const Issue = struct {
    id: []const u8,
    code: []const u8,
};

/// 渲染成 SVG（每个字符随机旋转/位移，叠加干扰线与噪点）。
pub fn renderSvg(arena: std.mem.Allocator, code: []const u8) ![]u8 {
    const rand = csprng();
    const width: usize = 34 + code.len * 28;
    const height: usize = 44;

    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    const w = &out.writer;
    try w.print(
        "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{d}\" height=\"{d}\" viewBox=\"0 0 {d} {d}\" role=\"img\" aria-label=\"验证码\">",
        .{ width, height, width, height },
    );
    try w.writeAll("<rect width=\"100%\" height=\"100%\" fill=\"#f4f6fb\"/>");

    // 干扰线（2 条，走向随机）
    var line: usize = 0;
    while (line < 2) : (line += 1) {
        const y1 = rand.uintLessThan(usize, height);
        const y2 = rand.uintLessThan(usize, height);
        try w.print(
            "<path d=\"M0 {d} Q {d} {d} {d} {d}\" stroke=\"#c9d4e6\" stroke-width=\"1.5\" fill=\"none\"/>",
            .{ y1, width / 2, rand.uintLessThan(usize, height), width, y2 },
        );
    }

    var index: usize = 0;
    while (index < code.len) : (index += 1) {
        const x = 12 + index * 28 + rand.uintLessThan(usize, 5);
        const y = 30 + rand.uintLessThan(usize, 5);
        const angle = @as(i32, @intCast(rand.uintLessThan(usize, 25))) - 12;
        const color = partyColor(rand);
        try w.print(
            "<text x=\"{d}\" y=\"{d}\" font-family=\"Georgia, 'Times New Roman', serif\" font-size=\"26\" font-weight=\"700\" fill=\"{s}\" transform=\"rotate({d} {d} {d})\">{c}</text>",
            .{ x, y, color, angle, x, y, code[index] },
        );
    }

    // 噪点
    var dot: usize = 0;
    while (dot < 18) : (dot += 1) {
        const cx = rand.uintLessThan(usize, width);
        const cy = rand.uintLessThan(usize, height);
        try w.print(
            "<circle cx=\"{d}\" cy=\"{d}\" r=\"1\" fill=\"#aab6c8\" opacity=\"0.7\"/>",
            .{ cx, cy },
        );
    }

    try w.writeAll("</svg>");
    return out.toOwnedSlice();
}

fn partyColor(rand: std.Random) []const u8 {
    const palette = [_][]const u8{ "#26406e", "#1f5f4b", "#6b2f5c", "#7a3b12", "#1b4e6e" };
    return palette[rand.uintLessThan(usize, palette.len)];
}

// ============ 多方案渲染 ============

/// 渲染结果（base64 不含 `data:` 前缀，`mime` 由调用方拼 data URI）。
pub const Rendered = struct {
    mime: []const u8,
    base64: []const u8,
};

/// 签发 + 渲染（一次拿到可直接回给前端的 base64 与 mime）。
pub const IssueImage = struct {
    id: []const u8,
    code: []const u8,
    mime: []const u8,
    base64: []const u8,
};

pub fn issueImage(self: *Store, arena: std.mem.Allocator, now_ms: i64, fixed_code: ?[]const u8) !IssueImage {
    const issue = try self.issueWithCode(arena, now_ms, fixed_code);
    const rendered = try renderBase64(arena, issue.code, self.opts.renderer);
    return .{
        .id = issue.id,
        .code = issue.code,
        .mime = rendered.mime,
        .base64 = rendered.base64,
    };
}

/// 按方案渲染成 base64（存储/校验逻辑与渲染完全解耦，新增方案只改这里）。
pub fn renderBase64(arena: std.mem.Allocator, code: []const u8, renderer: Renderer) !Rendered {
    const raw = switch (renderer) {
        .svg => try renderSvg(arena, code),
        .gif => try renderGif(arena, code),
    };
    return .{ .mime = renderer.mime(), .base64 = try base64Alloc(arena, raw) };
}

pub fn base64Alloc(arena: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    const encoder = std.base64.standard.Encoder;
    const size = encoder.calcSize(bytes.len);
    const out = try arena.alloc(u8, size);
    _ = encoder.encode(out, bytes);
    return out;
}

const gif_width: usize = 90;
const gif_height: usize = 38;
const GifCanvas = [gif_width * gif_height]u8;

fn gifPutPixel(canvas: *GifCanvas, x: i32, y: i32, color: u8) void {
    if (x < 0 or y < 0 or x >= @as(i32, @intCast(gif_width)) or y >= @as(i32, @intCast(gif_height))) return;
    canvas[@as(usize, @intCast(y)) * gif_width + @as(usize, @intCast(x))] = color;
}

fn gifFillRect(canvas: *GifCanvas, x: i32, y: i32, w: i32, h: i32, color: u8) void {
    var dy: i32 = 0;
    while (dy < h) : (dy += 1) {
        var dx: i32 = 0;
        while (dx < w) : (dx += 1) gifPutPixel(canvas, x + dx, y + dy, color);
    }
}

/// 七段数码管（GIF 方案只支持 `digits` 字符集；其它字符会被跳过）。
fn gifDrawDigit(canvas: *GifCanvas, digit: u8, x: i32, y: i32, scale: i32, color: u8) void {
    const mask: u8 = switch (digit) {
        '2' => 0b1011011,
        '3' => 0b1001111,
        '4' => 0b1100110,
        '5' => 0b1101101,
        '6' => 0b1111101,
        '7' => 0b0000111,
        '8' => 0b1111111,
        '9' => 0b1101111,
        else => 0,
    };
    if (mask == 0) return;

    const seg_len = 5 * scale;
    const thick = scale;
    const top_y = y;
    const mid_y = y + 3 * scale;
    const bot_y = y + 6 * scale;
    const left_x = x;
    const right_x = x + 4 * scale;

    if (mask & 1 != 0) gifFillRect(canvas, left_x, top_y, seg_len, thick, color);
    if (mask & 2 != 0) gifFillRect(canvas, right_x, top_y, thick, 4 * scale, color);
    if (mask & 4 != 0) gifFillRect(canvas, right_x, mid_y, thick, 4 * scale, color);
    if (mask & 8 != 0) gifFillRect(canvas, left_x, bot_y, seg_len, thick, color);
    if (mask & 16 != 0) gifFillRect(canvas, left_x, mid_y, thick, 4 * scale, color);
    if (mask & 32 != 0) gifFillRect(canvas, left_x, top_y, thick, 4 * scale, color);
    if (mask & 64 != 0) gifFillRect(canvas, left_x, mid_y, seg_len, thick, color);
}

fn renderGif(arena: std.mem.Allocator, code: []const u8) ![]u8 {
    var canvas: GifCanvas = undefined;
    @memset(&canvas, 0);

    const rand = csprng();

    var line: usize = 0;
    while (line < 3) : (line += 1) {
        var x: i32 = 0;
        var y: i32 = rand.intRangeAtMost(i32, 2, @as(i32, @intCast(gif_height)) - 2);
        const step: i32 = if (rand.boolean()) 1 else -1;
        while (x < gif_width) : (x += 1) {
            y += step;
            if (y < 1 or y > @as(i32, @intCast(gif_height)) - 2) break;
            gifPutPixel(&canvas, x, y, 2);
        }
    }

    var dot: usize = 0;
    while (dot < 26) : (dot += 1) {
        gifPutPixel(
            &canvas,
            rand.intRangeAtMost(i32, 0, @as(i32, @intCast(gif_width)) - 1),
            rand.intRangeAtMost(i32, 0, @as(i32, @intCast(gif_height)) - 1),
            3,
        );
    }

    const scale: i32 = 3;
    const digit_width = 5 * scale;
    const gap = 2;
    const total = @as(i32, @intCast(code.len)) * digit_width + @as(i32, @intCast(code.len - 1)) * gap;
    const start_x = @divTrunc(@as(i32, gif_width) - total, 2);
    for (code, 0..) |ch, index| {
        const x = start_x + @as(i32, @intCast(index)) * (digit_width + gap) + rand.intRangeAtMost(i32, -1, 1);
        gifDrawDigit(&canvas, ch, x, 8 + rand.intRangeAtMost(i32, -2, 2), scale, 1);
    }

    return encodeGif(arena, &canvas);
}

/// GIF89a（8 色调色板；LZW 只发 Clear/字面码，不做字典压缩）。
fn encodeGif(arena: std.mem.Allocator, canvas: *const GifCanvas) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(arena);

    try out.appendSlice(arena, "GIF89a");
    var header: [4]u8 = undefined;
    std.mem.writeInt(u16, header[0..2], @intCast(gif_width), .little);
    std.mem.writeInt(u16, header[2..4], @intCast(gif_height), .little);
    try out.appendSlice(arena, &header);
    try out.appendSlice(arena, &.{ 0xF7, 0x00, 0x00 });

    const palette = [_][3]u8{
        .{ 255, 255, 255 },
        .{ 20, 30, 60 },
        .{ 60, 110, 200 },
        .{ 180, 190, 205 },
        .{ 0, 0, 0 },
        .{ 0, 0, 0 },
        .{ 0, 0, 0 },
        .{ 0, 0, 0 },
    };
    for (palette) |rgb| try out.appendSlice(arena, &rgb);

    try out.append(arena, 0x2C);
    var idesc: [9]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    std.mem.writeInt(u16, idesc[4..6], @intCast(gif_width), .little);
    std.mem.writeInt(u16, idesc[6..8], @intCast(gif_height), .little);
    try out.appendSlice(arena, &idesc);

    const min_code_size: u8 = 3;
    try out.append(arena, min_code_size);

    var data: std.ArrayList(u8) = .empty;
    defer data.deinit(arena);
    try lzwEncode(arena, canvas, min_code_size, &data);

    var offset: usize = 0;
    while (offset < data.items.len) {
        const chunk = @min(@as(usize, 255), data.items.len - offset);
        try out.append(arena, @intCast(chunk));
        try out.appendSlice(arena, data.items[offset .. offset + chunk]);
        offset += chunk;
    }
    try out.append(arena, 0x00);
    try out.append(arena, 0x3B);

    return out.toOwnedSlice(arena);
}

fn lzwEncode(arena: std.mem.Allocator, canvas: *const GifCanvas, min_code_size: u8, out: *std.ArrayList(u8)) !void {
    const clear: u16 = @as(u16, 1) << @intCast(min_code_size);
    const end: u16 = clear + 1;

    var code_size: u5 = @intCast(min_code_size + 1);
    var next_code: u16 = clear + 2;
    var first = true;

    var bits: u64 = 0;
    var bit_count: u6 = 0;

    const Emitter = struct {
        fn emit(o: *std.ArrayList(u8), a: std.mem.Allocator, bits_in: *u64, count_in: *u6, code: u16, size: u5) !void {
            bits_in.* |= @as(u64, code) << @intCast(count_in.*);
            count_in.* += @as(u6, size);
            while (count_in.* >= 8) {
                try o.append(a, @intCast(bits_in.* & 0xFF));
                bits_in.* >>= 8;
                count_in.* -= 8;
            }
        }
    };

    try Emitter.emit(out, arena, &bits, &bit_count, clear, code_size);

    for (canvas.*) |pixel| {
        try Emitter.emit(out, arena, &bits, &bit_count, pixel, code_size);

        if (!first) {
            next_code += 1;
            if (next_code == (@as(u16, 1) << @intCast(code_size))) {
                if (code_size < 12) code_size += 1;
            }
            if (next_code >= 4095) {
                try Emitter.emit(out, arena, &bits, &bit_count, clear, code_size);
                code_size = @intCast(min_code_size + 1);
                next_code = clear + 2;
                first = true;
            }
        }
        first = false;
    }

    try Emitter.emit(out, arena, &bits, &bit_count, end, code_size);
    if (bit_count > 0) try out.append(arena, @intCast(bits & 0xFF));
}

// ============ 测试 ============

const testing = std.testing;

test "zzig.web.captcha：签发后可用正确值校验一次，第二次失败" {
    var store = Store.init(testing.allocator, .{});
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const issue = try store.issue(arena.allocator(), 1_000_000);
    try testing.expectEqual(@as(usize, 4), issue.code.len);
    try testing.expect(store.take(issue.id, issue.code, 1_000_001));
    // 一次性：重复校验必须失败
    try testing.expect(!store.take(issue.id, issue.code, 1_000_002));
}

test "zzig.web.captcha：大小写不敏感 + 过期失效" {
    var store = Store.init(testing.allocator, .{ .ttl_seconds = 1 });
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const first = try store.issue(arena.allocator(), 0);
    var lower_buf: [16]u8 = undefined;
    const lower = std.ascii.lowerString(lower_buf[0..first.code.len], first.code);
    try testing.expect(store.take(first.id, lower, 500));

    const second = try store.issue(arena.allocator(), 0);
    try testing.expect(!store.take(second.id, second.code, 5000));
}

test "zzig.web.captcha：SVG 含字符且为合法开头" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const svg = try renderSvg(arena.allocator(), "A7KM");
    try testing.expect(std.mem.startsWith(u8, svg, "<svg"));
    try testing.expect(std.mem.endsWith(u8, svg, "</svg>"));
    try testing.expect(std.mem.indexOf(u8, svg, ">A<") != null);
    try testing.expect(std.mem.indexOf(u8, svg, ">M<") != null);
}

test "zzig.web.captcha：固定答案 + 可重试校验（错误不消耗，成功才删除）" {
    var store = Store.init(testing.allocator, .{ .charset = digits });
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const issue = try store.issueWithCode(arena.allocator(), 1_000_000, "2345");
    try testing.expectEqualStrings("2345", issue.code);
    try testing.expect(!store.verify(issue.id, "9999", 1_000_001, true));
    // 错误一次后仍可用正确值（C# 缓存不删的语义）
    try testing.expect(store.verify(issue.id, "2345", 1_000_002, true));
    // 成功后已消费
    try testing.expect(!store.verify(issue.id, "2345", 1_000_003, false));
}

test "zzig.web.captcha：GIF 方案输出 GIF89a 且 base64 可解码" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const rendered = try renderBase64(arena.allocator(), "2345", .gif);
    try testing.expectEqualStrings("image/gif", rendered.mime);
    try testing.expect(rendered.base64.len > 100);

    const decoder = std.base64.standard.Decoder;
    const raw_len = try decoder.calcSizeForSlice(rendered.base64);
    const raw = try arena.allocator().alloc(u8, raw_len);
    try decoder.decode(raw, rendered.base64);
    try testing.expect(std.mem.startsWith(u8, raw, "GIF89a"));
    try testing.expectEqual(@as(u8, 0x3B), raw[raw.len - 1]);
}
