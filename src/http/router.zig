//! HTTP 路由与请求上下文（对齐 ASP.NET Core 路由语义 + DH.RustBase `net::router` 的极简子集）。
//!
//! 口径：
//! - `map(method, "/admin/{action}", handler)`：`{name}` 段捕获（值按 URL 解码，**不解码 `+`**）
//!   段匹配**大小写不敏感**（对齐 ASP.NET 路由），先注册先匹配；
//! - `useMiddleware`：洋葱链（先注册先进入；不调用 `next` 即短路，可改写响应）；
//! - `fallback`：全不命中时的兜底（静态资源、SPA 深链接通常挂这里）；
//! - 路径命中但方法不符 → 405 + `Allow` 头；全不命中 → 404（由调用方决定如何响应）；
//! - 处理器/中间件用「函数指针 + 上下文指针」表达（Zig 无闭包捕获，这是可跨线程共享的写法）；
//! - 请求级分配一律走调用方给的 `arena`（请求结束统一释放），响应体可直接借用 arena。
//!
//! 与 `http/server.zig` 的关系：`server` 只管「监听 + 线程 + 上限 + 收报文」，
//! 本文件只管「路由 + 上下文」；两者在 `http/web.zig` 里对接。

const std = @import("std");
const value = @import("value.zig");

/// 视图/动作通用值（复用 [`value.Value`]）。
pub const Value = value.Value;

/// 键值对（路由参数 / 查询串 / 表单字段；保序）。
pub const Param = struct {
    name: []const u8,
    value: []const u8,
};

/// 业务层看到的请求。
pub const Request = struct {
    /// 方法（`GET`/`POST`/…；大小写不敏感比较）
    method: []const u8 = "GET",
    /// 路径（不含查询串；**未解码**，参数按段解码）
    path: []const u8 = "/",
    /// 原始查询串（`?` 之后）
    query: []const u8 = "",
    body: []const u8 = "",
    /// 请求头（名称统一小写；沿用 std 的头结构便于与 `server` 对接）
    headers: []const std.http.Header = &.{},
    /// 对端地址（可选）
    remote_addr: ?[]const u8 = null,

    /// 取请求头（大小写不敏感）。
    pub fn header(self: Request, name: []const u8) ?[]const u8 {
        for (self.headers) |item| {
            if (std.ascii.eqlIgnoreCase(item.name, name)) return item.value;
        }
        return null;
    }
};

/// 文件响应体（大文件走流式，避免整个读进内存）。
///
/// **句柄所有权**：谁最终发送就由谁关闭——`App.serverHandler` 交给 `http/server` 后由服务端关闭；
/// 直接调用 `dispatch` 的调用方需自行 `file.close(io)`。
pub const FileBody = struct {
    file: std.Io.File,
    /// 要发送的字节数（从文件起始位置 0 开始）
    length: u64,
};

/// 业务层返回的响应（`body` 生命周期由调用方保证：通常借用请求 arena）。
pub const Response = struct {
    status: std.http.Status = .ok,
    content_type: []const u8 = "application/json; charset=utf-8",
    body: []const u8 = "",
    headers: []const std.http.Header = &.{},
    /// 非空时忽略 `body`，由服务端流式发送文件
    file: ?FileBody = null,
    /// 无正文但需声明长度（典型：`HEAD`）；`null` = 由 `body` 长度决定
    content_length: ?u64 = null,

    /// JSON 响应（200）。
    pub fn json(body: []const u8) Response {
        return .{ .body = body };
    }

    /// JSON 响应（指定状态码）。
    pub fn jsonStatus(status: std.http.Status, body: []const u8) Response {
        return .{ .status = status, .body = body };
    }

    /// 文本响应。
    pub fn text(status: std.http.Status, body: []const u8) Response {
        return .{ .status = status, .content_type = "text/plain; charset=utf-8", .body = body };
    }

    /// HTML 响应（200）。
    pub fn html(body: []const u8) Response {
        return .{ .content_type = "text/html; charset=utf-8", .body = body };
    }

    /// 任意类型的响应（自定义 `Content-Type`）。
    pub fn bytes(status: std.http.Status, content_type: []const u8, body: []const u8) Response {
        return .{ .status = status, .content_type = content_type, .body = body };
    }

    /// 404。
    pub fn notFound() Response {
        return .{
            .status = .not_found,
            .content_type = "application/json; charset=utf-8",
            .body = "{\"code\":404,\"message\":\"Not Found\"}",
        };
    }

    /// 302 跳转（`Location` 头按 arena 分配）。
    pub fn redirectAlloc(arena: std.mem.Allocator, location: []const u8) !Response {
        const headers = try arena.alloc(std.http.Header, 1);
        headers[0] = .{ .name = "location", .value = location };
        return .{
            .status = .found,
            .content_type = "text/plain; charset=utf-8",
            .body = "",
            .headers = headers,
        };
    }
};

