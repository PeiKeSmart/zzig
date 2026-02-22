/// input.zig — 跨平台单键读取（无需按 Enter）
///
/// Windows : 暂时关闭 ENABLE_LINE_INPUT / ENABLE_ECHO_INPUT，读取一个字符后恢复
/// Linux   : 切换 termios 到 raw 模式，读取一个字节后恢复
/// macOS   : 同 Linux，使用 POSIX termios
const std = @import("std");
const builtin = @import("builtin");

/// 读取单个按键，不需要用户按 Enter 即可返回。
/// 返回按下的字节值（u8）。
pub fn readKey() !u8 {
    return switch (builtin.os.tag) {
        .windows => readKeyWindows(),
        .linux, .macos => readKeyUnix(),
        else => {
            // 其他平台降级到普通读取，取第一个字符
            var buf: [1]u8 = undefined;
            _ = try std.posix.read(std.posix.STDIN_FILENO, &buf);
            return buf[0];
        },
    };
}

// ─────────────────────────────────────────────────────────────────────────────
// Windows 实现
// ─────────────────────────────────────────────────────────────────────────────

fn readKeyWindows() !u8 {
    const w = std.os.windows;
    const winapi = std.builtin.CallingConvention.winapi;

    const GetConsoleMode = struct {
        extern "kernel32" fn GetConsoleMode(
            hConsoleHandle: w.HANDLE,
            lpMode: *w.DWORD,
        ) callconv(winapi) w.BOOL;
    }.GetConsoleMode;

    const SetConsoleMode = struct {
        extern "kernel32" fn SetConsoleMode(
            hConsoleHandle: w.HANDLE,
            dwMode: w.DWORD,
        ) callconv(winapi) w.BOOL;
    }.SetConsoleMode;

    const FlushConsoleInputBuffer = struct {
        extern "kernel32" fn FlushConsoleInputBuffer(
            hConsoleInput: w.HANDLE,
        ) callconv(winapi) w.BOOL;
    }.FlushConsoleInputBuffer;

    const stdin = w.kernel32.GetStdHandle(w.STD_INPUT_HANDLE) orelse
        return error.InvalidHandle;
    if (stdin == w.INVALID_HANDLE_VALUE) return error.InvalidHandle;

    // 保存原始控制台模式
    var orig_mode: w.DWORD = 0;
    _ = GetConsoleMode(stdin, &orig_mode);

    // 仅保留 ENABLE_PROCESSED_INPUT（处理 Ctrl-C 等），关闭行缓冲和回显
    const ENABLE_PROCESSED_INPUT: w.DWORD = 0x0001;
    _ = SetConsoleMode(stdin, ENABLE_PROCESSED_INPUT);
    defer _ = SetConsoleMode(stdin, orig_mode); // 退出时还原

    // 读取一个字节
    var ch: [1]u8 = undefined;
    var bytes_read: w.DWORD = 0;
    if (w.kernel32.ReadFile(stdin, &ch, 1, &bytes_read, null) == 0 or bytes_read == 0) {
        return error.ReadFailed;
    }

    // 清除输入缓冲区中残留的 \r\n 等字节
    _ = FlushConsoleInputBuffer(stdin);

    return ch[0];
}

// ─────────────────────────────────────────────────────────────────────────────
// Linux / macOS 实现 (POSIX termios)
// ─────────────────────────────────────────────────────────────────────────────

fn readKeyUnix() !u8 {
    const fd = std.posix.STDIN_FILENO;

    // 获取当前 termios 设置
    var orig: std.posix.termios = undefined;
    try std.posix.tcgetattr(fd, &orig);

    // 切换到 raw 模式：关闭行缓冲（ICANON）和回显（ECHO）
    var raw = orig;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 1; // 至少读取 1 个字节才返回
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0; // 无超时，一直等待

    try std.posix.tcsetattr(fd, .NOW, raw);
    defer std.posix.tcsetattr(fd, .NOW, orig) catch {}; // 退出时还原

    var buf: [1]u8 = undefined;
    const n = try std.posix.read(fd, &buf);
    if (n == 0) return error.EndOfStream;

    return buf[0];
}
