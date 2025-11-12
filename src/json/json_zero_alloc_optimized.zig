// json_zero_alloc_optimized.zig - JSON 解析器零分配优化版本
// 针对性能和内存占用的关键优化

const std = @import("std");
const builtin = @import("builtin");

/// 优化后的配置（零分配优先）
pub const OptimizedConfig = struct {
    index_type: type = u32, // ✅ u32 vs usize = 50% 内存节省（64-bit）
    enable_helpers: bool = true,
    compact_tokens: bool = true,
    max_depth: usize = 1024,
    tiny_mode: bool = false,
    use_simd: ?bool = null,
    force_simd: bool = false,
    force_scalar: bool = false,

    // ✅ 新增：栈阈值配置
    stack_threshold: usize = 2048, // 提高到 2048（原 512）

    // ✅ 新增：精确估算
    precise_estimate: bool = true, // 避免 2x 安全系数
};

/// 零分配优化版本的 Token（64-bit 平台）
pub const Token32 = struct {
    start: u32, // 4 bytes（支持 4GB JSON）
    end: u32, // 4 bytes
    size: u32, // 4 bytes
    typ: TokenType, // 1 byte
    _pad: [3]u8 = undefined, // 显式 padding，保持 16 字节对齐

    pub const TokenType = enum(u8) {
        Undefined = 0,
        Object = 1,
        Array = 2,
        String = 3,
        Primitive = 4,
    };

    comptime {
        // 编译期断言：确保大小为 16 字节
        if (@sizeOf(@This()) != 16) {
            @compileError("Token32 must be 16 bytes for cache alignment");
        }
    }
};

/// 优化后的紧凑 Token（保持 4 字节）
pub const CompactToken = u32;

