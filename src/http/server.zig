//! 极简 HTTP/1.1 服务端（服务型接口用：数据库远程服务、内部 API）。
//!
//! 为什么自建监听层：Zig 标准库有 `std.http.Server`（协议解析），但**没有**「监听 + 线程 + 上限」这层。
//!
//! **协议解析已不再使用 `std.http.Server`**（2026-11-19 起）：它的 head 解析路径实测需要
//! >64 KiB 的协程栈，在 zio 协程后端下把每连接内存推到 59 KB（C# Kestrel 11 KB / Rust hyper 14 KB）。
//! 现在改用 `lighting` 的 `parseRequestHead`（零拷贝）+ `BodyReader`（Content-Length/chunked）
//! + `ResponseWriter`（双模缓冲），实测降到 20 KB/连接。连接循环、上限、早拒、XFF 仍在本文件。
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
const lighting = @import("lighting");
const compat = @import("../compat.zig");
const socket_timeout = @import("../net/socket_timeout.zig");

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
    /// 对端地址（**纯 IP**，不含端口；IPv6 为 `::1` 这种裸形式）。
    /// WAF / 限流 / IP 名单 / 审计直接用它；**不要**再自己剥端口。
    /// 反代场景下它已被 `trust_forwarded_for` 换成真实客户端 IP。
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
    /// 是否信任反代转发头：**只当 TCP 对端是回环或命中 `trusted_proxy_prefixes` 时才采纳**，
    /// 按 `x-real-ip` 优先 → `x-forwarded-for` **末段** 取真实客户端 IP。
    ///
    /// **默认开**：生态里应用绝大多数跑在 nginx 之后；直连公网时对端不是回环/受信网段，
    /// 转发头一律忽略 —— 所以默认开与关的安全强度一致，但少了「反代后面全变 127.0.0.1」这个默衰。
    trust_forwarded_for: bool = true,
    /// 除回环外，还信任哪些「TCP 对端地址前缀」（容器 / 跨机反代）：如 `&.{"172.16.", "10."}`。
    /// **只在明确知道反代网段时配**：前缀越宽越容易被伪造。
    trusted_proxy_prefixes: []const []const u8 = &.{},
    /// 连接调度方式（与 `zgrpc.grpc.ConnDispatch` 同一口径）：
    ///
    /// - `.thread_per_conn`（默认）：每连接一独立线程。几百连接以内吞吐最好，
    ///   但线程数随连接数线性增长（每线程 ~86µs 创建成本，上万长连接会被拖垮）；
    /// - `.task`：连接跑在 `std.Io.Group` 的**运行时任务**里，而不是 OS 线程里。
    ///   语义完全由传入的 `std.Io` 决定：
    ///   - 传 `std.Io.Threaded`：落到线程池（有并发上限，超限会自动回退独立线程，不丢连接）；
    ///   - 传异步后端（如 zio：Windows IOCP / Linux io_uring）：任务是**协程**，
    ///     连接数不再等于线程数。
    ///
    /// 上千到上万长连接**必须**用 `.task` 并配异步后端；面板类几百并发保持默认即可。
    dispatch: Dispatch = .thread_per_conn,
    /// 读超时（毫秒），**默认 0（关闭）**。
    ///
    /// 实测（2026-11-19，Windows 11 + Zig 0.17.1，以及 WSL Ubuntu 26.04 + 同一版本）：
    /// - Windows：`IOCTL_AFD_SOCKOPT + SO_RCVTIMEO` **结果不稳定**，既回 `STATUS_NOT_SUPPORTED`
    ///   （`0xC00000BB`）也回过成功；`std.os.windows.AFD.RECEIVE` 根本没有 Timeout 字段。
    /// - Linux：`setsockopt` 能设上，但到点后 `read` 返回 `EAGAIN`，而 Zig 的 `std.Io`
    ///   在 Debug 构建下会把它当成 programmer bug **直接 panic**（实测报
    ///   “programmer bug caused syscall error: AGAIN”）。
    ///
    /// 所以**不把它作为默认防线**：Slowloris 靠 `max_connections` + `keep_alive_requests`
    /// 与前置 nginx 的 `client_header_timeout` 兜。确实要在 POSIX 上试，可显式设 >0
    /// （建议 ReleaseFast 构建，避免 Debug 下的 panic 路径）。
    header_timeout_ms: u32 = 0,
    /// 是否关闭 Nagle（`TCP_NODELAY`）。小包交互默认关掉：否则 header+body 两个小包
    /// 会等前一个的 ACK，与对端延迟 ACK 叠加出 10~200ms 的随机尾部延迟。
    tcp_nodelay: bool = true,
    /// 每连接的**接收缓冲**（字节，堆分配）。决定「一次 read 能拿回多少请求」。
    ///
    /// 这是每连接的固定内存开销：上万连接时把它调小（如 4 KiB）能省很多。
    conn_recv_buf_size: usize = 16 * 1024,
    /// 每连接的**发送缓冲**（字节，堆分配），同时是延迟 flush 的批量上限。
    conn_send_buf_size: usize = 16 * 1024,
    /// 单个请求允许的**头数量上限**（超限回 431）。
    ///
    /// `std.http.Server` 的 head buffer 只限制**总字节**、不限制**个数**，
    /// 600 个 13 字节的小头（总量 < 8 KB）能正常通过 —— 这类请求会白白消耗解析与复制开销。
    /// 正常浏览器 10~20 个头，反代叠加也到不了 100，所以默认 100 足够宽松。
    max_header_count: usize = 100,
};

