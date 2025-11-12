// json_example.zig - JSON 解析器基础示例
// 演示：基本解析、字符串处理、数字解析、对象/数组遍历

const std = @import("std");
const zzig = @import("zzig");

pub fn main() !void {
    std.debug.print("=== JSON 解析器基础示例 ===\n\n", .{});

    // 创建内存分配器
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // ========== 示例 1: 基本解析 ==========
    try example1_basic_parsing();

    // ========== 示例 2: 字符串解析与转义处理 ==========
    try example2_string_parsing();

    // ========== 示例 3: 数字解析 ==========
    try example3_number_parsing();

    // ========== 示例 4: 对象遍历 ==========
    try example4_object_traversal(allocator);

    // ========== 示例 5: 数组遍历 ==========
    try example5_array_traversal();

    // ========== 示例 6: 嵌套结构解析 ==========
    try example6_nested_structure(allocator);

    std.debug.print("\n=== 所有示例执行完毕 ===\n", .{});
}

/// 示例 1: 基本解析
fn example1_basic_parsing() !void {
    std.debug.print("--- 示例 1: 基本解析 ---\n", .{});

    // 使用默认配置创建解析器
    const Parser = zzig.json.createParser();

    // 定义 JSON 字符串
    const json = "{\"name\":\"Alice\",\"age\":30}";

    // 准备 token 缓冲区
    var tokens: [16]Parser.Token = undefined;
    var parents: [16]Parser.IndexT = undefined;

    // 执行解析
    const count = try Parser.parseTokens(&tokens, &parents, json);

    std.debug.print("  JSON: {s}\n", .{json});
    std.debug.print("  解析到 {} 个 token\n", .{count});

    // 打印 token 详情
    for (tokens[0..count], 0..) |tok, i| {
        const type_name = switch (tok.typ) {
            .Object => "对象",
            .Array => "数组",
            .String => "字符串",
            .Primitive => "原始值",
            else => "未定义",
        };
        const text = Parser.tokenText(tok, json);
        std.debug.print("  Token[{}]: {s} - {s}\n", .{ i, type_name, text });
    }
    std.debug.print("\n", .{});
}

/// 示例 2: 字符串解析与转义处理
fn example2_string_parsing() !void {
    std.debug.print("--- 示例 2: 字符串解析与转义处理 ---\n", .{});

    const Parser = zzig.json.createParser();

    // 包含转义字符的 JSON
    const json = "\"Hello\\nWorld\\t\\u4E2D\\u6587\"";

    var tokens: [8]Parser.Token = undefined;
    var parents: [8]Parser.IndexT = undefined;

    const count = try Parser.parseTokens(&tokens, &parents, json);
    std.debug.print("  JSON: {s}\n", .{json});

    if (count > 0 and tokens[0].typ == .String) {
        // 创建 StringToken 进行转义处理
        const str_token = Parser.StringToken{
            .start = tokens[0].start,
            .end = tokens[0].end,
            .has_escapes = true,
        };

        // 解析到缓冲区
        var buffer: [256]u8 = undefined;
        const unescaped = try Parser.parseStringToBuffer(str_token, json, &buffer);

        std.debug.print("  原始字符串: {s}\n", .{Parser.tokenText(tokens[0], json)});
        std.debug.print("  解析后: {s}\n", .{unescaped});
    }
    std.debug.print("\n", .{});
}

/// 示例 3: 数字解析
fn example3_number_parsing() !void {
    std.debug.print("--- 示例 3: 数字解析 ---\n", .{});

    const Parser = zzig.json.createParser();

    // 测试不同类型的数字
    const test_cases = [_]struct { json: []const u8, is_int: bool }{
        .{ .json = "42", .is_int = true },
        .{ .json = "-123", .is_int = true },
        .{ .json = "3.14159", .is_int = false },
        .{ .json = "-2.71828", .is_int = false },
        .{ .json = "1.23e5", .is_int = false },
    };

    for (test_cases) |case| {
        var tokens: [8]Parser.Token = undefined;
        var parents: [8]Parser.IndexT = undefined;

        const count = try Parser.parseTokens(&tokens, &parents, case.json);
        if (count > 0 and tokens[0].typ == .Primitive) {
            std.debug.print("  JSON: {s} => ", .{case.json});

            if (case.is_int) {
                const value = try Parser.parseInteger(tokens[0], case.json);
                std.debug.print("整数 {}\n", .{value});
            } else {
                const value = try Parser.parseFloat(tokens[0], case.json);
                std.debug.print("浮点数 {d:.5}\n", .{value});
            }
        }
    }
    std.debug.print("\n", .{});
}