/// 零分配解析器
pub fn ZeroAllocParser(comptime cfg: OptimizedConfig) type {
    return struct {
        pub const IndexT = cfg.index_type;
        pub const USE_COMPACT = cfg.compact_tokens;
        pub const STACK_THRESHOLD = cfg.stack_threshold;

        pub const Token = if (@sizeOf(usize) == 8) Token32 else struct {
            start: IndexT,
            end: IndexT,
            size: IndexT,
            typ: Token32.TokenType,
        };

        pub const Error = error{
            InvalidJson,
            OutOfTokens,
            InvalidString,
            NotEnoughParents,
            TooDeep,
            CompactOverflow,
        };

        /// ✅ 零分配 API #1：用户提供缓冲区
        pub fn parseZeroAlloc(
            tokens: []Token,
            parents: []IndexT,
            input: []const u8,
        ) Error!usize {
            if (parents.len < tokens.len) return Error.NotEnoughParents;

            var pos: IndexT = 0;
            var tcount: IndexT = 0;
            var stack_top: IndexT = 0;
            const N: IndexT = @intCast(input.len);

            while (pos < N) {
                const c = input[pos];

                // 跳过空白
                if (isSpace(c)) {
                    pos += 1;
                    continue;
                }

                // 对象/数组开始
                if (c == '{' or c == '[') {
                    if (stack_top >= cfg.max_depth) return Error.TooDeep;
                    if (tcount >= tokens.len) return Error.OutOfTokens;

                    const idx = tcount;
                    tokens[idx].typ = if (c == '{') .Object else .Array;
                    tokens[idx].start = @intCast(pos);
                    tokens[idx].size = 0;
                    tcount += 1;

                    if (stack_top != 0) {
                        const pidx = parents[stack_top - 1];
                        tokens[pidx].size += 1;
                    }

                    parents[stack_top] = idx;
                    stack_top += 1;
                    pos += 1;
                    continue;
                }

                // 对象/数组结束
                if (c == '}' or c == ']') {
                    if (stack_top == 0) return Error.InvalidJson;

                    const top_idx = parents[stack_top - 1];
                    const top_type = tokens[top_idx].typ;

                    if ((c == '}' and top_type != .Object) or
                        (c == ']' and top_type != .Array))
                    {
                        return Error.InvalidJson;
                    }

                    tokens[top_idx].end = @intCast(pos + 1);
                    stack_top -= 1;
                    pos += 1;
                    continue;
                }

                // 字符串
                if (c == '"') {
                    if (tcount >= tokens.len) return Error.OutOfTokens;

                    const idx = tcount;
                    tokens[idx].typ = .String;
                    tokens[idx].start = @intCast(pos + 1);

                    pos += 1;
                    var escaped = false;

                    while (pos < N) {
                        const ch = input[pos];
                        if (ch == '\\' and !escaped) {
                            escaped = true;
                            pos += 1;
                            continue;
                        }
                        if (ch == '"' and !escaped) {
                            tokens[idx].end = @intCast(pos);
                            pos += 1;
                            tcount += 1;
                            if (stack_top != 0) {
                                tokens[parents[stack_top - 1]].size += 1;
                            }
                            break;
                        }
                        escaped = false;
                        pos += 1;
                    }
                    continue;
                }

                // 跳过分隔符
                if (c == ':' or c == ',') {
                    pos += 1;
                    continue;
                }

                // 原始值
                if (tcount >= tokens.len) return Error.OutOfTokens;

                const idx = tcount;
                tokens[idx].typ = .Primitive;
                tokens[idx].start = @intCast(pos);

                while (pos < N) {
                    const ch = input[pos];
                    if (isDelim(ch)) break;
                    pos += 1;
                }

                tokens[idx].end = @intCast(pos);
                tcount += 1;

                if (stack_top != 0) {
                    tokens[parents[stack_top - 1]].size += 1;
                }
            }

            return tcount;
        }

        /// ✅ 零分配 API #2：栈缓冲区智能选择
        pub fn parseStack(
            comptime max_tokens: usize,
            input: []const u8,
        ) Error!struct {
            tokens: [max_tokens]Token,
            count: usize,
        } {
            var tokens: [max_tokens]Token align(64) = undefined; // ✅ 缓存行对齐
            var parents: [max_tokens]IndexT align(64) = undefined;

            const count = try parseZeroAlloc(&tokens, &parents, input);

            return .{ .tokens = tokens, .count = count };
        }

        /// ✅ 精确估算（避免 2x 安全系数）
        pub fn estimateTokenCountPrecise(input: []const u8) usize {
            var c: usize = 0;
            var i: usize = 0;
            const len = input.len;

            while (i < len) {
                const b = input[i];
                switch (b) {
                    '{', '[', '}', ']' => {
                        c += 1;
                        i += 1;
                    },
                    '"' => {
                        c += 1;
                        i += 1;
                        var escaped = false;
                        while (i < len) {
                            const ch = input[i];
                            if (ch == '\\' and !escaped) {
                                escaped = true;
                            } else if (ch == '"' and !escaped) {
                                i += 1;
                                break;
                            } else {
                                escaped = false;
                            }
                            i += 1;
                        }
                    },
                    ',', ':', ' ', '\t', '\n', '\r' => {
                        i += 1;
                    },
                    else => {
                        c += 1;
                        while (i < len) {
                            const ch = input[i];
                            if (isDelim(ch)) break;
                            i += 1;
                        }
                    },
                }
            }

            // ✅ 只加小缓冲（32 vs 原来的 2x）
            return c + 32;
        }

        /// ✅ 改进的 parseHybrid（更高栈阈值）
        pub fn parseHybrid(
            allocator: ?std.mem.Allocator,
            input: []const u8,
        ) Error!HybridResult {
            const est = if (cfg.precise_estimate)
                estimateTokenCountPrecise(input)
            else
                estimateTokenCountLegacy(input);

            // ✅ 使用更高的栈阈值
            if (allocator == null or est <= STACK_THRESHOLD) {
                var std_tokens: [STACK_THRESHOLD]Token align(64) = undefined;
                var parents: [STACK_THRESHOLD]IndexT align(64) = undefined;

                const used = try parseZeroAlloc(&std_tokens, &parents, input);

                var res: HybridResult = undefined;
                res.owned = false;
                res.inline_count = used;
                res.heap_slice = undefined;

                // 复制到内联存储
                @memcpy(res.inline_storage[0..used], std_tokens[0..used]);
                res.heap_slice = res.inline_storage[0..used];

                return res;
            } else {
                // 堆分配路径（仅大型 JSON）
                const a = allocator.?;

                const tokens = try a.alloc(Token, est);
                errdefer a.free(tokens);

                const parents = try a.alloc(IndexT, est);
                defer a.free(parents);

                const used = try parseZeroAlloc(tokens, parents, input);

                return HybridResult{
                    .owned = true,
                    .heap_slice = tokens[0..used],
                    .inline_count = 0,
                    .inline_storage = undefined,
                };
            }
        }

        pub const HybridResult = struct {
            owned: bool,
            heap_slice: []Token,
            inline_count: usize,
            inline_storage: [STACK_THRESHOLD]Token,

            pub fn deinit(self: *HybridResult, allocator: std.mem.Allocator) void {
                if (self.owned) {
                    allocator.free(self.heap_slice);
                    self.owned = false;
                }
            }

            pub fn count(self: HybridResult) usize {
                return self.heap_slice.len;
            }
        };

        // ============ 辅助函数 ============

        inline fn isSpace(c: u8) bool {
            return c == ' ' or c == '\t' or c == '\n' or c == '\r';
        }

        inline fn isDelim(c: u8) bool {
            return c == ',' or c == ']' or c == '}' or c <= 0x20;
        }

        fn estimateTokenCountLegacy(input: []const u8) usize {
            const precise = estimateTokenCountPrecise(input);
            return @max(precise * 2, 64); // 旧版 2x 安全系数
        }
    };
}

