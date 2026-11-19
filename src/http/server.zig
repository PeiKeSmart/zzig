//! 极简 HTTP/1.1 服务端（服务型接口用：数据库远程服务、内部 API）。
//!
//! 为什么自建：Zig 标准库有 `std.http.Server`（协议解析），但**没有**「监听 + 线程 + 上限」这层。
//! 本文件只补这一层，协议解析仍交给 std，不重复实现。
//!
//! 口径：
//! - 请求体上限（默认 1 MB）、连接数上限（超限直接关，不排队不分配线程）、每连接独立 arena；
//! - 默认 HTTP/1.1 **keep-alive**（复用连接；可用 `Options.keep_alive = false` 改回短连接）；
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
    /// 对端地址（`ip:port` 文本，来自 accept 返回的 socket 地址；拿不到时为 `null`）。
    /// WAF / 限流 / IP 名单靠它拿真实来源；不填就等于所有请求都「没有 IP」。
    remote_addr: ?[]const u8 = null,
};

/// 业务回调要回的响应。
pub const Reply = struct {
    status: std.http.Status = .ok,
    body: []const u8 = "",
    content_type: []const u8 = "application/json; charset=utf-8",
    /// 附加响应头（`location`/`etag`/`allow` 等；与 `content-type`/`connection` 重名时以后者为准）
    headers: []const std.http.Header = &.{},
    /// 非空时忽略 `body`，从文件起始位置流式发送 `length` 字节；**句柄由服务端负责关闭**
    file: ?FileBody = null,
    /// 无正文但需声明长度（典型：`HEAD`）；`null` = 由 `body` 长度决定
    content_length: ?u64 = null,
};

/// 文件响应体（大文件用；避免整个读进内存）。
pub const FileBody = struct {
    file: std.Io.File,
    length: u64,
};

