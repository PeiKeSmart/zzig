//! 配置热加载（**通用**）：变化驱动的 `stat` 节流 + 解析失败保旧 + 版本宽限回收 + 请求中间件。
//!
//! 为什么进框架：这套「stat 节流 → 只在变化时读盘解析 → 原子切换指针 → 旧版本留一段宽限期」
//! 在多个 Zig 站点里各写了一份（本项目与兄弟站 `Pek.ZTools/src/hot_config.zig` 同款），
//! 差异只有「配置结构体」与「怎么解析」。于是把机器留在这里，业务只提供三件事：
//!
//! 1. `T`：配置结构体（由 `parse` 负责分配、`destroy` 负责释放）；
//! 2. `parse` / `destroy` 回调（**解析失败不许崩**，返回 error 即保留旧配置）；
//! 3. 模板文本 + 缺键补齐（`zzig.config.toml_template`）与可选 `on_change` 回调。
//!
//! 口径（对齐「资源与带宽惯例」）：
//! - **变化驱动**：最多每 `retry_seconds` 秒做一次 `stat`（mtime + size），无变化不读盘、不解析；
//! - **解析失败保留旧配置**（打日志说明原因），不会把站点打挂；
//! - **每份配置各自一个 arena**，切换后旧版本保留 `retention_seconds` 秒（并发请求能安全读到旧切片）；
//! - **时钟不可用时不做节流**：某些平台 `nowUnix()` 恒为 0 的历史 bug 会让 `0 < next` 永远成立、
//!   热加载被静默关死，这里显式兜住。
//!
//! ```zig
//! pub const HotConfig = zzig.config.hot.Hot(Settings);
//!
//! self.hot = try HotConfig.init(.{
//!     .allocator = allocator,
//!     .io = io,
//!     .path = path,
//!     .template = template,          // 缺文件时按它生成
//!     .hooks = .{ .ctx = self, .parse = parseSettings, .destroy = destroySettings },
//! });
//! ```

const std = @import("std");
const FileText = @import("file.zig").FileText;
const fsio = @import("../file/fsio.zig");
const Logger = @import("../logs/logger.zig");
const DateTime = @import("../time/datetime.zig").DateTime;
const router = @import("../http/router.zig");

/// 默认检查间隔（秒）：无变化时一个请求只做一次整数比较。
pub const DEFAULT_RETRY_SECONDS: i64 = 2;
/// 默认旧版本保留时长（秒）：超过且已非当前版本则回收（防长期编辑导致内存无界）。
pub const DEFAULT_RETENTION_SECONDS: i64 = 600;

