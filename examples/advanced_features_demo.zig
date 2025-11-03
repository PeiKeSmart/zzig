const std = @import("std");
const zzig = @import("zzig");
const DynamicQueue = @import("zzig").logs.DynamicQueue;
const RotationManager = @import("zzig").logs.RotationManager;
const Profiler = @import("zzig").profiler.Profiler;

/// 综合演示：动态队列 + 日志轮转 + 性能剖析
///
/// 展示 v1.2.0 新增的高级特性如何协同工作：
/// 1. DynamicQueue - 自动扩容的无锁队列
/// 2. RotationManager - 多策略日志轮转
/// 3. Profiler - 零开销性能剖析
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n╔══════════════════════════════════════════════╗\n", .{});
    std.debug.print("║   ZZig v1.2.0 - 高级特性综合演示             ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════╝\n\n", .{});

    // ========== 场景 1: 动态队列压力测试 ==========
    std.debug.print("【场景 1】动态队列 - 自动扩容\n", .{});
    {
        var queue = try DynamicQueue(u64).init(allocator, .{
            .initial_capacity = 8, // 初始容量很小
            .max_capacity = 1024,
            .growth_factor = 2.0,
            .resize_threshold = 0.95,
        });
        defer queue.deinit();

        std.debug.print("初始容量: {}\n", .{queue.buffer.len});

        // 快速推入数据，触发自动扩容
        for (0..100) |i| {
            try queue.push(i);
        }

        std.debug.print("推入 100 条数据后容量: {}\n", .{queue.buffer.len});
        std.debug.print("队列长度: {}\n", .{queue.size()});
        std.debug.print("✅ 零阻塞扩容完成\n\n", .{});
    }

    // ========== 场景 2: 日志轮转策略 ==========
    std.debug.print("【场景 2】日志轮转 - 配置演示\n", .{});
    {
        var rotation_mgr = try RotationManager.init(allocator, .{
            .strategy = .size_based,
            .max_file_size = 1024 * 100, // 100 KB
            .max_backup_files = 5,
            .enable_compression = false,
        });
        defer rotation_mgr.deinit();

        std.debug.print("轮转策略: 按大小触发\n", .{});
        std.debug.print("最大文件大小: {} KB\n", .{rotation_mgr.config.max_file_size / 1024});
        std.debug.print("保留备份数: {}\n", .{rotation_mgr.config.max_backup_files});
        std.debug.print("✅ 轮转管理器已就绪\n\n", .{});
    }

    // ========== 场景 3: 性能剖析 - 热点识别 ==========
    std.debug.print("【场景 3】性能剖析 - 热点识别\n", .{});
    {
        var profiler = try Profiler.init(allocator, .{
            .enable = true,
            .sample_rate = 1.0, // 全量采样
        });
        defer profiler.deinit();

        // 模拟日志处理流程
        for (0..1000) |_| {
            {
                const zone = profiler.beginZone("queue_push");
                defer profiler.endZone(zone);
                std.Thread.sleep(1 * std.time.ns_per_us);
            }

            {
                const zone = profiler.beginZone("format_log");
                defer profiler.endZone(zone);
                std.Thread.sleep(5 * std.time.ns_per_us);
            }

            {
                const zone = profiler.beginZone("write_file");
                defer profiler.endZone(zone);
                std.Thread.sleep(20 * std.time.ns_per_us);
            }
        }

        profiler.printSummary();
    }

    // ========== 场景 4: 生产环境配置（零开销） ==========
    std.debug.print("\n【场景 4】生产环境配置（性能验证）\n", .{});
    {
        var profiler = try Profiler.init(allocator, .{ .enable = false });
        defer profiler.deinit();

        const start = std.time.nanoTimestamp();

        // 100万次操作
        for (0..1_000_000) |_| {
            const zone = profiler.beginZone("production_log");
            defer profiler.endZone(zone);
            // 空操作
        }

        const end = std.time.nanoTimestamp();
        const duration_ns = @as(u64, @intCast(end - start));

        std.debug.print("100 万次剖析调用耗时: {} ns\n", .{duration_ns});
        std.debug.print("平均每次: {d:.2} ns\n", .{@as(f64, @floatFromInt(duration_ns)) / 1_000_000.0});
        std.debug.print("✅ 禁用模式下接近零开销\n\n", .{});
    }

    // ========== 场景 5: 性能剖析多线程测试 ==========
    std.debug.print("【场景 5】多线程环境下的性能剖析\n", .{});
    {
        const ThreadContext = struct {
            profiler: *Profiler,
            thread_id: usize,
        };

        var profiler = try Profiler.init(allocator, .{
            .enable = true,
            .sample_rate = 0.01, // 1% 采样
        });
        defer profiler.deinit();

        // 创建多个工作线程
        var threads: [4]std.Thread = undefined;
        var contexts: [4]ThreadContext = undefined;

        for (0..4) |i| {
            contexts[i] = .{
                .profiler = &profiler,
                .thread_id = i,
            };
        }

        // 启动工作线程
        for (0..4) |i| {
            threads[i] = try std.Thread.spawn(.{}, struct {
                fn worker(ctx: *const ThreadContext) void {
                    for (0..1000) |_| {
                        const zone = ctx.profiler.beginZone("thread_work");
                        defer ctx.profiler.endZone(zone);

                        // 模拟工作负载
                        var sum: u64 = 0;
                        for (0..100) |j| {
                            sum +%= ctx.thread_id * 100 + j;
                        }
                        std.mem.doNotOptimizeAway(&sum);
                    }
                }
            }.worker, .{&contexts[i]});
        }

        // 等待完成
        for (threads) |thread| {
            thread.join();
        }

        std.debug.print("4 线程 × 1000 次工作完成\n", .{});
        profiler.printSummary();
    }

    std.debug.print("\n╔══════════════════════════════════════════════╗\n", .{});
    std.debug.print("║   所有高级特性演示完成！                     ║\n", .{});
    std.debug.print("╚══════════════════════════════════════════════╝\n\n", .{});
}
