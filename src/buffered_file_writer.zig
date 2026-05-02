const std = @import("std");
const compat = @import("compat.zig");
const fs = compat.fs;

pub const BufferedFileWriter = struct {
    file: fs.File,
    buffer: [4096]u8 = undefined,
    used: usize = 0,

    pub fn init(file: fs.File) BufferedFileWriter {
        return .{ .file = file };
    }

    pub fn flush(self: *@This()) !void {
        if (self.used == 0) return;
        try self.file.writeAll(self.buffer[0..self.used]);
        self.used = 0;
    }

    pub fn writeAll(self: *@This(), bytes: []const u8) !void {
        if (bytes.len >= self.buffer.len) {
            try self.flush();
            try self.file.writeAll(bytes);
            return;
        }

        if (self.used + bytes.len > self.buffer.len) {
            try self.flush();
        }

        @memcpy(self.buffer[self.used..][0..bytes.len], bytes);
        self.used += bytes.len;
    }

    pub fn writeByte(self: *@This(), byte: u8) !void {
        if (self.used == self.buffer.len) {
            try self.flush();
        }

        self.buffer[self.used] = byte;
        self.used += 1;
    }

    pub fn print(self: *@This(), comptime fmt: []const u8, args: anytype) !void {
        try std.fmt.format(self, fmt, args);
    }
};
