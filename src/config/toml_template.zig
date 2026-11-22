//! TOML 模板渲染（带注释）—— 让程序生成的配置文件自带逐字段说明。
//!
//! 为什么需要它：Zig 运行期**拿不到** `///` 文档注释（`std.builtin.Type.StructField`
//! 只有 `name` / `type` / `default_value_ptr` / `is_comptime` / `alignment`，没有 doc），
//! 所以做不到 Rust `toml_edit` + derive 那种「写注释即得注释」。可行且更好的做法是
//! **声明表驱动**：注释与键值写在同一条记录里，由本模块统一渲染，从而
//!   - 新增字段时「忘写注释」一眼可见（同一条字面量里 doc 空着很突兀）；
//!   - `# ` 前缀、分组空行、列表格式、字符串转义全项目一致，不用各写一遍。
//!
//! 用法：
//! ```zig
//! const t = zzig.config.toml_template;
//! const items = [_]t.Item{
//!     .{ .key = "enable", .doc = &.{"总开关（false = 旁路）"}, .value = .{ .boolean = true } },
//!     .{ .key = "mode", .doc = &.{ "运行模式", "adminApi | publicSite" }, .value = .{ .string = "adminApi" } },
//!     .{ .key = "sensitivePrefixes", .value = .{ .string_list = &.{"/admin"} } },
//! };
//! const text = try t.render(a, .{ .header = &.{"Pek.XYZ 配置"} }, &items);
//! ```
//!
//! 只负责**生成**（首次落盘 / 面板导出），不做解析；解析见 `zzig.config.toml`。

const std = @import("std");
const zzig = @import("../zzig.zig");

/// 一个 TOML 值（渲染成合法 TOML 字面量）。
pub const Value = union(enum) {
    boolean: bool,
    integer: i64,
    float: f64,
    /// 字符串（自动加引号并转义 `"` `\` 与控制字符）
    string: []const u8,
    /// 字符串数组（元素自动加引号并转义）
    string_list: []const []const u8,
    /// 原样输出：调用方自行保证是合法 TOML 值文本（如 `[]`、内联表）
    raw: []const u8,
};

/// 一条配置项。
pub const Item = struct {
    /// 键名（原样输出，不做大小写转换）
    key: []const u8,
    /// 注释（每行一个元素，渲染时自动加 `# `；空元素渲染成单独一个 `#`）
    doc: []const []const u8 = &.{},
    value: Value,
    /// 是否在本条之前输出空行（`null` = 有注释就空行，没注释就紧跟上一行）
    blank_before: ?bool = null,
};

/// 渲染选项。
pub const Options = struct {
    /// 文件头注释（每行一个元素）
    header: []const []const u8 = &.{},
    /// 头部之后是否输出空行
    blank_after_header: bool = true,
    /// 同一 `key` 出现多次时是否允许（默认允许：TOML 里后出现的坏值会覆盖，但模板不该依赖它）
    trailing_newline: bool = true,
};

/// 把声明表渲染成 TOML 文本（调用方负责 `free`）。
pub fn render(a: std.mem.Allocator, opts: Options, items: []const Item) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);

    if (opts.header.len > 0) {
        try writeComment(&out, a, opts.header);
        if (opts.blank_after_header) try out.append(a, '\n');
    }

    for (items, 0..) |item, i| {
        const want_blank = item.blank_before orelse (item.doc.len > 0);
        if (want_blank and (i > 0 or opts.header.len > 0 and !opts.blank_after_header)) {
            try out.append(a, '\n');
        }
        try writeComment(&out, a, item.doc);
        try out.appendSlice(a, item.key);
        try out.appendSlice(a, " = ");
        try writeValue(&out, a, item.value);
        try out.append(a, '\n');
    }

    if (opts.trailing_newline and out.items.len > 0 and out.items[out.items.len - 1] != '\n') {
        try out.append(a, '\n');
    }
    return out.toOwnedSlice(a);
}

/// 渲染一组注释行（每行自动 `# ` 前缀；空串 → 单个 `#`，即空注释行）。
pub fn writeComment(out: *std.ArrayList(u8), a: std.mem.Allocator, doc: []const []const u8) !void {
    for (doc) |line| {
        const text = std.mem.trimEnd(u8, line, " \t");
        if (text.len == 0) {
            try out.appendSlice(a, "#\n");
        } else {
            try out.appendSlice(a, "# ");
            try out.appendSlice(a, text);
            try out.append(a, '\n');
        }
    }
}

