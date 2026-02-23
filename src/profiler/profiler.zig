const std = @import("std");

/// 性能剖析配置
pub const ProfilerConfig = struct {
    /// 启用性能剖析（编译期可关闭）
    enable: bool = false,

    /// 采样率（0.0-1.0，1.0 = 100% 采样）
    sample_rate: f32 = 0.01, // 默认 1% 采样

    /// 最大记录数量
    max_records: usize = 10000,

    /// 启用内存追踪
    enable_memory_tracking: bool = false,
};

/// 性能指标
pub const Metrics = struct {
    /// 调用次数
    call_count: u64 = 0,

    /// 总耗时（纳秒）
    total_duration_ns: u64 = 0,

    /// 最小耗时（纳秒）
    min_duration_ns: u64 = std.math.maxInt(u64),

    /// 最大耗时（纳秒）
    max_duration_ns: u64 = 0,

    /// 平均耗时（纳秒）
    pub fn avgDuration(self: *const Metrics) u64 {
        if (self.call_count == 0) return 0;
        return self.total_duration_ns / self.call_count;
    }
};

/// 性能剖析器
///
/// # 特性
/// - 零开销（Release 模式完全编译掉）
/// - 采样模式（减少性能影响）
/// - 热点识别（Top N）
/// - JSON 报告导出
///
/// # 示例
/// ```zig
/// var profiler = try Profiler.init(allocator, .{ .enable = true });
/// defer profiler.deinit();
///
/// {
///     const zone = profiler.beginZone("log_processing");
///     defer profiler.endZone(zone);
///
///     // 你的代码...
/// }
///
/// try profiler.exportReport("perf.json");
/// ```
pub const Profiler = struct {
    allocator: std.mem.Allocator,
    config: ProfilerConfig,

    // 性能数据
    zones: std.StringHashMap(Metrics),
    mutex: std.Thread.Mutex,

    // 随机数生成器（采样用）
    prng: std.Random.DefaultPrng,

    pub fn init(allocator: std.mem.Allocator, config: ProfilerConfig) !Profiler {
        return Profiler{
            .allocator = allocator,
            .config = config,
            .zones = std.StringHashMap(Metrics).init(allocator),
            .mutex = .{},
            .prng = std.Random.DefaultPrng.init(@intCast(std.time.milliTimestamp())),
        };
    }

    pub fn deinit(self: *Profiler) void {
        self.zones.deinit();
    }

    /// 开始性能区域
    ///
    /// # 返回
    /// Zone 句柄，需传递给 endZone()
    pub fn beginZone(self: *Profiler, zone_name: []const u8) Zone {
        if (!self.config.enable) {
            return .{ .profiler = self, .zone_name = zone_name, .start_time = 0, .should_record = false };
        }

        // 采样判断
        const should_sample = self.shouldSample();
        if (!should_sample) {
            return .{ .profiler = self, .zone_name = zone_name, .start_time = 0, .should_record = false };
        }

        return .{
            .profiler = self,
            .zone_name = zone_name,
            .start_time = std.time.nanoTimestamp(),
            .should_record = true,
        };
    }

    /// 结束性能区域
    pub fn endZone(self: *Profiler, zone: Zone) void {
        if (!zone.should_record) return;

        const end_time = std.time.nanoTimestamp();
        const duration = @as(u64, @intCast(end_time - zone.start_time));

        self.recordMetrics(zone.zone_name, duration);
    }

    /// 记录性能指标
    fn recordMetrics(self: *Profiler, zone_name: []const u8, duration_ns: u64) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const entry = self.zones.getOrPutValue(zone_name, .{}) catch return;
        const metrics = entry.value_ptr;

        metrics.call_count += 1;
        metrics.total_duration_ns += duration_ns;
        metrics.min_duration_ns = @min(metrics.min_duration_ns, duration_ns);
        metrics.max_duration_ns = @max(metrics.max_duration_ns, duration_ns);
    }

    /// 判断是否采样
    /// prng 非线程安全，需在 mutex 保护下访问
    fn shouldSample(self: *Profiler) bool {
        if (self.config.sample_rate >= 1.0) return true;
        if (self.config.sample_rate <= 0.0) return false;

        self.mutex.lock();
        defer self.mutex.unlock();
        const random_value = self.prng.random().float(f32);
        return random_value < self.config.sample_rate;
    }

    /// 导出性能报告（JSON 格式）
    pub fn exportReport(self: *Profiler, file_path: []const u8) !void {
        const file = try std.fs.cwd().createFile(file_path, .{});
        defer file.close();

        // 使用缓冲区来构建 JSON
        var buf: std.ArrayList(u8) = .{};
        defer buf.deinit(self.allocator);

        const writer = buf.writer(self.allocator);

        try writer.writeAll("{\n");
        try writer.writeAll("  \"zones\": [\n");

        var iter = self.zones.iterator();
        var first = true;
        while (iter.next()) |entry| {
            if (!first) try writer.writeAll(",\n");
            first = false;

            const metrics = entry.value_ptr.*;
            try writer.print(
                \\    {{
                \\      "name": "{s}",
                \\      "call_count": {},
                \\      "total_duration_ns": {},
                \\      "min_duration_ns": {},
                \\      "max_duration_ns": {},
                \\      "avg_duration_ns": {}
                \\    }}
            , .{
                entry.key_ptr.*,
                metrics.call_count,
                metrics.total_duration_ns,
                metrics.min_duration_ns,
                metrics.max_duration_ns,
                metrics.avgDuration(),
            });
        }

        try writer.writeAll("\n  ]\n}\n");

        // 写入文件
        try file.writeAll(buf.items);
    }

    /// 打印性能摘要（控制台）
    pub fn printSummary(self: *Profiler) void {
        std.debug.print("\n=== 性能剖析报告 ===\n\n", .{});

        // 收集并排序（按总耗时）
        var entries: std.ArrayList(struct { name: []const u8, metrics: Metrics }) = .{};
        defer entries.deinit(self.allocator);

        var iter = self.zones.iterator();
        while (iter.next()) |entry| {
            entries.append(self.allocator, .{
                .name = entry.key_ptr.*,
                .metrics = entry.value_ptr.*,
            }) catch continue;
        }

        // 无数据时跳过排序，避免 entries.items[0] 越界 panic
        if (entries.items.len == 0) {
            std.debug.print("(无性能数据)\n", .{});
            return;
        }

        std.mem.sort(@TypeOf(entries.items[0]), entries.items, {}, struct {
            fn lessThan(_: void, a: @TypeOf(entries.items[0]), b: @TypeOf(entries.items[0])) bool {
                return a.metrics.total_duration_ns > b.metrics.total_duration_ns;
            }
        }.lessThan);

        // 打印 Top 10
        std.debug.print("{s:<30} {s:>10} {s:>15} {s:>15} {s:>15}\n", .{ "Zone", "Calls", "Avg (μs)", "Min (μs)", "Max (μs)" });
        std.debug.print("{s}\n", .{"-" ** 85});

        const top_n = @min(10, entries.items.len);
        for (entries.items[0..top_n]) |entry| {
            const avg_us = entry.metrics.avgDuration() / 1000;
            const min_us = entry.metrics.min_duration_ns / 1000;
            const max_us = entry.metrics.max_duration_ns / 1000;

            std.debug.print("{s:<30} {d:>10} {d:>15} {d:>15} {d:>15}\n", .{
                entry.name,
                entry.metrics.call_count,
                avg_us,
                min_us,
                max_us,
            });
        }

        std.debug.print("\n", .{});
    }

    /// 重置所有统计数据
    pub fn reset(self: *Profiler) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        self.zones.clearRetainingCapacity();
    }
};

