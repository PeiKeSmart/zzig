//! HTTP/1.1 请求头解析（零拷贝 + RFC 9112 合规校验）。
//!
//! **收编自 lighting**（<https://github.com/jiacai2050/lighting>，MIT License）。
//! 裁剪点：去掉它的 `HeaderMap` —— 本库的 `RequestView.headers` 直接按原始字节扫一遍，
//! 不需要中间容器，因此这里**不需要 allocator**，是纯函数、零分配、可安全用于每连接协程。
//!
//! 保留的校验（都是 RFC 硬性要求，也是请求走私 / 头部注入的防线）：
//! - 请求行严格三段非空、target 字符集（禁控制字符与空格）、`*` 仅 OPTIONS 可用、
//!   CONNECT 必须 authority-form（不能以 `/` 或 `http(s)://` 开头）；
//! - 头名必须是 token 字符集，**禁止冒号前空白**（RFC 9112 §5.1），头值禁 CR/LF 与控制字符；
//! - 多个 `Host` 直接拒绝；`Content-Length` 冲突值拒绝（走私防御）；
//! - `Transfer-Encoding` 只接受 `chunked`，且必须唯一、必须是最后一个 coding；
//! - HTTP/1.1 必须有 `Host`；keep-alive 由 version + `Connection` 推导；
//! - `Transfer-Encoding: chunked` 时 **Content-Length 被忽略**（RFC 9112 §6.1）。
//!
//! 与 lighting 的差异仅限「不建 HeaderMap」，解析规则与错误分类保持一致。

const std = @import("std");

/// HTTP 请求方法（与 lighting 一致：只认标准 9 个，`QUERY` 之类不在内）。
pub const Method = enum {
    GET,
    HEAD,
    POST,
    PUT,
    PATCH,
    DELETE,
    CONNECT,
    OPTIONS,
    TRACE,

    /// 解析方法字符串；无法识别返回 `null`（调用方转成 `error.InvalidMethod`）。
    pub fn parse(s: []const u8) ?Method {
        if (std.mem.eql(u8, s, "GET")) return .GET;
        if (std.mem.eql(u8, s, "POST")) return .POST;
        if (std.mem.eql(u8, s, "PUT")) return .PUT;
        if (std.mem.eql(u8, s, "DELETE")) return .DELETE;
        if (std.mem.eql(u8, s, "HEAD")) return .HEAD;
        if (std.mem.eql(u8, s, "OPTIONS")) return .OPTIONS;
        if (std.mem.eql(u8, s, "PATCH")) return .PATCH;
        if (std.mem.eql(u8, s, "CONNECT")) return .CONNECT;
        if (std.mem.eql(u8, s, "TRACE")) return .TRACE;
        return null;
    }
};

/// HTTP 协议版本。
pub const Version = enum {
    @"HTTP/1.0",
    @"HTTP/1.1",

    pub fn parse(s: []const u8) ?Version {
        if (std.mem.eql(u8, s, "HTTP/1.1")) return .@"HTTP/1.1";
        if (std.mem.eql(u8, s, "HTTP/1.0")) return .@"HTTP/1.0";
        return null;
    }
};

/// 解析结果：所有切片都**借用调用方的 buffer**，生命周期不超出该 buffer。
pub const RequestHead = struct {
    method: Method,
    /// 原始请求目标（路径 + 可选查询串），未解码。
    target: []const u8,
    version: Version,
    /// 显式 `Content-Length`（chunked 时为 null）
    content_length: ?u64 = null,
    /// `Transfer-Encoding` 含 chunked
    is_chunked: bool = false,
    /// 连接是否可复用
    keep_alive: bool = true,
    /// 从头起始到 `\r\n\r\n`（含）消耗的字节数
    bytes_consumed: usize,
};

pub const ParseError = error{
    /// 还没读到完整的 `\r\n\r\n`
    Incomplete,
    InvalidMethod,
    InvalidTarget,
    InvalidVersion,
    InvalidRequestLine,
    InvalidHeader,
    /// 头名与冒号之间有空白（RFC 9112 §5.1 禁止）
    InvalidHeaderColonWhitespace,
    DuplicateHostHeader,
    InvalidContentLength,
    /// HTTP/1.1 缺少 Host
    MissingHostHeader,
    UnsupportedTransferEncoding,
    ChunkedNotFinalTransferEncoding,
    DuplicateChunkedTransferEncoding,
    InvalidTransferEncoding,
};

