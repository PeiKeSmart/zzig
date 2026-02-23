// jsmn_zig.zig
// JSMN-like tokenizer for Zig 0.13 - streaming, compact tokens, hybrid parse
const std = @import("std");
const builtin = @import("builtin");

pub const Config = struct {
    index_type: type = usize,
    enable_helpers: bool = true,
    compact_tokens: bool = true,
    max_depth: usize = 1024,
    tiny_mode: bool = false,
    use_simd: ?bool = null,
    force_simd: bool = false,
    force_scalar: bool = false,
};

pub fn jsmn_default_config() Config {
    return .{
        .index_type = usize,
        .enable_helpers = true,
        .compact_tokens = true,
        .max_depth = 1024,
        .tiny_mode = false,
        .use_simd = null,
        .force_simd = false,
        .force_scalar = false,
    };
}

pub fn Jsmn(comptime cfg: Config) type {
    const can_use_simd = comptime blk: {
        if (cfg.force_scalar) break :blk false;
        if (cfg.force_simd) break :blk true;
        if (cfg.use_simd) |v| break :blk v;
        break :blk switch (builtin.cpu.arch) {
            .x86, .x86_64 => true,
            .aarch64, .arm => true,
            else => false,
        };
    };

    return struct {
        pub const IndexT = cfg.index_type;
        pub const ENABLE_HELPERS = if (cfg.tiny_mode) false else cfg.enable_helpers;
        pub const MAX_DEPTH = cfg.max_depth;
        pub const USE_COMPACT = cfg.compact_tokens;
        pub const USE_SIMD = can_use_simd and !cfg.tiny_mode;

        pub const Error = error{
            InvalidJson,
            OutOfTokens,
            InvalidString,
            NotEnoughParents,
            EscapingRequired,
            NeedMoreInput,
            NumberParseError,
            TooDeep,
            CompactOverflow,
        };

        pub const TokenType = enum(u8) {
            Undefined = 0,
            Object = 1,
            Array = 2,
            String = 3,
            Primitive = 4,
        };

        pub const Token = struct {
            typ: TokenType,
            start: IndexT,
            end: IndexT,
            size: IndexT,
        };

        // Compact token format: [start:20][len:8][flags:4]
        pub const CompactToken = u32;

        inline fn packCompact(typ: u32, is_key: bool, start: u32, len: u32) !u32 {
            if (start >= (1 << 20)) return Error.CompactOverflow;
            if (len >= (1 << 8)) return Error.CompactOverflow;
            const flags: u32 = (typ & 0x3) | ((if (is_key) @as(u32, 1) else 0) << 2);
            return (start << 12) | (len << 4) | flags;
        }

        inline fn compactGetStart(ct: CompactToken) u32 {
            return (ct >> 12) & ((1 << 20) - 1);
        }

        inline fn compactGetLen(ct: CompactToken) u32 {
            return (ct >> 4) & 0xFF;
        }

        inline fn compactGetFlags(ct: CompactToken) u32 {
            return ct & 0xF;
        }

        inline fn compactGetType(ct: CompactToken) u32 {
            return compactGetFlags(ct) & 0x3;
        }

        inline fn compactIsKey(ct: CompactToken) bool {
            return ((compactGetFlags(ct) >> 2) & 1) == 1;
        }

        pub const UniversalToken = union(enum) {
            standard: Token,
            compact: CompactToken,

            pub fn getStart(self: UniversalToken) IndexT {
                return switch (self) {
                    .standard => |t| t.start,
                    .compact => |ct| @as(IndexT, compactGetStart(ct)),
                };
            }

            pub fn getEnd(self: UniversalToken) IndexT {
                return switch (self) {
                    .standard => |t| t.end,
                    .compact => |ct| @as(IndexT, compactGetStart(ct) + compactGetLen(ct)),
                };
            }

            pub fn getType(self: UniversalToken) TokenType {
                return switch (self) {
                    .standard => |t| t.typ,
                    .compact => |ct| @enumFromInt(compactGetType(ct)),
                };
            }

            pub fn getSize(self: UniversalToken) IndexT {
                return switch (self) {
                    .standard => |t| t.size,
                    .compact => |ct| @as(IndexT, compactGetLen(ct)),
                };
            }
        };

        pub const StringToken = struct {
            start: IndexT,
            end: IndexT,
            has_escapes: bool,

            pub fn slice(self: @This(), input: []const u8) []const u8 {
                return input[self.start..self.end];
            }

            pub fn parseUnescapedToBuf(self: @This(), input: []const u8, out_buf: []u8) !usize {
                const s = self.slice(input);
                var oi: usize = 0;
                var i: usize = 0;
                while (i < s.len) : (i += 1) {
                    const ch = s[i];
                    if (ch == '\\') {
                        i += 1;
                        if (i >= s.len) return Error.InvalidString;
                        const esc = s[i];
                        if (esc == 'u') {
                            if (i + 4 >= s.len) return Error.InvalidString;
                            var hex: u32 = 0;
                            var j: usize = 1;
                            while (j <= 4) : (j += 1) {
                                const c = s[i + j];
                                const v = hexDigitToVal(c);
                                if (v == 0xFF) return Error.InvalidString;
                                hex = (hex << 4) | v;
                            }
                            i += 4;
                            var tmp: [4]u8 = undefined;
                            const n = encodeUtf8(hex, &tmp);
                            if (oi + n > out_buf.len) return Error.OutOfTokens;
                            @memcpy(out_buf[oi..][0..n], tmp[0..n]);
                            oi += n;
                        } else {
                            const mapped: u8 = switch (esc) {
                                '"' => '"',
                                '\\' => '\\',
                                '/' => '/',
                                'b' => 0x08, // backspace
                                'f' => 0x0C, // form feed
                                'n' => '\n',
                                'r' => '\r',
                                't' => '\t',
                                else => return Error.InvalidString,
                            };
                            if (oi >= out_buf.len) return Error.OutOfTokens;
                            out_buf[oi] = mapped;
                            oi += 1;
                        }
                    } else {
                        if (oi >= out_buf.len) return Error.OutOfTokens;
                        out_buf[oi] = ch;
                        oi += 1;
                    }
                }
                return oi;
            }
        };

        pub const NumberToken = struct {
            start: IndexT,
            end: IndexT,
            is_float: bool,
            is_negative: bool,

            pub fn slice(self: @This(), input: []const u8) []const u8 {
                return input[self.start..self.end];
            }

            pub fn parse(self: @This(), input: []const u8) !f64 {
                const s = self.slice(input);
                return std.fmt.parseFloat(f64, s) catch return Error.NumberParseError;
            }

            pub fn parseInteger(self: @This(), input: []const u8) !i64 {
                const s = self.slice(input);
                return std.fmt.parseInt(i64, s, 10) catch return Error.NumberParseError;
            }
        };

        inline fn hexDigitToVal(c: u8) u32 {
            return switch (c) {
                '0'...'9' => c - '0',
                'A'...'F' => 10 + (c - 'A'),
                'a'...'f' => 10 + (c - 'a'),
                else => 0xFF,
            };
        }

        inline fn encodeUtf8(cp: u32, out: *[4]u8) usize {
            if (cp <= 0x7F) {
                out[0] = @intCast(cp);
                return 1;
            } else if (cp <= 0x7FF) {
                out[0] = @intCast(0xC0 | (cp >> 6));
                out[1] = @intCast(0x80 | (cp & 0x3F));
                return 2;
            } else if (cp <= 0xFFFF) {
                out[0] = @intCast(0xE0 | (cp >> 12));
                out[1] = @intCast(0x80 | ((cp >> 6) & 0x3F));
                out[2] = @intCast(0x80 | (cp & 0x3F));
                return 3;
            } else {
                out[0] = @intCast(0xF0 | (cp >> 18));
                out[1] = @intCast(0x80 | ((cp >> 12) & 0x3F));
                out[2] = @intCast(0x80 | ((cp >> 6) & 0x3F));
                out[3] = @intCast(0x80 | (cp & 0x3F));
                return 4;
            }
        }

        inline fn isSpace(c: u8) bool {
            return c == ' ' or c == '\t' or c == '\n' or c == '\r';
        }

        inline fn byteAt(inp: []const u8, p: IndexT) u8 {
            return inp[p];
        }

        inline fn isDelim(c: u8) bool {
            return c == ',' or c == ']' or c == '}' or c <= 0x20;
        }

        pub const ParserState = struct {
            pos: IndexT,
            stack_top: IndexT,
            tokens_written: IndexT,

            pub fn reset(self: *ParserState) void {
                self.pos = 0;
                self.stack_top = 0;
                self.tokens_written = 0;
            }
        };

        fn parseString(pos_ptr: *IndexT, input: []const u8) !StringToken {
            const start = pos_ptr.*;
            if (start >= input.len) return Error.InvalidString;

            // 批量跳过普通字符：直接定位到下一个 \ 或 "，避免逐字节检测
            var pos: usize = @as(usize, pos_ptr.*) + 1;
            var has_esc = false;

            while (pos < input.len) {
                const next = std.mem.indexOfAnyPos(u8, input, pos, "\\\"") orelse
                    return Error.InvalidString;
                if (input[next] == '"') {
                    pos_ptr.* = @intCast(next + 1);
                    return .{
                        .start = start + 1,
                        .end = @intCast(next),
                        .has_escapes = has_esc,
                    };
                }
                // 反斜杠：直接跳过转义字符对（\ + 被转义字符），无需 escaped 标志
                has_esc = true;
                pos = next + 2;
            }
            return Error.InvalidString;
        }

        fn parseStringScalar(pos_ptr: *IndexT, input: []const u8) !StringToken {
            return parseString(pos_ptr, input);
        }

        fn parseStringSimd(pos_ptr: *IndexT, input: []const u8) !StringToken {
            return parseString(pos_ptr, input);
        }

        fn parseStringAdaptive(pos_ptr: *IndexT, input: []const u8) !StringToken {
            if (USE_SIMD) {
                return parseStringSimd(pos_ptr, input);
            } else {
                return parseStringScalar(pos_ptr, input);
            }
        }

        // Core parsing function with streaming support
        pub fn parseChunk(
            state: *ParserState,
            tokens: []Token,
            parent_stack: []IndexT,
            input: []const u8,
            is_final: bool,
        ) !IndexT {
            if (parent_stack.len < tokens.len) return Error.NotEnoughParents;

            var pos: IndexT = state.pos;
            const N: IndexT = @intCast(input.len);
            var tcount: IndexT = state.tokens_written;
            var stack_top: IndexT = state.stack_top;

            while (pos < N) {
                const c = byteAt(input, pos);
                if (isSpace(c)) {
                    pos += 1;
                    continue;
                }

                if (c == '{' or c == '[') {
                    if (MAX_DEPTH > 0 and stack_top >= MAX_DEPTH) return Error.TooDeep;
                    if (tcount >= tokens.len) return Error.OutOfTokens;
                    const idx = tcount;
                    tokens[idx].typ = if (c == '{') TokenType.Object else TokenType.Array;
                    tokens[idx].start = pos;
                    tokens[idx].size = 0;
                    tcount += 1;
                    if (stack_top != 0) {
                        const pidx = parent_stack[stack_top - 1];
                        tokens[pidx].size += 1;
                    }
                    parent_stack[stack_top] = idx;
                    stack_top += 1;
                    pos += 1;
                    continue;
                }

                if (c == '}' or c == ']') {
                    if (stack_top == 0) return Error.InvalidJson;
                    const top_idx = parent_stack[stack_top - 1];
                    const top_type = tokens[top_idx].typ;
                    if ((c == '}' and top_type != TokenType.Object) or (c == ']' and top_type != TokenType.Array))
                        return Error.InvalidJson;
                    tokens[top_idx].end = pos + 1;
                    stack_top -= 1;
                    pos += 1;
                    continue;
                }

                if (c == '"') {
                    if (tcount >= tokens.len) return Error.OutOfTokens;
                    const idx = tcount;
                    tokens[idx].typ = TokenType.String;
                    tokens[idx].start = pos + 1;

                    var p_index: IndexT = pos;
                    const st = parseStringAdaptive(&p_index, input) catch |err| {
                        if (err == Error.InvalidString and !is_final) {
                            state.pos = p_index;
                            state.stack_top = stack_top;
                            state.tokens_written = tcount;
                            return Error.NeedMoreInput;
                        }
                        return err;
                    };
                    tokens[idx].end = st.end;
                    tcount += 1;
                    if (stack_top != 0) tokens[parent_stack[stack_top - 1]].size += 1;
                    pos = p_index;
                    continue;
                }

                if (c == ':' or c == ',') {
                    pos += 1;
                    continue;
                }

                {
                    if (tcount >= tokens.len) return Error.OutOfTokens;
                    const idx = tcount;
                    tokens[idx].typ = TokenType.Primitive;
                    tokens[idx].start = pos;
                    while (pos < N) {
                        const ch = byteAt(input, pos);
                        if (isDelim(ch)) break;
                        pos += 1;
                    }
                    tokens[idx].end = pos;
                    tcount += 1;
                    if (stack_top != 0) tokens[parent_stack[stack_top - 1]].size += 1;
                    continue;
                }
            }

            state.pos = pos;
            state.stack_top = stack_top;
            state.tokens_written = tcount;
            return tcount;
        }

        pub fn parseTokens(tokens: []Token, parent_stack: []IndexT, input: []const u8) !IndexT {
            var s: ParserState = .{ .pos = 0, .stack_top = 0, .tokens_written = 0 };
            return parseChunk(&s, tokens, parent_stack, input, true);
        }

        pub fn compressTokens(parsed: []const Token, parsed_count: usize, out: []CompactToken) !usize {
            var o: usize = 0;
            for (parsed[0..parsed_count]) |t| {
                const typ_u32: u32 = switch (t.typ) {
                    .Object => 1,
                    .Array => 2,
                    .String => 3,
                    .Primitive => 3,
                    else => 0,
                };
                const length = if (t.typ == .Object or t.typ == .Array)
                    @as(u32, @intCast(t.size))
                else
                    @as(u32, @intCast(t.end - t.start));
                const start32 = @as(u32, @intCast(t.start));
                // 检查是否超出紧凑格式限制
                if (start32 >= (1 << 20) or length >= (1 << 8)) {
                    // ❌ 超出紧凑格式限制，返回错误而不是跳过
                    return Error.CompactOverflow;
                }
                const packed_val = try packCompact(typ_u32, false, start32, length);
                if (o >= out.len) return Error.OutOfTokens;
                out[o] = packed_val;
                o += 1;
            }

            // Mark keys in objects
            var i: usize = 0;
            while (i < parsed_count) {
                const t = parsed[i];
                if (t.typ == .Object) {
                    var child = i + 1;
                    var rem: usize = @intCast(t.size);
                    while (rem > 0) : (rem -= 2) {
                        if (child >= parsed_count) break;
                        if (child < out.len) {
                            const key_token = out[child];
                            const new_key = try packCompact(compactGetType(key_token), true, compactGetStart(key_token), compactGetLen(key_token));
                            out[child] = new_key;
                        }
                        child += 2; // Skip key-value pair
                    }
                    i = skipToken(parsed, i);
                } else {
                    i += 1;
                }
            }

            return o; // Повертаємо реальну кількість записаних компактних токенів
        }

        pub fn tokenText(tok: Token, input: []const u8) []const u8 {
            return input[tok.start..tok.end];
        }

        pub fn skipToken(tokens: []const Token, idx: usize) usize {
            const t = tokens[idx];
            if (t.typ == .Object or t.typ == .Array) {
                var i: usize = idx + 1;
                var remaining: usize = @intCast(t.size);
                while (remaining > 0) {
                    i = skipToken(tokens, i);
                    remaining -= 1;
                }
                return i;
            } else {
                return idx + 1;
            }
        }

        pub fn parseInteger(tok: Token, input: []const u8) !i64 {
            const s = tokenText(tok, input);
            return std.fmt.parseInt(i64, s, 10) catch return Error.NumberParseError;
        }

        pub fn parseFloat(tok: Token, input: []const u8) !f64 {
            const s = tokenText(tok, input);
            return std.fmt.parseFloat(f64, s) catch return Error.NumberParseError;
        }

        pub const HybridResult = struct {
            owned: bool,
            heap_slice: []UniversalToken,
            inline_count: usize,
            inline_storage: [512]UniversalToken,

            pub fn deinit(self: *HybridResult, allocator: std.mem.Allocator) void {
                if (self.owned) {
                    allocator.free(self.heap_slice);
                    self.owned = false;
                    self.heap_slice = &.{};
                }
            }

            pub fn getToken(self: HybridResult, index: usize) ?UniversalToken {
                if (index < self.heap_slice.len) {
                    return self.heap_slice[index];
                }
                return null;
            }

            pub fn count(self: HybridResult) usize {
                return self.heap_slice.len;
            }
        };

        pub fn estimateTokenCount(input: []const u8) usize {
            var c: usize = 0;
            var i: usize = 0;
            const len = input.len;

            while (i < len) {
                const b = input[i];
                switch (b) {
                    '{', '[', '}', ']' => {
                        c += 1; // Structural tokens
                        i += 1;
                    },
                    '"' => {
                        // String token
                        c += 1;
                        i += 1;
                        // 批量跳过普通字符：直接定位到下一个 \ 或 "，避免逐字节检测
                        while (i < len) {
                            const next = std.mem.indexOfAnyPos(u8, input, i, "\\\"") orelse {
                                i = len;
                                break;
                            };
                            if (input[next] == '"') {
                                i = next + 1;
                                break;
                            }
                            // 反斜杠：跳过转义字符对
                            i = next + 2;
                        }
                    },
                    ',', ':', ' ', '\t', '\n', '\r' => {
                        // Skip delimiters and whitespace
                        i += 1;
                    },
                    else => {
                        // Primitive token (number, true, false, null)
                        c += 1;
                        // Skip until delimiter
                        while (i < len) {
                            const ch = input[i];
                            if (ch == ',' or ch == ']' or ch == '}' or ch == ' ' or
                                ch == '\t' or ch == '\n' or ch == '\r')
                            {
                                break;
                            }
                            i += 1;
                        }
                    },
                }
            }

            // Add buffer for safety
            return @max(c * 2, 64);
        }

        pub fn parseHybrid(allocator: ?std.mem.Allocator, input: []const u8) !HybridResult {
            const est = estimateTokenCount(input);

            // Use stack for small allocations, heap for large ones
            if (allocator == null or est <= 512) {
                var std_tokens: [512]Token = undefined;
                var parents: [512]IndexT = undefined;
                const used = try parseTokens(&std_tokens, &parents, input);

                var res: HybridResult = undefined;
                res.owned = false;
                res.inline_count = 0;
                res.heap_slice = &.{};

                if (USE_COMPACT and input.len < (1 << 20)) {
                    var compact_buf: [512]CompactToken = undefined;
                    // 尝试压缩，如果失败则回退到标准格式
                    const ccount = compressTokens(&std_tokens, used, &compact_buf) catch |err| {
                        if (err == Error.CompactOverflow) {
                            // 回退到标准格式
                            for (std_tokens[0..used], 0..) |tok, i| {
                                res.inline_storage[i] = .{ .standard = tok };
                            }
                            res.inline_count = used;
                            res.heap_slice = res.inline_storage[0..used];
                            return res;
                        } else {
                            return err;
                        }
                    };
                    for (compact_buf[0..ccount], 0..) |ct, i| {
                        res.inline_storage[i] = .{ .compact = ct };
                    }
                    res.inline_count = ccount;
                    res.heap_slice = res.inline_storage[0..ccount];
                } else {
                    for (std_tokens[0..used], 0..) |tok, i| {
                        res.inline_storage[i] = .{ .standard = tok };
                    }
                    res.inline_count = used;
                    res.heap_slice = res.inline_storage[0..used];
                }
                return res;
            } else {
                const a = allocator.?;

                // Allocate with some extra capacity
                const alloc_count = est + 64;
                var tmp_tokens = try a.alloc(Token, alloc_count);
                defer a.free(tmp_tokens);

                const parent_stack = try a.alloc(IndexT, alloc_count);
                defer a.free(parent_stack);

                const used = try parseTokens(tmp_tokens, parent_stack, input);

                if (USE_COMPACT and input.len < (1 << 20)) {
                    var compact_tmp = try a.alloc(CompactToken, alloc_count);
                    defer a.free(compact_tmp);

                    // 尝试压缩，如果失败则回退到标准格式
                    const ccount = compressTokens(tmp_tokens, used, compact_tmp) catch |err| {
                        if (err == Error.CompactOverflow) {
                            // 回退到标准格式
                            var tokens = try a.alloc(UniversalToken, used);
                            for (tmp_tokens[0..used], 0..) |tok, i| {
                                tokens[i] = .{ .standard = tok };
                            }
                            return HybridResult{
                                .owned = true,
                                .heap_slice = tokens,
                                .inline_count = 0,
                                .inline_storage = undefined,
                            };
                        } else {
                            return err;
                        }
                    };

                    // Allocate final tokens array
                    var tokens = try a.alloc(UniversalToken, ccount);

                    for (compact_tmp[0..ccount], 0..) |ct, i| {
                        tokens[i] = .{ .compact = ct };
                    }

                    return HybridResult{
                        .owned = true,
                        .heap_slice = tokens,
                        .inline_count = 0,
                        .inline_storage = undefined,
                    };
                } else {
                    // Allocate final tokens array
                    var tokens = try a.alloc(UniversalToken, used);

                    for (tmp_tokens[0..used], 0..) |tok, i| {
                        tokens[i] = .{ .standard = tok };
                    }

                    return HybridResult{
                        .owned = true,
                        .heap_slice = tokens,
                        .inline_count = 0,
                        .inline_storage = undefined,
                    };
                }
            }
        }

        pub fn parseDirect(comptime max_tokens: usize, input: []const u8) !struct {
            tokens: if (USE_COMPACT) [max_tokens]CompactToken else [max_tokens]Token,
            count: usize,
        } {
            var std_tokens: [max_tokens]Token = undefined;
            var parents: [max_tokens]IndexT = undefined;
            const used = try parseTokens(&std_tokens, &parents, input);

            if (USE_COMPACT and input.len < (1 << 20)) {
                var compact: [max_tokens]CompactToken = undefined;
                const count = try compressTokens(&std_tokens, used, &compact);
                return .{ .tokens = compact, .count = count };
            } else {
                return .{ .tokens = std_tokens, .count = used };
            }
        }

        pub fn parseStringToBuffer(str_token: StringToken, input: []const u8, buffer: []u8) ![]const u8 {
            if (!str_token.has_escapes) {
                const slice = str_token.slice(input);
                if (slice.len > buffer.len) return Error.OutOfTokens;
                @memcpy(buffer[0..slice.len], slice);
                return buffer[0..slice.len];
            }
            const written = try str_token.parseUnescapedToBuf(input, buffer);
            return buffer[0..written];
        }

        // Helper functions - conditionally compiled
        pub fn findObjectValue(tokens: []const Token, count: usize, input: []const u8, key: []const u8) ?usize {
            if (!ENABLE_HELPERS) return null;

            var i: usize = 0;
            while (i < count) : (i += 1) {
                const t = tokens[i];
                if (t.typ == .Object) {
                    var child = i + 1;
                    var rem: usize = @intCast(t.size);
                    while (rem > 0) {
                        if (child >= count) break;
                        const keyTok = tokens[child];
                        if (keyTok.typ == .String) {
                            const s = tokenText(keyTok, input);
                            if (std.mem.eql(u8, s, key)) return child + 1;
                            child += 1;
                        } else {
                            child += 1;
                        }
                        rem -= 1;
                    }
                }
            }
            return null;
        }

        pub fn getArrayItems(tokens: []const Token, array_index: usize) []const Token {
            if (!ENABLE_HELPERS) return &.{};

            const array_token = tokens[array_index];
            if (array_token.typ != .Array) return &.{};
            const start = array_index + 1;
            const end = start + @as(usize, @intCast(array_token.size));
            if (end > tokens.len) return tokens[start..];
            return tokens[start..end];
        }

        pub fn getObjectEntries(tokens: []const Token, object_index: usize) struct {
            keys: []const Token,
            values: []const Token,
        } {
            if (!ENABLE_HELPERS) return .{ .keys = &.{}, .values = &.{} };

            const obj_token = tokens[object_index];
            if (obj_token.typ != .Object) return .{ .keys = &.{}, .values = &.{} };

            const start = object_index + 1;
            const count = @as(usize, @intCast(obj_token.size));
            const end = start + count * 2;

            if (end > tokens.len) {
                const available = (tokens.len - start) / 2;
                return .{
                    .keys = tokens[start..][0..available],
                    .values = tokens[start + available ..][0..available],
                };
            }

            return .{
                .keys = tokens[start..][0..count],
                .values = tokens[start + count ..][0..count],
            };
        }

        pub const JsonParser = struct {
            config: Config,

            pub fn init() JsonParser {
                return .{ .config = jsmn_default_config() };
            }

            pub fn forEmbedded(self: *JsonParser) *JsonParser {
                self.config.compact_tokens = true;
                self.config.use_simd = null;
                self.config.tiny_mode = true;
                return self;
            }

            pub fn forDesktop(self: *JsonParser) *JsonParser {
                self.config.compact_tokens = false;
                self.config.use_simd = true;
                self.config.tiny_mode = false;
                self.config.enable_helpers = true;
                return self;
            }

            pub fn withMaxDepth(self: *JsonParser, depth: usize) *JsonParser {
                self.config.max_depth = depth;
                return self;
            }

            pub fn withIndexType(comptime T: type) JsonParser {
                var parser = init();
                parser.config.index_type = T;
                return parser;
            }

            pub fn build(self: JsonParser) type {
                return Jsmn(self.config);
            }
        };
    };
}

