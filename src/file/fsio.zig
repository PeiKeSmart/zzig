//! 显式传入 `std.Io` 的文件系统工具。
//!
//! 为什么单列：`zzig.compat` 的 Dir/File 走进程级 `currentIo()`，跨线程使用会 panic；
//! 服务端/多线程项目需要把 io 作为显式参数传递，这一层就是那些重复代码的收口。

const std = @import("std");

pub fn cwd() std.Io.Dir {
    return std.Io.Dir.cwd();
}

/// 0.17 的 `readStreaming` 用 `error.EndOfStream` 表示 EOF（不是返回 0）。
pub fn readChunk(io: std.Io, file: std.Io.File, buf: []u8) !usize {
    return file.readStreaming(io, &.{buf}) catch |e| switch (e) {
        error.EndOfStream => 0,
        else => return e,
    };
}

pub fn readFileAlloc(io: std.Io, allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    var file = try cwd().openFile(io, path, .{});
    defer file.close(io);

    const len = try file.length(io);
    if (len > max_bytes) return error.FileTooBig;

    const buf = try allocator.alloc(u8, @intCast(len));
    errdefer allocator.free(buf);

    var read: usize = 0;
    while (read < buf.len) {
        const n = try readChunk(io, file, buf[read..]);
        if (n == 0) break;
        read += n;
    }
    return buf[0..read];
}

pub fn writeFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var file = try cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}

/// 原子写：先写 `<path>.tmp`，再替换目标（Windows 上先删目标再改名）。
pub fn writeFileAtomic(io: std.Io, allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
    const tmp = try std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
    defer allocator.free(tmp);
    try writeFile(io, tmp, bytes);
    try replaceFile(io, tmp, path);
}

pub fn makePath(io: std.Io, path: []const u8) !void {
    try cwd().createDirPath(io, path);
}

pub fn ensureParent(io: std.Io, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |dir| {
        if (dir.len > 0) try makePath(io, dir);
    }
}

pub fn deleteFile(io: std.Io, path: []const u8) !void {
    try cwd().deleteFile(io, path);
}

pub fn rename(io: std.Io, from: []const u8, to: []const u8) !void {
    try std.Io.Dir.rename(cwd(), from, cwd(), to, io);
}

pub fn replaceFile(io: std.Io, from: []const u8, to: []const u8) !void {
    try ensureParent(io, to);
    cwd().deleteFile(io, to) catch |e| switch (e) {
        error.FileNotFound => {},
        else => return e,
    };
    try rename(io, from, to);
}

pub fn statFile(io: std.Io, path: []const u8) !std.Io.File.Stat {
    return cwd().statFile(io, path, .{});
}

pub fn exists(io: std.Io, path: []const u8) bool {
    _ = statFile(io, path) catch return false;
    return true;
}

pub fn openDirIterable(io: std.Io, path: []const u8) !std.Io.Dir {
    return cwd().openDir(io, path, .{ .iterate = true });
}

/// 解析为绝对路径（不要求目标已存在）。
pub fn absolutePath(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);

    const cwd_abs = try cwd().realPathFileAlloc(io, ".", allocator);
    defer allocator.free(cwd_abs);
    return std.fs.path.resolve(allocator, &.{ cwd_abs, path });
}