/// 请求上下文。
pub const Ctx = struct {
    /// 请求级分配器（请求结束统一释放）
    arena: std.mem.Allocator,
    req: Request,
    /// 路由参数
    params: []const Param = &.{},
    /// 查询串
    query: []const Param = &.{},
    /// 表单（仅 `application/x-www-form-urlencoded` 的 POST/PUT/PATCH）
    form: []const Param = &.{},
    /// 中间件状态（鉴权结果、请求 ID 等链路数据）
    state: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// 命中的路由模式（诊断用）
    pattern: []const u8 = "",
    json_parsed: bool = false,
    json_value: Value = .null,

    /// 由原始请求构建（预解析查询串与 urlencoded 表单）。
    pub fn build(arena: std.mem.Allocator, req: Request) !Ctx {
        var ctx = Ctx{ .arena = arena, .req = req };
        if (req.query.len > 0) ctx.query = try parseKv(arena, req.query, true);
        if (isFormMethod(req.method) and isFormContentType(req.header("content-type"))) {
            ctx.form = try parseKv(arena, req.body, true);
        }
        return ctx;
    }

    /// 释放上下文自身的容器（值都在 arena 里，无需逐个释放）。
    pub fn deinit(self: *Ctx) void {
        self.state.deinit(self.arena);
    }

    /// 路由参数。
    pub fn param(self: *const Ctx, name: []const u8) ?[]const u8 {
        return findValue(self.params, name);
    }

    /// 查询串参数。
    pub fn queryValue(self: *const Ctx, name: []const u8) ?[]const u8 {
        return findValue(self.query, name);
    }

    /// 表单字段。
    pub fn formValue(self: *const Ctx, name: []const u8) ?[]const u8 {
        return findValue(self.form, name);
    }

    /// 请求头（大小写不敏感）。
    pub fn header(self: *const Ctx, name: []const u8) ?[]const u8 {
        return self.req.header(name);
    }

    /// 中间件状态。
    pub fn stateValue(self: *const Ctx, name: []const u8) ?[]const u8 {
        return self.state.get(name);
    }

    /// 写入中间件状态。
    pub fn setState(self: *Ctx, name: []const u8, value_: []const u8) !void {
        try self.state.put(self.arena, name, value_);
    }

    /// 表单字段 → 字符串（缺省空串，对齐 C# 绑定习惯）。
    pub fn formStr(self: *const Ctx, name: []const u8) []const u8 {
        return self.formValue(name) orelse "";
    }

    /// 表单字段 → 整数（宽松解析：缺失/非法为 0，对齐 `ToInt()`）。
    pub fn formInt(self: *const Ctx, comptime T: type, name: []const u8) T {
        const text = std.mem.trim(u8, self.formStr(name), " \t\r\n");
        return std.fmt.parseInt(T, text, 10) catch 0;
    }

    /// 表单字段 → 布尔（`true` 忽略大小写为真，其余 false，对齐 `Boolean.TryParse`）。
    pub fn formBool(self: *const Ctx, name: []const u8) bool {
        const text = std.mem.trim(u8, self.formStr(name), " \t\r\n");
        return std.ascii.eqlIgnoreCase(text, "true");
    }

    /// JSON 请求体（懒解析并缓存；非 JSON 或解析失败返回 `.null`）。
    pub fn jsonBody(self: *Ctx) Value {
        if (!self.json_parsed) {
            self.json_parsed = true;
            if (self.req.body.len > 0) {
                self.json_value = Value.parse(self.arena, self.req.body) catch .null;
            }
        }
        return self.json_value;
    }
};

