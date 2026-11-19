//! HTTP 请求体读取：Content-Length 与 `chunked` 传输编码（含 trailer 校验）。
//!
//! **收编自 lighting**（<https://github.com/jiacai2050/lighting>，MIT License）。
//! 与上游的差异：
//! - 去掉每次读的 `deadline` 参数（本库的超时由**连接层**统一控制，见 `socket_timeout`），
//!   读 socket 直接走 `std.Io.net.Stream.read`；
//! - 其余分块状态机与校验规则保持一致（bare LF、重复 CR、chunk 扩展、trailer 语法、
//!   禁用 trailer 字段名单等）。
//!
//! 为什么需要它：`Content-Length` 好办，`chunked` 的解码（chunk-size 行 / 尾部 CRLF /
//! trailer 到终止空行）容易写漏边界 —— 漏一处就是请求走私或连接卡死。

const std = @import("std");

/// 请求体读取器：先从「头解析时一并读进来的剩余字节」里消费，再读 socket。
pub const BodyReader = struct {
    stream: std.Io.net.Stream,
    io: std.Io,
    unread_slice: []const u8,
    remaining_content_length: ?u64,
    is_chunked: bool,
    chunk_remaining: u64 = 0,
    chunk_done: bool = false,

    pub fn init(
        stream: std.Io.net.Stream,
        io: std.Io,
        initial_unread: []const u8,
        content_length: ?u64,
        is_chunked: bool,
    ) BodyReader {
        return .{
            .stream = stream,
            .io = io,
            .unread_slice = initial_unread,
            .remaining_content_length = content_length,
            .is_chunked = is_chunked,
        };
    }

    /// 读最多 `dest.len` 字节；返回 0 表示 body 结束。
    pub fn read(self: *BodyReader, dest: []u8) !usize {
        if (dest.len == 0) return 0;
        if (self.is_chunked) return self.readChunked(dest);

        if (self.remaining_content_length) |rem| {
            if (rem == 0) return 0;
            const to_read = @min(dest.len, @as(usize, @intCast(@min(rem, @as(u64, std.math.maxInt(usize))))));

            if (self.unread_slice.len > 0) {
                const take = @min(self.unread_slice.len, to_read);
                @memcpy(dest[0..take], self.unread_slice[0..take]);
                self.unread_slice = self.unread_slice[take..];
                self.remaining_content_length.? -= take;
                return take;
            }

            const n = try self.readSocket(dest[0..to_read]);
            if (n == 0) return error.UnexpectedEOF; // 声明了更多内容但连接提前关闭
            self.remaining_content_length.? -= n;
            return n;
        }

        return 0; // 既无 Content-Length 也非 chunked：没有 body
    }

    /// 一次性读完剩余 body（上限 `max_size`，超出返回 `error.StreamTooLong`）。
    /// 返回值由 `allocator` 分配，调用方负责释放（本库传的是每请求 arena）。
    pub fn readAllAlloc(self: *BodyReader, allocator: std.mem.Allocator, max_size: usize) ![]u8 {
        if (self.remaining_content_length) |rem| {
            if (rem > max_size) return error.StreamTooLong;
        }

        var list = std.ArrayListUnmanaged(u8).empty;
        errdefer list.deinit(allocator);

        var buf: [4096]u8 = undefined;
        while (true) {
            const n = try self.read(&buf);
            if (n == 0) break;
            if (list.items.len + n > max_size) return error.StreamTooLong;
            try list.appendSlice(allocator, buf[0..n]);
        }
        return list.toOwnedSlice(allocator);
    }

    // ── 内部 ──

    fn readSocket(self: *BodyReader, dest: []u8) !usize {
        var slices: [1][]u8 = .{dest};
        return self.stream.read(self.io, &slices) catch |e| return e;
    }

    fn readChunked(self: *BodyReader, dest: []u8) !usize {
        if (self.chunk_done) return 0;

        // 正在某个 chunk 内：先给它
        if (self.chunk_remaining > 0) {
            const to_read = @min(dest.len, @as(usize, @intCast(@min(self.chunk_remaining, @as(u64, std.math.maxInt(usize))))));
            var n: usize = 0;
            if (self.unread_slice.len > 0) {
                n = @min(self.unread_slice.len, to_read);
                @memcpy(dest[0..n], self.unread_slice[0..n]);
                self.unread_slice = self.unread_slice[n..];
            } else {
                n = try self.readSocket(dest[0..to_read]);
                if (n == 0) return error.UnexpectedEOF;
            }
            self.chunk_remaining -= n;
            if (self.chunk_remaining == 0) try self.consumeExact("\r\n");
            return n;
        }

        // 读下一个 chunk 的大小行
        const chunk_sz = try self.readChunkSize();
        if (chunk_sz == 0) {
            self.chunk_done = true;
            // 0 长度块之后是可选 trailer，以空行结束
            var total_trailer_bytes: usize = 0;
            const max_trailer_bytes: usize = 16 * 1024;
            var trailer_buf: [1024]u8 = undefined;
            while (true) {
                const trailer_len = try self.readTrailerLine(&trailer_buf);
                if (trailer_len == 0) break;
                total_trailer_bytes += trailer_len + 2;
                if (total_trailer_bytes > max_trailer_bytes) return error.TrailerTooLarge;
            }
            return 0;
        }

        self.chunk_remaining = chunk_sz;
        return self.readChunked(dest);
    }

    fn readByte(self: *BodyReader) !u8 {
        if (self.unread_slice.len > 0) {
            const b = self.unread_slice[0];
            self.unread_slice = self.unread_slice[1..];
            return b;
        }
        var buf: [1]u8 = undefined;
        const n = try self.readSocket(&buf);
        if (n == 0) return error.UnexpectedEOF;
        return buf[0];
    }

    fn readTrailerLine(self: *BodyReader, out_buf: []u8) !usize {
        var len: usize = 0;
        var cr_seen = false;
        while (len < out_buf.len) {
            const b = try self.readByte();
            if (b == '\n') {
                if (!cr_seen) return error.InvalidTrailerCRLF; // 裸 LF 禁止
                break;
            }
            if (b == '\r') {
                if (cr_seen) return error.InvalidTrailerCRLF;
                cr_seen = true;
                continue;
            }
            if (cr_seen) return error.InvalidTrailerCRLF;
            out_buf[len] = b;
            len += 1;
        }
        if (len == out_buf.len and !cr_seen) {
            // 行恰好填满缓冲：确认紧跟 CRLF
            const next_b = try self.readByte();
            if (next_b == '\r') {
                const next_lf = try self.readByte();
                if (next_lf != '\n') return error.InvalidTrailerCRLF;
            } else {
                return error.LineTooLong;
            }
        }

        if (len == 0) return 0; // 终止空行

        // trailer 字段行语法校验（RFC 9112 §7.1.2）
        const colon_idx = std.mem.indexOfScalar(u8, out_buf[0..len], ':') orelse return error.InvalidTrailerHeader;
        const raw_name = out_buf[0..colon_idx];
        if (raw_name.len == 0) return error.InvalidTrailerHeader;
        if (raw_name[raw_name.len - 1] == ' ' or raw_name[raw_name.len - 1] == '\t') return error.InvalidTrailerHeader;
        for (raw_name) |c| {
            if (!isValidTokenChar(c)) return error.InvalidTrailerHeader;
        }
        if (!isValidHeaderValue(out_buf[colon_idx + 1 .. len])) return error.InvalidTrailerHeader;

        // RFC 9110 §6.5.1：禁止出现在 trailer 的字段
        if (std.ascii.eqlIgnoreCase(raw_name, "transfer-encoding") or
            std.ascii.eqlIgnoreCase(raw_name, "content-length") or
            std.ascii.eqlIgnoreCase(raw_name, "host") or
            std.ascii.eqlIgnoreCase(raw_name, "trailer") or
            std.ascii.eqlIgnoreCase(raw_name, "authorization") or
            std.ascii.eqlIgnoreCase(raw_name, "set-cookie"))
        {
            return error.ForbiddenTrailerField;
        }

        return len;
    }

    fn consumeExact(self: *BodyReader, expected: []const u8) !void {
        for (expected) |exp_b| {
            const b = try self.readByte();
            if (b != exp_b) return error.InvalidChunk;
        }
    }

    fn readChunkSize(self: *BodyReader) !u64 {
        var line_buf: [64]u8 = undefined;
        var len: usize = 0;
        var cr_seen = false;
        while (len < line_buf.len) {
            const b = try self.readByte();
            if (b == '\n') {
                if (!cr_seen) return error.InvalidChunkCRLF;
                break;
            }
            if (b == '\r') {
                if (cr_seen) return error.InvalidChunkCRLF;
                cr_seen = true;
                continue;
            }
            if (cr_seen) return error.InvalidChunkCRLF;
            line_buf[len] = b;
            len += 1;
        }
        if (len == line_buf.len and !cr_seen) {
            const next_b = try self.readByte();
            if (next_b == '\r') {
                const next_lf = try self.readByte();
                if (next_lf != '\n') return error.InvalidChunkCRLF;
            } else {
                return error.InvalidChunkSize;
            }
        }

        var hex_str = std.mem.trim(u8, line_buf[0..len], " \t");
        if (hex_str.len == 0) return error.InvalidChunkSize;
        // 允许 chunk 扩展：`1a;ext=val`
        if (std.mem.indexOfScalar(u8, hex_str, ';')) |semi| {
            hex_str = std.mem.trim(u8, hex_str[0..semi], " \t");
        }
        return std.fmt.parseInt(u64, hex_str, 16) catch return error.InvalidChunkSize;
    }
};

