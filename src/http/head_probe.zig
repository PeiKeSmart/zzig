//! 【通用】线上实测头探针：对本机实例发一次**真实 HTTP 请求**，把响应的 `<head>` 解析成可判定的事实。
//!
//! 为什么真发请求、而不是直接调渲染函数：体检要回答的是「**爬虫实际拿到了什么**」——
//! 中间还隔着 WAF（UA 分类 / 敏感前缀）、路由、多语言前缀、gzip、状态码。
//! 直接调渲染函数会绕过这些，那就变成了「配置判定」而不是「实测」。
//!
//! **不出外网**：目标固定是本机监听地址（`0.0.0.0` / `::` 一律归一成回环），
//! 单次开销 ≈ 1–3 ms，只读前 256 KB（读到 `</head>` 就停）。
//!
//! 超时策略：Windows 走 AFD 设原生读超时；**Debug 构建下不设** —— Linux 上 `SO_RCVTIMEO`
//! 到点返回 `EAGAIN`，`std.Io` 在 Debug 会当成 programmer bug 直接 panic（见
//! `net/socket_timeout.zig` 的说明）。本机回环 + `Connection: close`，正常都是一次读完。

const std = @import("std");
const compat = @import("../compat.zig");
const socket_timeout = @import("../net/socket_timeout.zig");
const http = @import("http.zig");

/// 一次探测的参数。
pub const Request = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 0,
    path: []const u8 = "/",
    /// 用爬虫 UA 才有意义：拿 403 就说明「配置说允许、但机器上并不允许」。
    user_agent: []const u8 = "Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)",
    timeout_ms: u32 = 3000,
    /// 最多读多少字节（`</head>` 之前的内容一定够判定）。
    max_bytes: usize = 256 * 1024,
};

/// 探测结果（全部切片都分配在传入的 arena 上）。
pub const Head = struct {
    /// 是否成功连上并拿到响应（`false` 时看 `failure`）。
    reached: bool = false,
    status: u16 = 0,
    took_us: i64 = 0,
    failure: []const u8 = "",
    content_type: []const u8 = "",
    gzip: bool = false,
    /// 实际读到的字节数（响应头 + 正文；读到 `</head>` 就停，所以小于整页大小）。
    bytes: usize = 0,
    /// 已解压的 HTML（`reached` 为真时有效）。
    html: []const u8 = "",
    /// `<html lang="…">`
    lang: []const u8 = "",
    title: []const u8 = "",
    description: []const u8 = "",
    keywords: []const u8 = "",
    canonical: []const u8 = "",
    robots: []const u8 = "",
    og_url: []const u8 = "",
    /// `<link rel="alternate" hreflang="…">` 的条数（含 `x-default`）
    hreflang: usize = 0,
    x_default: bool = false,
    /// JSON-LD 里出现的 `@type`（逗号分隔，已去重）
    ld_types: []const u8 = "",
    /// JSON-LD 里的 `inLanguage`（与 `<html lang>` 不一致就是自相矛盾，搜索引擎会困惑）
    ld_lang: []const u8 = "",

    /// `robots` 是否明确禁止收录。
    pub fn noindex(self: Head) bool {
        return containsIgnoreCase(self.robots, "noindex");
    }
};

/// 发请求并解析。**任何失败都不抛错**，写进 `failure` 后返回。
pub fn fetch(arena: std.mem.Allocator, io: std.Io, req: Request) Head {
    const t0 = compat.nanoTimestamp();
    var head = fetchInner(arena, io, req);
    // 耗时必须在**返回之后**赋值：`defer` 里的修改改不到已经复制出去的返回值（踩过）。
    head.took_us = @intCast(@divTrunc(compat.nanoTimestamp() - t0, 1000));
    return head;
}