/// 方法是否按表单处理。
fn isFormMethod(method: []const u8) bool {
    return std.ascii.eqlIgnoreCase(method, "POST") or
        std.ascii.eqlIgnoreCase(method, "PUT") or
        std.ascii.eqlIgnoreCase(method, "PATCH");
}

fn isFormContentType(content_type: ?[]const u8) bool {
    const text = content_type orelse return false;
    return std.ascii.startsWithIgnoreCase(text, "application/x-www-form-urlencoded");
}

fn findValue(list: []const Param, name: []const u8) ?[]const u8 {
    for (list) |item| {
        if (std.mem.eql(u8, item.name, name)) return item.value;
    }
    return null;
}

/// 解析 `k=v&k2=v2`（键与值都 URL 解码；`plus_as_space` 区分查询串与路径参数）。
pub fn parseKv(arena: std.mem.Allocator, text: []const u8, plus_as_space: bool) ![]const Param {
    var list: std.ArrayList(Param) = .empty;
    var iter = std.mem.splitScalar(u8, text, '&');
    while (iter.next()) |pair| {
        if (pair.len == 0) continue;
        const index = std.mem.indexOfScalar(u8, pair, '=');
        const raw_key = if (index) |i| pair[0..i] else pair;
        const raw_value = if (index) |i| pair[i + 1 ..] else "";
        try list.append(arena, .{
            .name = try percentDecode(arena, raw_key, plus_as_space),
            .value = try percentDecode(arena, raw_value, plus_as_space),
        });
    }
    return list.toOwnedSlice(arena);
}

/// URL 解码（`%XX`；`plus_as_space` 为真时 `+` → 空格；非法序列原样保留）。
pub fn percentDecode(arena: std.mem.Allocator, text: []const u8, plus_as_space: bool) ![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '%') == null and
        (!plus_as_space or std.mem.indexOfScalar(u8, text, '+') == null))
    {
        return text;
    }

    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '+' and plus_as_space) {
            try out.append(arena, ' ');
            i += 1;
            continue;
        }
        if (c == '%' and i + 2 < text.len) {
            const hi = hexValue(text[i + 1]);
            const lo = hexValue(text[i + 2]);
            if (hi != null and lo != null) {
                try out.append(arena, hi.? * 16 + lo.?);
                i += 3;
                continue;
            }
        }
        try out.append(arena, c);
        i += 1;
    }
    return out.toOwnedSlice(arena);
}