pub const Options = struct {
    /// 请求体上限（数据库请求是几 KB 级 JSON）
    max_body: usize = 1024 * 1024,
    /// 同时处理连接数上限（超限立刻关连接）
    ///
    /// 取 512 的理由：**每连接一线程**，浏览器对同一域名默认就开 6 条连接，
    /// 80 个用户同时打开面板就能打满 480 条 —— 原先的 64 会在正常使用下直接拒连、页面白屏。
    /// 上千**长连接**不要靠调大这个值硬扛（线程数与连接数 O(n)），应改用事件循环后端。
    max_connections: usize = 512,
    /// 是否复用连接（HTTP/1.1 keep-alive）；关闭则每个请求结束后立即关连接
    keep_alive: bool = true,
    /// 单连接最多处理的请求数（防长连接长期占用一个线程；`0` 按 1 处理）
    keep_alive_requests: usize = 100,
    /// `Keep-Alive: timeout=N` 提示（秒）；**不做硬超时**，空闲超时建议由前置反代管理
    keep_alive_timeout_secs: u32 = 5,
    /// 是否附加默认安全响应头：
    /// `x-content-type-options: nosniff`（禁止 MIME 猜测）、
    /// `x-frame-options: SAMEORIGIN`（防点击劫持）、
    /// `referrer-policy: no-referrer`（防路径/参数经 referer 外泄）。
    ///
    /// 只加这三个「不依赖页面结构」的头；CSP 会打到内联脚本与外链 CDN，
    /// 必须由业务按自己页面定制，库不默认开。
    security_headers: bool = true,
    /// 是否信任反代转发头（**仅当 TCP 对端是回环时**才采纳，符合「只信任紧邻那一跳」口径）：
    /// `x-real-ip` 优先 → `x-forwarded-for` **末段**。
    /// 开了它，`RequestView.remote_addr` 才是真实客户端 IP（WAF / 限流 / 审计都靠它）；
    /// 不开则恒为 TCP 对端（反代后全是 `127.0.0.1`）。
    trust_forwarded_for: bool = false,
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
        const limit = if (self.opts.keep_alive) @max(self.opts.keep_alive_requests, 1) else 1;
        self.serveWithLimit(stream, limit) catch |e| switch (e) {
            error.HttpConnectionClosing => {},
            else => std.debug.print("[zzig.http] 连接处理结束（{s}）\n", .{@errorName(e)}),
        };
        stream.close(self.io);
    }

    /// 处理**一条**连接上的一个请求（单线程可用，便于测试）。
    pub fn serveOne(self: *Server, stream: std.Io.net.Stream) !void {
        return self.serveWithLimit(stream, 1);
    }

    /// 连接主循环：在同一连接上服务最多 `max_requests` 个请求（keep-alive）。
    fn serveWithLimit(self: *Server, stream: std.Io.net.Stream, max_requests: usize) !void {
        var recv_buf: [16 * 1024]u8 = undefined;
        var send_buf: [16 * 1024]u8 = undefined;
        var sr = stream.reader(self.io, &recv_buf);
        var sw = stream.writer(self.io, &send_buf);
        var http = std.http.Server.init(&sr.interface, &sw.interface);

        // 对端地址（accept 返回的 socket 地址即远端，Windows/POSIX 同口径）：
        // 格式为 `ip:port`（IPv6 为 `[::1]:port`），消费方自行剥端口。
        // 注意：`IpAddress` 只实现了新 `Io.Writer` 接口，`std.fmt` 的 `{}` 会退化成
        // 结构体调试打印（实测输出 `.{ .ip4 = ... }`），必须显式用 `Io.Writer.fixed`。
        var remote_buf: [80]u8 = undefined;
        var remote_writer: std.Io.Writer = .fixed(&remote_buf);
        const remote_addr: ?[]const u8 = blk: {
            stream.socket.address.format(&remote_writer) catch break :blk null;
            break :blk remote_writer.buffered();
        };

        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();

        var served: usize = 0;
        while (served < max_requests) : (served += 1) {
            _ = arena_state.reset(.retain_capacity);
            const keep = try self.handleOne(&http, remote_addr, arena_state.allocator());
            // keep-alive 时必须立即把响应刷给客户端：否则数据滞留在写缓冲里，
            // 客户端会一直等到连接关闭（多请求复用场景直接死锁）。
            try sw.interface.flush();
            if (!keep) return;
        }
    }

    /// 本次响应的头组装开关（安全头 / keep-alive 提示）。
    fn headerOptions(self: *Server, keep: bool) HeaderOptions {
        return .{
            .keep_alive = keep,
            .keep_alive_timeout_secs = self.opts.keep_alive_timeout_secs,
            .security_headers = self.opts.security_headers,
        };
    }

    /// 在已就绪的连接上处理**一个**请求；返回 `true` 表示连接可以继续复用。
    fn handleOne(self: *Server, http: *std.http.Server, tcp_peer: ?[]const u8, arena: std.mem.Allocator) !bool {
        var req = http.receiveHead() catch |e| switch (e) {
            // 客户端主动关闭（或 keep-alive 空闲超时）→ 正常结束
            error.HttpConnectionClosing => return false,
            else => return e,
        };
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

        // 真实客户端 IP：反代场景下 TCP 对端恒为回环，需采纳转发头（只信紧邻那一跳）
        var remote_addr = tcp_peer;
        if (self.opts.trust_forwarded_for) {
            if (tcp_peer) |peer| {
                if (isLoopbackPeer(peer)) {
                    if (headerValue(header_list.items, "x-real-ip")) |value| {
                        const trimmed = std.mem.trim(u8, value, " \t");
                        if (trimmed.len > 0) remote_addr = trimmed;
                    } else if (headerValue(header_list.items, "x-forwarded-for")) |value| {
                        if (lastForwardedFor(value)) |ip| remote_addr = ip;
                    }
                }
            }
        }

        // 连接能否复用：客户端没要求 close、没启用 keep-alive 开关、或用了分块传输（不读 body）都不能复用
        const keep = self.opts.keep_alive and req.head.keep_alive and req.head.transfer_encoding == .none;

        // 早拒：声明长度超上限就不读 body
        var body: []const u8 = "";
        if (req.head.content_length) |len| {
            if (len > self.opts.max_body) {
                const msg = "{\"code\":413,\"msg\":\"request body too large\"}";
                try req.respond(msg, .{
                    .status = .payload_too_large,
                    .keep_alive = false,
                    .extra_headers = try buildHeaders(arena, .{ .body = msg }, self.headerOptions(false)),
                });
                return false;
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
            .remote_addr = remote_addr,
        }, arena) catch |e| {
            std.debug.print("[zzig.http] 处理 {s} {s} 失败：{s}\n", .{ @tagName(req.head.method), path, @errorName(e) });
            const msg = "{\"code\":500,\"msg\":\"internal error\"}";
            req.respond(msg, .{
                .status = .internal_server_error,
                .keep_alive = false,
                .extra_headers = buildHeaders(arena, .{ .body = msg }, self.headerOptions(false)) catch &.{},
            }) catch {};
            return false;
        };

        // 文件响应：流式发送（大文件不整读进内存）
        if (reply.file) |file_body| {
            defer file_body.file.close(self.io);

            var body_buf: [8 * 1024]u8 = undefined;
            var bw = try req.respondStreaming(&body_buf, .{
                .content_length = file_body.length,
                .respond_options = .{
                    .status = reply.status,
                    .keep_alive = keep,
                    .extra_headers = try buildHeaders(arena, reply, self.headerOptions(keep)),
                },
            });

            // HEAD：只发头（respondStreaming 已按 content-length 写好），不读文件。
            // 注意：eliding 分支不会递减 content-length 状态，此处**不能** end()（会断言长度不符），
            // 只把已写的响应头刷出去即可。
            if (req.head.method == .HEAD) {
                try bw.flush();
                return keep;
            }

            // 优先零拷贝（Linux sendfile 走内核 file→socket，不经过用户态内存）；
            // `Unimplemented`（如 Windows）回退到 32 KB 缓冲的读-写循环。
            var read_buf: [32 * 1024]u8 = undefined;
            var file_reader = file_body.file.reader(self.io, &read_buf);
            var remaining = file_body.length;
            var zero_copy = true;
            while (remaining > 0) {
                if (zero_copy) {
                    const n = bw.writer.sendFile(&file_reader, .limited64(remaining)) catch |e| switch (e) {
                        error.Unimplemented => {
                            zero_copy = false;
                            continue;
                        },
                        error.EndOfStream => break,
                        else => return e,
                    };
                    if (n == 0) break;
                    remaining -= n;
                    continue;
                }

                const want: usize = @intCast(@min(remaining, read_buf.len));
                // `readSliceShort` 内部已把 EOF 表示为「返回 0」，只报 ReadFailed
                const n = try file_reader.interface.readSliceShort(read_buf[0..want]);
                if (n == 0) break;
                try bw.writer.writeAll(read_buf[0..n]);
                remaining -= n;
            }

            if (remaining > 0) {
                // 文件被截断：content-length 已声明，不能再 end()（会断言长度不符），
                // 直接返回让连接关闭，并留下可定位的日志。
                std.debug.print(
                    "[zzig.http] 发送文件时被截断：已声明 {d} 字节，还差 {d} 字节\n",
                    .{ file_body.length, remaining },
                );
                return false;
            }
            try bw.end();
            return keep;
        }

        // 无正文但需声明长度（通常 HEAD）：transfer-encoding none + 自填 content-length
        if (reply.content_length) |length| {
            const headers = try buildHeadersWithLength(arena, reply, length, self.headerOptions(keep));
            try req.respond("", .{
                .status = reply.status,
                .transfer_encoding = .none,
                .keep_alive = keep,
                .extra_headers = headers,
            });
            return keep;
        }

        try req.respond(reply.body, .{
            .status = reply.status,
            .keep_alive = keep,
            .extra_headers = try buildHeaders(arena, reply, self.headerOptions(keep)),
        });
        return keep;
    }
};

