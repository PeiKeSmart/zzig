//! 文本级键值读写：**保留注释与其它行**，只动目标那一行。
//!
//! 为什么需要它（而不是每次都 parse 再整体重写）：
//! - 运维手写的配置文件里有大段注释、分组空行、自定义顺序；
//! - 「面板保存一个开关」不应该把整份文件重新排版；
//! - 而用字符串搜索定位又容易误伤（注释里出现同样的键名）。
//!
//! 本模块的做法是**行级**定位：跳过行首空白后以 `key` 开头、且紧跟 `=` / 空白
//! 的行才算键行（`# key = ...` 这类注释不会被命中）。
//!
//! 只处理「值是不带内嵌引号/换行的简单字符串或标量」的场景——需要改数组/多行字符串时
//! 请用 `toml_template` 重新生成整份文件。

const std = @import("std");
const fsio = @import("../file/fsio.zig");

/// 单文件读取上限（超过视为异常配置，调用方按需调整）。
pub const MAX_CONFIG_BYTES: usize = 1 << 20;

/// 读 `Key = value`（自动去引号）；找不到返回 `null`。
///
/// 返回的切片**借用 `text`**，不做分配。
pub fn get(text: []const u8, key: []const u8) ?[]const u8 {
    var iterator = std.mem.splitScalar(u8, text, '\n');
    while (iterator.next()) |line| {
        if (!isKeyLine(line, key)) continue;
        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        var value = std.mem.trim(u8, line[eq + 1 ..], " \t\r");
        // 行尾注释：`Key = "x"  # 说明`
        if (std.mem.indexOfScalar(u8, value, '#')) |hash| value = std.mem.trim(u8, value[0..hash], " \t");
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
            value = value[1 .. value.len - 1];
        }
        return if (value.len > 0) value else null;
    }
    return null;
}

/// 行级替换 `Key = "value"`（找不到就追加到末尾），返回新文本（调用方 `free`）。
///
/// 一律写成**带引号的字符串**：调用方传数字/布尔时也会被引起来 —— 需要标量时请直接用
/// `toml_template` 生成整份配置。这样做的目的是让「面板保存」这条路径行为可预期。
pub fn set(allocator: std.mem.Allocator, text: []const u8, key: []const u8, value: []const u8) ![]u8 {
    // 拼接用的临时行放内部 arena：返回的文本用调用方 allocator，中间分配一次释放。
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var lines: std.ArrayList([]const u8) = .empty;
    var replaced = false;

    var iterator = std.mem.splitScalar(u8, text, '\n');
    while (iterator.next()) |line| {
        if (!replaced and isKeyLine(line, key)) {
            // 保留原行尾注释，便于运维继续看懂这一行为什么这么配
            const tail = if (std.mem.indexOfScalar(u8, line, '#')) |hash| line[hash..] else "";
            if (tail.len > 0) {
                try lines.append(a, try std.fmt.allocPrint(a, "{s} = \"{s}\"  {s}", .{ key, value, tail }));
            } else {
                try lines.append(a, try std.fmt.allocPrint(a, "{s} = \"{s}\"", .{ key, value }));
            }
            replaced = true;
            continue;
        }
        try lines.append(a, line);
    }
    if (!replaced) {
        try lines.append(a, try std.fmt.allocPrint(a, "{s} = \"{s}\"", .{ key, value }));
    }
    return std.mem.join(allocator, "\n", lines.items);
}

/// 批量改键并**原子写回**（保留注释、其它行与原有键序）。
///
/// 任何一步失败都不会留下半个文件：写入走 `fsio.writeFileAtomic`。
/// 文件不存在或全为空时静默返回（配置尚未生成，交给模板生成流程）。
pub fn writeAll(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    updates: []const [2][]const u8,
) !void {
    if (updates.len == 0) return;
    const existing = fsio.readFileAlloc(io, allocator, path, MAX_CONFIG_BYTES) catch return;
    defer allocator.free(existing);
    if (std.mem.trim(u8, existing, " \t\r\n").len == 0) return;

    var current = try allocator.dupe(u8, existing);
    defer allocator.free(current);
    for (updates) |pair| {
        const next = try set(allocator, current, pair[0], pair[1]);
        allocator.free(current);
        current = next;
    }
    try fsio.writeFileAtomic(io, allocator, path, current);
}

/// 把键 `old_key` 改名为 `new_key`：**值、行尾注释、行首缩进原样保留**。
///
/// 用途：配置项改名迁移（旧名 → 与框架/规范统一的新名）。规矩：
/// - `new_key` 已存在 → 返回 `null`（**不覆盖**新名，哪怕值是空的）；
/// - `old_key` 不存在 → 返回 `null`；
/// - 返回 `null` 时调用方**不要写文件**（幂等，二次启动零写入）。
pub fn rename(
    allocator: std.mem.Allocator,
    text: []const u8,
    old_key: []const u8,
    new_key: []const u8,
) !?[]u8 {
    // 注意：不能用 `get` 判断存在性 —— 它对**空值**（`Key = ""`）返回 null，
    // 而空值键同样需要改名（刚开始就是空的，后面才填）。这里只看「有没有这个键行」。
    if (findKeyLine(text, new_key) != null) return null;
    if (findKeyLine(text, old_key) == null) return null;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var lines: std.ArrayList([]const u8) = .empty;
    var renamed = false;
    var iterator = std.mem.splitScalar(u8, text, '\n');
    while (iterator.next()) |line| {
        if (renamed or !isKeyLine(line, old_key)) {
            try lines.append(a, line);
            continue;
        }
        var i: usize = 0;
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
        const rest = line[i + old_key.len ..];
        try lines.append(a, try std.fmt.allocPrint(a, "{s}{s}{s}", .{ line[0..i], new_key, rest }));
        renamed = true;
    }
    if (!renamed) return null;
    return try std.mem.join(allocator, "\n", lines.items);
}