/// 渲染一个值。
pub fn writeValue(out: *std.ArrayList(u8), a: std.mem.Allocator, value: Value) !void {
    switch (value) {
        .boolean => |b| try out.appendSlice(a, if (b) "true" else "false"),
        .integer => |n| try out.print(a, "{d}", .{n}),
        .float => |f| try out.print(a, "{d}", .{f}),
        .string => |s| try writeString(out, a, s),
        .string_list => |list| {
            try out.append(a, '[');
            for (list, 0..) |s, i| {
                if (i > 0) try out.appendSlice(a, ", ");
                try writeString(out, a, s);
            }
            try out.append(a, ']');
        },
        .raw => |text| try out.appendSlice(a, text),
    }
}

/// 写一个带引号且转义的 TOML 字符串。
///
/// 必须转义：`"`（提前结束）、`\`（变成转义序列）；控制字符（< 0x20）用 `\u00XX`。
/// 不转义就会出现「值里带一个反斜杠，整份配置解析失败」这类最难查的问题。
pub fn writeString(out: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) !void {
    try out.append(a, '"');
    for (s) |ch| {
        switch (ch) {
            '"' => try out.appendSlice(a, "\\\""),
            '\\' => try out.appendSlice(a, "\\\\"),
            '\n' => try out.appendSlice(a, "\\n"),
            '\r' => try out.appendSlice(a, "\\r"),
            '\t' => try out.appendSlice(a, "\\t"),
            else => {
                if (ch < 0x20) {
                    try out.print(a, "\\u{X:0>4}", .{ch});
                } else {
                    try out.append(a, ch);
                }
            },
        }
    }
    try out.append(a, '"');
}

/// 便捷构造：布尔项。
pub fn boolItem(key: []const u8, doc: []const []const u8, v: bool) Item {
    return .{ .key = key, .doc = doc, .value = .{ .boolean = v } };
}

/// 便捷构造：整数项。
pub fn intItem(key: []const u8, doc: []const []const u8, v: i64) Item {
    return .{ .key = key, .doc = doc, .value = .{ .integer = v } };
}

/// 便捷构造：字符串项。
pub fn strItem(key: []const u8, doc: []const []const u8, v: []const u8) Item {
    return .{ .key = key, .doc = doc, .value = .{ .string = v } };
}

/// 便捷构造：字符串数组项。
pub fn listItem(key: []const u8, doc: []const []const u8, v: []const []const u8) Item {
    return .{ .key = key, .doc = doc, .value = .{ .string_list = v } };
}

/// 补键结果（键名由 `gpa` 分配，调用方 `free`）。
pub const AppendReport = struct {
    /// 本次补上的键名（顺序同 `items`）
    added: []const []const u8,
    /// 是否留下了 `.bak` 备份
    backed_up: bool,

    pub fn deinit(self: AppendReport, gpa: std.mem.Allocator) void {
        for (self.added) |name| gpa.free(name);
        gpa.free(self.added);
    }

    /// 拼成一行日志用的 "A, B, C"（`gpa` 分配）。
    pub fn joined(self: AppendReport, gpa: std.mem.Allocator) ![]u8 {
        return std.mem.join(gpa, ", ", self.added);
    }
};

/// 补键选项。
pub const AppendOptions = struct {
    /// 写前是否把原文件复制成 `<path>.bak`（只留最近一次）
    backup: bool = true,
    /// 单文件读取上限（超出视为异常配置，不动它）
    max_bytes: usize = 1 << 20,
};

