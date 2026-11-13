//! 最小可用的 ZIP 归档（**store** / **deflate** 两种方法）。
//!
//! 用途：多文件归档（数据包 `BackupAll` / `RestoreAll`、导出包、按表分文件备份）。
//! 只实现「写多条目 + 读回」这一条主线，明确**不支持**：加密、ZIP64（>4GB）、
//! 数据描述符（flag bit 3，本实现写前已知 CRC 与长度）、跨卷。
//!
//! 结构（PKZIP 2.0）：
//!
//! ```text
//! [local header][file data]×N  [central directory]  [EOCD]
//! ```
//!
//! 与 `zzig.http.gzipCompressAlloc` 的分工：
//! - 单流压缩（`DbPackage` 的 `.gz`、HTTP 响应）→ 用 gzip（`http.gz*`）；
//! - 多文件归档（每个表一个条目）→ 用本模块（`.zip`）。
//!
//! ```
//! var w = zip.Writer.init(gpa);
//! defer w.deinit();
//! try w.addEntry("Model.xml", xml, .deflate);
//! try w.addEntry("User.zcode", data, .deflate);
//! const bytes = try w.finish();          // 调用方 free
//! ```

const std = @import("std");
const compat = @import("../compat.zig");
const flate = std.compress.flate;

/// 压缩方法（ZIP 规范里的 method 字段）。
pub const Method = enum(u16) {
    store = 0,
    deflate = 8,
};

pub const Error = error{
    /// 不是合法 ZIP（找不到 EOCD / 中央目录损坏）
    NotZip,
    /// 条目用了本模块不支持的压缩方法（加密、lzma、zstd 等）
    UnsupportedMethod,
    /// 条目名不存在
    EntryNotFound,
    /// 解压后长度与中央目录记录不一致（截断或损坏）
    Corrupted,
};

/// UTF-8 文件名标志（general purpose bit 11）：非 ASCII 名必须置位，否则解压端按 CP437 解码。
const flag_utf8: u16 = 1 << 11;
const version_needed: u16 = 20; // 2.0：deflate + 目录

const sig_local = 0x04034b50;
const sig_central = 0x02014b50;
const sig_eocd = 0x06054b50;

const local_header_len = 30;
const central_header_len = 46;
const eocd_len = 22;

pub const Entry = struct {
    /// 归档内路径（UTF-8，`/` 分隔）
    name: []const u8,
    method: Method,
    crc32: u32,
    compressed_size: u64,
    uncompressed_size: u64,
    /// 本地文件头在归档内的偏移
    local_offset: u64,
};

// ── 写 ──────────────────────────────────────────────────────────────────────