/// 处理函数：`reply.body` 必须自己分配，或借用 `arena`。
pub const HandlerFn = *const fn (ctx: *anyopaque, req: RequestView, arena: std.mem.Allocator) anyerror!Reply;

/// 连接调度方式（对齐 `zgrpc.grpc.ConnDispatch`；`.pool` 需外部线程池，本库不内建）。
pub const Dispatch = enum {
    /// 每连接一独立线程（默认；几百连接以内吞吐最好）
    thread_per_conn,
    /// 每连接一个运行时任务（配异步 `std.Io` 后端就是事件循环）
    task,
};

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
    /// `.task` 调度时的连接任务组：`run` 退出时 await 它（优雅收尾）。
    task_group: std.Io.Group = .init,
    /// 读超时设置失败的提示是否已发过（只提示一次，避免每连接刷屏）
    timeout_warned: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

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
        // `.task` 调度：连接任务挂在 `task_group` 上，退出时必须 await（否则改内存时还有未完成连接）
        defer if (self.opts.dispatch == .task) self.task_group.await(self.io) catch {};

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
            self.dispatchStream(stream);
        }
    }

    /// 按 `opts.dispatch` 把一条已 accept 的连接交给对应执行体（调用方已 `active +1`）。
    ///
    /// `.task` 在「带并发上限的后端」（如 `std.Io.Threaded` 的线程池）也可能返回
    /// `ConcurrencyUnavailable` —— 那时**回退独立线程，绝不丢连接**（与 zgrpc 一致）。
    fn dispatchStream(self: *Server, stream: std.Io.net.Stream) void {
        if (self.opts.dispatch == .task) {
            self.task_group.concurrent(self.io, connTaskEntry, .{ self, stream }) catch |e| {
                std.debug.print("[zzig.http] 连接任务创建失败（{s}），回退为独立线程\n", .{@errorName(e)});
                self.spawnConnThread(stream);
            };
            return;
        }
        self.spawnConnThread(stream);
    }

    /// `.task` 的任务入口：`std.Io.Group` 要求返回值可强转成 `Cancelable!void`。
    fn connTaskEntry(self: *Server, stream: std.Io.net.Stream) std.Io.Cancelable!void {
        self.connMain(stream);
    }

    /// 独立线程模型：起线程后立即 detach，连接结束由线程自己退出。
    fn spawnConnThread(self: *Server, stream: std.Io.net.Stream) void {
        const th = std.Thread.spawn(.{}, connMain, .{ self, stream }) catch |e| {
            _ = self.active.fetchSub(1, .acq_rel);
            std.debug.print("[zzig.http] 创建连接线程失败：{s}\n", .{@errorName(e)});
            stream.close(self.io);
            return;
        };
        th.detach();
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
        self.applySocketOptions(stream);
        const limit = if (self.opts.keep_alive) @max(self.opts.keep_alive_requests, 1) else 1;
        self.serveWithLimit(stream, limit) catch |e| switch (e) {
            error.HttpConnectionClosing => {},
            else => std.debug.print("[zzig.http] 连接处理结束（{s}）\n", .{@errorName(e)}),
        };
        stream.close(self.io);
    }

    /// 连接级 socket 选项：读超时（Slowloris）与 TCP_NODELAY。
    ///
    /// 失败只降级不报错：某些平台/被包装的 socket 不支持这些选项，但服务必须能继续。
    fn applySocketOptions(self: *Server, stream: std.Io.net.Stream) void {
        if (self.opts.header_timeout_ms > 0) {
            socket_timeout.setRecvTimeout(self.io, stream, self.opts.header_timeout_ms) catch |e| {
                // 只提示一次：Windows 上 AFD 不支持 SO_RCVTIMEO（实测 STATUS_NOT_SUPPORTED），
                // 每连接打一条会把日志变成负担。生产部署走 Linux（POSIX 生效）。
                if (!self.timeout_warned.swap(true, .acq_rel)) {
                    std.debug.print(
                        "[zzig.http] 原生读超时不可用（{s}）：该平台请靠 max_connections + keep_alive_requests + 反代 client_header_timeout 兜住 Slowloris\n",
                        .{@errorName(e)},
                    );
                }
            };
        }
        if (self.opts.tcp_nodelay) socket_timeout.setNoDelay(self.io, stream, true) catch {};
    }

    /// 处理**一条**连接上的一个请求（单线程可用，便于测试）。
    pub fn serveOne(self: *Server, stream: std.Io.net.Stream) !void {
        return self.serveWithLimit(stream, 1);
    }

    /// 连接主循环：在同一连接上服务最多 `max_requests` 个请求（keep-alive）。
    fn serveWithLimit(self: *Server, stream: std.Io.net.Stream, max_requests: usize) !void {
        // **收发缓冲必须在堆上**：原先两个 16 KiB 栈数组会把协程栈顶到 128 KiB 以上，
        // 5000 个连接就是几百 MB 的差距（见 docs/决策记录.md 2026-11-19（八））。
        const recv_buf = self.gpa.alloc(u8, self.opts.conn_recv_buf_size) catch return error.OutOfMemory;
        defer self.gpa.free(recv_buf);
        const send_buf = self.gpa.alloc(u8, self.opts.conn_send_buf_size) catch return error.OutOfMemory;
        defer self.gpa.free(send_buf);
        var sw = stream.writer(self.io, send_buf);
        // 读缓冲由本层自己管：需要「读到 \r\n\r\n 为止」并保留管线化剩余字节。
        var cb = ConnBuf{ .buf = recv_buf };

        // 对端地址（accept 返回的 socket 地址即远端，Windows/POSIX 同口径）：
        // 格式为 `ip:port`（IPv6 为 `[::1]:port`），消费方自行剥端口。
        // 注意：`IpAddress` 只实现了新 `Io.Writer` 接口，`std.fmt` 的 `{}` 会退化成
        // 结构体调试打印（实测输出 `.{ .ip4 = ... }`），必须显式用 `Io.Writer.fixed`。
        var remote_buf: [80]u8 = undefined;
        var remote_writer: std.Io.Writer = .fixed(&remote_buf);
        const tcp_peer: ?[]const u8 = blk: {
            stream.socket.address.format(&remote_writer) catch break :blk null;
            // 只留纯 IP：`127.0.0.1:52341` / `[::1]:52341` → `127.0.0.1` / `::1`
            break :blk stripPort(remote_writer.buffered());
        };

        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();

        var served: usize = 0;
        while (served < max_requests) : (served += 1) {
            _ = arena_state.reset(.retain_capacity);
            const keep = self.handleOne(stream, &sw, &cb, tcp_peer, arena_state.allocator()) catch |e| switch (e) {
                // 请求头超过缓冲上限 / 头数量超限：回 431 让客户端或反代拿到明确原因。
                error.HttpHeadersOversize => {
                    const body = "{\"code\":431,\"msg\":\"request headers too large\"}";
                    const raw = std.fmt.allocPrint(
                        arena_state.allocator(),
                        "HTTP/1.1 431 Request Header Fields Too Large\r\n" ++
                            "content-type: application/json; charset=utf-8\r\n" ++
                            "content-length: {d}\r\nconnection: close\r\n\r\n{s}",
                        .{ body.len, body },
                    ) catch return;
                    sw.interface.writeAll(raw) catch {};
                    sw.interface.flush() catch {};
                    stream.shutdown(self.io, .send) catch {};
                    return;
                },
                // 对端正常关闭（含 keep-alive 空闲后客户端先关）→ 结束本条连接。
                error.HttpConnectionClosing => return,
                // 读超时（Slowloris / 空闲 keep-alive）：回 408 并关闭，不让连接永久占线程。
                // 用 isReadTimeout 判定而不是写死错误名：该错误来自底层 socket 读，
                // 不在 `handleOne` 声明的错误集里，Windows 是 ConnectionTimedOut、POSIX 是 WouldBlock。
                else => {
                    if (socket_timeout.isReadTimeout(e)) {
                        self.replyRequestTimeout(stream);
                        return;
                    }
                    return e;
                },
            };
            // keep-alive 时必须立即把响应刷给客户端：否则数据滞留在写缓冲里，
            // 客户端会一直等到连接关闭（多请求复用场景直接死锁）。
            try sw.interface.flush();
            if (!keep) return;
        }
    }

    /// 读到 `\r\n\r\n` 为止；返回的头字节**指向 `cb.buf`**，调用方必须先复制再读 body。
    fn readHeadBytes(self: *Server, stream: std.Io.net.Stream, cb: *ConnBuf) ![]const u8 {
        while (true) {
            if (std.mem.indexOf(u8, cb.buf[0..cb.len], "\r\n\r\n")) |idx| return cb.buf[0 .. idx + 4];
            if (cb.len >= cb.buf.len) return error.HttpHeadersOversize;
            var slices: [1][]u8 = .{cb.buf[cb.len..]};
            const n = stream.read(self.io, &slices) catch |e| return e;
            if (n == 0) return error.HttpConnectionClosing;
            cb.len += n;
        }
    }

    /// 读超时时回 408（连接不再复用）：让客户端/反代拿到明确原因，而不是只看到连接被重置。
    fn replyRequestTimeout(self: *Server, stream: std.Io.net.Stream) void {
        var send_buf: [512]u8 = undefined;
        var sw = stream.writer(self.io, &send_buf);
        const body = "{\"code\":408,\"msg\":\"request timeout\"}";
        var head_buf: [256]u8 = undefined;
        const head = std.fmt.bufPrint(
            &head_buf,
            "HTTP/1.1 408 Request Timeout\r\n" ++
                "content-type: application/json; charset=utf-8\r\n" ++
                "content-length: {d}\r\nconnection: close\r\n\r\n",
            .{body.len},
        ) catch return;
        sw.interface.writeAll(head) catch return;
        sw.interface.writeAll(body) catch return;
        sw.interface.flush() catch return;
        // 先发 FIN 再返回：直接 close 会让 Windows 发 RST，408 可能到不了客户端
        stream.shutdown(self.io, .send) catch {};
    }

    /// 本次响应的头组装开关（安全头 / keep-alive 提示）。
    fn headerOptions(self: *Server, keep: bool) HeaderOptions {
        return .{
            .keep_alive = keep,
            .keep_alive_timeout_secs = self.opts.keep_alive_timeout_secs,
            .security_headers = self.opts.security_headers,
        };
    }

    /// TCP 对端是否可信代理（回环，或命中 `trusted_proxy_prefixes`）。
    fn isTrustedProxy(self: *const Server, peer: []const u8) bool {
        if (isLoopbackPeer(peer)) return true;
        for (self.opts.trusted_proxy_prefixes) |prefix| {
            if (prefix.len > 0 and std.mem.startsWith(u8, peer, prefix)) return true;
        }
        return false;
    }

    /// 在已就绪的连接上处理**一个**请求；返回 `true` 表示连接可以继续复用。
    fn handleOne(
        self: *Server,
        stream: std.Io.net.Stream,
        sw: *std.Io.net.Stream.Writer,
        cb: *ConnBuf,
        tcp_peer: ?[]const u8,
        arena: std.mem.Allocator,
    ) !bool {
        // 1) 读头 → **立即拷进 arena**：下一步读 body 会覆盖连接缓冲。
        const head_raw = try self.readHeadBytes(stream, cb);
        const head_len = head_raw.len;
        const head_bytes = try arena.dupe(u8, head_raw);
        cb.consume(head_len);

        // 2) 解析（lighting 的零拷贝分帧，不再用 std.http —— 后者要吃 39 KB 协程栈）
        const head = lighting.parseRequestHead(arena, head_bytes) catch |e| {
            std.debug.print("[zzig.http] 请求头解析失败：{s}\n", .{@errorName(e)});
            const msg = "{\"code\":400,\"msg\":\"bad request\"}";
            try self.writeReply(sw, .{ .status = .bad_request, .body = msg }, null, self.headerOptions(false), false);
            return false;
        };
        const method = toStdMethod(head.method);
        const path_end = std.mem.indexOfScalar(u8, head.target, '?') orelse head.target.len;
        const path = head.target[0..path_end];
        const query = if (path_end < head.target.len) head.target[path_end + 1 ..] else "";

        // 3) 头列表：lighting 的 `HeaderMap` 只提供 get/set（没有遍历接口），
        //    这里直接按原始字节扫一遍 —— head_bytes 已通过 `parseRequestHead` 的格式校验，
        //    二次扫描是安全的，且零额外分配（名字转小写，符合 `RequestView.headers` 的约定）。
        var header_list: std.ArrayList(std.http.Header) = .empty;
        {
            var line_it = std.mem.splitSequence(u8, head_bytes, "\r\n");
            _ = line_it.next(); // 请求行
            while (line_it.next()) |line| {
                if (line.len == 0) break; // 头部结束的空行
                const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
                const name = std.mem.trim(u8, line[0..colon], " \t");
                const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
                if (name.len == 0) continue;
                if (header_list.items.len >= self.opts.max_header_count) return error.HttpHeadersOversize;
                const lower = try arena.alloc(u8, name.len);
                for (name, 0..) |ch, i| lower[i] = std.ascii.toLower(ch);
                try header_list.append(arena, .{
                    .name = lower,
                    .value = try arena.dupe(u8, value),
                });
            }
        }

        // 真实客户端 IP：反代场景下 TCP 对端是回环/受信代理，需采纳转发头（只信紧邻那一跳）
        var remote_addr = tcp_peer;
        if (self.opts.trust_forwarded_for) {
            if (tcp_peer) |peer| {
                if (self.isTrustedProxy(peer)) {
                    if (headerValue(header_list.items, "x-real-ip")) |value| {
                        const trimmed = std.mem.trim(u8, value, " \t");
                        if (trimmed.len > 0) remote_addr = trimmed;
                    } else if (headerValue(header_list.items, "x-forwarded-for")) |value| {
                        if (lastForwardedFor(value)) |ip| remote_addr = ip;
                    }
                }
            }
        }

        // 连接能否复用：客户端没要求 close、没启用 keep-alive 开关、或用了分块传输（body 流未读完）
        const keep = self.opts.keep_alive and head.keep_alive and !head.is_chunked;

        // 早拒：声明长度超上限就不读 body
        var body: []const u8 = "";
        if (head.content_length) |len| {
            if (len > self.opts.max_body) {
                const msg = "{\"code\":413,\"msg\":\"request body too large\"}";
                try self.writeReply(sw, .{ .status = .payload_too_large, .body = msg }, null, self.headerOptions(false), false);
                return false;
            }
            if (len > 0) body = try self.readBody(stream, cb, @intCast(len), arena);
        } else if (head.is_chunked) {
            body = self.readChunkedBody(stream, cb, arena) catch |e| {
                std.debug.print("[zzig.http] 读分块请求体失败：{s}\n", .{@errorName(e)});
                return false;
            };
        }

        const reply = self.handler(self.ctx, .{
            .method = method,
            .target = head.target,
            .path = path,
            .query = query,
            .body = body,
            .headers = header_list.items,
            .remote_addr = remote_addr,
        }, arena) catch |e| {
            std.debug.print("[zzig.http] 处理 {s} {s} 失败：{s}\n", .{ @tagName(method), path, @errorName(e) });
            const msg = "{\"code\":500,\"msg\":\"internal error\"}";
            self.writeReply(sw, .{ .status = .internal_server_error, .body = msg }, null, self.headerOptions(false), false) catch {};
            return false;
        };

        // 文件响应：流式发送（大文件不整读进内存）
        if (reply.file) |file_body| {
            defer file_body.file.close(self.io);

            try self.writeReplyHead(sw, reply, file_body.length, self.headerOptions(keep));

            // HEAD：只发头（content-length 已按文件长度声明），不读文件。
            if (method == .HEAD) {
                try sw.interface.flush();
                return keep;
            }

            // 优先零拷贝（Linux sendfile 走内核 file→socket，不经过用户态内存）；
            // `Unimplemented`（如 Windows）回退到 32 KB 缓冲的读-写循环。
            //
            // **这个缓冲必须堆分配**：写成 `var read_buf: [32 * 1024]u8` 会让 Zig 在函数入口
            // 就为整个 `handleOne` 预留 32 KiB 栈 —— 即使走的是非文件分支，每个连接协程也要吃满，
            // 实测把每连接内存顶到 53 KB（与 128 KiB / 32 KiB 栈上限无关）。
            const read_buf = try self.gpa.alloc(u8, 32 * 1024);
            defer self.gpa.free(read_buf);
            var file_reader = file_body.file.reader(self.io, read_buf);
            var remaining = file_body.length;
            var zero_copy = true;
            while (remaining > 0) {
                if (zero_copy) {
                    const n = sw.interface.sendFile(&file_reader, .limited64(remaining)) catch |e| switch (e) {
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
                try sw.interface.writeAll(read_buf[0..n]);
                remaining -= n;
            }

            if (remaining > 0) {
                // 文件被截断：content-length 已声明，直接返回让连接关闭，并留下可定位的日志。
                std.debug.print(
                    "[zzig.http] 发送文件时被截断：已声明 {d} 字节，还差 {d} 字节\n",
                    .{ file_body.length, remaining },
                );
                return false;
            }
            return keep;
        }

        // 无正文但需声明长度（通常 HEAD）：自填 content-length，不发 body
        if (reply.content_length) |length| {
            try self.writeReplyHead(sw, reply, length, self.headerOptions(keep));
            return keep;
        }

        if (method == .HEAD) {
            // HEAD：头里声明 body 长度，但**不写** body
            try self.writeReplyHead(sw, reply, reply.body.len, self.headerOptions(keep));
        } else {
            try self.writeReply(sw, reply, null, self.headerOptions(keep), false);
        }
        return keep;
    }

    /// 写响应头：**先在栈上小缓冲里拼好整块，再一次 writeAll**。
    ///
    /// 逐段 `writeAll`（状态行 1 次 + 每个头 3 次 + content-length + connection）在 2 万 rps 下
    /// 累积成明显开销：实测 2 executor 时，带 3 个默认安全头 11287 rps，关掉安全头 21211 rps。
    /// 同样的头改成「一次写」后这部分开销直接拿回来。缓冲放栈上（768 B，覆盖十几个常规头），
    /// 溢出（超长 `set-cookie` 等）自动回退到逐段写，不会因为头太大出错。
    ///
    /// 同时**不再建中间的 `[]std.http.Header` 列表**：原先靠 `buildHeaders()` 用 arena
    /// 组数组（`ArrayList` 多次增长 + `allocPrint("timeout=N")` 一次格式化分配），
    /// 现在全部内联到这里直接写，每请求省掉那几次分配。
    fn writeReplyHead(
        self: *Server,
        sw: *std.Io.net.Stream.Writer,
        reply: Reply,
        content_length: u64,
        opts: HeaderOptions,
    ) !void {
        _ = self;
        var buf: [768]u8 = undefined;
        var fw: std.Io.Writer = .fixed(&buf);
        formatReplyHead(&fw, reply, content_length, opts) catch {
            // 小缓冲装不下：直接对着 socket writer 再拼一遍（错误集同口径，不会丢头）
            try formatReplyHead(&sw.interface, reply, content_length, opts);
            return;
        };
        try sw.interface.writeAll(fw.buffered());
    }

    /// 写完整响应（头 + body）；`is_head` 为真时只写头（`content-length` 仍按 body 长度声明）。
    fn writeReply(
        self: *Server,
        sw: *std.Io.net.Stream.Writer,
        reply: Reply,
        content_length: ?u64,
        opts: HeaderOptions,
        is_head: bool,
    ) !void {
        try self.writeReplyHead(sw, reply, content_length orelse reply.body.len, opts);
        if (!is_head and reply.body.len > 0) try sw.interface.writeAll(reply.body);
    }

    /// 读固定长度请求体：连接缓冲里已有的先取（管线化场景下后面还可能有下一个请求），
    /// 不够再从 socket 读。
    fn readBody(
        self: *Server,
        stream: std.Io.net.Stream,
        cb: *ConnBuf,
        len: usize,
        arena: std.mem.Allocator,
    ) ![]const u8 {
        if (len == 0) return "";
        const out = try arena.alloc(u8, len);
        var filled: usize = 0;
        const take = @min(len, cb.len);
        if (take > 0) {
            @memcpy(out[0..take], cb.buf[0..take]);
            cb.consume(take);
            filled = take;
        }
        while (filled < len) {
            var slices: [1][]u8 = .{out[filled..]};
            const n = stream.read(self.io, &slices) catch |e| {
                std.debug.print(
                    "[zzig.http] 读请求体失败（声明 {d} 字节，已读 {d}）：{s}\n",
                    .{ len, filled, @errorName(e) },
                );
                return e;
            };
            if (n == 0) return error.HttpConnectionClosing;
            filled += n;
        }
        return out;
    }

    /// 读分块（chunked）请求体：交给 lighting 的 `BodyReader`（已处理分块解码与 trailer）。
    fn readChunkedBody(
        self: *Server,
        stream: std.Io.net.Stream,
        cb: *ConnBuf,
        arena: std.mem.Allocator,
    ) ![]const u8 {
        var br = lighting.BodyReader.init(stream, self.io, cb.buf[0..cb.len], null, true);
        const body = try br.readAllAlloc(arena, self.opts.max_body);
        // BodyReader 直接消费 socket 流，连接缓冲里的字节已由它接管
        cb.len = 0;
        return body;
    }
};

/// 连接级读缓冲（跨请求复用）。支持管线化：一次 `read` 可能带回多个请求，
/// 消费掉当前请求后把剩余字节前移，不做额外分配。
const ConnBuf = struct {
    buf: []u8,
    len: usize = 0,

    fn consume(self: *ConnBuf, n: usize) void {
        const drop = @min(n, self.len);
        if (drop == self.len) {
            self.len = 0;
            return;
        }
        std.mem.copyForwards(u8, self.buf[0 .. self.len - drop], self.buf[drop..self.len]);
        self.len -= drop;
    }
};

/// lighting 的方法枚举 → `std.http.Method`（`RequestView.method` 保持标准库类型，
/// 消费方的 `.method == .GET` 之类写法不用改）。`std.http.Method` 多一个 `QUERY`，
/// lighting 不认（返回 InvalidMethod → 400），属于可接受的行为收窄。
fn toStdMethod(m: lighting.Method) std.http.Method {
    return switch (m) {
        .GET => .GET,
        .HEAD => .HEAD,
        .POST => .POST,
        .PUT => .PUT,
        .PATCH => .PATCH,
        .DELETE => .DELETE,
        .CONNECT => .CONNECT,
        .OPTIONS => .OPTIONS,
        .TRACE => .TRACE,
    };
}

/// 响应头组装的开关（从 `Options` 拍出来，避免把整个 `*Server` 传给纯函数）。
const HeaderOptions = struct {
    keep_alive: bool,
    keep_alive_timeout_secs: u32,
    security_headers: bool,
};

/// 组装响应头：`content-type` → 默认安全头 → 业务附加头（跳过重名）→ `keep-alive`。
/// 把「状态行 + content-type + 默认安全头 + 业务附加头 + content-length + keep-alive/connection」
/// **直接写进 writer**（`writeReplyHead` 的小缓冲与回退两条路径共用）。
///
/// 这里刻意不建中间的 `[]std.http.Header`：原先走 `buildHeaders()` 时，每请求要在 arena 里
/// 组一次数组（`ArrayList` 增长）并 `allocPrint` 出 `timeout=N` 字符串，2 万 rps 下是可见开销。
fn formatReplyHead(
    w: *std.Io.Writer,
    reply: Reply,
    content_length: u64,
    opts: HeaderOptions,
) !void {
    try w.print("HTTP/1.1 {d} {s}\r\n", .{
        @backingInt(reply.status),
        reply.status.phrase() orelse "OK",
    });
    try w.writeAll("content-type: ");
    try w.writeAll(reply.content_type);
    try w.writeAll("\r\n");
    if (opts.security_headers) {
        try w.writeAll("x-content-type-options: nosniff\r\n" ++
            "x-frame-options: SAMEORIGIN\r\n" ++
            "referrer-policy: no-referrer\r\n");
    }
    for (reply.headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, "content-type")) continue;
        if (std.ascii.eqlIgnoreCase(header.name, "connection")) continue;
        if (std.ascii.eqlIgnoreCase(header.name, "keep-alive")) continue;
        if (std.ascii.eqlIgnoreCase(header.name, "content-length")) continue;
        if (opts.security_headers and isSecurityHeader(header.name)) continue;
        try w.writeAll(header.name);
        try w.writeAll(": ");
        try w.writeAll(header.value);
        try w.writeAll("\r\n");
    }
    try w.print("content-length: {d}\r\n", .{content_length});
    if (opts.keep_alive) {
        try w.print("keep-alive: timeout={d}\r\n", .{opts.keep_alive_timeout_secs});
        try w.writeAll("connection: keep-alive\r\n\r\n");
    } else {
        try w.writeAll("connection: close\r\n\r\n");
    }
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

