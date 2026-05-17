const std = @import("std");
const builtin = @import("builtin");

const is_zig_016_or_newer = builtin.zig_version.minor >= 16;
var current_io_override: ?std.Io = null;

pub fn currentIo() std.Io {
    return current_io_override orelse std.Io.Threaded.global_single_threaded.io();
}

pub fn setCurrentIo(io: std.Io) void {
    current_io_override = io;
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

    pub fn realpathAlloc(self: @This(), allocator: std.mem.Allocator, sub_path: []const u8) ![:0]u8 {
        return self.inner.realPathFileAlloc(currentIo(), sub_path, allocator);
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

pub const process = struct {
    pub fn run(allocator: std.mem.Allocator, options: std.process.RunOptions) std.process.RunError!std.process.RunResult {
        return std.process.run(allocator, currentIo(), options);
    }
};

const ConnectResult = struct {
    stream: ?std.Io.net.Stream = null,
    err: ?anyerror = null,
    completed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

pub const net = struct {
    pub fn connectTcp(ip_text: []const u8, port: u16) !std.Io.net.Stream {
        const address = try std.Io.net.IpAddress.parse(ip_text, port);
        return std.Io.net.IpAddress.connect(&address, currentIo(), .{ .mode = .stream, .protocol = .tcp });
    }

    pub fn connectTcpWithTimeout(ip_text: []const u8, port: u16, timeout_ms: u32, poll_interval_ms: u64) !std.Io.net.Stream {
        if (timeout_ms == 0) return connectTcp(ip_text, port);

        const io = currentIo();
        var result = ConnectResult{};
        var future = io.concurrent(connectTcpWorker, .{ ip_text, port, &result }) catch |err| switch (err) {
            error.ConcurrencyUnavailable => return connectTcp(ip_text, port),
        };

        const timeout_ns: i128 = @as(i128, @intCast(timeout_ms)) * std.time.ns_per_ms;
        const start_time = nanoTimestamp();

        while (true) {
            if (result.completed.load(.acquire)) {
                _ = future.await(io);

                if (result.err) |err| return err;
                if (result.stream) |stream| return stream;
                return error.UnknownError;
            }

            if (nanoTimestamp() - start_time >= timeout_ns) {
                _ = future.cancel(io);
                if (result.stream) |stream| stream.close(io);
                return error.RequestTimeout;
            }

            sleep(poll_interval_ms * std.time.ns_per_ms);
        }
    }

    fn connectTcpWorker(ip_text: []const u8, port: u16, result: *ConnectResult) void {
        defer result.completed.store(true, .release);

        const stream = connectTcp(ip_text, port) catch |err| {
            result.err = err;
            return;
        };

        result.stream = stream;
    }
};

pub const windows = struct {
    pub const STD_INPUT_HANDLE: std.os.windows.DWORD = @bitCast(@as(i32, -10));
    pub const STD_OUTPUT_HANDLE: std.os.windows.DWORD = @bitCast(@as(i32, -11));

    const DWORD = std.os.windows.DWORD;
    const BOOL = std.os.windows.BOOL;
    const HANDLE = std.os.windows.HANDLE;
    const HKEY = std.os.windows.HKEY;
    const REGSAM = std.os.windows.REGSAM;
    const BYTE = u8;
    const LONG = i32;
    const PSID = *anyopaque;
    const BOOL_FALSE: BOOL = @enumFromInt(0);
    const BOOL_TRUE: BOOL = @enumFromInt(1);
    const ERROR_SUCCESS: DWORD = 0;
    const KEY_READ: REGSAM = @bitCast(@as(DWORD, 0x20019));
    const REG_SZ: DWORD = 1;
    const REG_EXPAND_SZ: DWORD = 2;
    const SECURITY_DESCRIPTOR_REVISION: DWORD = 1;
    const ACL_REVISION: DWORD = 2;
    const DACL_SECURITY_INFORMATION: DWORD = 0x00000004;
    const MUTEX_ALL_ACCESS: DWORD = 0x1F0001;

    const SID_IDENTIFIER_AUTHORITY = extern struct {
        Value: [6]u8,
    };

    const ACL = extern struct {
        AclRevision: BYTE,
        Sbz1: BYTE,
        AclSize: std.os.windows.WORD,
        AceCount: std.os.windows.WORD,
        Sbz2: std.os.windows.WORD,
    };

    const SECURITY_DESCRIPTOR = extern struct {
        Revision: BYTE,
        Sbz1: BYTE,
        Control: std.os.windows.WORD,
        Owner: PSID,
        Group: PSID,
        Sacl: ?*ACL,
        Dacl: ?*ACL,
    };

    const SECURITY_WORLD_SID_AUTHORITY = SID_IDENTIFIER_AUTHORITY{ .Value = [_]u8{ 0, 0, 0, 0, 0, 1 } };
    const SECURITY_WORLD_RID: DWORD = 0;

    pub const RegistryStringError = std.mem.Allocator.Error || error{
        DanglingSurrogateHalf,
        ExpectedSecondSurrogateHalf,
        InvalidUtf8,
        RegistryKeyNotFound,
        RegistryValueNotFound,
        InvalidRegistryValueType,
        InvalidRegistryValueData,
        UnexpectedSecondSurrogateHalf,
    };

    pub const CreateDeniedMutexError = std.mem.Allocator.Error || error{
        InvalidUtf8,
        CreateMutexFailed,
        CreateWorldSidFailed,
        InitializeAclFailed,
        AddAccessDeniedAceFailed,
        InitializeSecurityDescriptorFailed,
        SetSecurityDescriptorDaclFailed,
        SetKernelObjectSecurityFailed,
    };

    fn utf8ToUtf16LeAllocZ(allocator: std.mem.Allocator, text: []const u8) ![:0]u16 {
        const utf16 = try std.unicode.utf8ToUtf16LeAlloc(allocator, text);
        defer allocator.free(utf16);
        return try allocator.dupeZ(u16, utf16);
    }

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

    pub fn queryRegistryStringAlloc(
        allocator: std.mem.Allocator,
        root_key: HKEY,
        sub_key: []const u8,
        value_name: []const u8,
    ) RegistryStringError![]u8 {
        const RegOpenKeyExW = struct {
            extern "advapi32" fn RegOpenKeyExW(
                hKey: HKEY,
                lpSubKey: [*:0]const u16,
                ulOptions: DWORD,
                samDesired: REGSAM,
                phkResult: *HKEY,
            ) callconv(.winapi) DWORD;
        }.RegOpenKeyExW;

        const RegQueryValueExW = struct {
            extern "advapi32" fn RegQueryValueExW(
                hKey: HKEY,
                lpValueName: [*:0]const u16,
                lpReserved: ?*DWORD,
                lpType: ?*DWORD,
                lpData: ?*BYTE,
                lpcbData: ?*DWORD,
            ) callconv(.winapi) DWORD;
        }.RegQueryValueExW;

        const RegCloseKey = struct {
            extern "advapi32" fn RegCloseKey(hKey: HKEY) callconv(.winapi) LONG;
        }.RegCloseKey;

        const sub_key_z = try utf8ToUtf16LeAllocZ(allocator, sub_key);
        defer allocator.free(sub_key_z);
        const value_name_z = try utf8ToUtf16LeAllocZ(allocator, value_name);
        defer allocator.free(value_name_z);

        var hKey: HKEY = undefined;
        if (RegOpenKeyExW(root_key, sub_key_z.ptr, 0, KEY_READ, &hKey) != ERROR_SUCCESS)
            return error.RegistryKeyNotFound;
        defer _ = RegCloseKey(hKey);

        var data_type: DWORD = 0;
        var data_bytes: DWORD = 0;
        if (RegQueryValueExW(hKey, value_name_z.ptr, null, &data_type, null, &data_bytes) != ERROR_SUCCESS)
            return error.RegistryValueNotFound;

        if (data_type != REG_SZ and data_type != REG_EXPAND_SZ)
            return error.InvalidRegistryValueType;

        if (data_bytes == 0) return allocator.dupe(u8, "");
        if (@rem(data_bytes, @sizeOf(u16)) != 0) return error.InvalidRegistryValueData;

        const unit_count: usize = @intCast(@divExact(data_bytes, @sizeOf(u16)));
        const utf16_value = try allocator.alloc(u16, unit_count);
        defer allocator.free(utf16_value);

        if (RegQueryValueExW(
            hKey,
            value_name_z.ptr,
            null,
            &data_type,
            @ptrCast(utf16_value.ptr),
            &data_bytes,
        ) != ERROR_SUCCESS) return error.RegistryValueNotFound;

        const trimmed = std.mem.sliceTo(utf16_value, 0);
        return try std.unicode.utf16LeToUtf8Alloc(allocator, trimmed);
    }

    pub fn createDeniedMutex(allocator: std.mem.Allocator, name: []const u8) CreateDeniedMutexError!HANDLE {
        const CreateMutexW = struct {
            extern "kernel32" fn CreateMutexW(
                lpMutexAttributes: ?*std.os.windows.SECURITY_ATTRIBUTES,
                bInitialOwner: BOOL,
                lpName: [*:0]const u16,
            ) callconv(.winapi) ?HANDLE;
        }.CreateMutexW;

        const CloseHandle = struct {
            extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) BOOL;
        }.CloseHandle;

        const AllocateAndInitializeSid = struct {
            extern "advapi32" fn AllocateAndInitializeSid(
                pIdentifierAuthority: *const SID_IDENTIFIER_AUTHORITY,
                nSubAuthorityCount: BYTE,
                nSubAuthority0: DWORD,
                nSubAuthority1: DWORD,
                nSubAuthority2: DWORD,
                nSubAuthority3: DWORD,
                nSubAuthority4: DWORD,
                nSubAuthority5: DWORD,
                nSubAuthority6: DWORD,
                nSubAuthority7: DWORD,
                pSid: *PSID,
            ) callconv(.winapi) BOOL;
        }.AllocateAndInitializeSid;

        const FreeSid = struct {
            extern "advapi32" fn FreeSid(pSid: PSID) callconv(.winapi) ?*anyopaque;
        }.FreeSid;

        const InitializeAcl = struct {
            extern "advapi32" fn InitializeAcl(
                pAcl: *ACL,
                nAclLength: DWORD,
                dwAclRevision: DWORD,
            ) callconv(.winapi) BOOL;
        }.InitializeAcl;

        const AddAccessDeniedAce = struct {
            extern "advapi32" fn AddAccessDeniedAce(
                pAcl: *ACL,
                dwAceRevision: DWORD,
                AccessMask: DWORD,
                pSid: PSID,
            ) callconv(.winapi) BOOL;
        }.AddAccessDeniedAce;

        const InitializeSecurityDescriptor = struct {
            extern "advapi32" fn InitializeSecurityDescriptor(
                pSecurityDescriptor: *SECURITY_DESCRIPTOR,
                dwRevision: DWORD,
            ) callconv(.winapi) BOOL;
        }.InitializeSecurityDescriptor;

        const SetSecurityDescriptorDacl = struct {
            extern "advapi32" fn SetSecurityDescriptorDacl(
                pSecurityDescriptor: *SECURITY_DESCRIPTOR,
                bDaclPresent: BOOL,
                pDacl: ?*ACL,
                bDaclDefaulted: BOOL,
            ) callconv(.winapi) BOOL;
        }.SetSecurityDescriptorDacl;

        const SetKernelObjectSecurity = struct {
            extern "advapi32" fn SetKernelObjectSecurity(
                Handle: HANDLE,
                SecurityInformation: DWORD,
                SecurityDescriptor: *SECURITY_DESCRIPTOR,
            ) callconv(.winapi) BOOL;
        }.SetKernelObjectSecurity;

        const mutex_name_z = try utf8ToUtf16LeAllocZ(allocator, name);
        defer allocator.free(mutex_name_z);

        const handle = CreateMutexW(null, BOOL_FALSE, mutex_name_z.ptr) orelse return error.CreateMutexFailed;
        errdefer _ = CloseHandle(handle);

        var everyone_sid: PSID = undefined;
        var authority = SECURITY_WORLD_SID_AUTHORITY;
        if (!AllocateAndInitializeSid(&authority, 1, SECURITY_WORLD_RID, 0, 0, 0, 0, 0, 0, 0, &everyone_sid).toBool())
            return error.CreateWorldSidFailed;
        defer _ = FreeSid(everyone_sid);

        var acl_buffer: [256]u8 align(4) = undefined;
        const acl: *ACL = @ptrCast(&acl_buffer);
        if (!InitializeAcl(acl, acl_buffer.len, ACL_REVISION).toBool())
            return error.InitializeAclFailed;

        if (!AddAccessDeniedAce(acl, ACL_REVISION, MUTEX_ALL_ACCESS, everyone_sid).toBool())
            return error.AddAccessDeniedAceFailed;

        var security_descriptor: SECURITY_DESCRIPTOR = undefined;
        if (!InitializeSecurityDescriptor(&security_descriptor, SECURITY_DESCRIPTOR_REVISION).toBool())
            return error.InitializeSecurityDescriptorFailed;

        if (!SetSecurityDescriptorDacl(&security_descriptor, BOOL_TRUE, acl, BOOL_FALSE).toBool())
            return error.SetSecurityDescriptorDaclFailed;

        if (!SetKernelObjectSecurity(handle, DACL_SECURITY_INFORMATION, &security_descriptor).toBool())
            return error.SetKernelObjectSecurityFailed;

        return handle;
    }
};

const compat = @This();
