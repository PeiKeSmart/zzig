//! `zzig-spa-gen`：扫描前端构建产物（Vite/Vue 的 `dist`），生成 Zig 资源表源码。
//!
//! 用途：对齐 DH.RustBase 的 `build.rs` 生成器 —— 让前端产物**编译期嵌入**后端可执行文件，
//! 生产环境单 exe、单端口、无 Node 运行环境、无 nginx。
//!
//! 为什么是独立可执行程序而不是"复制一段 build.zig 代码"：
//! Zig 的 build 脚本之间不能互相 `@import`，但**可以依赖别的包的 artifact**，
//! 所以把扫描逻辑做成程序，消费方 build.zig 只要三行（见 `docs/spa_vue.md`）。
//!
//! 用法：
//! ```text
//! zzig-spa-gen --dist web/dist --out <输出文件> [--name files]
//! ```
//! 输出内容：
//! ```zig
//! pub const source_dir = "D:/proj/web/dist";
//! pub const Entry = struct { path: []const u8, data: []const u8 };
//! pub const files = [_]Entry{ .{ .path = "index.html", .data = @embedFile("D:/proj/web/dist/index.html") }, ... };
//! ```
//! `@embedFile` 用**绝对路径**（实测 Zig 0.17 支持），因此生成文件放在缓存目录也能正确解析。

const std = @import("std");

const Item = struct {
    /// 相对 `dist` 的路径，统一用 `/` 分隔
    rel: []const u8,
    /// 绝对路径（统一用 `/` 分隔，供 `@embedFile` 用）
    abs: []const u8,
};

pub fn main(init: std.process.Init) !void {
    // Zig 0.17：`main(init: std.process.Init)` 直接提供 gpa / io / args
    const alloc = init.gpa;
    const io = init.io;

    var arg_it = try std.process.Args.Iterator.initAllocator(init.minimal.args, alloc);
    defer arg_it.deinit();
    _ = arg_it.skip(); // 跳过程序名

    var dist: ?[]const u8 = null;
    var out: ?[]const u8 = null;
    var table_name: []const u8 = "files";

    while (arg_it.next()) |raw| {
        const a: []const u8 = raw;
        if (std.mem.eql(u8, a, "--dist")) {
            dist = arg_it.next() orelse return fail("--dist 缺少参数", .{});
        } else if (std.mem.eql(u8, a, "--out")) {
            out = arg_it.next() orelse return fail("--out 缺少参数", .{});
        } else if (std.mem.eql(u8, a, "--name")) {
            table_name = arg_it.next() orelse return fail("--name 缺少参数", .{});
        } else if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            std.debug.print(
                "用法：zzig-spa-gen --dist <前端dist目录> --out <生成文件> [--name <表名>]\n",
                .{},
            );
            return;
        } else {
            return fail("未知参数：{s}（用 --help 查看用法）", .{a});
        }
    }

    const dist_arg = dist orelse return fail("必须指定 --dist（前端构建产物目录）", .{});
    const out_path = out orelse return fail("必须指定 --out（生成的 .zig 文件路径）", .{});

    // 前端尚未构建：生成空表并警告，不阻断后端编译（对齐 DH.RustBase 的 cargo:warning 行为）
    if (!pathExists(io, dist_arg)) {
        std.debug.print(
            "[zzig-spa-gen] 警告：资源目录不存在（{s}）；已生成空资源表。请先执行前端构建（npm run build）\n",
            .{dist_arg},
        );
        try writeTable(io, alloc, out_path, table_name, dist_arg, &.{});
        return;
    }
    const abs_dist = try absolutePath(io, alloc, dist_arg);
    defer alloc.free(abs_dist);

    var items: std.ArrayListUnmanaged(Item) = .empty;
    defer {
        for (items.items) |it| {
            alloc.free(it.rel);
            alloc.free(it.abs);
        }
        items.deinit(alloc);
    }

    var dir = std.Io.Dir.cwd().openDir(io, abs_dist, .{ .iterate = true }) catch |e| {
        return fail("打不开资源目录 {s}：{s}", .{ abs_dist, @errorName(e) });
    };
    defer dir.close(io);
    try collect(io, alloc, dir, "", abs_dist, &items);

    std.mem.sort(Item, items.items, {}, struct {
        fn lt(_: void, a: Item, b: Item) bool {
            return std.mem.lessThan(u8, a.rel, b.rel);
        }
    }.lt);

    try writeTable(io, alloc, out_path, table_name, abs_dist, items.items);
    std.debug.print(
        "[zzig-spa-gen] 已生成 {d} 个资源 → {s}（源：{s}）\n",
        .{ items.items.len, out_path, abs_dist },
    );
}

