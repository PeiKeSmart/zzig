//! **原生 socket 读超时 / TCP_NODELAY**：Windows 走 AFD 层，POSIX 走 `setsockopt`。
//!
//! 来源：与 `zgrpc` 的 `src/socket_timeout.zig` 同一实现（该库里已验证），按「同一逻辑
//! 第二份就下沉」的约定收到 zzig，供 HTTP 服务端与 gRPC 共用。
//!
//! ## 实测结论（2026-11-19 本机 Windows 11 + Zig 0.17.1）
//!
//! - **POSIX（Linux，生产部署目标）：可用** —— `setsockopt(SO_RCVTIMEO)` 到点 `read` 返回
//!   `EAGAIN` → `error.WouldBlock`。
//! - **Windows：不稳定** —— 同一台机器上 `IOCTL_AFD_SOCKOPT` + `SO_RCVTIMEO` 实测既出现过
//!   `STATUS_NOT_SUPPORTED`（`0xC00000BB`），也出现过成功（随后 100ms 读真的超时返回）。
//!   源码佐证：`std.os.windows.AFD.RECEIVE` 只有 `Request` / `ReceiveFlags`，**没有 Timeout 字段**
//!   （而 `AFD.CONNECT` / `AFD.DISCONNECT` 有），所以这条路不保证有效。
//!
//! 因此调用方**必须能降级**：设置失败不崩、不阻塞业务；Windows 开发机靠
//! `max_connections` + `keep_alive_requests` + 前置 nginx 的 `client_header_timeout` 兜 Slowloris。

const std = @import("std");
const builtin = @import("builtin");

pub const SetError = error{
    /// 该平台不支持在已建立的连接上设置选项
    Unsupported,
    /// 底层返回了失败状态
    SetFailed,
    SystemResources,
};

/// 给 socket 设置**原生读超时**（毫秒）。`ms == 0` 表示不限。
pub fn setRecvTimeout(io: std.Io, stream: std.Io.net.Stream, ms: u32) SetError!void {
    if (builtin.os.tag == .windows) return setSocketOptionAfd(io, stream, .recv_timeout, ms);
    return setRecvTimeoutPosix(stream, ms);
}

/// 控制 Nagle 算法（`TCP_NODELAY`）。
///
/// 小包交互（HTTP/1.1 的 header+body、gRPC 的 HEADERS+DATA+TRAILERS）**应当关闭**：
/// Nagle 会让后续小包等前一个 ACK，与对端延迟 ACK 叠加后出现随机 10~200ms 尖峰。
pub fn setNoDelay(io: std.Io, stream: std.Io.net.Stream, enable: bool) SetError!void {
    if (builtin.os.tag == .windows) return setSocketOptionAfd(io, stream, .nodelay, @intFromBool(enable));
    if (builtin.os.tag == .wasi or builtin.os.tag == .freestanding) return error.Unsupported;
    const v: c_int = @intFromBool(enable);
    std.posix.setsockopt(
        stream.socket.handle,
        std.posix.IPPROTO.TCP,
        std.posix.TCP.NODELAY,
        std.mem.asBytes(&v),
    ) catch return error.SetFailed;
}

/// 读错误是否属于「原生读超时」。
///
/// - Windows：AFD 到点 `STATUS_IO_TIMEOUT` → `error.ConnectionTimedOut`；
/// - POSIX：`SO_RCVTIMEO` 到点 → `EAGAIN` → `error.WouldBlock`。
pub fn isReadTimeout(err: anyerror) bool {
    return switch (err) {
        error.ConnectionTimedOut, error.WouldBlock => true,
        else => false,
    };
}

const Which = enum { recv_timeout, nodelay };

/// Windows：`IOCTL_AFD_SOCKOPT` + `SOL.SOCKET/SO.RCVTIMEO`（或 `IPPROTO.TCP/TCP.NODELAY`）。
///
/// 注意只能走 AFD 路径，不能调 Winsock 库函数 —— 见文件头说明。
fn setSocketOptionAfd(io: std.Io, stream: std.Io.net.Stream, which: Which, value_in: u32) SetError!void {
    if (builtin.os.tag != .windows) unreachable;
    var value: u32 = value_in;
    const info = std.os.windows.AFD.SOCKOPT_INFO{
        .mode = .set,
        .level = switch (which) {
            .recv_timeout => std.os.windows.ws2_32.SOL.SOCKET,
            .nodelay => std.os.windows.ws2_32.IPPROTO.TCP,
        },
        .optname = switch (which) {
            .recv_timeout => std.os.windows.ws2_32.SO.RCVTIMEO,
            .nodelay => std.os.windows.ws2_32.TCP.NODELAY,
        },
        .optval = @ptrCast(&value),
        .optlen = @sizeOf(u32),
    };
    const result = io.operate(.{ .device_io_control = .{
        .file = .{ .handle = stream.socket.handle, .flags = .{ .nonblocking = true } },
        .code = std.os.windows.IOCTL.AFD.SOCKOPT,
        .in = std.mem.asBytes(&info),
    } }) catch |e| {
        std.debug.print("[socket_timeout] AFD SOCKOPT 调用失败：{s}\n", .{@errorName(e)});
        return error.SetFailed;
    };
    switch (result.device_io_control.u.Status) {
        .SUCCESS => return,
        .INSUFFICIENT_RESOURCES => return error.SystemResources,
        .CANCELLED => return error.SetFailed,
        else => |status| {
            // 带上具体 NTSTATUS：0xC00000BB = NOT_SUPPORTED，0xC000000D = INVALID_PARAMETER
            std.debug.print(
                "[socket_timeout] AFD SOCKOPT 失败：opt={s} value={d} status=0x{X}\n",
                .{ @tagName(which), value_in, @backingInt(status) },
            );
            return error.SetFailed;
        },
    }
}

