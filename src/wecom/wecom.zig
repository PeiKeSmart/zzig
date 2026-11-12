//! 企业微信机器人（Webhook）推送（对齐 DH.RustBase `WeComBot` 的同步入口）。
//!
//! 只做常驻服务/定时任务需要的部分：文本与 markdown 两种消息；按响应 `errcode`
//! 判定成败（0 成功；非 0 视为失败并携带 errmsg）。

const std = @import("std");
const http = @import("../http/http.zig");

pub const Error = error{
    EmptyWebhook,
    HttpFailed,
    BadResponse,
    WeComRejected,
};

pub const Result = struct {
    errcode: i64,
    errmsg: []const u8,
};

/// 发送 markdown 消息（企业微信群机器人）。
pub fn sendMarkdown(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    webhook: []const u8,
    content: []const u8,
    timeout_ms: u64,
    out_errmsg: *[]u8,
) !Result {
    if (std.mem.trim(u8, webhook, " \t").len == 0) return error.EmptyWebhook;

    const Payload = struct {
        msgtype: []const u8 = "markdown",
        markdown: struct { content: []const u8 },
    };
    const body = try std.json.Stringify.valueAlloc(allocator, Payload{ .markdown = .{ .content = content } }, .{});
    defer allocator.free(body);

    const resp = http.fetchBytesWithTimeout(allocator, client, .{
        .url = webhook,
        .method = .POST,
        .payload = body,
        .extra_headers = &.{.{ .name = "content-type", .value = "application/json" }},
        .user_agent = "zzig-wecom/1.0",
    }, timeout_ms, 100) catch return error.HttpFailed;
    defer allocator.free(resp.body);

    const code = @intFromEnum(resp.status);
    if (code < 200 or code >= 300) {
        out_errmsg.* = try std.fmt.allocPrint(allocator, "HTTP {d}: {s}", .{ code, truncate(resp.body) });
        return error.HttpFailed;
    }

    const Body = struct { errcode: i64 = -1, errmsg: []const u8 = "" };
    const parsed = std.json.parseFromSliceLeaky(Body, allocator, resp.body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch {
        out_errmsg.* = try allocator.dupe(u8, truncate(resp.body));
        return error.BadResponse;
    };
    if (parsed.errcode != 0) {
        out_errmsg.* = try std.fmt.allocPrint(allocator, "{d} {s}", .{ parsed.errcode, parsed.errmsg });
        return error.WeComRejected;
    }
    return .{ .errcode = 0, .errmsg = "" };
}

fn truncate(s: []const u8) []const u8 {
    return if (s.len > 200) s[0..200] else s;
}

const testing = std.testing;

test "wecom: 空 webhook 本地拒绝" {
    var client: std.http.Client = .{ .allocator = testing.allocator, .io = testing.io };
    defer client.deinit();
    var msg: []u8 = &.{};
    try testing.expectError(error.EmptyWebhook, sendMarkdown(testing.allocator, &client, "  ", "hi", 1000, &msg));
}