/// 响应头组装的开关（从 `Options` 拍出来，避免把整个 `*Server` 传给纯函数）。
const HeaderOptions = struct {
    keep_alive: bool,
    keep_alive_timeout_secs: u32,
    security_headers: bool,
};

/// 组装响应头：`content-type` → 默认安全头 → 业务附加头（跳过重名）→ `keep-alive`。
fn buildHeaders(
    arena: std.mem.Allocator,
    reply: Reply,
    opts: HeaderOptions,
) ![]const std.http.Header {
    var headers: std.ArrayList(std.http.Header) = .empty;
    try headers.append(arena, .{ .name = "content-type", .value = reply.content_type });
    if (opts.security_headers) try appendSecurityHeaders(arena, &headers);
    for (reply.headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "content-type")) continue;
        if (std.ascii.eqlIgnoreCase(header.name, "connection")) continue;
        if (std.ascii.eqlIgnoreCase(header.name, "keep-alive")) continue;
        if (std.ascii.eqlIgnoreCase(header.name, "content-length")) continue;
        if (opts.security_headers and isSecurityHeader(header.name)) continue;
        try headers.append(arena, header);
    }
    if (opts.keep_alive) {
        try headers.append(arena, .{
            .name = "keep-alive",
            .value = try std.fmt.allocPrint(arena, "timeout={d}", .{opts.keep_alive_timeout_secs}),
        });
    }
    return headers.items;
}

/// 默认安全响应头（不依赖页面结构，任何响应都安全）。
fn appendSecurityHeaders(arena: std.mem.Allocator, headers: *std.ArrayList(std.http.Header)) !void {
    try headers.append(arena, .{ .name = "x-content-type-options", .value = "nosniff" });
    try headers.append(arena, .{ .name = "x-frame-options", .value = "SAMEORIGIN" });
    try headers.append(arena, .{ .name = "referrer-policy", .value = "no-referrer" });
}

fn isSecurityHeader(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "x-content-type-options") or
        std.ascii.eqlIgnoreCase(name, "x-frame-options") or
        std.ascii.eqlIgnoreCase(name, "referrer-policy");
}

/// 取请求头值（大小写无关；缺失返回 `null`）。
fn headerValue(headers: []const std.http.Header, name: []const u8) ?[]const u8 {
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, name)) return header.value;
    }
    return null;
}

/// `x-forwarded-for` 取**末段**：左侧各段客户端可凭空追加，只有紧邻我们的那一跳代理写入的末段不可伪造。
/// （与 dhrust `panel_auth::client_ip_with_proxy_flag` 同一口径。）
fn lastForwardedFor(value: []const u8) ?[]const u8 {
    const idx = std.mem.lastIndexOfScalar(u8, value, ',') orelse 0;
    const last = std.mem.trim(u8, if (idx == 0) value else value[idx + 1 ..], " \t");
    return if (last.len == 0) null else last;
}

