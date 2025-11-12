// json_advanced_example.zig - JSON 解析器高级示例
// 演示：流式解析、混合模式、紧凑格式、SIMD 优化、嵌入式配置

const std = @import("std");
const zzig = @import("zzig");

pub fn main() !void {
    std.debug.print("=== JSON 解析器高级示例 ===\n\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // ========== 示例 1: 流式解析（适用于大文件或网络流） ==========
    try example1_streaming_parse();

    // ========== 示例 2: 混合模式（栈/堆自动切换） ==========
    try example2_hybrid_mode(allocator);

    // ========== 示例 3: 紧凑格式解析 ==========
    try example3_compact_tokens(allocator);

    // ========== 示例 4: 嵌入式环境配置 ==========
    try example4_embedded_config();

    // ========== 示例 5: 桌面/服务器配置（SIMD 优化） ==========
    try example5_desktop_config();

    // ========== 示例 6: 自定义配置 ==========
    try example6_custom_config(allocator);

    // ========== 示例 7: 性能对比测试 ==========
    try example7_performance_comparison(allocator);

    std.debug.print("\n=== 所有高级示例执行完毕 ===\n", .{});
}

/// 示例 1: 流式解析（分块处理）
fn example1_streaming_parse() !void {
    std.debug.print("--- 示例 1: 流式解析 ---\n", .{});

    const Parser = zzig.json.createParser();

    // 模拟网络流分块接收 - 注意：这里演示的是概念，实际需要完整 JSON
    const full_json = "{\"message\":\"Hello World\",\"id\":42}";

    // 准备缓冲区和状态
    var tokens: [32]Parser.Token = undefined;
    var parents: [32]Parser.IndexT = undefined;
    var state: Parser.ParserState = .{ .pos = 0, .stack_top = 0, .tokens_written = 0 };

    std.debug.print("  完整 JSON: {s}\n", .{full_json});
    std.debug.print("  演示流式解析流程（分块处理）:\n", .{});

    // 模拟第一块 - 不完整
    const chunk1 = "{\"message\":\"Hello";
    std.debug.print("    分块 1: {s}\n", .{chunk1});
    _ = Parser.parseChunk(&state, &tokens, &parents, chunk1, false) catch |err| {
        if (err == Parser.Error.NeedMoreInput) {
            std.debug.print("      -> 需要更多数据\n", .{});
        } else return err;
    };

    // 模拟第二块 - 仍不完整
    const chunk2 = " World\",\"id\":";
    std.debug.print("    分块 2: {s}\n", .{chunk2});
    _ = Parser.parseChunk(&state, &tokens, &parents, chunk2, false) catch |err| {
        if (err == Parser.Error.NeedMoreInput) {
            std.debug.print("      -> 需要更多数据\n", .{});
        } else return err;
    };

    // 实际解析完整 JSON
    state.reset();
    const count = try Parser.parseTokens(&tokens, &parents, full_json);

    std.debug.print("  ✓ 解析完成，共 {} 个 token\n", .{count});

    // 提取值
    for (tokens[0..count], 0..) |tok, i| {
        const text = Parser.tokenText(tok, full_json);
        std.debug.print("    Token[{}]: {s}\n", .{ i, text });
    }
    std.debug.print("\n", .{});
}

/// 示例 2: 混合模式（自动选择栈或堆）
fn example2_hybrid_mode(allocator: std.mem.Allocator) !void {
    std.debug.print("--- 示例 2: 混合模式 ---\n", .{});

    const Parser = zzig.json.createParser();

    // 小型 JSON - 使用栈内存
    const small_json = "{\"key\":\"value\"}";
    var small_result = try Parser.parseHybrid(null, small_json);
    defer small_result.deinit(allocator);

    std.debug.print("  小型 JSON (栈): owned={}, count={}\n", .{ small_result.owned, small_result.count() });

    // 大型 JSON - 使用堆内存
    var large_json_builder: std.ArrayList(u8) = .{};

    try large_json_builder.appendSlice(allocator, "{\"data\":[");
    for (0..100) |i| {
        if (i > 0) try large_json_builder.appendSlice(allocator, ",");
        try large_json_builder.writer(allocator).print("{{\"id\":{}}}", .{i});
    }
    try large_json_builder.appendSlice(allocator, "]}");

    const large_json = large_json_builder.items;
    var large_result = try Parser.parseHybrid(allocator, large_json);
    defer large_result.deinit(allocator);

    std.debug.print("  大型 JSON (堆): owned={}, count={}\n", .{ large_result.owned, large_result.count() });
    std.debug.print("\n", .{});

    large_json_builder.deinit(allocator);
}

/// 示例 3: 紧凑格式解析
fn example3_compact_tokens(allocator: std.mem.Allocator) !void {
    std.debug.print("--- 示例 3: 紧凑格式解析 ---\n", .{});

    const Parser = zzig.json.createParser();

    const json = "{\"name\":\"Eve\",\"age\":28,\"active\":true}";

    // 先解析为标准 token
    var std_tokens: [32]Parser.Token = undefined;
    var parents: [32]Parser.IndexT = undefined;
    const count = try Parser.parseTokens(&std_tokens, &parents, json);

    std.debug.print("  标准 token 数量: {}\n", .{count});
    std.debug.print("  标准 token 大小: {} 字节\n", .{@sizeOf(Parser.Token) * count});

    // 压缩为紧凑格式
    var compact: [32]Parser.CompactToken = undefined;
    const compact_count = try Parser.compressTokens(&std_tokens, count, &compact);

    std.debug.print("  紧凑 token 数量: {}\n", .{compact_count});
    std.debug.print("  紧凑 token 大小: {} 字节\n", .{@sizeOf(Parser.CompactToken) * compact_count});

    const savings = (@sizeOf(Parser.Token) * count) - (@sizeOf(Parser.CompactToken) * compact_count);
    std.debug.print("  节省内存: {} 字节 ({d:.1}%)\n", .{
        savings,
        @as(f64, @floatFromInt(savings)) / @as(f64, @floatFromInt(@sizeOf(Parser.Token) * count)) * 100.0,
    });

    // 使用混合解析自动选择紧凑格式
    var result = try Parser.parseHybrid(allocator, json);
    defer result.deinit(allocator);

    std.debug.print("  混合解析结果: {} tokens\n", .{result.count()});
    std.debug.print("\n", .{});
}

/// 示例 4: 嵌入式环境配置
fn example4_embedded_config() !void {
    std.debug.print("--- 示例 4: 嵌入式环境配置 ---\n", .{});

    // 创建嵌入式优化的解析器
    const EmbeddedParser = zzig.json.createEmbeddedParser();

    const json = "{\"sensor\":\"temp\",\"value\":25.5}";

    // 使用栈内存解析（无堆分配）
    var tokens: [16]EmbeddedParser.Token = undefined;
    var parents: [16]EmbeddedParser.IndexT = undefined;

    const count = try EmbeddedParser.parseTokens(&tokens, &parents, json);

    std.debug.print("  JSON: {s}\n", .{json});
    std.debug.print("  解析器配置: 紧凑模式, 无 SIMD, Tiny 模式\n", .{});
    std.debug.print("  解析结果: {} tokens\n", .{count});
    std.debug.print("  内存使用: 完全栈分配（零堆分配）\n", .{});
    std.debug.print("\n", .{});
}

/// 示例 5: 桌面/服务器配置（SIMD 优化）
fn example5_desktop_config() !void {
    std.debug.print("--- 示例 5: 桌面/服务器配置 ---\n", .{});

    // 创建桌面优化的解析器
    const DesktopParser = zzig.json.createDesktopParser();

    const json =
        \\{
        \\  "users": [
        \\    {"id": 1, "name": "Alice"},
        \\    {"id": 2, "name": "Bob"}
        \\  ],
        \\  "total": 2
        \\}
    ;

    var tokens: [64]DesktopParser.Token = undefined;
    var parents: [64]DesktopParser.IndexT = undefined;

    const count = try DesktopParser.parseTokens(&tokens, &parents, json);

    std.debug.print("  解析器配置: 标准模式, SIMD 优化, 完整功能\n", .{});
    std.debug.print("  解析结果: {} tokens\n", .{count});
    std.debug.print("  特性: 支持辅助函数、对象查找、数组遍历\n", .{});

    // 使用辅助函数查找对象字段
    if (DesktopParser.findObjectValue(&tokens, count, json, "total")) |idx| {
        const value = try DesktopParser.parseInteger(tokens[idx], json);
        std.debug.print("  查找 'total' 字段: {}\n", .{value});
    }
    std.debug.print("\n", .{});
}

/// 示例 6: 自定义配置
fn example6_custom_config(allocator: std.mem.Allocator) !void {
    std.debug.print("--- 示例 6: 自定义配置 ---\n", .{});

    // 使用 JsonParser 构建器创建自定义配置
    const custom_config = zzig.json.Config{
        .index_type = u32, // 使用 32 位索引
        .enable_helpers = true,
        .compact_tokens = false,
        .max_depth = 128, // 限制嵌套深度
        .tiny_mode = false,
        .use_simd = true,
        .force_simd = false,
        .force_scalar = false,
    };

    const CustomParser = zzig.json.Jsmn(custom_config);

    const json = "{\"config\":{\"timeout\":30,\"retries\":3}}";

    var result = try CustomParser.parseHybrid(allocator, json);
    defer result.deinit(allocator);

    std.debug.print("  自定义配置:\n", .{});
    std.debug.print("    - 索引类型: u32\n", .{});
    std.debug.print("    - 最大深度: 128\n", .{});
    std.debug.print("    - SIMD 优化: 启用\n", .{});
    std.debug.print("  解析结果: {} tokens\n", .{result.count()});
    std.debug.print("\n", .{});
}

/// 示例 7: 性能对比测试
fn example7_performance_comparison(allocator: std.mem.Allocator) !void {
    std.debug.print("--- 示例 7: 性能对比测试 ---\n", .{});

    // 生成测试数据
    var json_builder: std.ArrayList(u8) = .{};
    defer json_builder.deinit(allocator);

    try json_builder.appendSlice(allocator, "[");
    for (0..1000) |i| {
        if (i > 0) try json_builder.appendSlice(allocator, ",");
        try json_builder.writer(allocator).print("{{\"id\":{},\"value\":\"{}\"}}", .{ i, i * 2 });
    }
    try json_builder.appendSlice(allocator, "]");

    const json = json_builder.items;

    std.debug.print("  测试数据大小: {} 字节\n", .{json.len});

    // 测试 1: 标准解析器（禁用紧凑格式以支持大 JSON）
    const StandardParser = zzig.json.Jsmn(.{
        .compact_tokens = false, // 禁用紧凑格式
        .use_simd = true,
        .enable_helpers = true,
    });
    const start1 = std.time.nanoTimestamp();
    var result1 = try StandardParser.parseHybrid(allocator, json);
    const end1 = std.time.nanoTimestamp();
    defer result1.deinit(allocator);

    const time1 = end1 - start1;
    std.debug.print("  标准解析器: {} ns ({} tokens)\n", .{ time1, result1.count() });

    // 测试 2: 精简解析器（禁用紧凑格式）
    const LeanParser = zzig.json.Jsmn(.{
        .compact_tokens = false, // 禁用紧凑格式
        .use_simd = false,
        .enable_helpers = false,
        .tiny_mode = true,
    });
    const start2 = std.time.nanoTimestamp();
    var result2 = try LeanParser.parseHybrid(allocator, json);
    const end2 = std.time.nanoTimestamp();
    defer result2.deinit(allocator);

    const time2 = end2 - start2;
    std.debug.print("  精简解析器: {} ns ({} tokens)\n", .{ time2, result2.count() });

    // 性能对比
    if (time1 > 0) {
        const speedup = @as(f64, @floatFromInt(time2)) / @as(f64, @floatFromInt(time1));
        std.debug.print("  性能对比: 精简/标准 = {d:.2}x\n", .{speedup});
    }

    std.debug.print("\n", .{});
}