pub const Writer = struct {
    gpa: std.mem.Allocator,
    buf: std.ArrayListUnmanaged(u8) = .empty,
    entries: std.ArrayListUnmanaged(Entry) = .empty,
    /// DOS 格式的修改时间/日期（两个 u16；缺省取当前时间）
    dos_time: u16 = 0,
    dos_date: u16 = 0,

    pub fn init(gpa: std.mem.Allocator) Writer {
        const now = dosNow();
        return .{ .gpa = gpa, .dos_time = now.time, .dos_date = now.date };
    }

    pub fn deinit(self: *Writer) void {
        for (self.entries.items) |e| self.gpa.free(e.name);
        self.entries.deinit(self.gpa);
        self.buf.deinit(self.gpa);
    }

    /// 追加一个条目。`data` 在返回前**全部复制**进归档缓冲，调用方可立刻释放。
    pub fn addEntry(self: *Writer, name: []const u8, data: []const u8, method: Method) !void {
        if (name.len == 0 or name.len > 0xFFFF) return error.InvalidName;
        const crc = std.hash.Crc32.hash(data);

        const offset = self.buf.items.len;
        var payload: []const u8 = data;
        var compressed: ?[]u8 = null;
        defer if (compressed) |c| self.gpa.free(c);

        if (method == .deflate) {
            compressed = try deflateAlloc(self.gpa, data);
            payload = compressed.?;
            // 压不小就不压（ZIP 允许每条目自选方法，读端按 method 字段处理）
            if (payload.len >= data.len) {
                self.gpa.free(compressed.?);
                compressed = null;
                payload = data;
            }
        }
        const use_method: Method = if (compressed != null) .deflate else .store;

        var hdr: [local_header_len]u8 = undefined;
        std.mem.writeInt(u32, hdr[0..4], sig_local, .little);
        std.mem.writeInt(u16, hdr[4..6], version_needed, .little);
        std.mem.writeInt(u16, hdr[6..8], flag_utf8, .little);
        std.mem.writeInt(u16, hdr[8..10], @backingInt(use_method), .little);
        std.mem.writeInt(u16, hdr[10..12], self.dos_time, .little);
        std.mem.writeInt(u16, hdr[12..14], self.dos_date, .little);
        std.mem.writeInt(u32, hdr[14..18], crc, .little);
        std.mem.writeInt(u32, hdr[18..22], @intCast(payload.len), .little);
        std.mem.writeInt(u32, hdr[22..26], @intCast(data.len), .little);
        std.mem.writeInt(u16, hdr[26..28], @intCast(name.len), .little);
        std.mem.writeInt(u16, hdr[28..30], 0, .little); // extra len

        try self.buf.appendSlice(self.gpa, &hdr);
        try self.buf.appendSlice(self.gpa, name);
        try self.buf.appendSlice(self.gpa, payload);

        try self.entries.append(self.gpa, .{
            .name = try self.gpa.dupe(u8, name),
            .method = use_method,
            .crc32 = crc,
            .compressed_size = payload.len,
            .uncompressed_size = data.len,
            .local_offset = offset,
        });
    }

    /// 写中央目录 + EOCD，返回整个归档（调用方 free）。
    ///
    /// 可以多次调用（每次返回同一份完整归档），便于「先落盘再继续追加」的调用方。
    pub fn finish(self: *Writer) ![]u8 {
        const cd_offset = self.buf.items.len;

        for (self.entries.items) |e| {
            var hdr: [central_header_len]u8 = undefined;
            std.mem.writeInt(u32, hdr[0..4], sig_central, .little);
            std.mem.writeInt(u16, hdr[4..6], version_needed, .little); // version made by
            std.mem.writeInt(u16, hdr[6..8], version_needed, .little); // version needed
            std.mem.writeInt(u16, hdr[8..10], flag_utf8, .little);
            std.mem.writeInt(u16, hdr[10..12], @backingInt(e.method), .little);
            std.mem.writeInt(u16, hdr[12..14], self.dos_time, .little);
            std.mem.writeInt(u16, hdr[14..16], self.dos_date, .little);
            std.mem.writeInt(u32, hdr[16..20], e.crc32, .little);
            std.mem.writeInt(u32, hdr[20..24], @intCast(e.compressed_size), .little);
            std.mem.writeInt(u32, hdr[24..28], @intCast(e.uncompressed_size), .little);
            std.mem.writeInt(u16, hdr[28..30], @intCast(e.name.len), .little);
            std.mem.writeInt(u16, hdr[30..32], 0, .little); // extra
            std.mem.writeInt(u16, hdr[32..34], 0, .little); // comment
            std.mem.writeInt(u16, hdr[34..36], 0, .little); // disk start
            std.mem.writeInt(u16, hdr[36..38], 0, .little); // internal attrs
            std.mem.writeInt(u32, hdr[38..42], 0, .little); // external attrs
            std.mem.writeInt(u32, hdr[42..46], @intCast(e.local_offset), .little);

            try self.buf.appendSlice(self.gpa, &hdr);
            try self.buf.appendSlice(self.gpa, e.name);
        }

        const cd_size = self.buf.items.len - cd_offset;

        var eocd: [eocd_len]u8 = undefined;
        std.mem.writeInt(u32, eocd[0..4], sig_eocd, .little);
        std.mem.writeInt(u16, eocd[4..6], 0, .little); // 本盘号
        std.mem.writeInt(u16, eocd[6..8], 0, .little); // 中央目录起始盘
        std.mem.writeInt(u16, eocd[8..10], @intCast(self.entries.items.len), .little);
        std.mem.writeInt(u16, eocd[10..12], @intCast(self.entries.items.len), .little);
        std.mem.writeInt(u32, eocd[12..16], @intCast(cd_size), .little);
        std.mem.writeInt(u32, eocd[16..20], @intCast(cd_offset), .little);
        std.mem.writeInt(u16, eocd[20..22], 0, .little); // comment len
        try self.buf.appendSlice(self.gpa, &eocd);

        return self.buf.toOwnedSlice(self.gpa);
    }
};