pub fn Hot(comptime T: type) type {
    return struct {
        const Self = @This();

        /// 业务侧钩子（`ctx` 由调用方保管，回调在热加载线程 / 请求线程内同步调用）。
        pub const Hooks = struct {
            ctx: ?*anyopaque = null,
            /// 解析配置；返回的 `*T` 由 `destroy` 释放。**失败必须返回 error 而不是 panic**。
            parse: *const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator, text: []const u8) anyerror!*T,
            /// 释放 `parse` 返回的对象（含其内部 arena）。
            destroy: *const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator, value: *T) void,
            /// 切换**之前**调用（先应用新值、再让新指针生效，避免片刻不一致）。
            on_change: ?*const fn (ctx: ?*anyopaque, value: *const T) void = null,
        };

        pub const Options = struct {
            allocator: std.mem.Allocator,
            io: std.Io,
            /// 配置文件绝对路径
            path: []const u8,
            /// 文件缺失时写出的模板内容（可为空串 = 不生成）
            template: []const u8 = "",
            hooks: Hooks,
            retry_seconds: i64 = DEFAULT_RETRY_SECONDS,
            retention_seconds: i64 = DEFAULT_RETENTION_SECONDS,
            /// 日志前缀（如 `[hailinxcom]`），便于多实例日志区分
            log_tag: []const u8 = "[config]",
        };

        /// 配置版本（`created_at` 用于宽限期回收）。
        const Version = struct { value: *T, created_at: i64 };

        allocator: std.mem.Allocator,
        io: std.Io,
        path: []u8,
        file: FileText,
        hooks: Hooks,
        retry_seconds: i64,
        retention_seconds: i64,
        log_tag: []const u8,
        mutex: std.Io.Mutex = .init,
        versions: std.ArrayList(Version) = .empty,
        /// 当前生效版本（原子切换；旧版本在 `retention_seconds` 内保留）
        current: std.atomic.Value(*T),
        next_check_at: std.atomic.Value(i64) = .init(0),

        /// 打开（缺失时按 `template` 生成）并解析当前配置。
        pub fn init(opts: Options) !*Self {
            const allocator = opts.allocator;
            const self = try allocator.create(Self);
            errdefer allocator.destroy(self);

            const path = try allocator.dupe(u8, opts.path);
            errdefer allocator.free(path);

            var file = try FileText.open(opts.io, allocator, path, opts.template, .{ .create_on_missing = true });
            errdefer file.deinit();

            const initial = try opts.hooks.parse(opts.hooks.ctx, allocator, file.current());
            errdefer opts.hooks.destroy(opts.hooks.ctx, allocator, initial);

            self.* = .{
                .allocator = allocator,
                .io = opts.io,
                .path = path,
                .file = file,
                .hooks = opts.hooks,
                .retry_seconds = opts.retry_seconds,
                .retention_seconds = opts.retention_seconds,
                .log_tag = opts.log_tag,
                .current = .init(initial),
            };
            try self.versions.append(allocator, .{ .value = initial, .created_at = DateTime.nowUnix() });
            return self;
        }

        pub fn deinit(self: *Self) void {
            for (self.versions.items) |item| self.hooks.destroy(self.hooks.ctx, self.allocator, item.value);
            self.versions.deinit(self.allocator);
            self.file.deinit();
            self.allocator.free(self.path);
            self.allocator.destroy(self);
        }

        /// 当前生效的配置（永不为 null；切换过程中读到的是旧版本，安全）。
        pub fn settings(self: *const Self) *const T {
            return self.current.load(.acquire);
        }

        /// 注册（或替换）变更回调。
        pub fn watchChanges(self: *Self, ctx: ?*anyopaque, func: *const fn (ctx: ?*anyopaque, value: *const T) void) void {
            self.hooks.ctx = ctx;
            self.hooks.on_change = func;
        }

        /// 按节流周期检查一次；有变化则应用并回调。
        pub fn maybeReload(self: *Self) void {
            const now = DateTime.nowUnix();
            const next = self.next_check_at.load(.monotonic);
            // `now == 0` 说明平台时钟不可用（历史 bug：Linux 上 nowUnix 恒为 0）——
            // 此时**不做节流**，否则 `0 < next` 永远成立，热加载会被静默关死。
            if (now > 0 and now < next) return;
            if (now > 0) {
                if (self.next_check_at.cmpxchgStrong(next, now + self.retry_seconds, .monotonic, .monotonic) != null) return;
            }

            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);

            const changed = self.file.reloadIfChanged(.{}) catch |err| {
                Logger.err("{s} 配置检查失败（继续使用当前配置）：{s}（{s}）", .{ self.log_tag, self.path, @errorName(err) });
                return;
            };
            if (!changed) return;

            const next_value = self.hooks.parse(self.hooks.ctx, self.allocator, self.file.current()) catch |err| {
                Logger.err("{s} 配置解析失败（保持当前配置）：{s}（{s}）", .{ self.log_tag, self.path, @errorName(err) });
                return;
            };

            self.versions.append(self.allocator, .{
                .value = next_value,
                .created_at = DateTime.nowUnix(),
            }) catch |err| {
                self.hooks.destroy(self.hooks.ctx, self.allocator, next_value);
                Logger.err("{s} 配置切换失败（{s}）", .{ self.log_tag, @errorName(err) });
                return;
            };

            // 先应用（区域切换等副作用），再切换指针：避免片刻「链接指向新值、路由还是旧值」。
            if (self.hooks.on_change) |func| func(self.hooks.ctx, next_value);
            self.current.store(next_value, .release);
            Logger.info("{s} 配置已热加载：{s}", .{ self.log_tag, self.path });
            self.sweepRetired();
        }

        /// 回收超出宽限期的旧版本（当前版本永不回收）。
        fn sweepRetired(self: *Self) void {
            const current = self.current.load(.acquire);
            const cutoff = DateTime.nowUnix() - self.retention_seconds;
            var index: usize = 0;
            while (index < self.versions.items.len) {
                const item = self.versions.items[index];
                if (item.value != current and item.created_at < cutoff) {
                    self.hooks.destroy(self.hooks.ctx, self.allocator, item.value);
                    _ = self.versions.orderedRemove(index);
                    continue;
                }
                index += 1;
            }
        }

        /// 中间件：每个请求节流检查一次（无变化时只做一次内存时间比较）。
        pub fn middleware(self: *Self) router.Middleware {
            return .{ .ctx = @ptrCast(self), .call = middlewareCall };
        }

        fn middlewareCall(raw: ?*anyopaque, c: *router.Ctx, next: router.Next) anyerror!router.Response {
            const self: *Self = @ptrCast(@alignCast(raw orelse return error.MissingContext));
            self.maybeReload();
            return next.run(c);
        }
    };
}

