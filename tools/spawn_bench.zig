// 线程创建成本实测（用于评估「每连接一线程」vs「线程池」的真实差距）
// 运行：zig run -OReleaseFast tools/spawn_bench.zig
// 计时用 Windows QPC（Zig 0.17 已移除 std.time.Timer / std.time.nanoTimestamp）
const std = @import("std");

extern "kernel32" fn QueryPerformanceCounter(*i64) callconv(.winapi) i32;
extern "kernel32" fn QueryPerformanceFrequency(*i64) callconv(.winapi) i32;

var freq: i64 = 0;

fn qpc() i64 {
    var v: i64 = 0;
    _ = QueryPerformanceCounter(&v);
    return v;
}

fn usSince(start: i64) f64 {
    return @as(f64, @floatFromInt(qpc() - start)) * 1_000_000.0 / @as(f64, @floatFromInt(freq));
}

fn noop() void {}

pub fn main() !void {
    _ = QueryPerformanceFrequency(&freq);
    const n: usize = 600;

    // 预热，避免首次 spawn 的页表/栈池开销污染结果
    for (0..50) |_| {
        const t = try std.Thread.spawn(.{ .stack_size = 128 * 1024 }, noop, .{});
        t.join();
    }

    var start = qpc();
    for (0..n) |_| {
        const t = try std.Thread.spawn(.{ .stack_size = 128 * 1024 }, noop, .{});
        t.join();
    }
    std.debug.print("SPAWN+JOIN n={d} per={d:.2}us\n", .{ n, usSince(start) / @as(f64, @floatFromInt(n)) });

    start = qpc();
    for (0..n) |_| {
        const t = try std.Thread.spawn(.{ .stack_size = 128 * 1024 }, noop, .{});
        t.detach();
    }
    std.debug.print("SPAWN+DETACH n={d} per={d:.2}us\n", .{ n, usSince(start) / @as(f64, @floatFromInt(n)) });
}