fn hexValue(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

// ————— 处理器与中间件 —————

/// 路由处理器（函数指针 + 上下文指针；`ctx` 可为 null）。
pub const Handler = struct {
    ctx: ?*anyopaque = null,
    call: *const fn (self: ?*anyopaque, c: *Ctx) anyerror!Response,

    /// 执行。
    pub fn invoke(self: Handler, c: *Ctx) anyerror!Response {
        return self.call(self.ctx, c);
    }
};

/// 中间件「下一环」。
pub const Next = struct {
    ctx: *anyopaque,
    call: *const fn (ctx: *anyopaque, c: *Ctx) anyerror!Response,

    /// 进入下一环。
    pub fn run(self: Next, c: *Ctx) anyerror!Response {
        return self.call(self.ctx, c);
    }
};

/// 中间件（`self` 为注册时的上下文指针）。
pub const Middleware = struct {
    ctx: ?*anyopaque = null,
    call: *const fn (self: ?*anyopaque, c: *Ctx, next: Next) anyerror!Response,
};

/// 无状态处理器便捷构造：`router.get("/ping", zzig.web.router.handler(ping))`。
pub fn handler(comptime f: anytype) Handler {
    const Wrap = struct {
        fn invoke(_: ?*anyopaque, c: *Ctx) anyerror!Response {
            return f(c);
        }
    };
    return .{ .call = Wrap.invoke };
}

/// 无状态中间件便捷构造。
pub fn middleware(comptime f: anytype) Middleware {
    const Wrap = struct {
        fn invoke(_: ?*anyopaque, c: *Ctx, next: Next) anyerror!Response {
            return f(c, next);
        }
    };
    return .{ .call = Wrap.invoke };
}

// ————— 路由表 —————

const Segment = union(enum) {
    literal: []const u8,
    param: []const u8,
};

const Route = struct {
    /// 大写方法名或 `*`
    method: []const u8,
    pattern: []const u8,
    segments: []const Segment,
    handler: Handler,
};

/// 匹配结果。
pub const Match = union(enum) {
    handler: Handler,
    not_found,
    method_not_allowed: []const u8,
};

/// 分发结果。
pub const Outcome = union(enum) {
    response: Response,
    not_found,
    method_not_allowed: []const u8,
};

/// HTTP 路由器。
pub const Router = struct {
    allocator: std.mem.Allocator,
    routes: std.ArrayList(Route) = .empty,
    middlewares: std.ArrayList(Middleware) = .empty,
    fallback_handler: ?Handler = null,

    /// 新建空路由器。
    pub fn init(allocator: std.mem.Allocator) Router {
        return .{ .allocator = allocator };
    }

    /// 释放路由表（路由模式串一并释放）。
    pub fn deinit(self: *Router) void {
        for (self.routes.items) |route| {
            self.allocator.free(route.method);
            self.allocator.free(route.pattern);
            self.allocator.free(route.segments);
        }
        self.routes.deinit(self.allocator);
        self.middlewares.deinit(self.allocator);
    }

    /// 注册中间件（先注册先进入）。
    pub fn useMiddleware(self: *Router, mw: Middleware) !void {
        try self.middlewares.append(self.allocator, mw);
    }

    /// 注册兜底处理器（全不命中时执行；仍走中间件链）。
    pub fn fallback(self: *Router, h: Handler) void {
        self.fallback_handler = h;
    }

    /// 注册路由。
    pub fn map(self: *Router, method: []const u8, pattern: []const u8, h: Handler) !void {
        const method_copy = try self.allocator.dupe(u8, method);
        errdefer self.allocator.free(method_copy);
        for (method_copy) |*c| c.* = std.ascii.toUpper(c.*);

        const pattern_copy = try self.allocator.dupe(u8, pattern);
        errdefer self.allocator.free(pattern_copy);

        var segments: std.ArrayList(Segment) = .empty;
        errdefer segments.deinit(self.allocator);
        var iter = std.mem.splitScalar(u8, pattern_copy, '/');
        while (iter.next()) |raw| {
            if (raw.len == 0) continue;
            if (raw.len >= 2 and raw[0] == '{' and raw[raw.len - 1] == '}') {
                const name = raw[1 .. raw.len - 1];
                if (name.len == 0) return error.InvalidPattern;
                try segments.append(self.allocator, .{ .param = name });
            } else {
                try segments.append(self.allocator, .{ .literal = raw });
            }
        }

        try self.routes.append(self.allocator, .{
            .method = method_copy,
            .pattern = pattern_copy,
            .segments = try segments.toOwnedSlice(self.allocator),
            .handler = h,
        });
    }

    /// 注册 GET 路由（同时接受 HEAD）。
    pub fn get(self: *Router, pattern: []const u8, h: Handler) !void {
        try self.map("GET", pattern, h);
    }

    /// 注册 POST 路由。
    pub fn post(self: *Router, pattern: []const u8, h: Handler) !void {
        try self.map("POST", pattern, h);
    }

    /// 注册 PUT 路由。
    pub fn put(self: *Router, pattern: []const u8, h: Handler) !void {
        try self.map("PUT", pattern, h);
    }

    /// 注册 DELETE 路由。
    pub fn delete(self: *Router, pattern: []const u8, h: Handler) !void {
        try self.map("DELETE", pattern, h);
    }

    /// 注册 PATCH 路由。
    pub fn patch(self: *Router, pattern: []const u8, h: Handler) !void {
        try self.map("PATCH", pattern, h);
    }

    /// 注册任意方法的路由。
    pub fn any(self: *Router, pattern: []const u8, h: Handler) !void {
        try self.map("*", pattern, h);
    }

    /// 只做匹配（不执行处理器、不跑中间件）；命中时写入 `c.params` 与 `c.pattern`。
    pub fn match(self: *const Router, c: *Ctx) !Match {
        var segments: std.ArrayList([]const u8) = .empty;
        var iter = std.mem.splitScalar(u8, c.req.path, '/');
        while (iter.next()) |raw| {
            if (raw.len == 0) continue;
            try segments.append(c.arena, raw);
        }

        var allow: std.Io.Writer.Allocating = .init(c.arena);
        defer allow.deinit();
        var allow_count: usize = 0;
        var path_matched = false;

        for (self.routes.items) |*route| {
            if (route.segments.len != segments.items.len) continue;
            const maybe_params = try matchSegments(c.arena, route.segments, segments.items);
            const params = maybe_params orelse continue;
            path_matched = true;

            if (!methodAllowed(route.method, c.req.method)) {
                if (!std.mem.eql(u8, route.method, "*")) {
                    if (allow_count > 0) try allow.writer.writeAll(",");
                    try allow.writer.writeAll(route.method);
                    allow_count += 1;
                }
                continue;
            }

            c.params = params;
            c.pattern = route.pattern;
            return .{ .handler = route.handler };
        }

        if (path_matched and allow_count > 0) {
            return .{ .method_not_allowed = try allow.toOwnedSlice() };
        }
        return .not_found;
    }

    /// 匹配并执行（含中间件链）。
    pub fn dispatch(self: *const Router, c: *Ctx) anyerror!Outcome {
        switch (try self.match(c)) {
            .handler => |h| {
                var chain = Chain{ .mws = self.middlewares.items, .handler = h, .ctx = c };
                return .{ .response = try chain.next() };
            },
            .method_not_allowed => |allow| return .{ .method_not_allowed = allow },
            .not_found => {
                if (self.fallback_handler) |h| {
                    c.pattern = "(fallback)";
                    var chain = Chain{ .mws = self.middlewares.items, .handler = h, .ctx = c };
                    return .{ .response = try chain.next() };
                }
                return .not_found;
            },
        }
    }
};

const Chain = struct {
    mws: []const Middleware,
    handler: Handler,
    ctx: *Ctx,
    index: usize = 0,

    fn next(self: *Chain) anyerror!Response {
        const index = self.index;
        if (index < self.mws.len) {
            self.index = index + 1;
            defer self.index = index;
            const mw = self.mws[index];
            return mw.call(mw.ctx, self.ctx, .{ .ctx = @ptrCast(self), .call = step });
        }
        return self.handler.invoke(self.ctx);
    }

    fn step(raw: *anyopaque, c: *Ctx) anyerror!Response {
        const self: *Chain = @ptrCast(@alignCast(raw));
        self.ctx = c;
        return self.next();
    }
};

fn matchSegments(
    arena: std.mem.Allocator,
    route_segments: []const Segment,
    request_segments: []const []const u8,
) !?[]const Param {
    // 无参数路由走零分配快路径
    var has_param = false;
    for (route_segments) |segment| {
        if (segment == .param) has_param = true;
    }

    if (!has_param) {
        for (route_segments, request_segments) |route_segment, request_segment| {
            if (!std.ascii.eqlIgnoreCase(route_segment.literal, request_segment)) return null;
        }
        return &.{};
    }

    var params: std.ArrayList(Param) = .empty;
    for (route_segments, request_segments) |route_segment, request_segment| {
        switch (route_segment) {
            .literal => |literal| {
                if (!std.ascii.eqlIgnoreCase(literal, request_segment)) return null;
            },
            .param => |name| {
                try params.append(arena, .{
                    .name = name,
                    .value = try percentDecode(arena, request_segment, false),
                });
            },
        }
    }
    return @as(?[]const Param, try params.toOwnedSlice(arena));
}

fn methodAllowed(route_method: []const u8, request_method: []const u8) bool {
    if (std.mem.eql(u8, route_method, "*")) return true;
    if (std.ascii.eqlIgnoreCase(route_method, request_method)) return true;
    if (std.ascii.eqlIgnoreCase(request_method, "HEAD") and
        std.ascii.eqlIgnoreCase(route_method, "GET")) return true;
    return false;
}

const testing = std.testing;

fn buildCtx(arena: std.mem.Allocator, method: []const u8, path: []const u8, query: []const u8) !Ctx {
    return Ctx.build(arena, .{ .method = method, .path = path, .query = query });
}

test "router：路径参数 + 大小写不敏感 + HEAD 兼容 GET" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var router = Router.init(testing.allocator);
    defer router.deinit();

    const S = struct {
        fn handle(c: *Ctx) anyerror!Response {
            const action = c.param("action") orelse "";
            return Response.json(try std.fmt.allocPrint(c.arena, "{{\"action\":\"{s}\"}}", .{action}));
        }
    };
    try router.get("/Admin/{action}", handler(S.handle));

    var ctx = try buildCtx(arena, "GET", "/admin/Index", "");
    defer ctx.deinit();
    switch (try router.dispatch(&ctx)) {
        .response => |resp| try testing.expectEqualStrings("{\"action\":\"Index\"}", resp.body),
        else => return error.TestUnexpectedResult,
    }

    var head_ctx = try buildCtx(arena, "HEAD", "/Admin/Index", "");
    defer head_ctx.deinit();
    switch (try router.dispatch(&head_ctx)) {
        .response => {},
        else => return error.TestUnexpectedResult,
    }
}