// ————— 单测：用最小结构体验证「解析失败保旧 / 变化才切换 / 旧版本回收不越界」————

const TestSettings = struct {
    arena: std.heap.ArenaAllocator,
    name: []const u8,
};

fn testParse(_: ?*anyopaque, allocator: std.mem.Allocator, text: []const u8) anyerror!*TestSettings {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const name = blk: {
        // 极简解析：`Name = xxx` 行；没有就用整段文本
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (std.mem.startsWith(u8, trimmed, "Name = ")) break :blk try a.dupe(u8, trimmed["Name = ".len..]);
        }
        break :blk try a.dupe(u8, std.mem.trim(u8, text, " \t\r\n"));
    };
    if (std.mem.eql(u8, name, "BAD")) return error.BadConfig;
    const value = try a.create(TestSettings);
    value.* = .{ .arena = arena, .name = name };
    return value;
}

fn testDestroy(_: ?*anyopaque, _: std.mem.Allocator, value: *TestSettings) void {
    value.arena.deinit();
}

fn testOnChange(ctx: ?*anyopaque, value: *const TestSettings) void {
    const counter: *usize = @ptrCast(@alignCast(ctx orelse return));
    counter.* = value.name.len;
}

test "zzig.config.hot：只改文件才切换，解析失败保留旧配置" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(path);

    const config_path = try std.fmt.allocPrint(a, "{s}/app.toml", .{path});
    defer a.free(config_path);

    var changed_len: usize = 0;
    const HotTest = Hot(TestSettings);
    const hot = try HotTest.init(.{
        .allocator = a,
        .io = std.testing.io,
        .path = config_path,
        .template = "Name = first\n",
        .retry_seconds = 0,
        .hooks = .{ .ctx = &changed_len, .parse = testParse, .destroy = testDestroy, .on_change = testOnChange },
    });
    defer hot.deinit();

    // 首次解析**不触发** on_change（回调只在「真的变了」时来），当前值立即可读。
    try std.testing.expectEqualStrings("first", hot.settings().name);
    try std.testing.expectEqual(@as(usize, 0), changed_len);

    // 无变化：不切换
    hot.maybeReload();
    try std.testing.expectEqualStrings("first", hot.settings().name);

    // 正常改值：切换 + 回调
    try fsio.writeFile(io, config_path, "Name = second\n");
    hot.maybeReload();
    try std.testing.expectEqualStrings("second", hot.settings().name);
    try std.testing.expectEqual(@as(usize, 6), changed_len);

    // 改坏：保留上一次成功解析的配置
    try fsio.writeFile(io, config_path, "Name = BAD\n");
    hot.maybeReload();
    try std.testing.expectEqualStrings("second", hot.settings().name);
}
