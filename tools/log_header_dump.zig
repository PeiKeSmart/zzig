//! 文件头自检工具：真实生成一份日志文件，供 `tools/check-log-header.ps1` 逐字段断言。
//!
//! 存在的意义：**「文件头字段是否齐全」不靠人眼复查**，而是一条命令跑出结果。
//!
//! 用法（在 zzig 根目录）：
//!   zig run --dep zzig -Mroot=tools/log_header_dump.zig -Mzzig=src/zzig.zig
//! 产物：`LogCheck/yyyy_MM_dd.log`（脚本会读它并校验字段清单）

const std = @import("std");
const zzig = @import("zzig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;

    // 走真实链路：异步队列 → 写线程 → 文件，确保产出与实际运行一致
    try zzig.Logger.init(io, gpa, null);
    defer zzig.Logger.shutdown();

    try zzig.Logger.useFile(io, gpa, .{
        .dir = "LogCheck",
        .use_console = false,
        .software = "zzig-log-header-check",
        // 含 `DateTime` → 每行带完整日期（跨天合并分析时必需）；含 `Level` → 正文带级别列
        .line_format = "DateTime|ThreadId|Kind|Name|Message|Level",
        .machine_name = "MACHINE-PLACEHOLDER",
        .user_name = "USER-PLACEHOLDER",
        .temp_path = "TEMP-PLACEHOLDER",
    });

    zzig.Logger.info("header check: 这一行必须出现在正文里", .{});
    zzig.Logger.shutdown();
}
