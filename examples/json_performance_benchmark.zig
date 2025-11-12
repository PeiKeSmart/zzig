// json_performance_benchmark.zig - JSON 解析器性能基准测试
// 对比原版 vs 零分配优化 vs SIMD 优化

const std = @import("std");
const zzig = @import("zzig");
const jsmn = zzig.json.Jsmn;

// 测试数据大小枚举
const SizeType = enum { small, medium, large };

// 测试数据生成器
fn generateTestJson(allocator: std.mem.Allocator, size: SizeType) ![]const u8 {
    var list: std.ArrayList(u8) = .{};
    errdefer list.deinit(allocator);

    switch (size) {
        .small => {
            // ~1KB JSON
            try list.appendSlice(allocator, "{\"users\":[");
            for (0..10) |i| {
                if (i > 0) try list.appendSlice(allocator, ",");
                try list.writer(allocator).print("{{\"id\":{},\"name\":\"user_{}\"}}", .{ i, i });
            }
            try list.appendSlice(allocator, "]}");
        },
        .medium => {
            // ~10KB JSON
            try list.appendSlice(allocator, "{\"data\":[");
            for (0..100) |i| {
                if (i > 0) try list.appendSlice(allocator, ",");
                try list.writer(allocator).print(
                    "{{\"id\":{},\"name\":\"item_{}\",\"value\":{},\"active\":true}}",
                    .{ i, i, i * 2 },
                );
            }
            try list.appendSlice(allocator, "]}");
        },
        .large => {
            // ~100KB JSON
            try list.appendSlice(allocator, "{\"records\":[");
            for (0..1000) |i| {
                if (i > 0) try list.appendSlice(allocator, ",");
                try list.writer(allocator).print(
                    "{{\"id\":{},\"name\":\"record_{}\",\"value\":{},\"tags\":[\"a\",\"b\",\"c\"]}}",
                    .{ i, i, i * 3 },
                );
            }
            try list.appendSlice(allocator, "]}");
        },
    }

    return list.toOwnedSlice(allocator);
}

// 基准测试结果
const BenchmarkResult = struct {
    name: []const u8,
    iterations: usize,
    total_time_ns: i128,
    avg_time_ns: i128,
    tokens_parsed: usize,
    memory_allocated: usize,
    heap_allocations: usize,

    pub fn print(self: BenchmarkResult) void {
        std.debug.print("  {s}:\n", .{self.name});
        std.debug.print("    迭代次数: {}\n", .{self.iterations});
        std.debug.print("    总时间: {} ns\n", .{self.total_time_ns});
        std.debug.print("    平均时间: {} ns ({d:.2} μs)\n", .{
            self.avg_time_ns,
            @as(f64, @floatFromInt(self.avg_time_ns)) / 1000.0,
        });
        std.debug.print("    解析 token 数: {}\n", .{self.tokens_parsed});
        std.debug.print("    内存分配: {} 字节\n", .{self.memory_allocated});
        std.debug.print("    堆分配次数: {}\n", .{self.heap_allocations});
        std.debug.print("    吞吐量: {d:.2} MB/s\n", .{
            self.calculateThroughput(),
        });
    }

    fn calculateThroughput(self: BenchmarkResult) f64 {
        const time_s = @as(f64, @floatFromInt(self.avg_time_ns)) / 1_000_000_000.0;
        const size_mb = @as(f64, @floatFromInt(self.memory_allocated)) / (1024.0 * 1024.0);
        return size_mb / time_s;
    }
};

// 基准测试：原版解析器（禁用紧凑格式以支持大 JSON）
fn benchmarkOriginal(allocator: std.mem.Allocator, json_text: []const u8, iterations: usize) !BenchmarkResult {
    const Parser = jsmn(.{
        .compact_tokens = false, // 禁用紧凑格式，避免大 JSON 溢出
        .use_simd = false,
    });

    var total_time: i128 = 0;
    var total_tokens: usize = 0;
    var total_allocs: usize = 0;

    for (0..iterations) |_| {
        const start = std.time.nanoTimestamp();

        var result = try Parser.parseHybrid(allocator, json_text);
        defer result.deinit(allocator);

        const end = std.time.nanoTimestamp();

        total_time += end - start;
        total_tokens = result.count();

        if (result.owned) {
            total_allocs += 1;
        }
    }

    return BenchmarkResult{
        .name = "原版解析器",
        .iterations = iterations,
        .total_time_ns = total_time,
        .avg_time_ns = @divTrunc(total_time, @as(i128, @intCast(iterations))),
        .tokens_parsed = total_tokens,
        .memory_allocated = json_text.len,
        .heap_allocations = total_allocs,
    };
}

// 基准测试：零分配优化版（禁用紧凑格式）
fn benchmarkZeroAlloc(allocator: std.mem.Allocator, json_text: []const u8, iterations: usize) !BenchmarkResult {
    _ = allocator;

    const Parser = jsmn(.{
        .compact_tokens = false,
        .use_simd = false,
    });

    var total_time: i128 = 0;
    var total_tokens: usize = 0;

    for (0..iterations) |_| {
        // ✅ 栈分配 - 零堆分配
        // 大型 JSON 需要更多 token 空间
        var tokens: [16384]Parser.Token = undefined;
        var parents: [16384]Parser.IndexT = undefined;

        const start = std.time.nanoTimestamp();

        const count = try Parser.parseTokens(&tokens, &parents, json_text);

        const end = std.time.nanoTimestamp();

        total_time += end - start;
        total_tokens = count;
    }

    return BenchmarkResult{
        .name = "零分配优化",
        .iterations = iterations,
        .total_time_ns = total_time,
        .avg_time_ns = @divTrunc(total_time, @as(i128, @intCast(iterations))),
        .tokens_parsed = total_tokens,
        .memory_allocated = json_text.len,
        .heap_allocations = 0, // ✅ 零堆分配
    };
}

