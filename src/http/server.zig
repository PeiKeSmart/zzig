//! 极简 HTTP/1.1 服务端（服务型接口用：数据库远程服务、内部 API）。
//!
//! 为什么自建：Zig 标准库有 `std.http.Server`（协议解析），但**没有**「监听 + 线程 + 上限」这层。
//! 本文件只补这一层，协议解析仍交给 std，不重复实现。
//!
//! 口径：
//! - 请求体上限（默认 1 MB）、连接数上限（超限直接关，不排队不分配线程）、每连接独立 arena；
//! - 默认 `Connection: close`（不复用连接，最简单也最安全）；
//! - **鉴权/限流不在这里**：传输层只管收发，令牌/白名单/限流由业务层做。
//!
//! 线程与 Io（踩坑记录）：`Io` 实例必须用**线程安全**的分配器构造
//! （仓库里统一用 `std.heap.page_allocator`）；给 `Io.Threaded.init` 传 `testing.allocator`
//! 这类带检查的非线程安全分配器，会在 accept 相关的内部路径上直接 panic。

const std = @import("std");
const compat = @import("../compat.zig");

/// 业务回调看到的请求视图（只在本次调用内有效）。
pub const RequestView = struct {
    method: std.http.Method,
    /// 原始目标（含查询串）
    target: []const u8,
    /// 路径部分（`?` 之前）
    path: []const u8,
    /// 查询串（`?` 之后，无则为空）
    query: []const u8,
    body: []const u8,
    /// 原始请求头（名称小写，值原样；已复制到本次请求的 arena）。
    /// 鉴权/限流/追踪等业务层规则需要它；传输层本身不解读。
    headers: []const std.http.Header = &.{},
};

/// 业务回调要回的响应。
pub const Reply = struct {
    status: std.http.Status = .ok,
    body: []const u8 = "",
    content_type: []const u8 = "application/json; charset=utf-8",
};

pub const Options = struct {
    /// 请求体上限（数据库请求是几 KB 级 JSON）
    max_body: usize = 1024 * 1024,
    /// 同时处理连接数上限（超限立刻关连接）
    max_connections: usize = 64,
};

/// 处理函数：`reply.body` 必须自己分配，或借用 `arena`。
pub const HandlerFn = *const fn (ctx: *anyopaque, req: RequestView, arena: std.mem.Allocator) anyerror!Reply;

