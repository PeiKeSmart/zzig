//! 路径安全与 glob 匹配（跨平台）。
//!
//! - 协议/备份/同步类项目都要「相对路径 + 排除规则」，此前各项目各写一份；
//! - 规则语义：不含 `/` 的规则只匹配末段（`*.tmp`、`node_modules`）；
//!   含 `/` 的按相对路径匹配，`**` 作为整段可跨任意层级；`*`/`?` 不跨段。
//! - `sanitizeRelPath` 拒绝绝对路径、盘符、`.`/`..`、控制字符与 Windows 非法字符。

const std = @import("std");
const builtin = @import("builtin");

pub const max_rel_path_len: usize = 1024;

pub fn defaultCaseInsensitive() bool {
    return builtin.os.tag == .windows;
}

/// 规范化并校验相对路径（统一 `/`）。返回切片由调用方释放。
pub fn sanitizeRelPath(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    if (raw.len == 0 or raw.len > max_rel_path_len) return error.InvalidPath;
    if (raw[0] == '/' or raw[0] == '\\') return error.InvalidPath;

    const out = try allocator.alloc(u8, raw.len);
    errdefer allocator.free(out);

    for (raw, 0..) |c, i| {
        if (c < 0x20 or c == 0x7f) return error.InvalidPath;
        switch (c) {
            '\\' => out[i] = '/',
            ':', '*', '?', '"', '<', '>', '|' => return error.InvalidPath,
            else => out[i] = c,
        }
    }

    var it = std.mem.splitScalar(u8, out, '/');
    while (it.next()) |seg| {
        if (seg.len == 0) return error.InvalidPath;
        if (std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) return error.InvalidPath;
        if (builtin.os.tag == .windows) {
            if (seg[seg.len - 1] == '.' or seg[seg.len - 1] == ' ') return error.InvalidPath;
            if (isWindowsReservedName(seg)) return error.InvalidPath;
        }
    }
    return out;
}

fn isWindowsReservedName(seg: []const u8) bool {
    const dot = std.mem.indexOfScalar(u8, seg, '.') orelse seg.len;
    const base = seg[0..dot];
    if (base.len == 0) return false;
    const reserved = [_][]const u8{
        "CON",  "PRN",  "AUX",  "NUL",  "COM1", "COM2", "COM3", "COM4",
        "COM5", "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3",
        "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    };
    for (reserved) |name| {
        if (std.ascii.eqlIgnoreCase(base, name)) return true;
    }
    return false;
}

pub fn matchPattern(pattern: []const u8, path: []const u8, case_insensitive: bool) bool {
    if (pattern.len == 0) return false;

    const has_slash = std.mem.indexOfScalar(u8, pattern, '/') != null or
        std.mem.indexOfScalar(u8, pattern, '\\') != null;

    if (!has_slash) {
        return matchSegment(pattern, basename(path), case_insensitive);
    }

    var pat_buf: [max_rel_path_len]u8 = undefined;
    var path_buf: [max_rel_path_len]u8 = undefined;
    if (pattern.len > pat_buf.len or path.len > path_buf.len) return false;

    const pat = normalizeInto(&pat_buf, pattern);
    const p = normalizeInto(&path_buf, path);

    var pat_segs: [256][]const u8 = undefined;
    var path_segs: [256][]const u8 = undefined;
    const pat_n = splitSegments(pat, &pat_segs);
    const path_n = splitSegments(p, &path_segs);
    return matchSegments(pat_segs[0..pat_n], path_segs[0..path_n], case_insensitive);
}

fn normalizeInto(buf: []u8, s: []const u8) []const u8 {
    for (s, 0..) |c, i| buf[i] = if (c == '\\') '/' else c;
    return buf[0..s.len];
}

fn splitSegments(s: []const u8, out: *[256][]const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, s, '/');
    while (it.next()) |seg| {
        if (seg.len == 0) continue;
        if (n >= out.len) return n;
        out[n] = seg;
        n += 1;
    }
    return n;
}

fn matchSegments(pat: []const []const u8, path: []const []const u8, ci: bool) bool {
    return matchSegmentsFrom(pat, 0, path, 0, ci);
}

fn matchSegmentsFrom(pat: []const []const u8, p0: usize, path: []const []const u8, s0: usize, ci: bool) bool {
    var pi = p0;
    var si = s0;
    while (pi < pat.len) {
        if (std.mem.eql(u8, pat[pi], "**")) {
            while (pi < pat.len and std.mem.eql(u8, pat[pi], "**")) pi += 1;
            if (pi == pat.len) return true;
            var k = si;
            while (k <= path.len) : (k += 1) {
                if (matchSegmentsFrom(pat, pi, path, k, ci)) return true;
            }
            return false;
        }
        if (si >= path.len) return false;
        if (!matchSegment(pat[pi], path[si], ci)) return false;
        pi += 1;
        si += 1;
    }
    return si == path.len;
}

fn matchSegment(pat: []const u8, s: []const u8, ci: bool) bool {
    var p: usize = 0;
    var i: usize = 0;
    var star: ?usize = null;
    var mark: usize = 0;

    while (i < s.len) {
        if (p < pat.len and (pat[p] == '?' or eqlChar(pat[p], s[i], ci))) {
            p += 1;
            i += 1;
        } else if (p < pat.len and pat[p] == '*') {
            star = p;
            p += 1;
            mark = i;
        } else if (star) |st| {
            p = st + 1;
            mark += 1;
            i = mark;
        } else {
            return false;
        }
    }
    while (p < pat.len and pat[p] == '*') p += 1;
    return p == pat.len;
}

fn eqlChar(a: u8, b: u8, ci: bool) bool {
    return if (ci) std.ascii.toLower(a) == std.ascii.toLower(b) else a == b;
}

pub fn basename(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 0 and (path[end - 1] == '/' or path[end - 1] == '\\')) end -= 1;
    var start = end;
    while (start > 0 and path[start - 1] != '/' and path[start - 1] != '\\') start -= 1;
    return path[start..end];
}

pub fn matchesAny(patterns: []const []const u8, path: []const u8, case_insensitive: bool) bool {
    for (patterns) |p| {
        if (matchPattern(p, path, case_insensitive)) return true;
    }
    return false;
}

const testing = std.testing;

test "glob: 单段/跨段/**" {
    try testing.expect(matchPattern("*.tmp", "a/b/c.tmp", true));
    try testing.expect(!matchPattern("*.tmp", "a/b/c.txt", true));
    try testing.expect(matchPattern("a/**/z.txt", "a/b/c/z.txt", false));
    try testing.expect(matchPattern("a/**/z.txt", "a/z.txt", false));
    try testing.expect(!matchPattern("a/*/z.txt", "a/b/c/z.txt", false));
    try testing.expect(matchPattern("**/*.log", "x/y/a.log", false));
}

test "sanitizeRelPath: 拒绝穿越/绝对路径" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings("a/b/c.txt", try sanitizeRelPath(a, "a\\b\\c.txt"));
    try testing.expectError(error.InvalidPath, sanitizeRelPath(a, "../etc/passwd"));
    try testing.expectError(error.InvalidPath, sanitizeRelPath(a, "/abs"));
    try testing.expectError(error.InvalidPath, sanitizeRelPath(a, "C:/x"));
    try testing.expectError(error.InvalidPath, sanitizeRelPath(a, "a//b"));
    try testing.expectError(error.InvalidPath, sanitizeRelPath(a, "a/./b"));
}
