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
};

/// 达到多少次失败后才要求验证码（低于封禁阈值：用户 5 / IP 10）。
pub const require_for_fails: u32 = 3;

const charset = "23456789abcdefghjkmnpqrstuvwxyz";

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
        const rand = csprng();
        var code: [16]u8 = undefined;
        const len = @min(self.opts.length, code.len);
        for (code[0..len]) |*c| {
            const index = rand.uintLessThan(usize, charset.len);
            c.* = std.ascii.toUpper(charset[index]);
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