/// TCP 对端是否回环（`127.x.x.x` / `[::1]` / `::1`，含端口）。
fn isLoopbackPeer(peer: []const u8) bool {
    if (std.mem.startsWith(u8, peer, "127.")) return true;
    if (std.mem.startsWith(u8, peer, "[::1]")) return true;
    return std.mem.eql(u8, peer, "::1");
}

/// 同上，但额外带上明确的 `content-length`（无正文的 HEAD 响应）。
fn buildHeadersWithLength(
    arena: std.mem.Allocator,
    reply: Reply,
    length: u64,
    opts: HeaderOptions,
) ![]const std.http.Header {
    var headers: std.ArrayList(std.http.Header) = .empty;
    try headers.append(arena, .{ .name = "content-type", .value = reply.content_type });
    if (opts.security_headers) try appendSecurityHeaders(arena, &headers);
    for (reply.headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "content-type")) continue;
        if (std.ascii.eqlIgnoreCase(header.name, "connection")) continue;
        if (std.ascii.eqlIgnoreCase(header.name, "keep-alive")) continue;
        if (std.ascii.eqlIgnoreCase(header.name, "content-length")) continue;
        if (opts.security_headers and isSecurityHeader(header.name)) continue;
        try headers.append(arena, header);
    }
    try headers.append(arena, .{
        .name = "content-length",
        .value = try std.fmt.allocPrint(arena, "{d}", .{length}),
    });
    if (opts.keep_alive) {
        try headers.append(arena, .{
            .name = "keep-alive",
            .value = try std.fmt.allocPrint(arena, "timeout={d}", .{opts.keep_alive_timeout_secs}),
        });
    }
    return headers.items;
}

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
        /// 对端地址断言结果（在 handler 内算，避免借用请求 arena 的切片）
        remote_ok: bool = false,

        fn handler(raw: *anyopaque, req: RequestView, arena: std.mem.Allocator) anyerror!Reply {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (req.remote_addr) |addr| {
                self.remote_ok = std.mem.startsWith(u8, addr, "127.0.0.1:");
            }
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
    // 对端地址必须拿到（WAF / 限流 / IP 名单全靠它）
    try testing.expect(ctx.remote_ok);
    std.debug.print("[http] 端到端 OK：收到 {d} 字节响应\n", .{got});
}

