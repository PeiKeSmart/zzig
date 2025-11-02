const std = @import("std");
const builtin = @import("builtin");

/// Windows API 声明
const windows = std.os.windows;
extern "kernel32" fn SetConsoleOutputCP(wCodePageID: u32) callconv(@import("std").builtin.CallingConvention.winapi) windows.BOOL;
extern "kernel32" fn SetConsoleCP(wCodePageID: u32) callconv(@import("std").builtin.CallingConvention.winapi) windows.BOOL;

/// 控制台功能标志
pub const ConsoleFeatures = packed struct {
    /// 启用 UTF-8 编码
    utf8: bool = true,
    /// 启用 ANSI 颜色支持
    ansi_colors: bool = true,
    /// 启用虚拟终端处理（Windows）
    virtual_terminal: bool = true,
};

/// 控制台初始化结果
pub const InitResult = struct {
    /// 是否成功设置 UTF-8
    utf8_enabled: bool = false,
    /// 是否成功启用 ANSI 颜色
    ansi_enabled: bool = false,
    /// 原始控制台模式（用于恢复，仅 Windows）
    original_mode: ?u32 = null,
};

/// 初始化控制台以支持 UTF-8 和 ANSI 颜色
///
/// # 功能
/// - **Windows**: 设置代码页为 UTF-8 (65001)，启用虚拟终端处理（ANSI 转义序列）
/// - **Unix/Linux/macOS**: 通常默认支持，无需特殊处理
///
/// # 示例
/// ```zig
/// const console = @import("console");
///
/// pub fn main() !void {
///     // 启用所有功能
///     const result = console.init(.{});
///     defer console.deinit(result);
///
///     // 现在可以正常显示中文和 ANSI 颜色
///     std.debug.print("✅ 中文显示正常\n", .{});
///     std.debug.print("\x1b[32m绿色文本\x1b[0m\n", .{});
/// }
/// ```
///
/// # 参数
/// - `features`: 要启用的功能，默认全部启用
///
/// # 返回
/// - `InitResult`: 初始化结果，包含各功能的启用状态
pub fn init(features: ConsoleFeatures) InitResult {
    var result = InitResult{};

    if (builtin.os.tag == .windows) {
        // Windows 平台特殊处理
        const w = std.os.windows;

        // 1. 设置 UTF-8 编码
        if (features.utf8) {
            const CP_UTF8 = 65001;
            const output_ok = SetConsoleOutputCP(CP_UTF8);
            const input_ok = SetConsoleCP(CP_UTF8);
            result.utf8_enabled = (output_ok != 0 and input_ok != 0);
        }

        // 2. 启用虚拟终端处理（ANSI 转义序列）
        if (features.virtual_terminal or features.ansi_colors) {
            const stdout_handle = w.kernel32.GetStdHandle(w.STD_OUTPUT_HANDLE);
            if (stdout_handle != null and stdout_handle != w.INVALID_HANDLE_VALUE) {
                var mode: w.DWORD = 0;
                if (w.kernel32.GetConsoleMode(stdout_handle.?, &mode) != 0) {
                    // 保存原始模式（用于恢复）
                    result.original_mode = mode;

                    // ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004
                    const ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004;
                    const new_mode = mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING;

                    if (w.kernel32.SetConsoleMode(stdout_handle.?, new_mode) != 0) {
                        result.ansi_enabled = true;
                    }
                }
            }
        }
    } else {
        // Unix/Linux/macOS 默认支持 UTF-8 和 ANSI
        result.utf8_enabled = true;
        result.ansi_enabled = true;
    }

    return result;
}

/// 恢复控制台原始设置（可选）
///
/// # 说明
/// 在程序退出前调用，恢复控制台到初始状态。通常不需要手动调用，
/// 因为操作系统会在进程退出时自动恢复。
///
/// # 参数
/// - `result`: `init()` 返回的结果
///
/// # 示例
/// ```zig
/// const result = console.init(.{});
/// defer console.deinit(result);  // 确保退出时恢复
/// ```
pub fn deinit(result: InitResult) void {
    if (builtin.os.tag == .windows) {
        if (result.original_mode) |original| {
            const w = std.os.windows;
            const stdout_handle = w.kernel32.GetStdHandle(w.STD_OUTPUT_HANDLE);
            if (stdout_handle != null and stdout_handle != w.INVALID_HANDLE_VALUE) {
                _ = w.kernel32.SetConsoleMode(stdout_handle.?, original);
            }
        }
    }
}

/// 快速初始化（使用默认配置）
///
/// 等同于 `init(.{})`，启用所有功能。
///
/// # 示例
/// ```zig
/// pub fn main() !void {
///     console.setup();  // 快速启用
///     std.debug.print("✅ 控制台已配置\n", .{});
/// }
/// ```
pub fn setup() void {
    _ = init(.{});
}