test "basic primitive parse" {
    const cfg = jsmn_default_config();
    const Parser = Jsmn(cfg);
    var toks: [8]Parser.Token = undefined;
    var parents: [8]Parser.IndexT = undefined;
    const json = "42";
    const used = try Parser.parseTokens(&toks, &parents, json);
    try std.testing.expect(used == 1);
    try std.testing.expect(toks[0].typ == .Primitive);
    const v = try Parser.parseInteger(toks[0], json);
    try std.testing.expect(v == 42);
}

test "string parse and unescape" {
    const cfg = jsmn_default_config();
    const Parser = Jsmn(cfg);
    var toks: [8]Parser.Token = undefined;
    var parents: [8]Parser.IndexT = undefined;
    const json = "\"a\\n\\u0041b\"";
    const used = try Parser.parseTokens(&toks, &parents, json);
    try std.testing.expect(used == 1);
    try std.testing.expect(toks[0].typ == .String);
    const st = Parser.StringToken{ .start = toks[0].start, .end = toks[0].end, .has_escapes = true };
    var buf: [16]u8 = undefined;
    const n = try st.parseUnescapedToBuf(json, &buf);
    try std.testing.expectEqualSlices(u8, buf[0..n], "a\nAb");
}

test "parseHybrid stack and heap path" {
    const cfg = jsmn_default_config();
    const Parser = Jsmn(cfg);

    // Stack path - маленький JSON
    const small_json = "{\"a\":1}";
    const res = try Parser.parseHybrid(null, small_json);
    defer if (res.owned) std.testing.allocator.free(res.heap_slice);
    try std.testing.expect(!res.owned);
    try std.testing.expect(res.inline_count > 0);

    // Heap path - великий JSON з явним аллокатором
    const allocator = std.testing.allocator;

    // Створюємо JSON, який гарантовано використає heap (більше 512 токенів)
    var list = std.ArrayList(u8).init(allocator);
    defer list.deinit();

    try list.appendSlice("{\"data\":[");
    for (0..100) |i| { // Збільшено для гарантованого використання heap
        if (i != 0) try list.appendSlice(",");
        try list.writer().print("{{\"id\":{},\"name\":\"item_{}\",\"values\":[1,2,3,4,5,6,7,8]}}", .{ i, i });
    }
    try list.appendSlice("]}");

    const big_json = list.items;

    var heap_res = try Parser.parseHybrid(allocator, big_json);
    defer heap_res.deinit(allocator);

    try std.testing.expect(heap_res.owned);
    try std.testing.expect(heap_res.count() > 100);
}