test "HTTP 服务端：文件流式响应（真 socket，GET + HEAD）" {
    const Ctx = struct {
        server: std.Io.net.Server,
        io: std.Io,
        impl: Server,
        path: []const u8,
        ok: bool = false,

        fn handler(raw: *anyopaque, _: RequestView, _: std.mem.Allocator) anyerror!Reply {
            const self: *@This() = @ptrCast(@alignCast(raw));
            // 每次请求各开一个句柄（服务端负责关闭）
            const file = try std.Io.Dir.cwd().openFile(self.io, self.path, .{});
            return .{
                .content_type = "application/octet-stream",
                .file = .{ .file = file, .length = 10 },
            };
        }

        fn serve(self: *@This()) void {
            const stream = self.server.accept(self.io) catch return;
            defer stream.close(self.io);
            self.impl.serveOne(stream) catch |e| {
                std.debug.print("[FAIL] serveOne（文件流）：{s}\n", .{@errorName(e)});
                return;
            };
            self.ok = true;
        }
    };

    const io = compat.currentIo();
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/http-stream-{d}.bin", .{compat.nanoTimestamp()});
    defer testing.allocator.free(path);
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    {
        var file = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        try file.writeStreamingAll(io, "0123456789");
    }

    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const sio = threaded.io();

    var port: u16 = 39351;
    var bound: ?std.Io.net.Server = null;
    while (port < 39370) : (port += 1) {
        const addr = std.Io.net.IpAddress.parse("127.0.0.1", port) catch continue;
        bound = addr.listen(sio, .{ .reuse_address = true }) catch continue;
        break;
    }
    const listener = bound orelse {
        std.debug.print("[SKIP] 39351-39369 端口均不可用，跳过文件流式用例\n", .{});
        return;
    };

    var ctx = Ctx{
        .server = listener,
        .io = sio,
        .impl = .{ .gpa = testing.allocator, .io = sio, .ctx = undefined, .handler = Ctx.handler },
        .path = path,
    };
    ctx.impl.ctx = @ptrCast(&ctx);
    defer ctx.server.deinit(sio);

    const address = try std.Io.net.IpAddress.parse("127.0.0.1", port);

    // 第一轮：GET —— 校验正文与 content-length
    {
        const th = try std.Thread.spawn(.{}, Ctx.serve, .{&ctx});
        const stream = std.Io.net.IpAddress.connect(&address, io, .{ .mode = .stream, .protocol = .tcp }) catch |e| {
            th.join();
            std.debug.print("[SKIP] 本机回环 TCP 不可用：{s}\n", .{@errorName(e)});
            return;
        };
        defer stream.close(io);

        var cw_buf: [2048]u8 = undefined;
        var cw = stream.writer(io, &cw_buf);
        try cw.interface.writeAll("GET /pkg HTTP/1.1\r\nHost: x\r\n\r\n");
        try cw.interface.flush();

        var cr_buf: [4096]u8 = undefined;
        var cr = stream.reader(io, &cr_buf);
        var resp_buf: [2048]u8 = undefined;
        var got: usize = 0;
        var rounds: usize = 0;
        while (rounds < 16) : (rounds += 1) {
            const n = try cr.interface.readSliceShort(resp_buf[got..]);
            if (n == 0) break;
            got += n;
            if (std.mem.indexOf(u8, resp_buf[0..got], "0123456789") != null) break;
        }
        th.join();

        const response = resp_buf[0..got];
        try testing.expect(std.mem.indexOf(u8, response, "200") != null);
        try testing.expect(std.mem.indexOf(u8, response, "content-length: 10") != null);
        try testing.expect(std.mem.indexOf(u8, response, "0123456789") != null);
        try testing.expect(ctx.ok);
    }

    // 第二轮：HEAD —— 只发头，content-length 必须准确，且不得触发 end() 的长度断言
    {
        ctx.ok = false;
        const th = try std.Thread.spawn(.{}, Ctx.serve, .{&ctx});
        const stream = try std.Io.net.IpAddress.connect(&address, io, .{ .mode = .stream, .protocol = .tcp });
        defer stream.close(io);

        var cw_buf: [2048]u8 = undefined;
        var cw = stream.writer(io, &cw_buf);
        try cw.interface.writeAll("HEAD /pkg HTTP/1.1\r\nHost: x\r\n\r\n");
        try cw.interface.flush();

        var cr_buf: [4096]u8 = undefined;
        var cr = stream.reader(io, &cr_buf);
        var resp_buf: [2048]u8 = undefined;
        var got: usize = 0;
        var rounds: usize = 0;
        while (rounds < 16) : (rounds += 1) {
            const n = try cr.interface.readSliceShort(resp_buf[got..]);
            if (n == 0) break;
            got += n;
            if (std.mem.indexOf(u8, resp_buf[0..got], "\r\n\r\n") != null) break;
        }
        th.join();

        const response = resp_buf[0..got];
        try testing.expect(std.mem.indexOf(u8, response, "200") != null);
        try testing.expect(std.mem.indexOf(u8, response, "content-length: 10") != null);
        try testing.expect(std.mem.indexOf(u8, response, "0123456789") == null);
        try testing.expect(ctx.ok);
        std.debug.print("[http] 文件流式端到端 OK：GET + HEAD 均通过（HEAD 收到 {d} 字节）\n", .{got});
    }
}

/// keep-alive 用例共用的服务端骨架：真监听 + 单连接跑到 `serveWithLimit`。
fn KeepAliveHarness(comptime requests: usize) type {
    return struct {
        server: std.Io.net.Server,
        io: std.Io,
        impl: Server,
        served: usize = 0,
        /// handler 看到的 `req.remote_addr`（固定缓冲，避免借用请求 arena）
        remote_seen: [64]u8 = undefined,
        remote_len: usize = 0,

        fn handler(raw: *anyopaque, req: RequestView, arena: std.mem.Allocator) anyerror!Reply {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.served += 1;
            if (req.remote_addr) |addr| {
                const n = @min(addr.len, self.remote_seen.len);
                @memcpy(self.remote_seen[0..n], addr[0..n]);
                self.remote_len = n;
            } else {
                self.remote_len = 0;
            }
            return .{ .body = try std.fmt.allocPrint(arena, "{{\"path\":\"{s}\"}}", .{req.path}) };
        }

        fn remoteSlice(self: *const @This()) []const u8 {
            return self.remote_seen[0..self.remote_len];
        }

        fn serve(self: *@This()) void {
            const stream = self.server.accept(self.io) catch return;
            defer stream.close(self.io);
            self.impl.serveWithLimit(stream, requests) catch |e| switch (e) {
                error.HttpConnectionClosing => {},
                else => std.debug.print("[FAIL] serveWithLimit：{s}\n", .{@errorName(e)}),
            };
        }
    };
}

/// 读一次响应，直到出现 `needle`（或对端关闭 / 轮次用尽）。
fn readUntil(reader: *std.Io.Reader, buf: []u8, needle: []const u8) !usize {
    var got: usize = 0;
    var rounds: usize = 0;
    while (rounds < 16) : (rounds += 1) {
        const n = reader.readSliceShort(buf[got..]) catch break; // 对端已关（或读失败）都按结束处理
        if (n == 0) break;
        got += n;
        if (std.mem.indexOf(u8, buf[0..got], needle) != null) break;
    }
    return got;
}