fn fail(comptime fmt: []const u8, args: anytype) error{InvalidArgs} {
    std.debug.print("[zzig-spa-gen] 错误：" ++ fmt ++ "\n", args);
    return error.InvalidArgs;
}

/// 递归收集目录下的普通文件。
fn collect(
    io: std.Io,
    alloc: std.mem.Allocator,
    dir: std.Io.Dir,
    prefix: []const u8,
    abs_parent: []const u8,
    out: *std.ArrayListUnmanaged(Item),
) !void {
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        const rel = if (prefix.len == 0)
            try alloc.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(alloc, "{s}/{s}", .{ prefix, entry.name });
        errdefer alloc.free(rel);

        const abs = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ abs_parent, entry.name });
        errdefer alloc.free(abs);

        switch (entry.kind) {
            .directory => {
                const sub = dir.openDir(io, entry.name, .{ .iterate = true }) catch |e| {
                    std.debug.print("[zzig-spa-gen] 跳过目录 {s}：{s}\n", .{ rel, @errorName(e) });
                    alloc.free(rel);
                    alloc.free(abs);
                    continue;
                };
                defer sub.close(io);
                try collect(io, alloc, sub, rel, abs, out);
                alloc.free(rel);
                alloc.free(abs);
            },
            else => try out.append(alloc, .{ .rel = rel, .abs = abs }),
        }
    }
}

/// 把路径规范成 `@embedFile` 可用的形式：统一正斜杠 + 转义引号/反斜杠。
fn emitPath(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(alloc);
    for (path) |c| {
        switch (c) {
            '\\' => try buf.append(alloc, '/'),
            '"' => try buf.appendSlice(alloc, "\\\""),
            else => try buf.append(alloc, c),
        }
    }
    return buf.toOwnedSlice(alloc);
}

fn writeTable(
    io: std.Io,
    alloc: std.mem.Allocator,
    out_path: []const u8,
    table_name: []const u8,
    source_dir: []const u8,
    items: []const Item,
) !void {
    // Zig 不允许 `@embedFile` 指向模块包路径之外，所以把 dist 内容**复制到生成文件同目录**，
    // 表里用相对路径引用（生成文件与资源同属一个模块根）。
    const out_dir = std.fs.path.dirname(out_path) orelse ".";

    var src: std.ArrayListUnmanaged(u8) = .empty;
    defer src.deinit(alloc);

    try src.appendSlice(alloc,
        \\//! 由 `zzig-spa-gen` 生成，请勿手改。
        \\//!
        \\//! 内容：前端构建产物（Vite/Vue 的 dist）的编译期嵌入表。
        \\//! 资源已复制到本文件同目录，用相对路径嵌入（Zig 不允许跨包路径 `@embedFile`）。
        \\//! 用法见 zzig 的 `docs/spa_vue.md`。
        \\
        \\
    );
    try src.appendSlice(alloc, "pub const source_dir = \"");
    const src_dir_norm = try escForString(alloc, source_dir);
    defer alloc.free(src_dir_norm);
    try src.appendSlice(alloc, src_dir_norm);
    try src.appendSlice(alloc, "\";\n\n");
    try src.appendSlice(alloc,
        \\/// 单条资源：`path` 是相对 dist 的路径，`data` 已编译期嵌入。
        \\pub const Entry = struct { path: []const u8, data: []const u8 };
        \\
        \\
    );
    try src.appendSlice(alloc, "pub const ");
    try src.appendSlice(alloc, table_name);
    try src.appendSlice(alloc, " = [_]Entry{\n");

    for (items) |it| {
        // 1) 复制文件：`<out_dir>/<rel>`
        const dst_rel = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ out_dir, it.rel });
        defer alloc.free(dst_rel);
        try ensureParent(io, dst_rel);
        try copyFile(io, alloc, it.abs, dst_rel);

        // 2) 表里用相对路径
        try src.appendSlice(alloc, "    .{ .path = \"");
        try src.appendSlice(alloc, it.rel);
        try src.appendSlice(alloc, "\", .data = @embedFile(\"");
        const rel_norm = try escForString(alloc, it.rel);
        defer alloc.free(rel_norm);
        try src.appendSlice(alloc, rel_norm);
        try src.appendSlice(alloc, "\") },\n");
    }
    try src.appendSlice(alloc, "};\n");

    try writeFile(io, out_path, src.items);
}

