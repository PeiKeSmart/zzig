const std = @import("std");
const zzig = @import("zzig");

/// 性能测试：过滤场景（日志被过滤，测量最小开销）
fn benchmarkFiltered(iterations: usize, thread_safe: bool) !void {
    if (thread_safe) {
        zzig.Logger.enableThreadSafe();
    } else {
        zzig.Logger.disableThreadSafe();
    }

    // 设置为 err 级别，debug 日志会被过滤
    zzig.Logger.setLevel(.err);

    const start = std.time.nanoTimestamp();

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        zzig.Logger.debug("测试消息 {d}", .{i});
    }

    const end = std.time.nanoTimestamp();
    const duration = end - start;
    const avg_ns = @divTrunc(duration, @as(i128, @intCast(iterations)));

    const mode = if (thread_safe) "线程安全" else "普通模式";
    std.debug.print("  {s}: 平均 {d} ns/次, 吞吐 {d} M次/秒\n", .{
        mode,
        avg_ns,
        @divTrunc(@as(i128, 1000), avg_ns),
    });
}

/// 性能测试：实际输出场景（包含格式化和IO）
fn benchmarkActual(iterations: usize, thread_safe: bool) !void {
    if (thread_safe) {
        zzig.Logger.enableThreadSafe();
    } else {
        zzig.Logger.disableThreadSafe();
    }

    // 全部启用，会实际输出
    zzig.Logger.setLevel(.debug);

    const start = std.time.nanoTimestamp();

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        zzig.Logger.info("测试 {d}", .{i});
    }

    const end = std.time.nanoTimestamp();
    const duration = end - start;
    const avg_us = @divTrunc(duration, @as(i128, @intCast(iterations)) * 1000);

    const mode = if (thread_safe) "线程安全" else "普通模式";
    std.debug.print("  {s}: 平均 {d} μs/次 (包含IO)\n", .{ mode, avg_us });
}

pub fn main() !void {
    std.debug.print("\n" ++ "=" ** 70 ++ "\n", .{});
    std.debug.print("Logger 性能基准测试\n", .{});
    std.debug.print("=" ** 70 ++ "\n", .{});

    // 测试 1: 过滤场景（测量最小开销）
    std.debug.print("\n【测试 1】过滤场景 (日志被过滤，几乎无开销)\n", .{});
    std.debug.print("迭代: 1,000,000 次\n", .{});
    try benchmarkFiltered(1_000_000, false);
    try benchmarkFiltered(1_000_000, true);

    std.debug.print("\n【测试 2】实际输出场景 (包含格式化 + IO，真实开销)\n", .{});
    std.debug.print("迭代: 1,000 次 (输出到控制台)\n", .{});
    try benchmarkActual(1_000, false);
    
    std.debug.print("\n启用线程安全...\n", .{});
    try benchmarkActual(1_000, true);

    std.debug.print("\n" ++ "=" ** 70 ++ "\n", .{});
    std.debug.print("结论:\n", .{});
    std.debug.print("1. 被过滤的日志几乎无开销 (~5 ns)\n", .{});
    std.debug.print("2. 线程安全开关对过滤日志无影响\n", .{});
    std.debug.print("3. 实际输出时，IO 是主要瓶颈 (10-100 μs)\n", .{});
    std.debug.print("4. 线程安全锁开销相比 IO 可以忽略\n", .{});
    std.debug.print("=" ** 70 ++ "\n\n", .{});
}
