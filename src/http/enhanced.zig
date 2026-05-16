//! HTTP 增强工具 - 提供更高级的 HTTP 客户端功能
//!
//! 本模块扩展了基础的 HTTP 功能，添加了：
//! - 带重试机制的 HTTP 请求
//! - 表单编码辅助函数
//! - 网络错误处理和重试策略
//! - 统一的超时和错误处理
//!
//! 设计目标：
//! 1. 提高网络请求的可靠性
//! 2. 简化常见网络操作的实现
//! 3. 提供统一的错误处理模式
//! 4. 支持自动重试和超时控制

const std = @import("std");
const zhttp = @import("../http/http.zig");
const compat = @import("../compat.zig");

/// HTTP 重试配置
pub const RetryConfig = struct {
    max_attempts: u32 = 3,          // 最大重试次数
    retry_delay_ms: u64 = 200,      // 重试延迟（毫秒）
    timeout_sec: u32 = 5,           // 请求超时时间（秒）
    poll_interval_ms: u64 = 100,    // 轮询间隔（毫秒）
};

/// HTTP POST 表单字段结构
pub const FormField = struct {
    key: []const u8,
    v1: []const u8,  // 主要值
    v2: []const u8 = "",  // 次要值（如 token_id,token）
};

/// 带重试的 HTTP POST 表单请求
/// 适用于需要高可靠性的 API 调用
pub fn httpPostFormWithRetry(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    url: []const u8,
    body: []const u8,
    config: RetryConfig,
) ![]u8 {
    var attempt: u32 = 1;

    while (true) {
        const data = httpPostFormWithTimeout(allocator, client, url, body, config) catch |err| {
            if (!shouldRetryHttpPost(err, attempt, config.max_attempts)) return err;

            std.debug.print("httpPostForm: attempt={d}/{d} 失败 err={s}，{d}ms 后重试\n", .{
                attempt,
                config.max_attempts,
                @errorName(err),
                config.retry_delay_ms,
            });
            compat.sleep(config.retry_delay_ms * std.time.ns_per_ms);
            attempt += 1;
            continue;
        };

        if (attempt > 1) {
            std.debug.print("httpPostForm: attempt={d}/{d} 重试成功\n", .{ attempt, config.max_attempts });
        }
        return data;
    }
}

/// 带超时的 HTTP POST 表单请求
fn httpPostFormWithTimeout(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    url: []const u8,
    body: []const u8,
    config: RetryConfig,
) ![]u8 {
    // 使用 Zig 0.15.2+ fetch API POST 表单（稳定路径）
    const response = try zhttp.fetchBytesWithTimeout(allocator, client, .{
        .url = url,
        .method = .POST,
        .payload = body,
        .headers = .{
            .content_type = .{ .override = "application/x-www-form-urlencoded" },
        },
        .user_agent = "Zig-HTTP-Client/1.0",
    }, @as(u64, config.timeout_sec) * std.time.ms_per_s, config.poll_interval_ms);
    defer allocator.free(response.body);

    const resp_buf = response.body;

    // 处理 gzip 压缩响应
    if (zhttp.isGzipMagic(resp_buf)) {
        defer allocator.free(resp_buf);
        return try zhttp.gzipDecompressAlloc(allocator, resp_buf);
    }
    return resp_buf;
}

/// 判断 HTTP 错误是否应该重试
fn shouldRetryHttpPost(err: anyerror, attempt: u32, max_attempts: u32) bool {
    if (attempt >= max_attempts) return false;

    // 这些错误通常可以重试
    return switch (err) {
        error.UnknownHostName,
        error.ConnectionRefused,
        error.ConnectionTimedOut,
        error.NetworkUnreachable,
        error.RequestTimeout,
        error.HttpConnectionClosing,
        => true,
        else => false,
    };
}

