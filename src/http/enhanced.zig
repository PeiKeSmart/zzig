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

// ============================================================================
// 测试用例
// ============================================================================

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