/// ✅ 便捷创建函数
pub fn createZeroAllocParser() type {
    return ZeroAllocParser(.{
        .index_type = u32,
        .compact_tokens = true,
        .stack_threshold = 2048,
        .precise_estimate = true,
    });
}

/// ✅ 嵌入式优化版本
pub fn createEmbeddedParser() type {
    return ZeroAllocParser(.{
        .index_type = u16, // ✅ u16 节省更多内存
        .compact_tokens = true,
        .max_depth = 64, // ✅ 降低栈深度
        .tiny_mode = true,
        .enable_helpers = false,
        .use_simd = false,
        .stack_threshold = 512, // ✅ 嵌入式栈小
        .precise_estimate = true,
    });
}

// ============ 测试 ============

test "零分配解析" {
    const Parser = createZeroAllocParser();

    const json = "{\"name\":\"Alice\",\"age\":30}";

    var tokens: [16]Parser.Token = undefined;
    var parents: [16]Parser.IndexT = undefined;

    const count = try Parser.parseZeroAlloc(&tokens, &parents, json);

    try std.testing.expect(count == 5);
    try std.testing.expect(tokens[0].typ == .Object);
}

test "栈缓冲区解析" {
    const Parser = createZeroAllocParser();

    const json = "[1,2,3,4,5]";

    const result = try Parser.parseStack(16, json);

    try std.testing.expect(result.count == 6);
    try std.testing.expect(result.tokens[0].typ == .Array);
}

test "精确估算" {
    const Parser = createZeroAllocParser();

    const json = "{\"key\":\"value\"}";

    const estimate = Parser.estimateTokenCountPrecise(json);

    // 实际：3 个 token（对象 + 2 个字符串）
    // 估算：3 + 32 = 35
    try std.testing.expect(estimate <= 64); // 远小于旧版 2x
}

test "Token32 大小验证" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Token32));
}
