//! 动态库加载（跨平台的 `LoadLibrary` / `dlopen` 薄封装）。
//!
//! 为什么不用 `std.DynLib`：**Zig 0.17 的 `std.DynLib` 没有 Windows 分支**
//! （只有 linux / mac / BSD），而本仓库的嵌入式驱动（SQLite、DuckDB）主要跑在 Windows 上，
//! 需要按名字加载 `xxx.dll` 并 `GetProcAddress` 取函数指针。
//!
//! 口径：
//! - Windows 走 `kernel32.LoadLibraryA` + `GetProcAddress` + `FreeLibrary`；
//! - 其它平台走 `std.DynLib`（Unix 上它是可用的）；
//! - 加载失败一律返回 `null`（由调用方决定「换下一个候选路径」还是报错）。

const std = @import("std");
const builtin = @import("builtin");

const win = if (builtin.os.tag == .windows) struct {
    extern "kernel32" fn LoadLibraryA(lpLibFileName: [*:0]const u8) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn GetProcAddress(hModule: ?*anyopaque, lpProcName: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
    extern "kernel32" fn FreeLibrary(hLibModule: ?*anyopaque) callconv(.winapi) i32;
} else struct {};

const unix_lib: ?std.DynLib = null; // 占位：Unix 分支用局部变量，保留类型引用便于阅读

pub const Module = struct {
    handle: ?*anyopaque = null,
    /// Unix 分支的句柄（Windows 上恒为 null）
    lib: ?*std.DynLib = null,
    /// 实际加载到的路径（诊断用，借用调用方内存）
    source: []const u8 = "",

    /// 取函数指针（名字必须与 C 导出名一致）。
    pub fn lookup(self: Module, comptime T: type, name: [:0]const u8) ?T {
        if (builtin.os.tag == .windows) {
            const proc = win.GetProcAddress(self.handle, name.ptr) orelse return null;
            return @ptrFromInt(@intFromPtr(proc));
        }
        const lib = self.lib orelse return null;
        const T2 = T;
        return lib.lookup(T2, name) catch null;
    }

    pub fn close(self: Module, gpa: std.mem.Allocator) void {
        if (builtin.os.tag == .windows) {
            if (self.handle) |h| _ = win.FreeLibrary(h);
            return;
        }
        if (self.lib) |lib| {
            lib.deinit();
            gpa.destroy(lib);
        }
    }
};

/// 尝试按路径加载；失败返回 `null`（不打印、不 panic）。
pub fn load(gpa: std.mem.Allocator, path: []const u8) ?Module {
    if (builtin.os.tag == .windows) {
        var buf: [1024]u8 = undefined;
        if (path.len >= buf.len) return null;
        @memcpy(buf[0..path.len], path);
        buf[path.len] = 0;
        const path_z: [*:0]const u8 = @ptrCast(&buf);
        const handle = win.LoadLibraryA(path_z) orelse return null;
        return .{ .handle = handle, .source = path };
    }
    var buf: [1024]u8 = undefined;
    if (path.len >= buf.len) return null;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    const p = gpa.create(std.DynLib) catch return null;
    p.* = std.DynLib.open(buf[0..path.len]) catch {
        gpa.destroy(p);
        return null;
    };
    return .{ .lib = p, .source = path };
}

/// 程序所在目录（取不到返回 `error.NotFound`）。
pub fn exeDirAlloc(gpa: std.mem.Allocator) ![]u8 {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    // 0.17 签名是 `executablePath(io, out_buffer)`
    const n = std.process.executablePath(@import("compat.zig").currentIo(), &buf) catch return error.NotFound;
    const dir = std.fs.path.dirname(buf[0..n]) orelse return error.NotFound;
    return gpa.dupe(u8, dir);
}

// ── 测试 ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "dyn：加载不存在的库返回 null 而不是崩溃" {
    const m = load(testing.allocator, "definitely-not-a-real-lib-xyz.dll");
    try testing.expect(m == null);
}