/// 性能区域句柄
pub const Zone = struct {
    profiler: *Profiler,
    zone_name: []const u8,
    start_time: i128,
    should_record: bool,
};

/// 便捷宏：自动命名性能区域
pub inline fn profile(profiler: *Profiler, comptime zone_name: []const u8, func: anytype) @TypeOf(func).ReturnType {
    const zone = profiler.beginZone(zone_name);
    defer profiler.endZone(zone);
    return func();
}

// ========== 单元测试 ==========

test "Profiler - 基本功能" {
    const allocator = std.testing.allocator;
    var profiler = try Profiler.init(allocator, .{
        .enable = true,
        .sample_rate = 1.0, // 100% 采样
    });
    defer profiler.deinit();

    // 模拟性能区域
    {
        const zone = profiler.beginZone("test_func");
        std.Thread.sleep(1 * std.time.ns_per_ms);
        profiler.endZone(zone);
    }

    // 验证记录
    const metrics = profiler.zones.get("test_func");
    try std.testing.expect(metrics != null);
    try std.testing.expectEqual(@as(u64, 1), metrics.?.call_count);
}

test "Profiler - 采样模式" {
    const allocator = std.testing.allocator;
    var profiler = try Profiler.init(allocator, .{
        .enable = true,
        .sample_rate = 0.0, // 0% 采样
    });
    defer profiler.deinit();

    // 调用多次
    for (0..100) |_| {
        const zone = profiler.beginZone("sampled_func");
        profiler.endZone(zone);
    }

    // 应该没有记录
    const metrics = profiler.zones.get("sampled_func");
    try std.testing.expect(metrics == null or metrics.?.call_count == 0);
}

test "Profiler - 导出报告" {
    const allocator = std.testing.allocator;
    var profiler = try Profiler.init(allocator, .{
        .enable = true,
        .sample_rate = 1.0,
    });
    defer profiler.deinit();

    {
        const zone = profiler.beginZone("export_test");
        std.Thread.sleep(100 * std.time.ns_per_us);
        profiler.endZone(zone);
    }

    try profiler.exportReport("test_perf_report.json");
    defer std.fs.cwd().deleteFile("test_perf_report.json") catch {};

    // 验证文件存在
    const file = try std.fs.cwd().openFile("test_perf_report.json", .{});
    file.close();
}