/// 把 `items` 里**文件缺失的键**补进配置（带注释），返回补了哪些。
///
/// 这是「配置自动补齐」的通用实现，规矩固定：
/// - **只补缺、绝不覆盖**：已有行与注释一个字节都不动；
/// - **按模板顺序插入**，不是统统堆到末尾：缺失键插到「模板里它前一个键」的后面，
///   这样配置文件的键序始终与模板一致（`SiteUrl` 就该在 `SiteName` 与 `ProbeIpv4Url` 之间）；
///   若前一个键也不在文件里，则跟着它一起插到更前一个已知键之后；整份文件都没有已知键时才追加到末尾；
/// - 键存在与否用 **TOML 解析**判断（不靠字符串搜索，避免注释里出现键名导致误判）；
/// - 写前留 `<path>.bak`，写用原子替换（临时文件 + rename），中途掉电不会写坏配置；
/// - **幂等**：没有缺键时零写入，返回 `null`；
/// - 解析失败/读写失败返回错误，由调用方决定是否降级（通常只 warn，不阻断启动）。
///
/// 返回 `null` 表示「无需补键」（文件不存在、没有缺键）。
pub fn appendMissing(
    io: std.Io,
    gpa: std.mem.Allocator,
    path: []const u8,
    items: []const Item,
    opts: AppendOptions,
) !?AppendReport {
    if (!zzig.fsio.exists(io, path)) return null;

    const text = try zzig.fsio.readFileAlloc(io, gpa, path, opts.max_bytes);
    defer gpa.free(text);
    const source = stripBom(text);
    if (std.mem.trim(u8, source, " \t\r\n").len == 0) return null;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    // 解析失败 → 交给调用方（通常「先修正语法」）；此处不猜测、不改文件。
    const table = try zzig.config.toml.parse(a, source);

    // 行视图（`splitScalar` 会切出一个空尾行，重建时按原样保留即可）
    var lines: std.ArrayList([]const u8) = .empty;
    {
        var iterator = std.mem.splitScalar(u8, source, '\n');
        while (iterator.next()) |line| try lines.append(a, line);
    }

    // 每个模板键在文件里的**首个命中行号**（注释行不算：`isKeyLine` 会跳过 `#`）
    var key_line = std.StringHashMap(usize).init(a);
    var first_key_line: ?usize = null;
    for (lines.items, 0..) |line, i| {
        for (items) |item| {
            if (!zzig.config.text_keys.isKeyLine(line, item.key)) continue;
            if (!key_line.contains(item.key)) try key_line.put(item.key, i);
            if (first_key_line == null or i < first_key_line.?) first_key_line = i;
        }
    }

    const Insert = struct { at: usize, block: []const u8 };
    var inserts: std.ArrayList(Insert) = .empty;
    var names: std.ArrayList([]const u8) = .empty;

    var last_known: ?usize = null;
    for (items) |item| {
        if (key_line.get(item.key)) |line_no| {
            last_known = line_no;
            continue;
        }
        // 解析层面已存在（写法不同，如内联表）→ 不算缺失，不动
        if (zzig.config.toml.lookup(table, item.key) != null) continue;

        // 插到「前一个已存在的键」的**下一行**；它前面没有已知键时放到文件第一个键行之前
        const at = if (last_known) |line_no| line_no + 1 else (first_key_line orelse lines.items.len);
        const block = try render(a, .{}, &.{item});
        // 同一插入位置的连续缺键合并成一个块（保持模板顺序）
        if (inserts.items.len > 0 and inserts.items[inserts.items.len - 1].at == at) {
            const merged = try std.fmt.allocPrint(a, "{s}{s}", .{ inserts.items[inserts.items.len - 1].block, block });
            inserts.items[inserts.items.len - 1].block = merged;
        } else {
            try inserts.append(a, .{ .at = at, .block = block });
        }
        try names.append(a, item.key);
    }
    if (inserts.items.len == 0) return null; // 幂等：全部已在，零写入

    if (opts.backup) {
        const bak = try std.fmt.allocPrint(a, "{s}.bak", .{path});
        zzig.fsio.writeFile(io, bak, text) catch |err| {
            zzig.Logger.warn("[config] 配置备份失败（仍继续补键）：{s}（{s}）", .{ bak, @errorName(err) });
        };
    }

    // 重建：逐行输出，在目标行之前插入块（块自带末尾换行，且避免与已有空行叠成两行）
    var out: std.ArrayList(u8) = .empty;
    for (lines.items, 0..) |line, i| {
        for (inserts.items) |ins| {
            if (ins.at != i) continue;
            try out.appendSlice(a, ins.block);
            const next_blank = i < lines.items.len and std.mem.trim(u8, lines.items[i], " \t\r").len == 0;
            if (!next_blank) try out.append(a, '\n');
        }
        try out.appendSlice(a, line);
        if (i + 1 < lines.items.len) try out.append(a, '\n');
    }
    // 整份文件没有任何已知键时，追加到末尾
    for (inserts.items) |ins| {
        if (ins.at != lines.items.len) continue;
        if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(a, '\n');
        try out.append(a, '\n');
        try out.appendSlice(a, ins.block);
    }

    try zzig.fsio.writeFileAtomic(io, gpa, path, out.items);

    const added = try gpa.alloc([]const u8, names.items.len);
    errdefer gpa.free(added);
    for (names.items, 0..) |name, i| added[i] = try gpa.dupe(u8, name);
    errdefer for (added) |name| gpa.free(name);
    return .{ .added = added, .backed_up = opts.backup };
}

/// 剥 UTF-8 BOM（PowerShell `Set-Content -Encoding UTF8`、部分编辑器会写）。
pub fn stripBom(text: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, text, "\xEF\xBB\xBF")) text[3..] else text;
}

test "渲染：注释 + 分组空行 + 各类值" {
    const a = std.testing.allocator;
    const items = [_]Item{
        .{ .key = "enable", .doc = &.{"总开关"}, .value = .{ .boolean = true } },
        .{ .key = "mode", .doc = &.{ "运行模式", "adminApi | publicSite" }, .value = .{ .string = "adminApi" } },
        listItem("skip", &.{"跳过前缀"}, &.{ "/api", "/pek" }),
        intItem("limit", &.{}, 300),
    };
    const text = try render(a, .{ .header = &.{ "Pek.X 配置", "第二行" } }, &items);
    defer a.free(text);

    try std.testing.expectEqualStrings(
        \\# Pek.X 配置
        \\# 第二行
        \\
        \\# 总开关
        \\enable = true
        \\
        \\# 运行模式
        \\# adminApi | publicSite
        \\mode = "adminApi"
        \\
        \\# 跳过前缀
        \\skip = ["/api", "/pek"]
        \\limit = 300
        \\
    , text);
}