fn fetchInner(arena: std.mem.Allocator, io: std.Io, req: Request) Head {
    var head: Head = .{};

    const host = normalizeHost(req.host);
    if (req.port == 0) {
        head.failure = "端口为 0（服务未监听）";
        return head;
    }

    const address = std.Io.net.IpAddress.parse(host, req.port) catch blk: {
        // 监听的是域名/通配地址时退回回环 —— 体检只关心「本机这个实例」。
        break :blk std.Io.net.IpAddress.parse("127.0.0.1", req.port) catch {
            head.failure = "监听地址无法解析";
            return head;
        };
    };

    const stream = std.Io.net.IpAddress.connect(&address, io, .{ .mode = .stream, .protocol = .tcp }) catch |err| {
        head.failure = std.fmt.allocPrint(arena, "{s}:{d} 连接失败：{s}", .{ host, req.port, @errorName(err) }) catch "连接失败";
        return head;
    };
    defer stream.close(io);

    if (@import("builtin").mode != .debug) {
        socket_timeout.setRecvTimeout(io, stream, req.timeout_ms) catch {};
    }

    // ————— 发请求 —————
    const text = std.fmt.allocPrint(
        arena,
        "GET {s} HTTP/1.1\r\nHost: {s}:{d}\r\nUser-Agent: {s}\r\nAccept: text/html,application/xhtml+xml\r\n" ++
            "Accept-Encoding: identity\r\nConnection: close\r\n\r\n",
        .{ req.path, host, req.port, req.user_agent },
    ) catch {
        head.failure = "请求文本分配失败";
        return head;
    };

    {
        var wbuf: [1024]u8 = undefined;
        var w = stream.writer(io, &wbuf);
        w.interface.writeAll(text) catch |err| {
            head.failure = std.fmt.allocPrint(arena, "发送请求失败：{s}", .{@errorName(err)}) catch "发送请求失败";
            return head;
        };
        w.interface.flush() catch |err| {
            head.failure = std.fmt.allocPrint(arena, "发送请求失败：{s}", .{@errorName(err)}) catch "发送请求失败";
            return head;
        };
    }

    // ————— 读响应（读到 `</head>` / 上限 / EOF 为止）—————
    var raw: std.ArrayListUnmanaged(u8) = .empty;
    {
        var rbuf: [8192]u8 = undefined;
        var r = stream.reader(io, &rbuf);
        var chunk: [8192]u8 = undefined;
        while (raw.items.len < req.max_bytes) {
            const n = r.interface.readSliceShort(&chunk) catch |err| {
                if (raw.items.len == 0) {
                    head.failure = std.fmt.allocPrint(arena, "读取响应失败：{s}", .{@errorName(err)}) catch "读取响应失败";
                    return head;
                }
                break; // 已经拿到一部分就按现状解析
            };
            if (n == 0) break;
            raw.appendSlice(arena, chunk[0..n]) catch break;
            if (std.mem.indexOf(u8, raw.items, "</head>") != null) break;
        }
    }
    if (raw.items.len == 0) {
        head.failure = "服务端没有返回任何内容";
        return head;
    }

    const resp = raw.items;
    head.bytes = resp.len;
    const head_end = std.mem.indexOf(u8, resp, "\r\n\r\n") orelse resp.len;
    const head_part = resp[0..head_end];
    const payload = if (head_end < resp.len) resp[head_end + 4 ..] else "";

    head.status = parseStatus(head_part);
    head.content_type = headerValue(arena, head_part, "content-type") orelse "";
    head.gzip = blk: {
        const enc = headerValue(arena, head_part, "content-encoding") orelse break :blk false;
        break :blk containsIgnoreCase(enc, "gzip");
    };
    if (head.status == 0) {
        head.failure = "响应不是合法 HTTP（首行无法解析状态码）";
        return head;
    }
    head.reached = true;

    var html = payload;
    if (head.gzip and payload.len > 0) {
        html = http.gzipDecompressAlloc(arena, payload) catch payload;
    }
    head.html = html;

    head.lang = attrInTag(html, "<html", "lang") orelse "";
    head.title = tagInner(html, "<title", "</title>") orelse "";
    head.description = metaContent(arena, html, "name", "description") orelse "";
    head.keywords = metaContent(arena, html, "name", "keywords") orelse "";
    head.robots = metaContent(arena, html, "name", "robots") orelse "";
    head.og_url = metaContent(arena, html, "property", "og:url") orelse "";
    head.canonical = linkAttr(arena, html, "canonical") orelse "";
    countHreflang(html, &head);
    head.ld_types = jsonLdTypes(arena, html) catch "";
    head.ld_lang = jsonLdString(arena, html, "inLanguage") orelse "";
    return head;
}

