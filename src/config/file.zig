//! 配置文本热加载（对齐 DH.RustBase `reload_if_changed` 的口径）：
//! - 文件不存在 → 按模板生成（原子写）；
//! - 每周期只做一次 `stat`（mtime + size），无变化零读盘零解析；
//! - 读失败保留旧文本并记录一条 note；
//! - 保存为原子写（.tmp + 改名），成功后刷新版本戳。
//!
//! 解析由调用方负责（TOML/JSON/XML 都行），本模块只管文本与版本戳。

const std = @import("std");
const fsio = @import("../file/fsio.zig");

pub const Stamp = struct {
    mtime_ms: i64,
    size: u64,
};

pub const Options = struct {
    create_on_missing: bool = true,
    /// 单文件上限，防误读超大文件
    max_bytes: usize = 4 * 1024 * 1024,
};

pub const FileText = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    path: []u8,
    template: []const u8,
    text: []u8,
    stamp: ?Stamp,
    notes: std.ArrayList([]u8) = .empty,

    pub fn open(
        io: std.Io,
        gpa: std.mem.Allocator,
        path: []const u8,
        template: []const u8,
        opts: Options,
    ) !FileText {
        const path_owned = try gpa.dupe(u8, path);
        errdefer gpa.free(path_owned);

        var self = FileText{
            .io = io,
            .gpa = gpa,
            .path = path_owned,
            .template = template,
            .text = &.{},
            .stamp = null,
        };
        errdefer self.notes.deinit(gpa);

        if (getStamp(io, path)) |st| {
            self.stamp = st;
            self.text = fsio.readFileAlloc(io, gpa, path, opts.max_bytes) catch |e| blk: {
                const note = try std.fmt.allocPrint(gpa, "读取配置失败（已用模板内容）：{s}（{s}）", .{ path, @errorName(e) });
                try self.notes.append(gpa, note);
                break :blk try gpa.dupe(u8, template);
            };
        } else if (opts.create_on_missing) {
            // 父目录可能还不存在（首次运行 `Config/` 尚未创建）：先建目录再原子写，
            // 否则 Windows 上 createFile 直接报 FileNotFound，配置生成功能形同虚设。
            if (std.fs.path.dirname(path)) |dir| {
                if (dir.len > 0) fsio.makePath(io, dir) catch {};
            }
            try fsio.writeFileAtomic(io, gpa, path, template);
            self.text = try gpa.dupe(u8, template);
            self.stamp = getStamp(io, path);
            const note = try std.fmt.allocPrint(gpa, "已生成默认配置：{s}", .{path});
            try self.notes.append(gpa, note);
        } else {
            return error.FileNotFound;
        }
        return self;
    }

    pub fn deinit(self: *FileText) void {
        for (self.notes.items) |n| self.gpa.free(n);
        self.notes.deinit(self.gpa);
        self.gpa.free(self.text);
        self.gpa.free(self.path);
    }

    pub fn current(self: *const FileText) []const u8 {
        return self.text;
    }

    /// 是否发生变化；变化时把新文本写入 `text`（调用方随后重新解析）。
    /// 解析失败由调用方决定是否保留旧配置（本函数不关心解析）。
    pub fn reloadIfChanged(self: *FileText, opts: Options) !bool {
        const now = getStamp(self.io, self.path) orelse {
            // 文件被删除：继续用内存中的文本，只记录一次
            if (self.stamp != null) {
                self.stamp = null;
                const note = try std.fmt.allocPrint(self.gpa, "配置文件被删除（继续使用内存中的配置）：{s}", .{self.path});
                try self.notes.append(self.gpa, note);
            }
            return false;
        };
        if (self.stamp) |old| {
            if (old.mtime_ms == now.mtime_ms and old.size == now.size) return false;
        }

        const text = fsio.readFileAlloc(self.io, self.gpa, self.path, opts.max_bytes) catch |e| {
            self.stamp = now;
            const note = try std.fmt.allocPrint(self.gpa, "配置文件读取失败（保持当前配置）：{s}（{s}）", .{ self.path, @errorName(e) });
            try self.notes.append(self.gpa, note);
            return false;
        };

        self.gpa.free(self.text);
        self.text = text;
        self.stamp = now;
        return true;
    }

    /// 原子写并刷新版本戳。
    pub fn save(self: *FileText, text: []const u8) !void {
        try fsio.writeFileAtomic(self.io, self.gpa, self.path, text);
        self.gpa.free(self.text);
        self.text = try self.gpa.dupe(u8, text);
        self.stamp = getStamp(self.io, self.path);
    }

    pub fn clearNotes(self: *FileText) void {
        for (self.notes.items) |n| self.gpa.free(n);
        self.notes.clearRetainingCapacity();
    }
};

pub fn getStamp(io: std.Io, path: []const u8) ?Stamp {
    const st = fsio.statFile(io, path) catch return null;
    if (st.kind != .file) return null;
    return .{ .mtime_ms = st.mtime.toMilliseconds(), .size = st.size };
}

const testing = std.testing;
const test_gpa = std.heap.page_allocator;

test "config file: 缺失生成 + 变化检测 + 原子写" {
    const io = std.testing.io;
    var dir = std.testing.tmpDir(.{});
    defer dir.cleanup();
    const base = try dir.dir.realPathFileAlloc(io, ".", testing.allocator);
    defer testing.allocator.free(base);
    const path = try std.fs.path.join(testing.allocator, &.{ base, "c.toml" });
    defer testing.allocator.free(path);

    var f = try FileText.open(io, test_gpa, path, "x = 1\n", .{});
    defer f.deinit();
    try testing.expectEqualStrings("x = 1\n", f.current());
    try testing.expect(f.notes.items.len >= 1);
    f.clearNotes();

    try testing.expect(!try f.reloadIfChanged(.{}));

    try f.save("x = 2\n");
    try testing.expectEqualStrings("x = 2\n", f.current());
    try testing.expect(!try f.reloadIfChanged(.{}));

    // 模拟外部修改（内容长度不同，确保 size 变化）
    try fsio.writeFile(io, path, "x = 22\n");
    try testing.expect(try f.reloadIfChanged(.{}));
    try testing.expectEqualStrings("x = 22\n", f.current());
}
