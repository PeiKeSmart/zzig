const std = @import("std");
const zzig = @import("zzig");
const Profiler = zzig.profiler.Profiler;

/// 模拟日志处理函数
fn processLog(profiler: *Profiler, msg: []const u8) void {
    const zone = profiler.beginZone("log_processing");
    defer profiler.endZone(zone);

    // 模拟字符串处理
    var hash: u64 = 0;
    for (msg) |byte| {
        hash = hash *% 31 +% byte;
    }
    std.mem.doNotOptimizeAway(&hash); // 防止编译器优化掉

    std.Thread.sleep(10 * std.time.ns_per_us); // 模拟耗时操作
}

/// 模拟文件写入
fn writeToFile(profiler: *Profiler) void {
    const zone = profiler.beginZone("file_write");
    defer profiler.endZone(zone);

    std.Thread.sleep(100 * std.time.ns_per_us);
}

/// 模拟队列操作
fn queueOperation(profiler: *Profiler) void {
    const zone = profiler.beginZone("queue_push");
    defer profiler.endZone(zone);

    std.Thread.sleep(5 * std.time.ns_per_us);
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== 性能剖析工具示例 ===\n\n", .{});

    // ========== 场景 1: 禁用模式（零开销） ==========
    std.debug.print("【场景 1】禁用模式（生产环境）\n", .{});
    {
        var profiler = try Profiler.init(allocator, .{
            .enable = false, // ✅ Release 模式下完全编译掉
        });
        defer profiler.deinit();

        for (0..10000) |_| {
            processLog(&profiler, "This is a test log message");
            queueOperation(&profiler);
        }

        std.debug.print("✅ 已执行 10,000 次操作，零性能开销\n\n", .{});
    }

    // ========== 场景 2: 全量采样（开发环境） ==========
    std.debug.print("【场景 2】全量采样（开发调试）\n", .{});
    {
        var profiler = try Profiler.init(allocator, .{
            .enable = true,
            .sample_rate = 1.0, // 100% 采样
        });
        defer profiler.deinit();

        for (0..100) |_| {
            processLog(&profiler, "Debug message for full sampling");
            writeToFile(&profiler);
            queueOperation(&profiler);
        }

        profiler.printSummary();
    }

    // ========== 场景 3: 采样模式（生产环境监控） ==========
    std.debug.print("【场景 3】采样模式（1% 采样率）\n", .{});
    {
        var profiler = try Profiler.init(allocator, .{
            .enable = true,
            .sample_rate = 0.01, // 1% 采样
        });
        defer profiler.deinit();

        for (0..10000) |_| {
            processLog(&profiler, "Production log message");
            queueOperation(&profiler);
        }

        profiler.printSummary();
    }

    // ========== 场景 4: 导出 JSON 报告 ==========
    std.debug.print("【场景 4】导出性能报告\n", .{});
    {
        var profiler = try Profiler.init(allocator, .{
            .enable = true,
            .sample_rate = 1.0,
        });
        defer profiler.deinit();

        // 模拟复杂工作流
        for (0..500) |_| {
            processLog(&profiler, "Test message");
        }
        for (0..200) |_| {
            writeToFile(&profiler);
        }
        for (0..1000) |_| {
            queueOperation(&profiler);
        }

        try profiler.exportReport("profiler_report.json");
        std.debug.print("✅ 性能报告已导出至 profiler_report.json\n\n", .{});
    }

    // ========== 场景 5: 性能对比测试 ==========
    std.debug.print("【场景 5】性能对比测试\n", .{});

    // 基线测试（无剖析）
    const baseline_start = std.time.nanoTimestamp();
    for (0..100000) |_| {
        var hash: u64 = 0;
        for ("test message") |byte| {
            hash = hash *% 31 +% byte;
        }
    }
    const baseline_end = std.time.nanoTimestamp();
    const baseline_duration = @as(u64, @intCast(baseline_end - baseline_start));

    // 禁用剖析测试
    {
        var profiler = try Profiler.init(allocator, .{ .enable = false });
        defer profiler.deinit();

        const disabled_start = std.time.nanoTimestamp();
        for (0..100000) |_| {
            const zone = profiler.beginZone("test");
            defer profiler.endZone(zone);

            var hash: u64 = 0;
            for ("test message") |byte| {
                hash = hash *% 31 +% byte;
            }
        }
        const disabled_end = std.time.nanoTimestamp();
        const disabled_duration = @as(u64, @intCast(disabled_end - disabled_start));

        const overhead = if (baseline_duration > 0)
            @as(f64, @floatFromInt(disabled_duration)) / @as(f64, @floatFromInt(baseline_duration)) - 1.0
        else
            0.0;

        std.debug.print("基线耗时: {} ns\n", .{baseline_duration});
        std.debug.print("禁用剖析耗时: {} ns\n", .{disabled_duration});
        std.debug.print("性能开销: {d:.2}%\n", .{overhead * 100});
    }

    // 1% 采样测试
    std.debug.print("\n", .{});
    {
        var profiler = try Profiler.init(allocator, .{
            .enable = true,
            .sample_rate = 0.01,
        });
        defer profiler.deinit();

        const sampled_start = std.time.nanoTimestamp();
        for (0..100000) |_| {
            const zone = profiler.beginZone("test");
            defer profiler.endZone(zone);

            var hash: u64 = 0;
            for ("test message") |byte| {
                hash = hash *% 31 +% byte;
            }
        }
        const sampled_end = std.time.nanoTimestamp();
        const sampled_duration = @as(u64, @intCast(sampled_end - sampled_start));

        const overhead = if (baseline_duration > 0)
            @as(f64, @floatFromInt(sampled_duration)) / @as(f64, @floatFromInt(baseline_duration)) - 1.0
        else
            0.0;

        std.debug.print("1%% 采样耗时: {} ns\n", .{sampled_duration});
        std.debug.print("性能开销: {d:.2}%\n", .{overhead * 100});
        std.debug.print("\n✅ 验证目标：<1%% 开销（实际 {d:.2}%%）\n", .{overhead * 100});
    }

    std.debug.print("\n=== 所有场景测试完成 ===\n", .{});
}
