const std = @import("std");
const AsyncLogger = @import("zzig").AsyncLogger;
const compat = @import("zzig").compat;

/// 零分配模式演示（适用于 ARM/嵌入式设备）
pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("\n=== 异步日志器 - 零分配模式演示 ===\n\n", .{});

    // ========================================
    // 模式对比演示
    // ========================================

    std.debug.print("📊 测试环境:\n", .{});
    std.debug.print("   CPU 架构: {s}\n", .{@tagName(@import("builtin").cpu.arch)});
    std.debug.print("   操作系统: {s}\n", .{@tagName(@import("builtin").os.tag)});
    std.debug.print("   是否 ARM: {}\n\n", .{isARMArchitecture()});

    // ========================================
    // 测试 1: 自动检测模式
    // ========================================
    std.debug.print("🧪 测试 1: 自动检测分配策略\n", .{});
    {
        const config_auto = AsyncLogger.AsyncLoggerConfig{
            .queue_capacity = 1024,
            .allocation_strategy = .auto, // 自动检测
        };

        const logger_auto = try AsyncLogger.AsyncLogger.init(allocator, config_auto);
        defer logger_auto.deinit();

        const detected_strategy = if (logger_auto.worker_format_buffer.len > 0) "零分配" else "动态分配";
        std.debug.print("   检测结果: {s}\n", .{detected_strategy});

        // 记录测试日志
        logger_auto.info("自动检测模式测试", .{});
        logger_auto.warn("内存占用: {d} KB", .{256});

        compat.sleep(200 * std.time.ns_per_ms);
        std.debug.print("   统计: 已处理 {d}, 已丢弃 {d}\n\n", .{
            logger_auto.getProcessedCount(),
            logger_auto.getDroppedCount(),
        });
    }

    // ========================================
    // 测试 2: 强制零分配模式
    // ========================================
    std.debug.print("🚀 测试 2: 强制零分配模式（推荐 ARM 设备）\n", .{});
    {
        const config_zero = AsyncLogger.AsyncLoggerConfig{
            .queue_capacity = 1024,
            .allocation_strategy = .zero_alloc, // 强制零分配
            .tls_format_buffer_size = 4096, // 4KB TLS 缓冲区
            .worker_file_buffer_size = 16384, // 16KB 文件缓冲区（ARM 设备用较小值）
        };

        const logger_zero = try AsyncLogger.AsyncLogger.init(allocator, config_zero);
        defer logger_zero.deinit();

        std.debug.print("   ✅ 零分配模式已启用\n", .{});
        std.debug.print("   TLS 缓冲区: {d} KB\n", .{config_zero.tls_format_buffer_size / 1024});
        std.debug.print("   文件缓冲区: {d} KB\n\n", .{config_zero.worker_file_buffer_size / 1024});

        // 性能测试
        const count = 10_000;
        const start = compat.nanoTimestamp();

        for (0..count) |i| {
            logger_zero.info("设备{d}: 温度 {d}°C, 内存 {d}MB", .{ i, 45 + (i % 20), 256 - (i % 100) });
        }

        const end = compat.nanoTimestamp();
        const duration_ns = @as(u64, @intCast(end - start));
        const latency_ns = duration_ns / count;
        const qps = (count * std.time.ns_per_s) / duration_ns;

        std.debug.print("   性能测试: {d} 条日志\n", .{count});
        std.debug.print("   平均延迟: {d} ns (≈ {d:.2} μs)\n", .{ latency_ns, @as(f64, @floatFromInt(latency_ns)) / 1000.0 });
        std.debug.print("   QPS: {d} 条/秒\n\n", .{qps});

        compat.sleep(1 * std.time.ns_per_s);

        std.debug.print("   统计: 已处理 {d}, 已丢弃 {d}\n\n", .{
            logger_zero.getProcessedCount(),
            logger_zero.getDroppedCount(),
        });
    }

    // ========================================
    // 测试 3: 动态分配模式（对比）
    // ========================================
    std.debug.print("🔄 测试 3: 动态分配模式（服务器环境）\n", .{});
    {
        const config_dynamic = AsyncLogger.AsyncLoggerConfig{
            .queue_capacity = 1024,
            .allocation_strategy = .dynamic, // 动态分配
        };

        const logger_dynamic = try AsyncLogger.AsyncLogger.init(allocator, config_dynamic);
        defer logger_dynamic.deinit();

        std.debug.print("   动态分配模式已启用\n\n", .{});

        // 性能测试
        const count = 10_000;
        const start = compat.nanoTimestamp();

        for (0..count) |i| {
            logger_dynamic.info("服务器{d}: CPU {d}%, 连接数 {d}", .{ i, 30 + (i % 70), 100 + (i % 500) });
        }

        const end = compat.nanoTimestamp();
        const duration_ns = @as(u64, @intCast(end - start));
        const latency_ns = duration_ns / count;
        const qps = (count * std.time.ns_per_s) / duration_ns;

        std.debug.print("   性能测试: {d} 条日志\n", .{count});
        std.debug.print("   平均延迟: {d} ns (≈ {d:.2} μs)\n", .{ latency_ns, @as(f64, @floatFromInt(latency_ns)) / 1000.0 });
        std.debug.print("   QPS: {d} 条/秒\n\n", .{qps});

        compat.sleep(1 * std.time.ns_per_s);

        std.debug.print("   统计: 已处理 {d}, 已丢弃 {d}\n\n", .{
            logger_dynamic.getProcessedCount(),
            logger_dynamic.getDroppedCount(),
        });
    }

    // ========================================
    // 推荐配置建议
    // ========================================
    std.debug.print("💡 推荐配置:\n\n", .{});
    std.debug.print("  ARM/嵌入式设备（< 1GB 内存）:\n", .{});
    std.debug.print("    .allocation_strategy = .zero_alloc\n", .{});
    std.debug.print("    .queue_capacity = 4096-8192\n", .{});
    std.debug.print("    .tls_format_buffer_size = 2048-4096\n", .{});
    std.debug.print("    .worker_file_buffer_size = 8192-16384\n\n", .{});

    std.debug.print("  服务器/PC（> 4GB 内存）:\n", .{});
    std.debug.print("    .allocation_strategy = .dynamic 或 .auto\n", .{});
    std.debug.print("    .queue_capacity = 16384-32768\n\n", .{});

    std.debug.print("=== 测试完成 ===\n", .{});
}

/// 检测是否为 ARM 架构
fn isARMArchitecture() bool {
    return switch (@import("builtin").cpu.arch) {
        .arm, .armeb, .aarch64, .aarch64_be => true,
        else => false,
    };
}