/// 转义为双引号字符串内容。
fn escForString(alloc: std.mem.Allocator, s: []const u8) ![]u8 {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(alloc);
    for (s) |c| {
        switch (c) {
            '\\' => try buf.appendSlice(alloc, "/"),
            '"' => try buf.appendSlice(alloc, "\\\""),
            else => try buf.append(alloc, c),
        }
    }
    return buf.toOwnedSlice(alloc);
}

fn copyFile(io: std.Io, alloc: std.mem.Allocator, src_path: []const u8, dst_path: []const u8) !void {
    var src_file = try std.Io.Dir.cwd().openFile(io, src_path, .{});
    defer src_file.close(io);
    const len = try src_file.length(io);
    const buf = try alloc.alloc(u8, @intCast(len));
    defer alloc.free(buf);
    var read: usize = 0;
    while (read < buf.len) {
        const n = src_file.readStreaming(io, &.{buf[read..]}) catch |e| switch (e) {
            error.EndOfStream => 0,
            else => return e,
        };
        if (n == 0) break;
        read += n;
    }
    try writeFile(io, dst_path, buf[0..read]);
}

// ---------------------------------------------------------------------------
// 文件小工具（自包含：不 import zzig 其它模块，保证可独立编译成 artifact）
// ---------------------------------------------------------------------------

fn pathExists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

/// 解析为绝对路径（不要求目标已存在）。
fn absolutePath(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return allocator.dupe(u8, path);
    const cwd_abs = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
    defer allocator.free(cwd_abs);
    return std.fs.path.resolve(allocator, &.{ cwd_abs, path });
}

fn ensureParent(io: std.Io, path: []const u8) !void {
    if (std.fs.path.dirname(path)) |d| {
        if (d.len > 0) try std.Io.Dir.cwd().createDirPath(io, d);
    }
}

fn writeFile(io: std.Io, path: []const u8, bytes: []const u8) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

const testing = std.testing;

test "spa-gen：递归收集并按相对路径排序" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(io, "dist/assets");
    try tmp.dir.writeFile(io, .{ .sub_path = "dist/index.html", .data = "<html/>" });
    try tmp.dir.writeFile(io, .{ .sub_path = "dist/assets/app.js", .data = "console.log(1)" });

    const abs = try tmp.dir.realPathFileAlloc(io, "dist", testing.allocator);
    defer testing.allocator.free(abs);

    const dir = try tmp.dir.openDir(io, "dist", .{ .iterate = true });
    defer dir.close(io);

    var items: std.ArrayListUnmanaged(Item) = .empty;
    defer {
        for (items.items) |it| {
            testing.allocator.free(it.rel);
            testing.allocator.free(it.abs);
        }
        items.deinit(testing.allocator);
    }
    try collect(io, testing.allocator, dir, "", abs, &items);
    std.mem.sort(Item, items.items, {}, struct {
        fn lt(_: void, a: Item, b: Item) bool {
            return std.mem.lessThan(u8, a.rel, b.rel);
        }
    }.lt);

    try testing.expectEqual(@as(usize, 2), items.items.len);
    // 排序后 assets/app.js 在 index.html 之前（'a' < 'i'）
    try testing.expectEqualStrings("assets/app.js", items.items[0].rel);
    try testing.expectEqualStrings("index.html", items.items[1].rel);
}

test "spa-gen：路径统一为正斜杠" {
    const p = try emitPath(testing.allocator, "E:\\proj\\web\\dist\\index.html");
    defer testing.allocator.free(p);
    try testing.expectEqualStrings("E:/proj/web/dist/index.html", p);
}