// ── 读 ──────────────────────────────────────────────────────────────────────

pub const Reader = struct {
    gpa: std.mem.Allocator,
    bytes: []const u8,
    entries: []Entry,
    owned_names: [][]u8,

    /// 解析中央目录。`bytes` 必须活得比 Reader 久（只借用，不复制归档本体）。
    pub fn init(gpa: std.mem.Allocator, bytes: []const u8) !Reader {
        const eocd = findEocd(bytes) orelse return Error.NotZip;
        const count = std.mem.readInt(u16, eocd[10..12], .little); // 总条目数
        const cd_size = std.mem.readInt(u32, eocd[12..16], .little);
        const cd_offset = std.mem.readInt(u32, eocd[16..20], .little);
        if (@as(u64, cd_offset) + cd_size > bytes.len) return Error.NotZip;

        var entries = try gpa.alloc(Entry, count);
        errdefer gpa.free(entries);
        var names = try gpa.alloc([]u8, count);
        errdefer gpa.free(names);

        var parsed: usize = 0;
        errdefer {
            for (names[0..parsed]) |n| gpa.free(n);
        }

        var pos: usize = cd_offset;
        while (parsed < count) : (parsed += 1) {
            if (pos + central_header_len > bytes.len) return Error.NotZip;
            if (std.mem.readInt(u32, bytes[pos..][0..4], .little) != sig_central) return Error.NotZip;

            const name_len = std.mem.readInt(u16, bytes[pos + 28 ..][0..2], .little);
            const extra_len = std.mem.readInt(u16, bytes[pos + 30 ..][0..2], .little);
            const comment_len = std.mem.readInt(u16, bytes[pos + 32 ..][0..2], .little);
            const method_bits = std.mem.readInt(u16, bytes[pos + 10 ..][0..2], .little);

            const name_start = pos + central_header_len;
            if (name_start + name_len > bytes.len) return Error.NotZip;

            names[parsed] = try gpa.dupe(u8, bytes[name_start .. name_start + name_len]);
            entries[parsed] = .{
                .name = names[parsed],
                .method = std.enums.fromInt(Method, method_bits) orelse return Error.UnsupportedMethod,
                .crc32 = std.mem.readInt(u32, bytes[pos + 16 ..][0..4], .little),
                .compressed_size = std.mem.readInt(u32, bytes[pos + 20 ..][0..4], .little),
                .uncompressed_size = std.mem.readInt(u32, bytes[pos + 24 ..][0..4], .little),
                .local_offset = std.mem.readInt(u32, bytes[pos + 42 ..][0..4], .little),
            };

            pos = name_start + name_len + extra_len + comment_len;
        }

        return .{ .gpa = gpa, .bytes = bytes, .entries = entries, .owned_names = names };
    }

    pub fn deinit(self: *Reader) void {
        for (self.owned_names) |n| self.gpa.free(n);
        self.gpa.free(self.owned_names);
        self.gpa.free(self.entries);
    }

    pub fn find(self: *const Reader, name: []const u8) ?usize {
        for (self.entries, 0..) |e, i| {
            if (std.mem.eql(u8, e.name, name)) return i;
        }
        return null;
    }

    /// 解出第 `index` 个条目的原始内容（调用方 free）。CRC 与长度都会校验。
    pub fn extractAlloc(self: *const Reader, index: usize) ![]u8 {
        if (index >= self.entries.len) return Error.EntryNotFound;
        const e = self.entries[index];

        const hdr_off = e.local_offset;
        if (hdr_off + local_header_len > self.bytes.len) return Error.Corrupted;
        if (std.mem.readInt(u32, self.bytes[hdr_off..][0..4], .little) != sig_local) return Error.Corrupted;

        const name_len = std.mem.readInt(u16, self.bytes[hdr_off + 26 ..][0..2], .little);
        const extra_len = std.mem.readInt(u16, self.bytes[hdr_off + 28 ..][0..2], .little);
        const data_start = hdr_off + local_header_len + name_len + extra_len;
        const data_end = data_start + e.compressed_size;
        if (data_end > self.bytes.len) return Error.Corrupted;
        const payload = self.bytes[data_start..data_end];

        const out = try self.gpa.alloc(u8, e.uncompressed_size);
        errdefer self.gpa.free(out);

        switch (e.method) {
            .store => {
                if (payload.len != out.len) return Error.Corrupted;
                @memcpy(out, payload);
            },
            .deflate => {
                var input: std.Io.Reader = .fixed(payload);
                const window = try self.gpa.alloc(u8, flate.max_window_len);
                defer self.gpa.free(window);
                var dec = flate.Decompress.init(&input, .raw, window);
                const n = dec.reader.readSliceShort(out) catch return Error.Corrupted;
                if (n != out.len) return Error.Corrupted;
                if (dec.err) |_| return Error.Corrupted;
            },
        }

        if (std.hash.Crc32.hash(out) != e.crc32) return Error.Corrupted;
        return out;
    }

    /// 按名字解出（不存在返回 `EntryNotFound`）。
    pub fn extractByNameAlloc(self: *const Reader, name: []const u8) ![]u8 {
        const idx = self.find(name) orelse return Error.EntryNotFound;
        return self.extractAlloc(idx);
    }
};