fn isValidTokenChar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

fn isValidHeaderValue(value: []const u8) bool {
    for (value) |c| {
        if (c == '\r' or c == '\n') return false;
        if (c < 0x20 and c != '\t') return false;
        if (c == 0x7f) return false;
    }
    return true;
}

// ── 测试：全部用「缓冲区里已有 body」的模式，不需要真 socket ──

test "BodyReader: chunked 合法载荷" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const dummy: std.Io.net.Stream = undefined;
    const raw = "5\r\nhello\r\n0\r\n\r\n";
    var r = BodyReader.init(dummy, io, raw, null, true);
    var buf: [16]u8 = undefined;
    const n = try r.read(&buf);
    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expectEqualStrings("hello", buf[0..n]);
    try std.testing.expectEqual(@as(usize, 0), try r.read(&buf));
}

test "BodyReader: 拒绝裸 LF 的 chunk 大小行" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const dummy: std.Io.net.Stream = undefined;
    var r = BodyReader.init(dummy, io, "5\nhello\r\n0\r\n\r\n", null, true);
    var buf: [16]u8 = undefined;
    try std.testing.expectError(error.InvalidChunkCRLF, r.read(&buf));
}

test "BodyReader: Content-Length 从初始缓冲取" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const dummy: std.Io.net.Stream = undefined;
    var r = BodyReader.init(dummy, io, "abcdef", 3, false);
    var buf: [16]u8 = undefined;
    const n = try r.read(&buf);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("abc", buf[0..n]);
}

test "BodyReader: readAllAlloc 超上限报 StreamTooLong" {
    const io = std.Io.Threaded.global_single_threaded.io();
    const dummy: std.Io.net.Stream = undefined;
    var r = BodyReader.init(dummy, io, "", 100, false);
    try std.testing.expectError(error.StreamTooLong, r.readAllAlloc(std.testing.allocator, 10));
}