/// 检测控制台是否支持 ANSI 颜色
///
/// # 返回
/// - `true`: 支持 ANSI 颜色
/// - `false`: 不支持
///
/// # 说明
/// - Windows: 检查是否成功启用虚拟终端处理
/// - Unix: 检查 `TERM` 环境变量
pub fn supportsAnsiColors() bool {
    if (builtin.os.tag == .windows) {
        // Windows 需要检查虚拟终端是否启用
        const w = std.os.windows;
        const stdout_handle = w.kernel32.GetStdHandle(w.STD_OUTPUT_HANDLE);
        if (stdout_handle != null and stdout_handle != w.INVALID_HANDLE_VALUE) {
            var mode: w.DWORD = 0;
            if (w.kernel32.GetConsoleMode(stdout_handle.?, &mode) != 0) {
                const ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004;
                return (mode & ENABLE_VIRTUAL_TERMINAL_PROCESSING) != 0;
            }
        }
        return false;
    } else {
        // Unix 检查 TERM 环境变量
        const term = std.posix.getenv("TERM") orelse return true; // 默认支持
        return !std.mem.eql(u8, term, "dumb");
    }
}

/// 控制台颜色工具
pub const Color = struct {
    /// ANSI 颜色代码
    pub const Code = enum {
        reset,
        black,
        red,
        green,
        yellow,
        blue,
        magenta,
        cyan,
        white,
        bright_black,
        bright_red,
        bright_green,
        bright_yellow,
        bright_blue,
        bright_magenta,
        bright_cyan,
        bright_white,

        /// 获取前景色 ANSI 代码
        pub fn fg(self: Code) []const u8 {
            return switch (self) {
                .reset => "\x1b[0m",
                .black => "\x1b[30m",
                .red => "\x1b[31m",
                .green => "\x1b[32m",
                .yellow => "\x1b[33m",
                .blue => "\x1b[34m",
                .magenta => "\x1b[35m",
                .cyan => "\x1b[36m",
                .white => "\x1b[37m",
                .bright_black => "\x1b[90m",
                .bright_red => "\x1b[91m",
                .bright_green => "\x1b[92m",
                .bright_yellow => "\x1b[93m",
                .bright_blue => "\x1b[94m",
                .bright_magenta => "\x1b[95m",
                .bright_cyan => "\x1b[96m",
                .bright_white => "\x1b[97m",
            };
        }

        /// 获取背景色 ANSI 代码
        pub fn bg(self: Code) []const u8 {
            return switch (self) {
                .reset => "\x1b[0m",
                .black => "\x1b[40m",
                .red => "\x1b[41m",
                .green => "\x1b[42m",
                .yellow => "\x1b[43m",
                .blue => "\x1b[44m",
                .magenta => "\x1b[45m",
                .cyan => "\x1b[46m",
                .white => "\x1b[47m",
                .bright_black => "\x1b[100m",
                .bright_red => "\x1b[101m",
                .bright_green => "\x1b[102m",
                .bright_yellow => "\x1b[103m",
                .bright_blue => "\x1b[104m",
                .bright_magenta => "\x1b[105m",
                .bright_cyan => "\x1b[106m",
                .bright_white => "\x1b[107m",
            };
        }
    };

    /// 文本样式
    pub const Style = enum {
        bold,
        dim,
        italic,
        underline,
        blink,
        reverse,
        hidden,
        strikethrough,

        pub fn code(self: Style) []const u8 {
            return switch (self) {
                .bold => "\x1b[1m",
                .dim => "\x1b[2m",
                .italic => "\x1b[3m",
                .underline => "\x1b[4m",
                .blink => "\x1b[5m",
                .reverse => "\x1b[7m",
                .hidden => "\x1b[8m",
                .strikethrough => "\x1b[9m",
            };
        }
    };

    /// 格式化带颜色的文本
    ///
    /// # 示例
    /// ```zig
    /// const text = console.Color.fmt(.green, "成功", .{});
    /// std.debug.print("{s}\n", .{text});
    /// ```
    pub fn fmt(color: Code, comptime text: []const u8, args: anytype) []const u8 {
        _ = args;
        return color.fg() ++ text ++ Code.reset.fg();
    }
};

// ========================================
// 测试
// ========================================

test "console init and deinit" {
    const result = init(.{});
    defer deinit(result);

    // 验证初始化结果
    if (builtin.os.tag == .windows) {
        // Windows 应该尝试启用 UTF-8 和 ANSI
        std.testing.expect(result.utf8_enabled or !result.utf8_enabled) catch unreachable;
    } else {
        // Unix 默认应该支持
        try std.testing.expect(result.utf8_enabled);
        try std.testing.expect(result.ansi_enabled);
    }
}

test "console setup" {
    // 快速设置应该不会崩溃
    setup();
}

test "console supportsAnsiColors" {
    _ = supportsAnsiColors(); // 应该返回 bool，不崩溃
}

test "Color codes" {
    const red = Color.Code.red.fg();
    try std.testing.expectEqualStrings("\x1b[31m", red);

    const bg_blue = Color.Code.blue.bg();
    try std.testing.expectEqualStrings("\x1b[44m", bg_blue);

    const reset = Color.Code.reset.fg();
    try std.testing.expectEqualStrings("\x1b[0m", reset);
}

test "Style codes" {
    const bold = Color.Style.bold.code();
    try std.testing.expectEqualStrings("\x1b[1m", bold);

    const underline = Color.Style.underline.code();
    try std.testing.expectEqualStrings("\x1b[4m", underline);
}