test "router：方法不符 → 405 且带 Allow" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var router = Router.init(testing.allocator);
    defer router.deinit();

    const S = struct {
        fn ok(_: *Ctx) anyerror!Response {
            return Response.json("{}");
        }
    };
    try router.post("/api/save", handler(S.ok));

    var ctx = try buildCtx(arena, "GET", "/api/save", "");
    defer ctx.deinit();
    switch (try router.dispatch(&ctx)) {
        .method_not_allowed => |allow| try testing.expectEqualStrings("POST", allow),
        else => return error.TestUnexpectedResult,
    }
}

test "router：中间件顺序与短路" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var router = Router.init(testing.allocator);
    defer router.deinit();

    const S = struct {
        var order: std.ArrayList(u8) = .empty;

        fn first(c: *Ctx, next: Next) anyerror!Response {
            try order.append(testing.allocator, 'A');
            return next.run(c);
        }

        fn second(c: *Ctx, next: Next) anyerror!Response {
            try order.append(testing.allocator, 'B');
            return next.run(c);
        }

        fn ok(_: *Ctx) anyerror!Response {
            return Response.json("{}");
        }
    };
    S.order = .empty;
    defer S.order.deinit(testing.allocator);

    try router.useMiddleware(middleware(S.first));
    try router.useMiddleware(middleware(S.second));
    try router.get("/x", handler(S.ok));

    var ctx = try buildCtx(arena, "GET", "/x", "");
    defer ctx.deinit();
    _ = try router.dispatch(&ctx);
    try testing.expectEqualStrings("AB", S.order.items);
}