/// TCP 对端是否回环（`127.x.x.x` / `::1`）。
fn isLoopbackPeer(peer: []const u8) bool {
    if (std.mem.startsWith(u8, peer, "127.")) return true;
    return std.mem.eql(u8, peer, "::1") or std.mem.eql(u8, peer, "[::1]");
}

/// 去掉 `ip:port` 的端口：`1.2.3.4:80` → `1.2.3.4`、`[::1]:80` → `::1`、裸 IPv6 原样。
fn stripPort(addr: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, addr, ']')) |close| return addr[1..close];
    const first = std.mem.indexOfScalar(u8, addr, ':') orelse return addr;
    if (std.mem.lastIndexOfScalar(u8, addr, ':').? != first) return addr; // 裸 IPv6
    return addr[0..first];
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
                self.remote_ok = std.mem.eql(u8, addr, "127.0.0.1");
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
    try cw.interface.writeAll("GET /one HTTP/1.1\r\nHost: x\r\n\r\nGET /two HTTP/1.1\r\nHost: x\r\n\r\n");
    try cw.interface.flush();
    var resp1: [4096]u8 = undefined;
    const got1 = try readUntil(&cr.interface, &resp1, "{\"path\":\"/two\"}");
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

    // 轮 1：默认信任转发头 → `X-Real-IP` 优先
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
        // 默认信任回环反代：采纳 X-Real-IP
        try testing.expectEqualStrings("8.8.8.8", ctx.remoteSlice());
    }

    // 轮 2：只有 XFF → 取**末段**（左侧客户端可伪造）
    {
        const th = try std.Thread.spawn(.{}, Ctx.serve, .{&ctx});
        var resp: [2048]u8 = undefined;
        _ = try Send.one(address, io, "X-Forwarded-For: 1.1.1.1, 9.9.9.9\r\n", &resp);
        th.join();
        try testing.expectEqualStrings("9.9.9.9", ctx.remoteSlice());
    }

    // 轮 3：显式关掉信任 → 仍是回环对端（直连部署的安全兜底）
    {
        ctx.impl.opts.trust_forwarded_for = false;
        const th = try std.Thread.spawn(.{}, Ctx.serve, .{&ctx});
        var resp: [2048]u8 = undefined;
        _ = try Send.one(address, io, "X-Real-IP: 8.8.8.8\r\n", &resp);
        th.join();
        try testing.expectEqualStrings("127.0.0.1", ctx.remoteSlice());
        ctx.impl.opts.trust_forwarded_for = true;
    }

    // 轮 4：受信代理网段（容器里 nginx 的 172.16.x.x 也要认）
    {
        ctx.impl.opts.trusted_proxy_prefixes = &.{"127."};
        const th = try std.Thread.spawn(.{}, Ctx.serve, .{&ctx});
        var resp: [2048]u8 = undefined;
        _ = try Send.one(address, io, "X-Real-IP: 7.7.7.7\r\n", &resp);
        th.join();
        try testing.expectEqualStrings("7.7.7.7", ctx.remoteSlice());
        ctx.impl.opts.trusted_proxy_prefixes = &.{};
    }

    std.debug.print("[http] 安全头 + 真实 IP OK：默认信任回环反代，XFF 取末段，可关可加网段\n", .{});
}