/// 解析 HTTP/1.x 请求头。`buffer` 必须**从头开始**且可能含 body（多余部分忽略）。
pub fn parseRequestHead(buffer: []const u8) ParseError!RequestHead {
    const end_idx = std.mem.indexOf(u8, buffer, "\r\n\r\n") orelse return error.Incomplete;
    const head_part = buffer[0..end_idx];

    var line_it = std.mem.splitSequence(u8, head_part, "\r\n");
    const request_line = line_it.next() orelse return error.InvalidMethod;

    // 请求行：METHOD SP TARGET SP VERSION（严格三段）
    var req_line_it = std.mem.splitScalar(u8, request_line, ' ');
    const method_str = req_line_it.next() orelse return error.InvalidMethod;
    const target = req_line_it.next() orelse return error.InvalidTarget;
    const version_str = req_line_it.next() orelse return error.InvalidVersion;
    if (req_line_it.next() != null) return error.InvalidRequestLine;
    if (method_str.len == 0 or target.len == 0 or version_str.len == 0) return error.InvalidRequestLine;

    const method = Method.parse(method_str) orelse return error.InvalidMethod;
    const version = Version.parse(version_str) orelse return error.InvalidVersion;

    // RFC 9112 §3.2：target 不得含空格与控制字符
    for (target) |c| {
        if (c <= 0x20 or c == 0x7f) return error.InvalidTarget;
    }

    if (std.mem.eql(u8, target, "*")) {
        if (method != .OPTIONS) return error.InvalidTarget;
    } else if (method == .CONNECT) {
        // CONNECT 用 authority-form（不能是 path 或 absolute URI）
        if (target[0] == '/' or std.ascii.startsWithIgnoreCase(target, "http://") or
            std.ascii.startsWithIgnoreCase(target, "https://"))
        {
            return error.InvalidTarget;
        }
    } else if (target[0] == '/') {
        // origin-form：合法
    } else if (std.ascii.startsWithIgnoreCase(target, "http://") or
        std.ascii.startsWithIgnoreCase(target, "https://"))
    {
        // absolute-form：合法
    } else {
        return error.InvalidTarget;
    }

    var content_length: ?u64 = null;
    var is_chunked = false;
    var has_conn_close = false;
    var has_conn_keep_alive = false;
    var host_count: usize = 0;

    while (line_it.next()) |line| {
        if (line.len == 0) continue;
        const colon_idx = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidHeader;
        const raw_key = line[0..colon_idx];
        if (raw_key.len == 0) return error.InvalidHeader;

        // RFC 9112 §5.1：字段名与冒号之间不允许空白
        if (raw_key[raw_key.len - 1] == ' ' or raw_key[raw_key.len - 1] == '\t') {
            return error.InvalidHeaderColonWhitespace;
        }
        for (raw_key) |c| {
            if (!isValidTokenChar(c)) return error.InvalidHeader;
        }

        const val = std.mem.trim(u8, line[colon_idx + 1 ..], " \t");
        if (!isValidHeaderValue(val)) return error.InvalidHeader;

        if (std.ascii.eqlIgnoreCase(raw_key, "host")) {
            host_count += 1;
            if (host_count > 1) return error.DuplicateHostHeader;
        } else if (std.ascii.eqlIgnoreCase(raw_key, "content-length")) {
            const parsed_cl = std.fmt.parseInt(u64, val, 10) catch return error.InvalidContentLength;
            if (content_length) |existing| {
                // RFC 9112 §6.3：多个冲突的 Content-Length 一律拒绝（请求走私防御）
                if (existing != parsed_cl) return error.InvalidContentLength;
            } else {
                content_length = parsed_cl;
            }
        } else if (std.ascii.eqlIgnoreCase(raw_key, "transfer-encoding")) {
            var te_it = std.mem.splitScalar(u8, val, ',');
            var last_token: ?[]const u8 = null;
            var chunked_count: usize = 0;
            while (te_it.next()) |raw_tok| {
                const tok = std.mem.trim(u8, raw_tok, " \t");
                if (tok.len == 0) return error.InvalidTransferEncoding; // 连续逗号
                last_token = tok;
                if (std.ascii.eqlIgnoreCase(tok, "chunked")) {
                    chunked_count += 1;
                } else {
                    return error.UnsupportedTransferEncoding;
                }
            }
            if (chunked_count > 1) return error.DuplicateChunkedTransferEncoding;
            if (last_token) |last| {
                if (!std.ascii.eqlIgnoreCase(last, "chunked")) return error.ChunkedNotFinalTransferEncoding;
                is_chunked = true;
            } else {
                return error.InvalidTransferEncoding;
            }
        } else if (std.ascii.eqlIgnoreCase(raw_key, "connection")) {
            var conn_it = std.mem.splitScalar(u8, val, ',');
            while (conn_it.next()) |raw_tok| {
                const tok = std.mem.trim(u8, raw_tok, " \t");
                if (std.ascii.eqlIgnoreCase(tok, "close")) {
                    has_conn_close = true;
                } else if (std.ascii.eqlIgnoreCase(tok, "keep-alive")) {
                    has_conn_keep_alive = true;
                }
            }
        }
    }

    // RFC 9112 §6.1：Transfer-Encoding 优先于 Content-Length
    if (is_chunked) content_length = null;

    // RFC 9112 §7.1：HTTP/1.1 必须有 Host
    if (version == .@"HTTP/1.1" and host_count == 0) return error.MissingHostHeader;

    const keep_alive: bool = switch (version) {
        .@"HTTP/1.1" => !has_conn_close,
        .@"HTTP/1.0" => !has_conn_close and has_conn_keep_alive,
    };

    return RequestHead{
        .method = method,
        .target = target,
        .version = version,
        .content_length = content_length,
        .is_chunked = is_chunked,
        .keep_alive = keep_alive,
        .bytes_consumed = end_idx + 4,
    };
}