fn normalizeHost(host: []const u8) []const u8 {
    const t = std.mem.trim(u8, host, " \t\r\n");
    if (t.len == 0) return "127.0.0.1";
    const wildcards = [_][]const u8{ "0.0.0.0", "*", "::", "[::]", "::0" };
    for (wildcards) |w| {
        if (std.mem.eql(u8, t, w)) return "127.0.0.1";
    }
    return t;
}

fn parseStatus(head_part: []const u8) u16 {
    // 首行形如 `HTTP/1.1 200 OK`
    const nl = std.mem.indexOf(u8, head_part, "\r\n") orelse head_part.len;
    const line = head_part[0..nl];
    if (!std.mem.startsWith(u8, line, "HTTP/")) return 0;
    const sp = std.mem.indexOfScalar(u8, line, ' ') orelse return 0;
    const rest = std.mem.trimStart(u8, line[sp + 1 ..], " ");
    if (rest.len < 3) return 0;
    return std.fmt.parseInt(u16, rest[0..3], 10) catch 0;
}

/// 响应头取值（名字大小写无关；返回的是 arena 上的副本，便于跟正文一起活到渲染结束）。
fn headerValue(arena: std.mem.Allocator, head_part: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, head_part, "\r\n");
    _ = it.next(); // 状态行
    while (it.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), name)) continue;
        const value = std.mem.trim(u8, line[colon + 1 ..], " \t");
        return arena.dupe(u8, value) catch null;
    }
    return null;
}

/// 取 `<tag …attr="value"…>` 里的属性值。
fn attrInTag(html: []const u8, open_prefix: []const u8, attr: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, html, open_prefix) orelse return null;
    const close = std.mem.indexOfScalarPos(u8, html, start, '>') orelse return null;
    return attrIn(html[start..close], attr);
}

/// 在单个标签文本里找 `attr="value"`（大小写无关，双引号）。
fn attrIn(tag: []const u8, attr: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < tag.len) : (i += 1) {
        if (!std.ascii.eqlIgnoreCase(tag[i..@min(tag.len, i + attr.len)], attr)) continue;
        // 前面必须是空白，避免 `data-lang` 命中 `lang`
        if (i > 0 and !std.ascii.isWhitespace(tag[i - 1])) continue;
        var j = i + attr.len;
        while (j < tag.len and std.ascii.isWhitespace(tag[j])) j += 1;
        if (j >= tag.len or tag[j] != '=') continue;
        j += 1;
        while (j < tag.len and std.ascii.isWhitespace(tag[j])) j += 1;
        if (j >= tag.len or tag[j] != '"') continue;
        const rest = tag[j + 1 ..];
        const end = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
        return rest[0..end];
    }
    return null;
}

fn tagInner(html: []const u8, open_prefix: []const u8, close_tag: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, html, open_prefix) orelse return null;
    const gt = std.mem.indexOfScalarPos(u8, html, start, '>') orelse return null;
    const rest = html[gt + 1 ..];
    const end = std.mem.indexOf(u8, rest, close_tag) orelse return null;
    return rest[0..end];
}