test "router：查询串 / 表单解析" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var ctx = try Ctx.build(arena, .{
        .method = "POST",
        .path = "/login",
        .query = "next=%2Fhome&flag=true",
        .body = "user=%E5%BC%A0%E4%B8%89&age=20&remember=true",
        .headers = &.{.{ .name = "content-type", .value = "application/x-www-form-urlencoded; charset=utf-8" }},
    });
    defer ctx.deinit();

    try testing.expectEqualStrings("/home", ctx.queryValue("next").?);
    try testing.expect(ctx.formBool("remember"));
    try testing.expectEqualStrings("张三", ctx.formValue("user").?);
    try testing.expectEqual(@as(u16, 20), ctx.formInt(u16, "age"));
    try testing.expectEqualStrings("", ctx.formStr("missing"));
}

test "router：fallback 兜底" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var router = Router.init(testing.allocator);
    defer router.deinit();

    const S = struct {
        fn fb(_: *Ctx) anyerror!Response {
            return Response.text(.not_found, "spa");
        }
    };
    router.fallback(handler(S.fb));

    var ctx = try buildCtx(arena, "GET", "/deep/link", "");
    defer ctx.deinit();
    switch (try router.dispatch(&ctx)) {
        .response => |resp| try testing.expectEqualStrings("spa", resp.body),
        else => return error.TestUnexpectedResult,
    }
}

test "router：非法模式报错" {
    var router = Router.init(testing.allocator);
    defer router.deinit();
    const S = struct {
        fn ok(_: *Ctx) anyerror!Response {
            return Response.json("{}");
        }
    };
    try testing.expectError(error.InvalidPattern, router.get("/a/{}", handler(S.ok)));
}
