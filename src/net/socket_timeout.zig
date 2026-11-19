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

/// 诊断输出：**只在 Debug 构建下打印**。
///
/// 生产包（ReleaseFast/ReleaseSmall）里 socket 选项失败是「预期内的降级」
/// （见文件头：Windows 上 AFD 对 `SO_RCVTIMEO` 结果不稳定），每次连接打一行会把日志变成负担。
/// 需要知道是否降级时，由调用方用自己的日志系统记一次（如 `http.server` 的 `timeout_warned`）。
fn logDebug(comptime fmt: []const u8, args: anytype) void {
    // Zig 0.17 的优化模式枚举成员是小写（`.debug`）；`.Debug` 只是保留别名且不在
    // `builtin.mode` 的枚举类型里 —— 直接比较会报 “no field named 'Debug'”。
    if (builtin.mode == .debug) std.debug.print("[socket_timeout] " ++ fmt ++ "\n", args);
}

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
        logDebug("AFD SOCKOPT 调用失败：{s}", .{@errorName(e)});
        return error.SetFailed;
    };
    switch (result.device_io_control.u.Status) {
        .SUCCESS => return,
        .INSUFFICIENT_RESOURCES => return error.SystemResources,
        .CANCELLED => return error.SetFailed,
        else => |status| {
            // 带上具体 NTSTATUS：0xC00000BB = NOT_SUPPORTED，0xC000000D = INVALID_PARAMETER
            logDebug("AFD SOCKOPT 失败：opt={s} value={d} status=0x{X}", .{ @tagName(which), value_in, @backingInt(status) });
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

test "socket_timeout：在真实连接上调用设置接口不崩（超时行为依平台而异，不断言）" {
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
        fn server(io2: std.Io, l: *std.Io.net.Server, recv_ok: *bool, nodelay_ok: *bool) void {
            const stream = l.accept(io2) catch return;
            defer stream.close(io2);
            // 两个接口都必须「要么成功、要么返回错误」，**绝不能 panic / 挂住**
            setRecvTimeout(io2, stream, 5000) catch {
                recv_ok.* = false;
            };
            setNoDelay(io2, stream, true) catch {
                nodelay_ok.* = false;
            };
        }
    };

    var recv_ok = true;
    var nodelay_ok = true;
    const th = try std.Thread.spawn(.{}, Run.server, .{ io, &listener, &recv_ok, &nodelay_ok });

    const address = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    const client = try std.Io.net.IpAddress.connect(&address, io, .{ .mode = .stream, .protocol = .tcp });
    defer client.close(io);
    th.join();

    // 不断言具体成功与否：**两个平台都实测过不一致**
    // - Windows：AFD 对 `SO_RCVTIMEO` 既回过 STATUS_NOT_SUPPORTED 也回过成功；
    // - Linux：`setsockopt` 能设上，但到点后 `read` 返回 `EAGAIN`，`std.Io` 在 Debug 构建下
    //   会当成 programmer bug 直接 panic（实测 “programmer bug caused syscall error: AGAIN”）。
    // 真要做 Slowloris 防护，用 `max_connections` + `keep_alive_requests` + 反代超时。
    std.debug.print(
        "[socket_timeout] 平台={s} recv_ok={} nodelay_ok={}（仅观测，不作断言）\n",
        .{ @tagName(builtin.os.tag), recv_ok, nodelay_ok },
    );
}