/// `<meta name="description" content="…">` / `<meta property="og:url" content="…">`
fn metaContent(arena: std.mem.Allocator, html: []const u8, key_attr: []const u8, key_value: []const u8) ?[]const u8 {
    var rest = html;
    while (std.mem.indexOf(u8, rest, "<meta")) |i| {
        rest = rest[i..];
        const gt = std.mem.indexOfScalar(u8, rest, '>') orelse return null;
        const tag = rest[0..gt];
        if (attrIn(tag, key_attr)) |value| {
            if (std.ascii.eqlIgnoreCase(value, key_value)) {
                if (attrIn(tag, "content")) |content| {
                    return arena.dupe(u8, std.mem.trim(u8, content, " \t\r\n")) catch null;
                }
            }
        }
        rest = rest[gt..];
    }
    return null;
}

/// `<link rel="canonical" href="…">`
fn linkAttr(arena: std.mem.Allocator, html: []const u8, rel_value: []const u8) ?[]const u8 {
    var rest = html;
    while (std.mem.indexOf(u8, rest, "<link")) |i| {
        rest = rest[i..];
        const gt = std.mem.indexOfScalar(u8, rest, '>') orelse return null;
        const tag = rest[0..gt];
        if (attrIn(tag, "rel")) |rel| {
            if (std.ascii.eqlIgnoreCase(rel, rel_value)) {
                if (attrIn(tag, "href")) |href| return arena.dupe(u8, href) catch null;
            }
        }
        rest = rest[gt..];
    }
    return null;
}

fn countHreflang(html: []const u8, out: *Head) void {
    var rest = html;
    while (std.mem.indexOf(u8, rest, "<link")) |i| {
        rest = rest[i..];
        const gt = std.mem.indexOfScalar(u8, rest, '>') orelse return;
        const tag = rest[0..gt];
        if (attrIn(tag, "hreflang")) |v| {
            out.hreflang += 1;
            if (std.ascii.eqlIgnoreCase(v, "x-default")) out.x_default = true;
        }
        rest = rest[gt..];
    }
}

/// 汇总 JSON-LD 里出现的 `@type`（去重，逗号分隔）。
fn jsonLdTypes(arena: std.mem.Allocator, html: []const u8) ![]const u8 {
    var types: std.ArrayListUnmanaged([]const u8) = .empty;
    var rest = html;
    const open = "<script type=\"application/ld+json\">";
    while (std.mem.indexOf(u8, rest, open)) |i| {
        const after = rest[i + open.len ..];
        const end = std.mem.indexOf(u8, after, "</script>") orelse break;
        var json = after[0..end];
        while (std.mem.indexOf(u8, json, "\"@type\"")) |k| {
            var p = json[k + "\"@type\"".len ..];
            p = std.mem.trimStart(u8, p, " \t\r\n:");
            if (p.len > 0 and p[0] == '"') {
                p = p[1..];
                if (std.mem.indexOfScalar(u8, p, '"')) |q| {
                    const name = p[0..q];
                    if (name.len > 0 and !hasString(types.items, name)) try types.append(arena, name);
                }
            }
            json = json[k + "\"@type\"".len ..];
        }
        rest = after[end + "</script>".len ..];
    }

    var out: std.ArrayListUnmanaged(u8) = .empty;
    for (types.items, 0..) |name, idx| {
        if (idx > 0) try out.appendSlice(arena, " / ");
        try out.appendSlice(arena, name);
    }
    return out.toOwnedSlice(arena);
}

