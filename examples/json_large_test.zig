// json_large_test.zig - 测试大型 JSON 的紧凑格式自动回退
const std = @import("std");
const zzig = @import("zzig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    std.debug.print("=== 大型 JSON 紧凑格式自动回退测试 ===\n\n", .{});

    // 生成一个超过 1MB 起始位置的 JSON
    var json_builder: std.ArrayList(u8) = .{};
    defer json_builder.deinit(allocator);

    // 先填充大量空白符，让后续 token 的起始位置超过 1MB
    try json_builder.appendNTimes(allocator, ' ', 1024 * 1024 + 100);

    // 添加实际的 JSON 内容
    try json_builder.appendSlice(allocator,
        \\{"users":[{"id":1,"name":"Alice"},{"id":2,"name":"Bob"}]}
    );

    const large_json = try json_builder.toOwnedSlice(allocator);
    defer allocator.free(large_json);

    std.debug.print("JSON 总大小: {} 字节 ({d:.2} MB)\n", .{
        large_json.len,
        @as(f64, @floatFromInt(large_json.len)) / (1024.0 * 1024.0),
    });
    std.debug.print("首个有效 token 起始位置: {} (超过 1MB 限制)\n\n", .{
        1024 * 1024 + 100,
    });

    // 使用默认配置（compact_tokens = true）
    const Parser = zzig.json.Jsmn(zzig.json.jsmn_default_config());

    std.debug.print("使用默认配置（compact_tokens = true）解析...\n", .{});

    var result = try Parser.parseHybrid(allocator, large_json);
    defer result.deinit(allocator);

    std.debug.print("✅ 解析成功！\n", .{});
    std.debug.print("解析到 {} 个 token\n", .{result.count()});
    std.debug.print("是否使用堆分配: {}\n", .{result.owned});

    // 检查 token 类型
    const first_token = result.getToken(0) orelse return error.NoToken;
    const is_compact = switch (first_token) {
        .compact => true,
        .standard => false,
    };

    std.debug.print("Token 格式: {s}\n\n", .{
        if (is_compact) "紧凑格式" else "标准格式（自动回退）",
    });

    std.debug.print("--- 说明 ---\n", .{});
    std.debug.print("紧凑格式限制:\n", .{});
    std.debug.print("  - Token 起始位置 < 1MB (20 位)\n", .{});
    std.debug.print("  - Token 长度 < 256 字节 (8 位)\n", .{});
    std.debug.print("\n当超出限制时，自动回退到标准格式，避免崩溃。\n", .{});
}