test "渲染：字符串转义" {
    const a = std.testing.allocator;
    const items = [_]Item{
        .{ .key = "path", .value = .{ .string = "C:\\Data\\x\"y" } },
        .{ .key = "ctrl", .value = .{ .string = "a\x01b" } },
    };
    const text = try render(a, .{}, &items);
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"C:\\\\Data\\\\x\\\"y\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\\u0001") != null);
}

test "渲染：空注释行与 raw 值" {
    const a = std.testing.allocator;
    const items = [_]Item{
        .{ .key = "empty", .value = .{ .raw = "[]" } },
        .{ .key = "docs", .doc = &.{ "", "下一行" }, .value = .{ .raw = "[]" }, .blank_before = true },
    };
    const text = try render(a, .{}, &items);
    defer a.free(text);
    try std.testing.expectEqualStrings(
        \\empty = []
        \\
        \\#
        \\# 下一行
        \\docs = []
        \\
    , text);
}

test "补键：按模板顺序插入（不是堆到末尾）" {
    const t = std.testing;
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(t.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer t.allocator.free(dir);
    const path = try std.fmt.allocPrint(t.allocator, "{s}/c.toml", .{dir});
    defer t.allocator.free(path);

    // 文件里已有 A、C，缺中间的 B（模板顺序 A,B,C,D）
    try zzig.fsio.writeFile(io, path,
        \\# 头部注释
        \\A = 1
        \\
        \\# C 的说明
        \\C = 3
        \\
    );

    const items = [_]Item{
        .{ .key = "A", .value = .{ .integer = 1 } },
        .{ .key = "B", .doc = &.{"B 的说明"}, .value = .{ .integer = 2 } },
        .{ .key = "C", .doc = &.{"C 的说明"}, .value = .{ .integer = 3 } },
        .{ .key = "D", .doc = &.{"D 的说明"}, .value = .{ .integer = 4 } },
    };

    const report = (try appendMissing(io, t.allocator, path, &items, .{ .backup = false })).?;
    defer report.deinit(t.allocator);
    try t.expectEqual(@as(usize, 2), report.added.len);

    const after = try zzig.fsio.readFileAlloc(io, t.allocator, path, 1 << 20);
    defer t.allocator.free(after);

    // B 必须在 A 之后、C 之前；D 在 C 之后（末尾）
    const a_pos = std.mem.indexOf(u8, after, "A = 1").?;
    const b_pos = std.mem.indexOf(u8, after, "B = 2").?;
    const c_pos = std.mem.indexOf(u8, after, "C = 3").?;
    const d_pos = std.mem.indexOf(u8, after, "D = 4").?;
    try t.expect(a_pos < b_pos and b_pos < c_pos and c_pos < d_pos);
    // 注释跟着键一起插入
    try t.expect(std.mem.indexOf(u8, after, "# B 的说明") != null);
    // 原注释保留
    try t.expect(std.mem.indexOf(u8, after, "# 头部注释") != null);
    try t.expect(std.mem.indexOf(u8, after, "# C 的说明") != null);

    // 幂等：再跑一次不写（返回 null），文件字节不变
    try t.expect((try appendMissing(io, t.allocator, path, &items, .{ .backup = false })) == null);
    const after2 = try zzig.fsio.readFileAlloc(io, t.allocator, path, 1 << 20);
    defer t.allocator.free(after2);
    try t.expectEqualStrings(after, after2);
}

test "补键：开头缺键插到最前、整份为空则在末尾" {
    const t = std.testing;
    const io = t.io;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try std.fmt.allocPrint(t.allocator, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer t.allocator.free(dir);
    const path = try std.fmt.allocPrint(t.allocator, "{s}/c2.toml", .{dir});
    defer t.allocator.free(path);

    try zzig.fsio.writeFile(io, path,
        \\# 只有 C
        \\C = 3
        \\
    );
    const items = [_]Item{
        .{ .key = "A", .doc = &.{"A 说明"}, .value = .{ .integer = 1 } },
        .{ .key = "C", .doc = &.{"C 说明"}, .value = .{ .integer = 3 } },
    };
    const report = (try appendMissing(io, t.allocator, path, &items, .{ .backup = false })).?;
    defer report.deinit(t.allocator);

    const after = try zzig.fsio.readFileAlloc(io, t.allocator, path, 1 << 20);
    defer t.allocator.free(after);
    try t.expect(std.mem.indexOf(u8, after, "A = 1").? < std.mem.indexOf(u8, after, "C = 3").?);
}