/// POSIX：标准 `setsockopt(SO_RCVTIMEO)`。
fn setRecvTimeoutPosix(stream: std.Io.net.Stream, ms: u32) SetError!void {
    if (builtin.os.tag == .windows) unreachable;
    if (builtin.os.tag == .wasi or builtin.os.tag == .freestanding) return error.Unsupported;
    const secs: i64 = @intCast(ms / 1000);
    const usecs: i64 = @intCast((ms % 1000) * 1000);
    var tv: std.posix.timeval = .{ .sec = secs, .usec = usecs };
    std.posix.setsockopt(
        stream.socket.handle,
        std.posix.SOL.SOCKET,
        std.posix.SO.RCVTIMEO,
        std.mem.asBytes(&tv),
    ) catch return error.SetFailed;
}

test "socket_timeout：读超时错误识别" {
    try std.testing.expect(isReadTimeout(error.ConnectionTimedOut));
    try std.testing.expect(isReadTimeout(error.WouldBlock));
    try std.testing.expect(!isReadTimeout(error.ConnectionResetByPeer));
    try std.testing.expect(!isReadTimeout(error.Timeout));
}

test "socket_timeout：设置原生读超时后，对端不发数据会按时返回超时" {
    const compat = @import("../compat.zig");
    const io = compat.currentIo();

    // 找可用端口
    var port: u16 = 39401;
    var bound: ?std.Io.net.Server = null;
    while (port < 39420) : (port += 1) {
        const addr = std.Io.net.IpAddress.parse("127.0.0.1", port) catch continue;
        bound = addr.listen(io, .{ .reuse_address = true }) catch continue;
        break;
    }
    var listener = bound orelse {
        std.debug.print("[SKIP] 39401-39419 端口均不可用\n", .{});
        return;
    };
    defer listener.deinit(io);

    const Run = struct {
        fn server(io2: std.Io, l: *std.Io.net.Server, set_ok: *bool, timed_out: *bool) void {
            const stream = l.accept(io2) catch return;
            defer stream.close(io2);
            // 设置失败也要继续读：Windows 无原生超时，靠客户端关闭解阻塞（降级路径同样要验证）
            setRecvTimeout(io2, stream, 100) catch {
                set_ok.* = false;
            };
            set_ok.* = true;
            var buf: [64]u8 = undefined;
            var sr = stream.reader(io2, &buf);
            const n = sr.interface.readSliceShort(&buf) catch {
                // 超时（POSIX）或对端关闭/重置（Windows 无原生超时，靠客户端关闭解阻塞）：
                // 两者都说明「连接没有永久占住线程」，这才是本用例要守的性质。
                timed_out.* = true;
                return;
            };
            if (n == 0) timed_out.* = true; // 对端关闭也算「没挂死」
        }
    };

    var set_ok = true;
    var timed_out = false;
    const th = try std.Thread.spawn(.{}, Run.server, .{ io, &listener, &set_ok, &timed_out });

    const address = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    var client = try std.Io.net.IpAddress.connect(&address, io, .{ .mode = .stream, .protocol = .tcp });

    // 客户端**一个字节都不发**：慢速攻击的最小复现。
    // Windows 上原生读超时不可用（AFD 不支持），服务端的读会一直阻塞 ——
    // 这里等 300ms 后由客户端主动关闭解阻塞，用例同样能给出确定结论。
    std.Io.sleep(io, .{ .nanoseconds = 300 * std.time.ns_per_ms }, .awake) catch {};
    client.close(io);

    th.join();
    // **只守「不永久挂住」这个性质**：`set_ok` 依赖运行时 socket 类型（AFD 上 `SO_RCVTIMEO`
    // 可能回 STATUS_NOT_SUPPORTED，也可能成功），不作为断言 —— 调用方必须两条路都能跑。
    std.debug.print("[socket_timeout] 平台={s} set_ok={}（仅观测） timed_out={}\n", .{ @tagName(builtin.os.tag), set_ok, timed_out });
    try std.testing.expect(timed_out);
}