// 基准测试：紧凑格式
fn benchmarkCompact(allocator: std.mem.Allocator, json_text: []const u8, iterations: usize) !BenchmarkResult {
    const Parser = jsmn(.{
        .compact_tokens = true,
        .use_simd = false,
    });

    var total_time: i128 = 0;
    var total_tokens: usize = 0;
    var total_allocs: usize = 0;

    for (0..iterations) |_| {
        const start = std.time.nanoTimestamp();

        var result = try Parser.parseHybrid(allocator, json_text);
        defer result.deinit(allocator);

        const end = std.time.nanoTimestamp();

        total_time += end - start;
        total_tokens = result.count();

        if (result.owned) {
            total_allocs += 1;
        }
    }

    return BenchmarkResult{
        .name = "紧凑格式",
        .iterations = iterations,
        .total_time_ns = total_time,
        .avg_time_ns = @divTrunc(total_time, @as(i128, @intCast(iterations))),
        .tokens_parsed = total_tokens,
        .memory_allocated = json_text.len,
        .heap_allocations = total_allocs,
    };
}

// 内存占用对比
fn compareMemoryUsage() void {
    const Parser = jsmn(zzig.json.jsmn_default_config());

    std.debug.print("\n=== 内存占用对比 ===\n", .{});
    std.debug.print("标准 Token 大小: {} 字节\n", .{@sizeOf(Parser.Token)});
    std.debug.print("紧凑 Token 大小: {} 字节\n", .{@sizeOf(Parser.CompactToken)});
    std.debug.print("内存节省: {d:.1}%\n\n", .{
        (1.0 - @as(f64, @floatFromInt(@sizeOf(Parser.CompactToken))) /
            @as(f64, @floatFromInt(@sizeOf(Parser.Token)))) * 100.0,
    });

    // 示例：1000 个 token 的内存占用
    const token_count = 1000;
    const standard_mem = @sizeOf(Parser.Token) * token_count;
    const compact_mem = @sizeOf(Parser.CompactToken) * token_count;

    std.debug.print("1000 个 token 内存占用:\n", .{});
    std.debug.print("  标准格式: {} KB\n", .{standard_mem / 1024});
    std.debug.print("  紧凑格式: {} KB\n", .{compact_mem / 1024});
    std.debug.print("  节省: {} KB ({d:.1}%)\n\n", .{
        (standard_mem - compact_mem) / 1024,
        @as(f64, @floatFromInt(standard_mem - compact_mem)) /
            @as(f64, @floatFromInt(standard_mem)) * 100.0,
    });
}

// 主基准测试程序
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== JSON 解析器性能基准测试 ===\n\n", .{});

    const sizes = [_]struct { name: []const u8, size: SizeType }{
        .{ .name = "小型 JSON (~1KB)", .size = .small },
        .{ .name = "中型 JSON (~10KB)", .size = .medium },
        .{ .name = "大型 JSON (~100KB)", .size = .large },
    };

    for (sizes) |s| {
        std.debug.print("--- {s} ---\n", .{s.name});

        const json = try generateTestJson(allocator, s.size);
        defer allocator.free(json);

        std.debug.print("JSON 大小: {} 字节\n\n", .{json.len});

        const iterations: usize = switch (s.size) {
            .small => 10000,
            .medium => 1000,
            .large => 100,
        };

        // 运行基准测试
        const result_original = try benchmarkOriginal(allocator, json, iterations);
        result_original.print();
        std.debug.print("\n", .{});

        const result_zero_alloc = try benchmarkZeroAlloc(allocator, json, iterations);
        result_zero_alloc.print();
        std.debug.print("\n", .{});

        // 紧凑格式仅用于小于 1MB 的 JSON
        if (json.len < 1024 * 1024) {
            const result_compact = try benchmarkCompact(allocator, json, iterations);
            result_compact.print();
            std.debug.print("\n", .{});
        }

        // 性能对比
        std.debug.print("  性能对比:\n", .{});
        const speedup_zero = @as(f64, @floatFromInt(result_original.avg_time_ns)) /
            @as(f64, @floatFromInt(result_zero_alloc.avg_time_ns));
        std.debug.print("    零分配 vs 原版: {d:.2}x\n", .{speedup_zero});

        const alloc_reduction = @as(f64, @floatFromInt(result_original.heap_allocations - result_zero_alloc.heap_allocations)) /
            @as(f64, @floatFromInt(result_original.heap_allocations)) * 100.0;
        std.debug.print("    堆分配减少: {d:.1}%\n", .{alloc_reduction});

        std.debug.print("\n{s}\n\n", .{"=" ** 60});
    }

    // 内存占用对比
    compareMemoryUsage();

    std.debug.print("=== 基准测试完成 ===\n", .{});
}