test "HTTP 服务端：keep-alive 在同一连接上复用（连发两个请求）" {
    std.debug.print("[trace] === 用例A 开始 ===\n", .{});
    const Ctx = KeepAliveHarness(2);

    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const sio = threaded.io();

    var port: u16 = 39370;
    var bound: ?std.Io.net.Server = null;
    while (port < 39389) : (port += 1) {
        const addr = std.Io.net.IpAddress.parse("127.0.0.1", port) catch continue;
        bound = addr.listen(sio, .{ .reuse_address = true }) catch continue;
        break;
    }
    const listener = bound orelse {
        std.debug.print("[SKIP] 39370-39388 端口均不可用，跳过 keep-alive 用例\n", .{});
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

    const io = compat.currentIo();
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    const stream = std.Io.net.IpAddress.connect(&address, io, .{ .mode = .stream, .protocol = .tcp }) catch |e| {
        th.join();
        std.debug.print("[SKIP] 本机回环 TCP 不可用：{s}\n", .{@errorName(e)});
        return;
    };
    var stream_alive = true;
    defer if (stream_alive) stream.close(io);

    var cw_buf: [4096]u8 = undefined;
    var cw = stream.writer(io, &cw_buf);
    var cr_buf: [4096]u8 = undefined;
    var cr = stream.reader(io, &cr_buf);

    // 请求 1 + 请求 2 一次性发出（HTTP pipelining），验证同一连接能连续服务两个请求
    std.debug.print("[trace] 客户端：写请求 1+2\n", .{});
    try cw.interface.writeAll("GET /one HTTP/1.1\r\nHost: x\r\n\r\nGET /two HTTP/1.1\r\nHost: x\r\n\r\n");
    try cw.interface.flush();
    std.debug.print("[trace] 客户端：已 flush，开始读\n", .{});
    var resp1: [4096]u8 = undefined;
    const got1 = try readUntil(&cr.interface, &resp1, "{\"path\":\"/two\"}");
    std.debug.print("[trace] 客户端：共收到 {d} 字节\n", .{got1});
    try testing.expect(std.mem.indexOf(u8, resp1[0..got1], "{\"path\":\"/one\"}") != null);
    try testing.expect(std.mem.indexOf(u8, resp1[0..got1], "{\"path\":\"/two\"}") != null);
    // 复用提示头必须出现（客户端 / 反代据此判断这条连接还能不能继续用）
    try testing.expect(std.mem.indexOf(u8, resp1[0..got1], "keep-alive") != null);
    // 复用时不得回 `connection: close`
    try testing.expect(std.mem.indexOf(u8, resp1[0..got1], "connection: close") == null);

    // 两个请求由同一条连接服务完 → 服务端按请求上限自行退出
    th.join();
    stream.close(io);
    stream_alive = false;

    try testing.expectEqual(@as(usize, 2), ctx.served);
    std.debug.print("[http] keep-alive OK：同一连接完成 2 个请求（共 {d} 字节）\n", .{got1});
}

test "HTTP 服务端：Connection: close 与 keep_alive=false 都只服务一个请求" {
    const Ctx = KeepAliveHarness(8);

    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const sio = threaded.io();

    var port: u16 = 39390;
    var bound: ?std.Io.net.Server = null;
    while (port < 39409) : (port += 1) {
        const addr = std.Io.net.IpAddress.parse("127.0.0.1", port) catch continue;
        bound = addr.listen(sio, .{ .reuse_address = true }) catch continue;
        break;
    }
    const listener = bound orelse {
        std.debug.print("[SKIP] 39390-39408 端口均不可用，跳过 close 用例\n", .{});
        return;
    };

    var ctx = Ctx{
        .server = listener,
        .io = sio,
        .impl = .{ .gpa = testing.allocator, .io = sio, .ctx = undefined, .handler = Ctx.handler },
    };
    ctx.impl.ctx = @ptrCast(&ctx);
    defer ctx.server.deinit(sio);

    const io = compat.currentIo();
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", port);

    // 轮 1：客户端显式 `Connection: close`
    {
        const th = try std.Thread.spawn(.{}, Ctx.serve, .{&ctx});
        const stream = std.Io.net.IpAddress.connect(&address, io, .{ .mode = .stream, .protocol = .tcp }) catch |e| {
            th.join();
            std.debug.print("[SKIP] 本机回环 TCP 不可用：{s}\n", .{@errorName(e)});
            return;
        };
        var cw_buf: [2048]u8 = undefined;
        var cw = stream.writer(io, &cw_buf);
        var cr_buf: [2048]u8 = undefined;
        var cr = stream.reader(io, &cr_buf);

        // 一次性发两个请求：若服务端错误地复用连接，会额外回一个 `/two` 响应
        try cw.interface.writeAll("GET /one HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\nGET /two HTTP/1.1\r\nHost: x\r\n\r\n");
        try cw.interface.flush();
        var resp: [4096]u8 = undefined;
        const got = try readUntil(&cr.interface, &resp, "{\"path\":\"/one\"}");
        try testing.expect(std.mem.indexOf(u8, resp[0..got], "connection: close") != null);
        try testing.expect(std.mem.indexOf(u8, resp[0..got], "keep-alive") == null);

        // 服务端应已关连接：第二段请求拿不到响应
        var resp_after: [512]u8 = undefined;
        const got_after = try readUntil(&cr.interface, &resp_after, "{\"path\":\"/two\"}");
        try testing.expectEqual(@as(usize, 0), got_after);

        th.join();
        stream.close(io);
        try testing.expectEqual(@as(usize, 1), ctx.served);
    }

    // 轮 2：服务端关掉 keep_alive（客户端没要求 close 也不复用）
    {
        ctx.impl.opts.keep_alive = false;
        ctx.served = 0;
        const th = try std.Thread.spawn(.{}, Ctx.serve, .{&ctx});
        const stream = try std.Io.net.IpAddress.connect(&address, io, .{ .mode = .stream, .protocol = .tcp });
        var cw_buf: [2048]u8 = undefined;
        var cw = stream.writer(io, &cw_buf);
        var cr_buf: [2048]u8 = undefined;
        var cr = stream.reader(io, &cr_buf);

        try cw.interface.writeAll("GET /one HTTP/1.1\r\nHost: x\r\n\r\nGET /two HTTP/1.1\r\nHost: x\r\n\r\n");
        try cw.interface.flush();
        var resp: [4096]u8 = undefined;
        const got = try readUntil(&cr.interface, &resp, "{\"path\":\"/one\"}");
        try testing.expect(std.mem.indexOf(u8, resp[0..got], "connection: close") != null);
        try testing.expect(std.mem.indexOf(u8, resp[0..got], "keep-alive") == null);

        var resp_after: [512]u8 = undefined;
        const got_after = try readUntil(&cr.interface, &resp_after, "{\"path\":\"/two\"}");
        try testing.expectEqual(@as(usize, 0), got_after);

        th.join();
        stream.close(io);
        try testing.expectEqual(@as(usize, 1), ctx.served);
        ctx.impl.opts.keep_alive = true;
    }

    std.debug.print("[http] 关闭语义 OK：Connection: close 与 keep_alive=false 均只服务 1 个请求\n", .{});
}

test "HTTP 服务端：keep_alive_requests 达到上限即关闭连接" {
    const Ctx = KeepAliveHarness(2);

    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const sio = threaded.io();

    var port: u16 = 39410;
    var bound: ?std.Io.net.Server = null;
    while (port < 39429) : (port += 1) {
        const addr = std.Io.net.IpAddress.parse("127.0.0.1", port) catch continue;
        bound = addr.listen(sio, .{ .reuse_address = true }) catch continue;
        break;
    }
    const listener = bound orelse {
        std.debug.print("[SKIP] 39410-39428 端口均不可用，跳过上限用例\n", .{});
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

    const io = compat.currentIo();
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    const stream = std.Io.net.IpAddress.connect(&address, io, .{ .mode = .stream, .protocol = .tcp }) catch |e| {
        th.join();
        std.debug.print("[SKIP] 本机回环 TCP 不可用：{s}\n", .{@errorName(e)});
        return;
    };
    var stream_alive = true;
    defer if (stream_alive) stream.close(io);

    var cw_buf: [4096]u8 = undefined;
    var cw = stream.writer(io, &cw_buf);
    var cr_buf: [4096]u8 = undefined;
    var cr = stream.reader(io, &cr_buf);

    // 一次发 3 个请求：服务端只应服务前 2 个（max_requests=2），第 3 个拿不到响应
    try cw.interface.writeAll("GET /one HTTP/1.1\r\nHost: x\r\n\r\nGET /two HTTP/1.1\r\nHost: x\r\n\r\nGET /three HTTP/1.1\r\nHost: x\r\n\r\n");
    try cw.interface.flush();
    var resp1: [4096]u8 = undefined;
    const got1 = try readUntil(&cr.interface, &resp1, "{\"path\":\"/two\"}");
    try testing.expect(std.mem.indexOf(u8, resp1[0..got1], "{\"path\":\"/one\"}") != null);
    try testing.expect(std.mem.indexOf(u8, resp1[0..got1], "{\"path\":\"/two\"}") != null);
    try testing.expect(std.mem.indexOf(u8, resp1[0..got1], "{\"path\":\"/three\"}") == null);

    var resp3: [512]u8 = undefined;
    const got3 = try readUntil(&cr.interface, &resp3, "{\"path\":\"/three\"}");
    th.join();

    try testing.expectEqual(@as(usize, 0), got3);
    try testing.expectEqual(@as(usize, 2), ctx.served);
    stream.close(io);
    stream_alive = false;
    std.debug.print("[http] 上限 OK：keep_alive_requests=2 时第 3 个请求被拒（服务端已关连接）\n", .{});
}

test "HTTP 服务端：默认安全响应头 + 反代真实 IP（X-Real-IP / X-Forwarded-For 末段）" {
    const Ctx = KeepAliveHarness(1);

    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const sio = threaded.io();

    var port: u16 = 39430;
    var bound: ?std.Io.net.Server = null;
    while (port < 39449) : (port += 1) {
        const addr = std.Io.net.IpAddress.parse("127.0.0.1", port) catch continue;
        bound = addr.listen(sio, .{ .reuse_address = true }) catch continue;
        break;
    }
    const listener = bound orelse {
        std.debug.print("[SKIP] 39430-39448 端口均不可用，跳过安全头用例\n", .{});
        return;
    };

    var ctx = Ctx{
        .server = listener,
        .io = sio,
        .impl = .{ .gpa = testing.allocator, .io = sio, .ctx = undefined, .handler = Ctx.handler },
    };
    ctx.impl.ctx = @ptrCast(&ctx);
    defer ctx.server.deinit(sio);

    const io = compat.currentIo();
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", port);

    // 发一个请求，返回原始响应字节数（响应缓冲由调用方给）
    const Send = struct {
        fn one(addr: std.Io.net.IpAddress, io2: std.Io, extra: []const u8, buf: []u8) !usize {
            const stream = try std.Io.net.IpAddress.connect(&addr, io2, .{ .mode = .stream, .protocol = .tcp });
            defer stream.close(io2);
            var cw_buf: [1024]u8 = undefined;
            var cw = stream.writer(io2, &cw_buf);
            try cw.interface.writeAll("GET /who HTTP/1.1\r\nHost: x\r\n");
            if (extra.len > 0) try cw.interface.writeAll(extra);
            try cw.interface.writeAll("\r\n");
            try cw.interface.flush();
            var cr_buf: [1024]u8 = undefined;
            var cr = stream.reader(io2, &cr_buf);
            return readUntil(&cr.interface, buf, "{\"path\":\"/who\"}");
        }
    };

    // 轮 1：默认不信任转发头 → remote_addr 必须是 TCP 对端（127.0.0.1:port）
    {
        const th = try std.Thread.spawn(.{}, Ctx.serve, .{&ctx});
        var resp: [2048]u8 = undefined;
        const got = Send.one(address, io, "X-Real-IP: 8.8.8.8\r\nX-Forwarded-For: 1.1.1.1, 9.9.9.9\r\n", &resp) catch |e| {
            th.join();
            std.debug.print("[SKIP] 本机回环 TCP 不可用：{s}\n", .{@errorName(e)});
            return;
        };
        th.join();
        const text = resp[0..got];
        // 默认安全头必须下发
        try testing.expect(std.mem.indexOf(u8, text, "x-content-type-options: nosniff") != null);
        try testing.expect(std.mem.indexOf(u8, text, "x-frame-options: SAMEORIGIN") != null);
        try testing.expect(std.mem.indexOf(u8, text, "referrer-policy: no-referrer") != null);
        // 默认不信任反代：仍是回环对端
        try testing.expect(std.mem.startsWith(u8, ctx.remoteSlice(), "127.0.0.1:"));
    }

    // 轮 2：信任反代 + X-Real-IP 优先
    {
        ctx.impl.opts.trust_forwarded_for = true;
        const th = try std.Thread.spawn(.{}, Ctx.serve, .{&ctx});
        var resp: [2048]u8 = undefined;
        _ = try Send.one(address, io, "X-Real-IP: 8.8.8.8\r\nX-Forwarded-For: 1.1.1.1, 9.9.9.9\r\n", &resp);
        th.join();
        try testing.expectEqualStrings("8.8.8.8", ctx.remoteSlice());
    }

    // 轮 3：信任反代 + 只有 XFF → 取**末段**（左侧客户端可伪造）
    {
        ctx.impl.opts.trust_forwarded_for = true;
        const th = try std.Thread.spawn(.{}, Ctx.serve, .{&ctx});
        var resp: [2048]u8 = undefined;
        _ = try Send.one(address, io, "X-Forwarded-For: 1.1.1.1, 9.9.9.9\r\n", &resp);
        th.join();
        try testing.expectEqualStrings("9.9.9.9", ctx.remoteSlice());
    }

    ctx.impl.opts.trust_forwarded_for = false;
    std.debug.print("[http] 安全头 + 真实 IP OK：默认 nosniff/SAMEORIGIN/no-referrer，XFF 取末段\n", .{});
}
