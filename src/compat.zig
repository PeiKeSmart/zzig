const std = @import("std");
const builtin = @import("builtin");

const is_zig_016_or_newer = builtin.zig_version.minor >= 16;

fn currentIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub const GeneralPurposeAllocator = if (is_zig_016_or_newer)
    std.heap.DebugAllocator
else
    std.heap.GeneralPurposeAllocator;

pub const Mutex = if (is_zig_016_or_newer) struct {
    state: std.atomic.Value(u8) = .init(0),

    pub fn lock(self: *@This()) void {
        while (true) {
            if (self.state.cmpxchgWeak(0, 1, .acquire, .monotonic) == null) return;

            while (self.state.load(.monotonic) != 0) {
                std.atomic.spinLoopHint();
                std.Thread.yield() catch {};
            }
        }
    }

    pub fn unlock(self: *@This()) void {
        self.state.store(0, .release);
    }
} else std.Thread.Mutex;

pub fn sleep(ns: u64) void {
    if (is_zig_016_or_newer) {
        switch (builtin.os.tag) {
            .windows => {
                var interval_100ns: i64 = -@as(i64, @intCast(@divTrunc(ns + 99, 100)));
                _ = std.os.windows.ntdll.NtDelayExecution(@enumFromInt(1), &interval_100ns);
            },
            else => {
                var req = std.c.timespec{
                    .sec = @intCast(ns / std.time.ns_per_s),
                    .nsec = @intCast(ns % std.time.ns_per_s),
                };
                while (std.c.nanosleep(&req, &req) != 0) {}
            },
        }
        return;
    }

    std.Thread.sleep(ns);
}

pub fn nanoTimestamp() i128 {
    if (is_zig_016_or_newer) {
        switch (builtin.os.tag) {
            .windows => {
                const windows_os = std.os.windows;
                const GetSystemTimePreciseAsFileTime = struct {
                    extern "kernel32" fn GetSystemTimePreciseAsFileTime(lpSystemTimeAsFileTime: *windows_os.FILETIME) callconv(.winapi) void;
                }.GetSystemTimePreciseAsFileTime;

                var file_time: windows_os.FILETIME = undefined;
                GetSystemTimePreciseAsFileTime(&file_time);

                const ticks_100ns: i128 = (@as(i128, file_time.dwHighDateTime) << 32) | file_time.dwLowDateTime;
                const windows_to_unix_epoch_100ns: i128 = 116_444_736_000_000_000;
                return (ticks_100ns - windows_to_unix_epoch_100ns) * 100;
            },
            else => {
                var ts: std.c.timespec = undefined;
                _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
                return @as(i128, ts.sec) * std.time.ns_per_s + ts.nsec;
            },
        }
    }

    return std.time.nanoTimestamp();
}

pub fn timestamp() i64 {
    if (is_zig_016_or_newer) {
        return @intCast(@divTrunc(nanoTimestamp(), std.time.ns_per_s));
    }

    return std.time.timestamp();
}

pub const File = if (is_zig_016_or_newer) struct {
    inner: std.Io.File,

    pub const Stat = std.Io.File.Stat;

    pub fn close(self: @This()) void {
        self.inner.close(currentIo());
    }

    pub fn stat(self: @This()) !Stat {
        return self.inner.stat(currentIo());
    }

    pub fn getEndPos(self: @This()) !u64 {
        return self.inner.length(currentIo());
    }

    pub fn seekFromEnd(self: @This(), offset: i64) !void {
        const end_pos = try self.getEndPos();
        const target: u64 = if (offset >= 0)
            end_pos + @as(u64, @intCast(offset))
        else
            end_pos - @as(u64, @intCast(-offset));
        try currentIo().vtable.fileSeekTo(currentIo().userdata, self.inner, target);
    }

    pub fn readAll(self: @This(), buffer: []u8) !usize {
        var index: usize = 0;
        while (index < buffer.len) {
            const amt = try self.inner.readStreaming(currentIo(), &.{buffer[index..]});
            if (amt == 0) break;
            index += amt;
        }
        return index;
    }

    pub fn readToEndAlloc(self: @This(), allocator: std.mem.Allocator, max_bytes: usize) ![]u8 {
        const end_pos = try self.getEndPos();
        const capped_len = @min(end_pos, max_bytes);
        const buffer = try allocator.alloc(u8, @intCast(capped_len));
        errdefer allocator.free(buffer);

        const amt = try self.inner.readPositionalAll(currentIo(), buffer, 0);
        return buffer[0..amt];
    }

    pub fn writeAll(self: @This(), bytes: []const u8) !void {
        var index: usize = 0;
        while (index < bytes.len) {
            const written = try self.inner.writeStreaming(currentIo(), "", &.{bytes[index..]}, 1);
            index += written;
        }
    }
} else std.fs.File;