pub const Server = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    ctx: *anyopaque,
    handler: HandlerFn,
    opts: Options = .{},
    active: std.atomic.Value(usize) = .init(0),
    stopped: std.atomic.Value(bool) = .init(false),
    /// 监听口生命周期保护（`run` 与 `stop` 都可能看它）
    listener_guard: std.Io.Mutex = .init,
    /// `run` 里创建的监听口（仅用于可观测；**不在 `stop` 里关闭**，见下）
    listener: ?*std.Io.net.Server = null,
    /// 唤醒 accept 用的回连地址（由 `run` 记下）
    wake_addr: ?std.Io.net.IpAddress = null,

    /// 阻塞跑监听循环（调用方决定放主线程还是子线程）。
    /// `host` 必须是 IP 字面量；绑不上会返回错误（调用方决定重试还是 SKIP）。
    pub fn run(self: *Server, host: []const u8, port: u16) !void {
        const address = try std.Io.net.IpAddress.parse(host, port);
        var listener = try address.listen(self.io, .{ .reuse_address = true });

        // 绑 0.0.0.0/:: 时，回连要落到回环地址，否则唤醒连接打不进来。
        const wake_host = if (std.mem.eql(u8, host, "0.0.0.0"))
            "127.0.0.1"
        else if (std.mem.eql(u8, host, "::"))
            "::1"
        else
            host;

        self.listener_guard.lockUncancelable(self.io);
        self.listener = &listener;
        self.wake_addr = std.Io.net.IpAddress.parse(wake_host, port) catch null;
        self.listener_guard.unlock(self.io);

        defer {
            self.listener_guard.lockUncancelable(self.io);
            self.listener = null;
            self.wake_addr = null;
            self.listener_guard.unlock(self.io);
            listener.deinit(self.io);
        }

        while (!self.stopped.load(.acquire)) {
            const stream = listener.accept(self.io) catch |e| {
                if (self.stopped.load(.acquire)) return;
                std.debug.print("[zzig.http] accept 失败：{s}\n", .{@errorName(e)});
                continue;
            };
            if (self.stopped.load(.acquire)) {
                // 这是 `stop()` 的回连唤醒包：直接关掉并退出（不处理业务）
                stream.close(self.io);
                return;
            }
            if (self.active.load(.acquire) >= self.opts.max_connections) {
                std.debug.print("[zzig.http] 连接数已达上限 {d}，直接关闭新连接\n", .{self.opts.max_connections});
                stream.close(self.io);
                continue;
            }
            _ = self.active.fetchAdd(1, .acq_rel);
            const th = std.Thread.spawn(.{}, connMain, .{ self, stream }) catch |e| {
                _ = self.active.fetchSub(1, .acq_rel);
                std.debug.print("[zzig.http] 创建连接线程失败：{s}\n", .{@errorName(e)});
                stream.close(self.io);
                continue;
            };
            th.detach();
        }
    }

    /// 让 `run` 退出（幂等）。
    ///
    /// **不关闭监听口**：在 Windows 上从另一个线程关闭正在 accept 的 listener，
    /// 会让 std 内部走到 `netAcceptWindows` 的 `.CANCELLED => unreachable` 直接 panic。
    /// 改为「回连一次」把阻塞中的 accept 唤醒，由 `run` 发现停止标志后自行收尾。
    pub fn stop(self: *Server) void {
        self.stopped.store(true, .release);

        self.listener_guard.lockUncancelable(self.io);
        const wake = self.wake_addr;
        self.listener_guard.unlock(self.io);

        var addr = wake orelse return;
        var stream = addr.connect(self.io, .{ .mode = .stream }) catch return;
        stream.close(self.io);
    }

    fn connMain(self: *Server, stream: std.Io.net.Stream) void {
        defer _ = self.active.fetchSub(1, .acq_rel);
        self.serveOne(stream) catch |e| {
            std.debug.print("[zzig.http] 连接处理结束（{s}）\n", .{@errorName(e)});
        };
        stream.close(self.io);
    }

    /// 处理**一条**连接上的一个请求（单线程可用，便于测试）。
    pub fn serveOne(self: *Server, stream: std.Io.net.Stream) !void {
        var recv_buf: [16 * 1024]u8 = undefined;
        var send_buf: [16 * 1024]u8 = undefined;
        var sr = stream.reader(self.io, &recv_buf);
        var sw = stream.writer(self.io, &send_buf);
        var http = std.http.Server.init(&sr.interface, &sw.interface);

        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        var req = try http.receiveHead();
        const path_end = std.mem.indexOfScalar(u8, req.head.target, '?') orelse req.head.target.len;
        const path = req.head.target[0..path_end];
        const query = if (path_end < req.head.target.len) req.head.target[path_end + 1 ..] else "";

        // 请求头必须在初始化 body 流之前复制：std 明确说明 head_buffer 随后失效。
        var header_list: std.ArrayList(std.http.Header) = .empty;
        var header_it = req.iterateHeaders();
        while (header_it.next()) |h| {
            try header_list.append(arena, .{
                .name = try arena.dupe(u8, h.name),
                .value = try arena.dupe(u8, h.value),
            });
        }

        // 早拒：声明长度超上限就不读 body
        var body: []const u8 = "";
        if (req.head.content_length) |len| {
            if (len > self.opts.max_body) {
                try req.respond("{\"code\":413,\"msg\":\"request body too large\"}", .{
                    .status = .payload_too_large,
                    .extra_headers = &.{.{ .name = "connection", .value = "close" }},
                });
                return;
            }
            if (len > 0) {
                var buf: [4096]u8 = undefined;
                const r = try req.readerExpectContinue(&buf);
                body = r.allocRemaining(arena, .limited(len)) catch |e| {
                    std.debug.print("[zzig.http] 读请求体失败（声明 {d} 字节）：{s}\n", .{ len, @errorName(e) });
                    return e;
                };
            }
        }

        const reply = self.handler(self.ctx, .{
            .method = req.head.method,
            .target = req.head.target,
            .path = path,
            .query = query,
            .body = body,
            .headers = header_list.items,
        }, arena) catch |e| {
            std.debug.print("[zzig.http] 处理 {s} {s} 失败：{s}\n", .{ @tagName(req.head.method), path, @errorName(e) });
            req.respond("{\"code\":500,\"msg\":\"internal error\"}", .{
                .status = .internal_server_error,
                .extra_headers = &.{.{ .name = "connection", .value = "close" }},
            }) catch {};
            return;
        };

        try req.respond(reply.body, .{
            .status = reply.status,
            .extra_headers = &.{
                .{ .name = "content-type", .value = reply.content_type },
                .{ .name = "connection", .value = "close" },
            },
        });
    }
};