test "object key marking" {
    const cfg = jsmn_default_config();
    const Parser = Jsmn(cfg);

    var toks: [16]Parser.Token = undefined;
    var parents: [16]Parser.IndexT = undefined;
    const json = "{\"key1\":\"value1\",\"key2\":42}";
    const used = try Parser.parseTokens(&toks, &parents, json);

    var compact: [16]Parser.CompactToken = undefined;
    const ccount = try Parser.compressTokens(&toks, used, &compact);

    try std.testing.expect(ccount > 0);
}

test "streaming parse" {
    const cfg = jsmn_default_config();
    const Parser = Jsmn(cfg);

    var toks: [16]Parser.Token = undefined;
    var parents: [16]Parser.IndexT = undefined;
    var state: Parser.ParserState = .{ .pos = 0, .stack_top = 0, .tokens_written = 0 };

    const chunk1 = "{\"key\":\"val";
    const chunk2 = "ue\"}";

    _ = Parser.parseChunk(&state, &toks, &parents, chunk1, false) catch |err| {
        try std.testing.expect(err == Parser.Error.NeedMoreInput);
    };

    const used = try Parser.parseChunk(&state, &toks, &parents, chunk2, true);
    try std.testing.expect(used > 0);
}

test "helper functions" {
    const cfg = jsmn_default_config();
    const Parser = Jsmn(cfg);

    var toks: [16]Parser.Token = undefined;
    var parents: [16]Parser.IndexT = undefined;
    const json = "{\"key1\":\"value1\",\"key2\":42}";
    const used = try Parser.parseTokens(&toks, &parents, json);

    const value_index = Parser.findObjectValue(&toks, used, json, "key2");
    try std.testing.expect(value_index != null);

    const array_items = Parser.getArrayItems(&toks, 0);
    try std.testing.expect(array_items.len == 0);
}