test "HTTP 服务端：请求头超限返回 431（而不是只断连接）" {
    const Ctx = KeepAliveHarness(1);

    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const sio = threaded.io();

    var port: u16 = 39450;
    var bound: ?std.Io.net.Server = null;
    while (port < 39469) : (port += 1) {
        const addr = std.Io.net.IpAddress.parse("127.0.0.1", port) catch continue;
        bound = addr.listen(sio, .{ .reuse_address = true }) catch continue;
        break;
    }
    const listener = bound orelse {
        std.debug.print("[SKIP] 39450-39468 端口均不可用，跳过 431 用例\n", .{});
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
    defer stream.close(io);

    var cw_buf: [4096]u8 = undefined;
    var cw = stream.writer(io, &cw_buf);
    // 单个 20 KB 的请求头：必然超过 std 的 head buffer
    try cw.interface.writeAll("GET /x HTTP/1.1\r\nHost: x\r\nX-Big: ");
    var chunk: [1024]u8 = undefined;
    @memset(&chunk, 'a');
    var sent: usize = 0;
    while (sent < 20 * 1024) : (sent += chunk.len) {
        try cw.interface.writeAll(&chunk);
    }
    try cw.interface.writeAll("\r\n\r\n");
    try cw.interface.flush();

    var cr_buf: [1024]u8 = undefined;
    var cr = stream.reader(io, &cr_buf);
    var resp: [512]u8 = undefined;
    const got = try readUntil(&cr.interface, &resp, "431");
    th.join();

    try testing.expect(got > 0);
    try testing.expect(std.mem.indexOf(u8, resp[0..got], "431") != null);
    try testing.expectEqual(@as(usize, 0), ctx.served); // 没进业务 handler
    std.debug.print("[http] 431 OK：超长请求头收到 {d} 字节（含 431）\n", .{got});
}

test "HTTP 服务端：dispatch=.task 走运行时任务也能正常服务（与 zgrpc ConnDispatch 对齐）" {
    const Ctx = struct {
        impl: Server,
        served: usize = 0,
        address: std.Io.net.IpAddress = undefined,

        fn handle(ctx: *anyopaque, req: RequestView, arena: std.mem.Allocator) anyerror!Reply {
            _ = req;
            _ = arena;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.served += 1;
            return .{ .status = .ok, .body = "task-ok" };
        }

        /// 模拟 accept 循环的那一步：拿到连接后按 dispatch 分发
        fn acceptAndDispatch(self: *@This()) void {
            var listener = std.Io.net.IpAddress.listen(&self.address, self.impl.io, .{ .reuse_address = true }) catch return;
            defer listener.deinit(self.impl.io);
            const stream = listener.accept(self.impl.io) catch return;
            _ = self.impl.active.fetchAdd(1, .acq_rel);
            self.impl.dispatchStream(stream);
        }
    };

    const io = compat.currentIo();
    // 端口从 39351 起找一个能绑的；找不到就显式 SKIP（不静默通过）
    var port: u16 = 39351;
    var bound: ?std.Io.net.Server = null;
    while (port < 39370) : (port += 1) {
        const addr = std.Io.net.IpAddress.parse("127.0.0.1", port) catch continue;
        bound = addr.listen(io, .{ .reuse_address = true }) catch continue;
        break;
    }
    if (bound) |b| {
        var owned = b;
        owned.deinit(io);
    } else {
        std.debug.print("[SKIP] 39351-39369 端口均不可用，跳过 dispatch=.task 用例\n", .{});
        return;
    }
    var ctx = Ctx{ .impl = .{
        .gpa = testing.allocator,
        .io = io,
        .ctx = undefined,
        .handler = Ctx.handle,
        .opts = .{ .dispatch = .task, .keep_alive = false },
    } };
    ctx.impl.ctx = @ptrCast(&ctx);
    ctx.address = try std.Io.net.IpAddress.parse("127.0.0.1", port);

    const th = try std.Thread.spawn(.{}, Ctx.acceptAndDispatch, .{&ctx});
    defer th.join();

    const Send = struct {
        fn one(addr: std.Io.net.IpAddress, io2: std.Io, buf: []u8) !usize {
            const stream = try std.Io.net.IpAddress.connect(&addr, io2, .{ .mode = .stream, .protocol = .tcp });
            defer stream.close(io2);
            var cw_buf: [1024]u8 = undefined;
            var cw = stream.writer(io2, &cw_buf);
            try cw.interface.writeAll("GET /x HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n");
            try cw.interface.flush();
            var cr_buf: [1024]u8 = undefined;
            var cr = stream.reader(io2, &cr_buf);
            var total: usize = 0;
            while (total < buf.len) {
                const n = cr.interface.readSliceShort(buf[total..]) catch break;
                if (n == 0) break;
                total += n;
            }
            return total;
        }
    };
    var resp: [2048]u8 = undefined;
    // 连接可能还没被 accept（线程刚起，Linux 上尤其明显）：多试几次，
    // 不要一次 `ConnectionRefused` 就 SKIP —— 那会把「调度延迟」误判成「TCP 不可用」。
    var got: usize = 0;
    var attempt: usize = 0;
    while (attempt < 20) : (attempt += 1) {
        got = Send.one(ctx.address, io, &resp) catch {
            std.Io.sleep(io, .{ .nanoseconds = 50 * std.time.ns_per_ms }, .awake) catch {};
            continue;
        };
        break;
    }
    if (got == 0) {
        std.debug.print("[SKIP] 回环 TCP 不可用（20 次重试均失败）\n", .{});
        return;
    }

    try testing.expect(got > 0);
    try testing.expect(std.mem.indexOf(u8, resp[0..got], "200") != null);
    try testing.expectEqual(@as(usize, 1), ctx.served);
    // 任务收尾（等价 run 退出时的 await）
    ctx.impl.task_group.await(io) catch {};
    std.debug.print("[http] dispatch=.task OK：{d} 字节 / served={d}\n", .{ got, ctx.served });
}

test "HTTP 服务端：请求头数量超限回 431（std 只限总字节，不限个数）" {
    const Ctx = struct {
        impl: Server,
        served: usize = 0,
        address: std.Io.net.IpAddress = undefined,

        fn handle(ctx: *anyopaque, req: RequestView, arena: std.mem.Allocator) anyerror!Reply {
            _ = req;
            _ = arena;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.served += 1;
            return .{ .status = .ok, .body = "ok" };
        }

        fn serve(self: *@This(), listener: *std.Io.net.Server) void {
            const stream = listener.accept(self.impl.io) catch return;
            defer stream.close(self.impl.io);
            self.impl.serveOne(stream) catch {};
        }
    };

    const io = compat.currentIo();
    var ctx = Ctx{ .impl = .{
        .gpa = testing.allocator,
        .io = io,
        .ctx = undefined,
        .handler = Ctx.handle,
        .opts = .{ .keep_alive = false, .max_header_count = 20 },
    } };
    ctx.impl.ctx = @ptrCast(&ctx);

    // **port 0 + 主线程 listen，再把 listener 交给服务端线程**。
    // 不要「先 listen 探测端口再 deinit」：实测 Linux 上 `listen` -> `listener.deinit(io)` -> `connect`
    // 这个组合会让随后的 connect 永久阻塞（std.Io.Threaded 内部状态问题），
    // 与业务代码无关 —— 生产路径 `Server.run` 只在退出时才 deinit，不受影响。
    const bind_addr = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var listener = bind_addr.listen(io, .{ .reuse_address = true }) catch |e| {
        std.debug.print("[SKIP] 无法监听回环端口：{s}\n", .{@errorName(e)});
        return;
    };
    defer listener.deinit(io);
    const port = listener.socket.address.getPort();
    ctx.address = try std.Io.net.IpAddress.parse("127.0.0.1", port);

    const th = try std.Thread.spawn(.{}, Ctx.serve, .{ &ctx, &listener });

    const stream = std.Io.net.IpAddress.connect(&ctx.address, io, .{ .mode = .stream, .protocol = .tcp }) catch |e| {
        th.join();
        std.debug.print("[SKIP] 回环 TCP 不可用：{s}\n", .{@errorName(e)});
        return;
    };
    defer stream.close(io);

    var cw_buf: [2048]u8 = undefined;
    var cw = stream.writer(io, &cw_buf);
    try cw.interface.writeAll("GET /x HTTP/1.1\r\nHost: x\r\nConnection: close\r\n");
    // 100 个小头（总量不到 2 KB —— std 的 head buffer 完全不觉得大）
    // 注意：必须用独立的栈缓冲拼头，复用 `cw_buf`（writer 自己的缓冲）会把已缓冲数据写坏
    var line_buf: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const line = try std.fmt.bufPrint(&line_buf, "X-Pad-{d}: 1\r\n", .{i});
        try cw.interface.writeAll(line);
    }
    try cw.interface.writeAll("\r\n");
    try cw.interface.flush();

    var cr_buf: [1024]u8 = undefined;
    var cr = stream.reader(io, &cr_buf);
    var resp: [512]u8 = undefined;
    var total: usize = 0;
    while (total < resp.len) {
        const n = cr.interface.readSliceShort(resp[total..]) catch break;
        if (n == 0) break;
        total += n;
        // 读到 431 就够：服务端发完即返回并关闭，这里若等 EOF 会和它对等（Linux 上直接挂死）
        if (std.mem.indexOf(u8, resp[0..total], "431") != null) break;
    }
    th.join();

    try testing.expect(total > 0);
    try testing.expect(std.mem.indexOf(u8, resp[0..total], "431") != null);
    try testing.expectEqual(@as(usize, 0), ctx.served); // 没进业务 handler
    std.debug.print("[http] 头数量上限 OK：100 个小头 → 431（{d} 字节）\n", .{total});
}