/// 示例 4: 对象遍历
fn example4_object_traversal(allocator: std.mem.Allocator) !void {
    std.debug.print("--- 示例 4: 对象遍历 ---\n", .{});

    const Parser = zzig.json.createParser();

    const json = "{\"name\":\"Bob\",\"age\":25,\"active\":true}";

    // 使用混合解析（自动选择栈或堆）
    var result = try Parser.parseHybrid(allocator, json);
    defer result.deinit(allocator);

    std.debug.print("  JSON: {s}\n", .{json});
    std.debug.print("  解析到 {} 个 token\n", .{result.count()});

    // 遍历所有 token
    var i: usize = 0;
    while (i < result.count()) : (i += 1) {
        if (result.getToken(i)) |utok| {
            const start = utok.getStart();
            const end = utok.getEnd();
            const text = json[start..end];

            const type_name = switch (utok.getType()) {
                .Object => "对象",
                .Array => "数组",
                .String => "字符串",
                .Primitive => "原始值",
                else => "未定义",
            };

            std.debug.print("  Token[{}]: {s} - {s}\n", .{ i, type_name, text });
        }
    }
    std.debug.print("\n", .{});
}

/// 示例 5: 数组遍历
fn example5_array_traversal() !void {
    std.debug.print("--- 示例 5: 数组遍历 ---\n", .{});

    const Parser = zzig.json.createParser();

    const json = "[1,2,3,\"four\",true,null]";

    var tokens: [16]Parser.Token = undefined;
    var parents: [16]Parser.IndexT = undefined;

    const count = try Parser.parseTokens(&tokens, &parents, json);
    std.debug.print("  JSON: {s}\n", .{json});

    // 第一个 token 应该是数组
    if (count > 0 and tokens[0].typ == .Array) {
        std.debug.print("  数组元素数量: {}\n", .{tokens[0].size});

        // 遍历数组元素
        var i: usize = 1; // 跳过数组本身
        var elem_idx: usize = 0;
        while (elem_idx < tokens[0].size) : (elem_idx += 1) {
            const text = Parser.tokenText(tokens[i], json);
            std.debug.print("  元素[{}]: {s}\n", .{ elem_idx, text });
            i += 1;
        }
    }
    std.debug.print("\n", .{});
}

/// 示例 6: 嵌套结构解析
fn example6_nested_structure(allocator: std.mem.Allocator) !void {
    std.debug.print("--- 示例 6: 嵌套结构解析 ---\n", .{});

    const Parser = zzig.json.createParser();

    const json =
        \\{
        \\  "user": {
        \\    "id": 123,
        \\    "name": "Charlie",
        \\    "tags": ["developer", "zig"]
        \\  },
        \\  "count": 42
        \\}
    ;

    var result = try Parser.parseHybrid(allocator, json);
    defer result.deinit(allocator);

    std.debug.print("  JSON: {s}\n", .{json});
    std.debug.print("  解析到 {} 个 token\n\n", .{result.count()});

    // 打印所有 token 的结构
    var i: usize = 0;
    var indent: usize = 0;
    while (i < result.count()) : (i += 1) {
        if (result.getToken(i)) |utok| {
            const start = utok.getStart();
            const end = utok.getEnd();
            const text = json[start..end];

            // 计算缩进（简化版）
            const type_name = switch (utok.getType()) {
                .Object => blk: {
                    const name = "对象";
                    indent += 2;
                    break :blk name;
                },
                .Array => blk: {
                    const name = "数组";
                    indent += 2;
                    break :blk name;
                },
                .String => "字符串",
                .Primitive => "原始值",
                else => "未定义",
            };

            // 打印带缩进的 token
            var j: usize = 0;
            while (j < indent) : (j += 1) {
                std.debug.print(" ", .{});
            }
            std.debug.print("Token[{}]: {s} - {s}\n", .{ i, type_name, text });

            // 恢复缩进
            if (utok.getType() == .Object or utok.getType() == .Array) {
                if (indent >= 2) indent -= 2;
            }
        }
    }
    std.debug.print("\n", .{});
}