fn hasString(items: []const []const u8, needle: []const u8) bool {
    for (items) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

/// 从页面里任一 JSON-LD 块取出某个字符串字段（目前用于 `inLanguage`）。
fn jsonLdString(arena: std.mem.Allocator, html: []const u8, key: []const u8) ?[]const u8 {
    var rest = html;
    while (std.mem.indexOf(u8, rest, "application/ld+json")) |i| {
        const after = rest[i..];
        const gt = std.mem.indexOfScalar(u8, after, '>') orelse return null;
        const body_start = gt + 1;
        const end = std.mem.indexOf(u8, after[body_start..], "</script>") orelse return null;
        const json = after[body_start .. body_start + end];
        if (std.mem.indexOf(u8, json, key)) |k| {
            var p = json[k + key.len ..];
            // 紧接着的是 key 自己的**结束引号**，先跳过它再跳过 `:` 与空白，
            // 否则会把 `: ` 当成值（2026-11-23 踩过，页面上显示「JSON-LD 写 :」）。
            p = std.mem.trimStart(u8, p, "\"");
            p = std.mem.trimStart(u8, p, " \t\r\n:");
            if (p.len > 0 and p[0] == '"') {
                p = p[1..];
                if (std.mem.indexOfScalar(u8, p, '"')) |q| return arena.dupe(u8, p[0..q]) catch null;
            }
        }
        rest = after[body_start + end ..];
    }
    return null;
}

/// 子串查找（大小写无关）。`std.ascii` 在 0.17 里没有现成的 indexOfIgnoreCase。
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

// ————————————————— 测试 —————————————————
//
// 覆盖：状态行 / 响应头解析（大小写无关、缺失返回 null）、head 关键项抽取
// （title / description / keywords / robots / og:url / canonical / hreflang / JSON-LD）、
// `robots: noindex` 识别、通配监听地址归一成回环。

const testing = std.testing;

test "zzig.web.head_probe：解析状态行与响应头" {
    const resp = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Encoding: gzip\r\n\r\nBODY";
    const sep = std.mem.indexOf(u8, resp, "\r\n\r\n").?;
    try testing.expectEqual(@as(u16, 200), parseStatus(resp[0..sep]));
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("text/html; charset=utf-8", headerValue(arena, resp[0..sep], "CONTENT-TYPE").?);
    try testing.expect(headerValue(arena, resp[0..sep], "x-missing") == null);
}

test "zzig.web.head_probe：解析 head 里的关键项" {
    const html =
        \\<!DOCTYPE html><html lang="zh-CN"><head>
        \\<title>公司简介</title>
        \\<meta name="description" content="查询你的公网出口 IP">
        \\<meta name="keywords" content="IP">
        \\<meta name="robots" content="index,follow">
        \\<meta property="og:url" content="https://x/">
        \\<link rel="canonical" href="https://x/client-ip">
        \\<link rel="alternate" hreflang="zh-CN" href="https://x/">
        \\<link rel="alternate" hreflang="x-default" href="https://x/">
        \\<script type="application/ld+json">{"@type":"FAQPage","mainEntity":[]}</script>
        \\<script type="application/ld+json">{"@type": "WebSite"}</script>
        \\</head><body>x</body></html>
    ;
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings("zh-CN", attrInTag(html, "<html", "lang").?);
    try testing.expectEqualStrings("公司简介", tagInner(html, "<title", "</title>").?);
    try testing.expectEqualStrings("查询你的公网出口 IP", metaContent(arena, html, "name", "description").?);
    try testing.expectEqualStrings("index,follow", metaContent(arena, html, "name", "robots").?);
    try testing.expectEqualStrings("https://x/", metaContent(arena, html, "property", "og:url").?);
    try testing.expectEqualStrings("https://x/client-ip", linkAttr(arena, html, "canonical").?);

    var head: Head = .{};
    countHreflang(html, &head);
    try testing.expectEqual(@as(usize, 2), head.hreflang);
    try testing.expect(head.x_default);

    const types = try jsonLdTypes(arena, html);
    try testing.expectEqualStrings("FAQPage / WebSite", types);
}

test "zzig.web.head_probe：robots noindex 识别" {
    var head: Head = .{};
    head.robots = "NOINDEX, nofollow";
    try testing.expect(head.noindex());
    head.robots = "index,follow";
    try testing.expect(!head.noindex());
}

test "zzig.web.head_probe：通配监听地址归一成回环" {
    try testing.expectEqualStrings("127.0.0.1", normalizeHost("0.0.0.0"));
    try testing.expectEqualStrings("127.0.0.1", normalizeHost("::"));
    try testing.expectEqualStrings("127.0.0.1", normalizeHost(""));
    try testing.expectEqualStrings("192.168.1.5", normalizeHost("192.168.1.5"));
}