pub const Dir = if (is_zig_016_or_newer) struct {
    inner: std.Io.Dir,

    pub const OpenOptions = std.Io.Dir.OpenOptions;
    pub const OpenFileOptions = std.Io.Dir.OpenFileOptions;
    pub const CreateFileOptions = std.Io.Dir.CreateFileOptions;
    pub const Stat = std.Io.Dir.Stat;

    pub const Iterator = struct {
        inner: std.Io.Dir.Iterator,

        pub fn next(self: *@This()) !?std.Io.Dir.Entry {
            return self.inner.next(currentIo());
        }
    };

    pub fn close(self: @This()) void {
        self.inner.close(currentIo());
    }

    pub fn openFile(self: @This(), sub_path: []const u8, options: OpenFileOptions) !File {
        return .{ .inner = try self.inner.openFile(currentIo(), sub_path, options) };
    }

    pub fn createFile(self: @This(), sub_path: []const u8, options: CreateFileOptions) !File {
        return .{ .inner = try self.inner.createFile(currentIo(), sub_path, options) };
    }

    pub fn openDir(self: @This(), sub_path: []const u8, options: OpenOptions) !Dir {
        return .{ .inner = try self.inner.openDir(currentIo(), sub_path, options) };
    }

    pub fn makePath(self: @This(), sub_path: []const u8) !void {
        try self.inner.createDirPath(currentIo(), sub_path);
    }

    pub fn deleteFile(self: @This(), sub_path: []const u8) !void {
        try self.inner.deleteFile(currentIo(), sub_path);
    }

    pub fn rename(self: @This(), old_sub_path: []const u8, new_sub_path: []const u8) !void {
        try std.Io.Dir.rename(self.inner, old_sub_path, self.inner, new_sub_path, currentIo());
    }

    pub fn statFile(self: @This(), sub_path: []const u8) !Stat {
        return self.inner.statFile(currentIo(), sub_path, .{});
    }

    pub fn iterate(self: @This()) Iterator {
        return .{ .inner = self.inner.iterate() };
    }
} else std.fs.Dir;

pub const fs = struct {
    pub const path = std.fs.path;
    pub const File = compat.File;
    pub const DirType = compat.Dir;

    pub fn cwd() compat.Dir {
        if (is_zig_016_or_newer) {
            return .{ .inner = std.Io.Dir.cwd() };
        }
        return std.fs.cwd();
    }
};

pub fn milliTimestamp() i64 {
    if (is_zig_016_or_newer) {
        return @intCast(@divTrunc(nanoTimestamp(), std.time.ns_per_ms));
    }
    return std.time.milliTimestamp();
}

pub const windows = struct {
    pub const STD_INPUT_HANDLE: std.os.windows.DWORD = @bitCast(@as(i32, -10));
    pub const STD_OUTPUT_HANDLE: std.os.windows.DWORD = @bitCast(@as(i32, -11));

    pub fn getStdHandle(std_handle: std.os.windows.DWORD) ?std.os.windows.HANDLE {
        const winapi = std.builtin.CallingConvention.winapi;
        const GetStdHandle = struct {
            extern "kernel32" fn GetStdHandle(nStdHandle: std.os.windows.DWORD) callconv(winapi) ?std.os.windows.HANDLE;
        }.GetStdHandle;

        return GetStdHandle(std_handle);
    }

    pub fn getConsoleMode(handle: std.os.windows.HANDLE, mode: *std.os.windows.DWORD) std.os.windows.BOOL {
        const GetConsoleMode = struct {
            extern "kernel32" fn GetConsoleMode(
                hConsoleHandle: std.os.windows.HANDLE,
                lpMode: *std.os.windows.DWORD,
            ) callconv(.winapi) std.os.windows.BOOL;
        }.GetConsoleMode;

        return GetConsoleMode(handle, mode);
    }

    pub fn setConsoleMode(handle: std.os.windows.HANDLE, mode: std.os.windows.DWORD) std.os.windows.BOOL {
        const SetConsoleMode = struct {
            extern "kernel32" fn SetConsoleMode(
                hConsoleHandle: std.os.windows.HANDLE,
                dwMode: std.os.windows.DWORD,
            ) callconv(.winapi) std.os.windows.BOOL;
        }.SetConsoleMode;

        return SetConsoleMode(handle, mode);
    }

    pub fn readFile(handle: std.os.windows.HANDLE, buffer: []u8, bytes_read: *std.os.windows.DWORD) std.os.windows.BOOL {
        const ReadFile = struct {
            extern "kernel32" fn ReadFile(
                hFile: std.os.windows.HANDLE,
                lpBuffer: [*]u8,
                nNumberOfBytesToRead: std.os.windows.DWORD,
                lpNumberOfBytesRead: *std.os.windows.DWORD,
                lpOverlapped: ?*anyopaque,
            ) callconv(.winapi) std.os.windows.BOOL;
        }.ReadFile;

        return ReadFile(handle, buffer.ptr, @intCast(buffer.len), bytes_read, null);
    }

    pub fn writeConsoleW(handle: std.os.windows.HANDLE, buffer: []const u16, written: *std.os.windows.DWORD) std.os.windows.BOOL {
        const WriteConsoleW = struct {
            extern "kernel32" fn WriteConsoleW(
                hConsoleOutput: std.os.windows.HANDLE,
                lpBuffer: [*]const u16,
                nNumberOfCharsToWrite: std.os.windows.DWORD,
                lpNumberOfCharsWritten: *std.os.windows.DWORD,
                lpReserved: ?*anyopaque,
            ) callconv(.winapi) std.os.windows.BOOL;
        }.WriteConsoleW;

        return WriteConsoleW(handle, buffer.ptr, @intCast(buffer.len), written, null);
    }
};

const compat = @This();
