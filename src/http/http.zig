const std = @import("std");
const compat = @import("../compat.zig");

pub const FormField = struct {
    key: []const u8,
    value: []const u8,
};

pub const RequestOptions = struct {
    url: []const u8,
    method: std.http.Method = .GET,
    payload: ?[]const u8 = null,
    headers: std.http.Client.Request.Headers = .{},
    user_agent: ?[]const u8 = null,
};

pub const Response = struct {
    status: std.http.Status,
    body: []u8,
};

const ResponseResult = struct {
    response: ?Response = null,
    err: ?anyerror = null,
    completed: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

pub fn isGzipMagic(buf: []const u8) bool {
    return buf.len >= 2 and buf[0] == 0x1F and buf[1] == 0x8B;
}

pub fn gzipDecompressAlloc(allocator: std.mem.Allocator, compressed: []const u8) ![]u8 {
    var input_reader: std.Io.Reader = .fixed(compressed);
    var decompressor = std.compress.flate.Decompress.init(&input_reader, .gzip, &.{});

    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();

    _ = try decompressor.reader.streamRemaining(&output.writer);

    if (decompressor.err) |err| {
        output.deinit();
        return err;
    }

    return try output.toOwnedSlice();
}

pub fn percentEncodeFormComponent(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    try out.ensureTotalCapacityPrecise(allocator, s.len + s.len / 4);
    const hex = "0123456789ABCDEF";

    for (s) |c| switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => try out.append(allocator, c),
        ' ' => try out.appendSlice(allocator, "%20"),
        else => {
            try out.append(allocator, '%');
            try out.append(allocator, hex[(c >> 4) & 0xF]);
            try out.append(allocator, hex[c & 0xF]);
        },
    };

    return out.toOwnedSlice(allocator);
}

pub fn buildFormUrlEncoded(allocator: std.mem.Allocator, fields: []const FormField) ![]u8 {
    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);

    for (fields) |field| {
        const key = try percentEncodeFormComponent(allocator, field.key);
        defer allocator.free(key);

        const value = try percentEncodeFormComponent(allocator, field.value);
        defer allocator.free(value);

        const part = try std.fmt.allocPrint(allocator, "{s}={s}", .{ key, value });
        try parts.append(allocator, part);
    }

    const joined = try std.mem.join(allocator, "&", parts.items);
    for (parts.items) |part| allocator.free(part);
    return joined;
}

pub fn fetchBytes(allocator: std.mem.Allocator, client: *std.http.Client, options: RequestOptions) !Response {
    var headers = options.headers;
    if (options.user_agent) |user_agent| {
        headers.user_agent = .{ .override = user_agent };
    }

    var allocating_writer = std.Io.Writer.Allocating.init(allocator);
    defer allocating_writer.deinit();

    const result = try client.fetch(.{
        .location = .{ .url = options.url },
        .method = options.method,
        .payload = options.payload,
        .headers = headers,
        .response_writer = &allocating_writer.writer,
    });

    const body = try allocator.dupe(u8, allocating_writer.writer.buffer[0..allocating_writer.writer.end]);
    return .{ .status = result.status, .body = body };
}

pub fn fetchBytesWithTimeout(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    options: RequestOptions,
    timeout_ms: u64,
    poll_interval_ms: u64,
) !Response {
    if (timeout_ms == 0) return fetchBytes(allocator, client, options);

    const io = client.io;
    var result = ResponseResult{};
    var future = io.concurrent(fetchWorker, .{ allocator, client, options, &result }) catch |err| switch (err) {
        error.ConcurrencyUnavailable => return fetchBytes(allocator, client, options),
    };

    const timeout_ns: i128 = @as(i128, @intCast(timeout_ms)) * std.time.ns_per_ms;
    const start_time = compat.nanoTimestamp();

    while (true) {
        if (result.completed.load(.acquire)) {
            _ = future.await(io);

            if (result.err) |err| {
                if (result.response) |response| allocator.free(response.body);
                return err;
            }

            if (result.response) |response| return response;
            return error.UnknownError;
        }

        if (compat.nanoTimestamp() - start_time >= timeout_ns) {
            _ = future.cancel(io);
            if (result.response) |response| allocator.free(response.body);
            return error.RequestTimeout;
        }

        compat.sleep(poll_interval_ms * std.time.ns_per_ms);
    }
}

fn fetchWorker(
    allocator: std.mem.Allocator,
    client: *std.http.Client,
    options: RequestOptions,
    result: *ResponseResult,
) void {
    defer result.completed.store(true, .release);

    const response = fetchBytes(allocator, client, options) catch |err| {
        result.err = err;
        return;
    };

    result.response = response;
}