// ── 内部 ────────────────────────────────────────────────────────────────────

fn findEocd(bytes: []const u8) ?[]const u8 {
    if (bytes.len < eocd_len) return null;
    // EOCD 末尾可能有注释（最长 65535），从尾部往前找签名
    const max_back = @min(bytes.len - eocd_len, 0xFFFF + eocd_len);
    var i: usize = 0;
    while (i <= max_back) : (i += 1) {
        const pos = bytes.len - eocd_len - i;
        if (std.mem.readInt(u32, bytes[pos..][0..4], .little) == sig_eocd) {
            return bytes[pos..][0..eocd_len];
        }
    }
    return null;
}

fn deflateAlloc(gpa: std.mem.Allocator, data: []const u8) ![]u8 {
    var output = try std.Io.Writer.Allocating.initCapacity(gpa, @max(data.len / 2, 512));
    errdefer output.deinit();

    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);

    // Compress 结构体约 224K，放堆上避免大栈帧
    const compressor = try gpa.create(flate.Compress);
    defer gpa.destroy(compressor);
    compressor.* = try flate.Compress.init(&output.writer, window, .raw, flate.Compress.Options.default);
    try compressor.writer.writeAll(data);
    try compressor.finish();

    return output.toOwnedSlice();
}

const DosDateTime = struct { time: u16, date: u16 };