/// 构造 application/x-www-form-urlencoded 表单体
/// 支持特殊的 login_token 格式（token_id,token）
pub fn buildFormEncoded(
    allocator: std.mem.Allocator,
    fields: []const FormField,
) ![]u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);

    for (fields) |f| {
        if (std.mem.eql(u8, f.key, "login_token")) {
            // 特殊处理 login_token 格式
            const key = try zhttp.percentEncodeFormComponent(allocator, f.key);
            defer allocator.free(key);

            const token_id = try zhttp.percentEncodeFormComponent(allocator, f.v1);
            defer allocator.free(token_id);

            const token = try zhttp.percentEncodeFormComponent(allocator, f.v2);
            defer allocator.free(token);

            const kv = try std.fmt.allocPrint(allocator, "{s}={s},{s}", .{ key, token_id, token });
            try parts.append(allocator, kv);
        } else if (f.v1.len != 0) {
            // 普通字段
            const key = try zhttp.percentEncodeFormComponent(allocator, f.key);
            defer allocator.free(key);

            const value = try zhttp.percentEncodeFormComponent(allocator, f.v1);
            defer allocator.free(value);

            const kv = try std.fmt.allocPrint(allocator, "{s}={s}", .{ key, value });
            try parts.append(allocator, kv);
        }
    }

    const joined = try std.mem.join(allocator, "&", parts.items);
    for (parts.items) |part| allocator.free(part);
    return joined;
}

/// 带重试的获取公网 IP（针对特定 IP 查询服务）
pub fn fetchPublicIPv4WithRetry(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    url: []const u8,
    config: RetryConfig,
) ![]u8 {
    var attempt: u32 = 1;

    while (true) {
        const ip = fetchPublicIPv4(allocator, client, url, config) catch |err| {
            if (!shouldRetryHttpPost(err, attempt, config.max_attempts)) return err;

            std.debug.print("fetchPublicIPv4: attempt={d}/{d} 失败 err={s}，{d}ms 后重试\n", .{
                attempt,
                config.max_attempts,
                @errorName(err),
                config.retry_delay_ms,
            });
            compat.sleep(config.retry_delay_ms * std.time.ns_per_ms);
            attempt += 1;
            continue;
        };

        if (attempt > 1) {
            std.debug.print("fetchPublicIPv4: attempt={d}/{d} 重试成功\n", .{ attempt, config.max_attempts });
        }
        return ip;
    }
}

/// 获取公网 IP（针对特定服务格式）
/// 服务返回格式示例：[{"Type":"IPv4","Ip":"192.168.1.1"},{"Type":"IPv6","Ip":"::1"}]
fn fetchPublicIPv4(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    url: []const u8,
    config: RetryConfig,
) ![]u8 {
    // 准备表单数据（特定服务需要）
    const form_data = "from=hlktech-nuget";

    const response = try zhttp.fetchBytesWithTimeout(allocator, client, .{
        .url = url,
        .method = .POST,
        .payload = form_data,
        .headers = .{
            .content_type = .{ .override = "application/x-www-form-urlencoded" },
        },
    }, @as(u64, config.timeout_sec) * std.time.ms_per_s, config.poll_interval_ms);
    defer allocator.free(response.body);

    const body = response.body;

    // 处理 gzip 压缩
    if (zhttp.isGzipMagic(body)) {
        const unzipped = try zhttp.gzipDecompressAlloc(allocator, body);
        defer allocator.free(unzipped);

        // 这里需要调用者使用 json.Query 来解析 IP
        // 返回原始 JSON 字符串，由调用者解析
        return try allocator.dupe(u8, unzipped);
    }

    // 返回原始 JSON 字符串
    return try allocator.dupe(u8, body);
}

// ============================================================================
// 测试用例
// ============================================================================

test "buildFormEncoded preserves raw comma in login_token" {
    const allocator = std.testing.allocator;

    const fields = [_]FormField{
        .{ .key = "login_token", .v1 = "123456", .v2 = "abcdef" },
        .{ .key = "format", .v1 = "json", .v2 = "" },
    };

    const body = try buildFormEncoded(allocator, &fields);
    defer allocator.free(body);

    try std.testing.expectEqualStrings("login_token=123456,abcdef&format=json", body);
}

test "shouldRetryHttpPost: retry logic" {
    // 应该重试的错误
    try std.testing.expect(shouldRetryHttpPost(error.UnknownHostName, 1, 3));
    try std.testing.expect(shouldRetryHttpPost(error.ConnectionTimedOut, 1, 3));
    try std.testing.expect(shouldRetryHttpPost(error.RequestTimeout, 1, 3));

    // 达到最大重试次数不应重试
    try std.testing.expect(!shouldRetryHttpPost(error.UnknownHostName, 3, 3));

    // 其他错误不应重试
    try std.testing.expect(!shouldRetryHttpPost(error.InvalidConfiguration, 1, 3));
}