const testing = std.testing;

// 端到端：真 TCP 连接 + 真请求/响应。
//
// 线程与 Io 的口径（照抄仓库里已验证可行的回环测试）：
// - **服务端**用 `Io.Threaded.init(page_allocator, .{})` 的 io，且**只在那一个子线程里用**；
// - **客户端**用本线程的 `compat.currentIo()`；
// - 不要把一个 io 实例跨线程共用（`global_single_threaded` 跨线程会 panic），
//   也不要把 `testing.allocator` 传给 `Threaded.init`（该参数要求线程安全）。
test "HTTP 服务端：真 socket 端到端（子线程监听，本线程发请求）" {
    const Ctx = struct {
        server: std.Io.net.Server,
        io: std.Io,
        impl: Server,
        ok: bool = false,

        fn handler(_: *anyopaque, req: RequestView, arena: std.mem.Allocator) anyerror!Reply {
            if (std.mem.eql(u8, req.path, "/echo")) {
                return .{ .body = try std.fmt.allocPrint(arena, "{{\"len\":{d}}}", .{req.body.len}) };
            }
            return .{ .status = .not_found, .body = "{\"code\":404}" };
        }

        fn serve(self: *@This()) void {
            const stream = self.server.accept(self.io) catch return;
            defer stream.close(self.io);
            self.impl.serveOne(stream) catch |e| {
                std.debug.print("[FAIL] serveOne：{s}\n", .{@errorName(e)});
                return;
            };
            self.ok = true;
        }
    };

    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const sio = threaded.io();

    // 端口从 39331 起找一个能绑的；找不到就显式 SKIP（不静默通过）
    var port: u16 = 39331;
    var bound: ?std.Io.net.Server = null;
    while (port < 39350) : (port += 1) {
        const addr = std.Io.net.IpAddress.parse("127.0.0.1", port) catch continue;
        bound = addr.listen(sio, .{ .reuse_address = true }) catch continue;
        break;
    }
    const listener = bound orelse {
        std.debug.print("[SKIP] 39331-39349 端口均不可用，跳过 HTTP 端到端用例\n", .{});
        return;
    };

    var ctx = Ctx{
        .server = listener,
        .io = sio,
        .impl = .{ .gpa = testing.allocator, .io = sio, .ctx = undefined, .handler = Ctx.handler },
    };
    ctx.impl.ctx = @ptrCast(&ctx);
    defer ctx.server.deinit(sio);

    const th = try std.Thread.spawn(.{}, Ctx.serve, .{&ctx});

    // 客户端：本线程的 io（与服务端 io 互不共用）
    const io = compat.currentIo();
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    const stream = std.Io.net.IpAddress.connect(&address, io, .{ .mode = .stream, .protocol = .tcp }) catch |e| {
        th.join();
        std.debug.print("[SKIP] 本机回环 TCP 不可用：{s}\n", .{@errorName(e)});
        return;
    };
    defer stream.close(io);

    var cw_buf: [4096]u8 = undefined;
    var cw = stream.writer(io, &cw_buf);
    try cw.interface.writeAll("POST /echo HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\nhello");
    try cw.interface.flush();

    // 按「读到出现期望内容」为止（`allocRemaining` 会读到对端关闭，而 serveOne 不关连接）
    var cr_buf: [4096]u8 = undefined;
    var cr = stream.reader(io, &cr_buf);
    var resp_buf: [1024]u8 = undefined;
    var got: usize = 0;
    var rounds: usize = 0;
    while (rounds < 16) : (rounds += 1) {
        const n = try cr.interface.readSliceShort(resp_buf[got..]);
        if (n == 0) break;
        got += n;
        if (std.mem.indexOf(u8, resp_buf[0..got], "{\"len\":5}") != null) break;
    }
    th.join();

    try testing.expect(std.mem.indexOf(u8, resp_buf[0..got], "200") != null);
    try testing.expect(std.mem.indexOf(u8, resp_buf[0..got], "{\"len\":5}") != null);
    try testing.expect(ctx.ok);
    std.debug.print("[http] 端到端 OK：收到 {d} 字节响应\n", .{got});
}