/// 当前时间 → DOS 时间/日期（无可用时钟时退回 1980-01-01）。
fn dosNow() DosDateTime {
    const ts = compat.timestamp();
    if (ts <= 0) return .{ .time = 0, .date = (1 << 5) | 1 };
    const epoch_secs: u64 = @intCast(ts);
    const days: u64 = epoch_secs / 86400;
    const secs_of_day: u64 = epoch_secs % 86400;

    // 1970-01-01 → 1980-01-01 差 3653 天（含 2 个闰日 + 1972/1976）
    var y: u64 = 1970;
    var remaining = days;
    while (true) {
        const leap = (y % 4 == 0 and y % 100 != 0) or (y % 400 == 0);
        const ydays: u64 = if (leap) 366 else 365;
        if (remaining < ydays) break;
        remaining -= ydays;
        y += 1;
    }
    var month: u64 = 1;
    while (true) {
        const leap = (y % 4 == 0 and y % 100 != 0) or (y % 400 == 0);
        const mdays: u64 = switch (month) {
            2 => if (leap) 29 else 28,
            4, 6, 9, 11 => 30,
            else => 31,
        };
        if (remaining < mdays) break;
        remaining -= mdays;
        month += 1;
    }
    if (y < 1980) return .{ .time = 0, .date = (1 << 5) | 1 };

    const year_bits: u16 = @intCast(@min(y - 1980, 127));
    const date: u16 = (year_bits << 9) | (@as(u16, @intCast(month)) << 5) | @as(u16, @intCast(remaining + 1));
    const time: u16 = (@as(u16, @intCast(secs_of_day / 3600)) << 11) |
        (@as(u16, @intCast((secs_of_day % 3600) / 60)) << 5) |
        @as(u16, @intCast((secs_of_day % 60) / 2));
    return .{ .time = time, .date = date };
}

// ── 测试 ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "zip 往返：store 与 deflate 混合" {
    const a = testing.allocator;

    var w = Writer.init(a);
    defer w.deinit();

    const small = "abc";
    var big_buf: [4096]u8 = undefined;
    @memset(&big_buf, 'x');
    const big: []const u8 = &big_buf;
    try w.addEntry("Model.xml", small, .store);
    try w.addEntry("Tables/User.zcode", big, .deflate);
    try w.addEntry("空 表.zcode", small, .deflate);

    const bytes = try w.finish();
    defer a.free(bytes);

    var r = try Reader.init(a, bytes);
    defer r.deinit();

    try testing.expectEqual(@as(usize, 3), r.entries.len);
    try testing.expectEqualStrings("Model.xml", r.entries[0].name);
    try testing.expectEqual(Method.store, r.entries[0].method);

    const got_small = try r.extractAlloc(0);
    defer a.free(got_small);
    try testing.expectEqualStrings(small, got_small);

    const got_big = try r.extractAlloc(1);
    defer a.free(got_big);
    try testing.expectEqualStrings(big, got_big);
    // 重复字符应该压得动：解压后长度一致且压缩后更小
    try testing.expect(r.entries[1].compressed_size < r.entries[1].uncompressed_size);

    const got_cn = try r.extractByNameAlloc("空 表.zcode");
    defer a.free(got_cn);
    try testing.expectEqualStrings(small, got_cn);

    try testing.expectError(Error.EntryNotFound, r.extractByNameAlloc("NoSuch"));
}

test "zip 条目内容不随调用方缓冲释放而失效" {
    const a = testing.allocator;
    var w = Writer.init(a);
    defer w.deinit();

    {
        const tmp = try a.alloc(u8, 1024);
        defer a.free(tmp);
        @memset(tmp, 'q');
        try w.addEntry("tmp.bin", tmp, .store);
    }

    const bytes = try w.finish();
    defer a.free(bytes);

    var r = try Reader.init(a, bytes);
    defer r.deinit();
    const out = try r.extractAlloc(0);
    defer a.free(out);
    try testing.expectEqual(@as(usize, 1024), out.len);
    try testing.expectEqual(@as(u8, 'q'), out[1023]);
}

test "zip 损坏归档被拒" {
    const a = testing.allocator;
    try testing.expectError(Error.NotZip, Reader.init(a, "not a zip at all"));
    try testing.expectError(Error.NotZip, Reader.init(a, &.{}));
}

test "zip 空归档可读" {
    const a = testing.allocator;
    var w = Writer.init(a);
    defer w.deinit();
    const bytes = try w.finish();
    defer a.free(bytes);

    var r = try Reader.init(a, bytes);
    defer r.deinit();
    try testing.expectEqual(@as(usize, 0), r.entries.len);
}