/// RFC 9110 §5.6.2：头字段名允许的 token 字符。
fn isValidTokenChar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

/// RFC 9110 §5.5：头值不得含 CR/LF 以外的控制字符（TAB 允许）。
fn isValidHeaderValue(value: []const u8) bool {
    for (value) |c| {
        if (c == '\r' or c == '\n') return false;
        if (c < 0x20 and c != '\t') return false;
        if (c == 0x7f) return false;
    }
    return true;
}

// ── 测试（收编时一并对齐 lighting 的用例，保证解析规则没被裁歪）──

test "parseRequestHead 简单 GET" {
    const raw = "GET /index.html HTTP/1.1\r\nHost: example.com\r\nUser-Agent: curl\r\n\r\n";
    const head = try parseRequestHead(raw);
    try std.testing.expectEqual(Method.GET, head.method);
    try std.testing.expectEqualStrings("/index.html", head.target);
    try std.testing.expectEqual(Version.@"HTTP/1.1", head.version);
    try std.testing.expectEqual(true, head.keep_alive);
    try std.testing.expectEqual(raw.len, head.bytes_consumed);
}

test "parseRequestHead POST + content-length + connection close" {
    const raw = "POST /api/data HTTP/1.1\r\nHost: localhost\r\nContent-Length: 42\r\nConnection: close\r\n\r\nrest";
    const head = try parseRequestHead(raw);
    try std.testing.expectEqual(Method.POST, head.method);
    try std.testing.expectEqual(@as(?u64, 42), head.content_length);
    try std.testing.expectEqual(false, head.keep_alive);
}

test "parseRequestHead chunked 覆盖 content-length" {
    const raw = "POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n";
    const head = try parseRequestHead(raw);
    try std.testing.expectEqual(true, head.is_chunked);
    try std.testing.expectEqual(@as(?u64, null), head.content_length);
}

test "parseRequestHead 拒绝重复 Host / 冲突 Content-Length / 冒号前空白" {
    try std.testing.expectError(
        error.DuplicateHostHeader,
        parseRequestHead("GET / HTTP/1.1\r\nHost: a\r\nHost: b\r\n\r\n"),
    );
    try std.testing.expectError(
        error.InvalidContentLength,
        parseRequestHead("POST / HTTP/1.1\r\nHost: a\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\n"),
    );
    try std.testing.expectError(
        error.InvalidHeaderColonWhitespace,
        parseRequestHead("GET / HTTP/1.1\r\nHost : a\r\n\r\n"),
    );
}

test "parseRequestHead HTTP/1.1 缺 Host 报错，1.0 允许" {
    try std.testing.expectError(error.MissingHostHeader, parseRequestHead("GET / HTTP/1.1\r\n\r\n"));
    const h10 = try parseRequestHead("GET / HTTP/1.0\r\n\r\n");
    try std.testing.expectEqual(false, h10.keep_alive);
}

test "parseRequestHead 不完整时报 Incomplete" {
    try std.testing.expectError(error.Incomplete, parseRequestHead("GET / HTTP/1.1\r\nHost: a\r\n"));
}