/// 找 `key` 的键行号（0 基）；不存在返回 `null`。**与值是否为空无关**。
pub fn findKeyLine(text: []const u8, key: []const u8) ?usize {
    var index: usize = 0;
    var iterator = std.mem.splitScalar(u8, text, '\n');
    while (iterator.next()) |line| : (index += 1) {
        if (isKeyLine(line, key)) return index;
    }
    return null;
}

/// 该行是否是 `key` 的键行（行首空白后可跟 `=` 或空白；`#` 开头的注释行不算）。
pub fn isKeyLine(line: []const u8, key: []const u8) bool {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t' or line[i] == '\r')) : (i += 1) {}
    const trimmed = line[i..];
    if (trimmed.len == 0 or trimmed[0] == '#') return false;
    if (!std.mem.startsWith(u8, trimmed, key)) return false;
    const rest = trimmed[key.len..];
    if (rest.len == 0) return false;
    return rest[0] == ' ' or rest[0] == '\t' or rest[0] == '=';
}

const testing = std.testing;

test "text_keys：get / set 保留注释与其它键" {
    const text =
        \\# 说明
        \\SiteName = "old"
        \\AdminArea = "Admin"
    ;
    try testing.expectEqualStrings("old", get(text, "SiteName").?);
    try testing.expect(get(text, "ProbeIpv4Url") == null);

    const updated = try set(testing.allocator, text, "SiteName", "new");
    defer testing.allocator.free(updated);
    try testing.expect(std.mem.indexOf(u8, updated, "SiteName = \"new\"") != null);
    try testing.expect(std.mem.indexOf(u8, updated, "# 说明") != null);
    try testing.expect(std.mem.indexOf(u8, updated, "AdminArea = \"Admin\"") != null);
    try testing.expect(std.mem.indexOf(u8, updated, "old") == null);
}

test "text_keys：追加缺失键与行尾注释保留" {
    const text =
        \\# 头部
        \\SiteName = "old"  # 站点名
    ;
    const appended = try set(testing.allocator, text, "ProbeIpv4Url", "http://x");
    defer testing.allocator.free(appended);
    try testing.expect(std.mem.indexOf(u8, appended, "ProbeIpv4Url = \"http://x\"") != null);

    const kept_comment = try set(testing.allocator, text, "SiteName", "new");
    defer testing.allocator.free(kept_comment);
    try testing.expect(std.mem.indexOf(u8, kept_comment, "# 站点名") != null);
    try testing.expectEqualStrings("new", get(kept_comment, "SiteName").?);
}

test "text_keys：注释里出现键名不算命中" {
    const text =
        \\# SiteName = "fake"
        \\AdminArea = "Admin"
    ;
    try testing.expect(get(text, "SiteName") == null);
    try testing.expectEqualStrings("Admin", get(text, "AdminArea").?);
}

test "text_keys：改名保留值与行尾注释，新名已存在则不动" {
    const text =
        \\# 头部
        \\SiteUrl = "https://x.example"  # 对外地址
        \\AdminArea = "Admin"
    ;
    const renamed = (try rename(testing.allocator, text, "SiteUrl", "CurDomainUrl")).?;
    defer testing.allocator.free(renamed);
    try testing.expectEqualStrings("https://x.example", get(renamed, "CurDomainUrl").?);
    try testing.expect(get(renamed, "SiteUrl") == null);
    try testing.expect(std.mem.indexOf(u8, renamed, "# 对外地址") != null);
    try testing.expect(std.mem.indexOf(u8, renamed, "# 头部") != null);

    // 新名已存在 → 不覆盖、返回 null
    const both =
        \\SiteUrl = "old"
        \\CurDomainUrl = "keep"
    ;
    try testing.expect((try rename(testing.allocator, both, "SiteUrl", "CurDomainUrl")) == null);
    // 旧名不存在 → 返回 null（幂等）
    try testing.expect((try rename(testing.allocator, text, "NoSuchKey", "X")) == null);

    // 空值键也要能改名（`get` 对空值返回 null，rename 不能据此判断存在性）
    const empty =
        \\SiteUrl = ""
        \\AdminArea = "Admin"
    ;
    const renamed_empty = (try rename(testing.allocator, empty, "SiteUrl", "CurDomainUrl")).?;
    defer testing.allocator.free(renamed_empty);
    try testing.expect(findKeyLine(renamed_empty, "CurDomainUrl") != null);
    try testing.expect(findKeyLine(renamed_empty, "SiteUrl") == null);
}
