//! HTTP 控制器（对齐 ASP.NET Core MVC 控制器约定 + DH.RustBase `net::controller`）。
//!
//! 口径：
//! - 一个控制器 = 一组命名动作，统一挂到 `/{prefix}/{action}`（`prefix` 可含区域前缀 `admin/home`）；
//! - 动作名大小写不敏感；方法可精确（`GET`/`POST`/…）或 `*`；
//! - 参数绑定 [`arg`]：**路由参数 → 查询串 → 表单 → JSON body 字段**（对齐 C# 模型绑定顺序），
//!   动作代码不用关心参数来源；
//! - 统一响应 [`jsonResult`]：`{code, message?, data?}` 信封（对齐 NewLife / DH 控制器 JSON 惯例）；
//! - 视图：[`ActionResult.view`] 按 [`view.ViewRenderer`] 的 MVC 约定渲染
//!   `Views/{Controller}/{Action}.cshtml` / `Areas/{Area}/Views/...`；
//! - 控制器对象**必须比路由器活得久**（路由器只保存指向它的指针）；`defer ctrl.deinit()` 放在
//!   `app.run()` 之后即可。

const std = @import("std");
const router = @import("router.zig");
const value = @import("value.zig");
const view = @import("view.zig");

/// 请求上下文。
pub const Ctx = router.Ctx;
/// 响应。
pub const Response = router.Response;
/// 视图模型值。
pub const Value = value.Value;

/// 动作结果：直接响应，或按约定渲染视图。
pub const ActionResult = union(enum) {
    response: Response,
    view: struct {
        /// 视图名（`null` = 用动作名）
        name: ?[]const u8 = null,
        /// 视图模型
        model: Value = .null,
    },
};

/// 动作处理器（`self` 为注册时的上下文指针）。
pub const ActionFn = *const fn (self: ?*anyopaque, c: *Ctx) anyerror!ActionResult;

const ActionEntry = struct {
    /// 大写方法名或 `*`
    method: []const u8,
    func: ActionFn,
    ctx: ?*anyopaque = null,
};

/// 返回视图（用动作名）。
pub fn viewResult(model: Value) ActionResult {
    return .{ .view = .{ .model = model } };
}

/// 返回指定视图。
pub fn viewNamed(name: []const u8, model: Value) ActionResult {
    return .{ .view = .{ .name = name, .model = model } };
}

/// 统一 JSON 信封：`{code, message?, data?}`。
///
/// `data` 为**已序列化的 JSON 文本**（`null` = 省略该字段），避免为了拼装引入额外 JSON 写入层。
pub fn jsonResult(
    arena: std.mem.Allocator,
    code: i64,
    message: []const u8,
    data: ?[]const u8,
) !Response {
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    try out.writer.print("{{\"code\":{d}", .{code});
    if (message.len > 0) {
        try out.writer.writeAll(",\"message\":");
        try value.writeJsonString(&out.writer, message);
    }
    if (data) |raw| {
        try out.writer.writeAll(",\"data\":");
        try out.writer.writeAll(raw);
    }
    try out.writer.writeAll("}");
    return Response.json(try out.toOwnedSlice());
}

/// 参数绑定：路由参数 → 查询串 → 表单 → JSON body 字段（大小写不敏感）。
pub fn arg(c: *Ctx, name: []const u8) ?[]const u8 {
    if (c.param(name)) |found| return found;
    if (c.queryValue(name)) |found| return found;
    if (c.formValue(name)) |found| return found;

    const field = c.jsonBody().get(name) orelse return null;
    return switch (field) {
        .string => |text| text,
        .integer => |number| std.fmt.allocPrint(c.arena, "{d}", .{number}) catch null,
        .number => |number| std.fmt.allocPrint(c.arena, "{d}", .{number}) catch null,
        .boolean => |flag| if (flag) "true" else "false",
        else => null,
    };
}

/// 参数绑定（整数；缺失或非法返回 `null`）。
pub fn argInt(c: *Ctx, name: []const u8) ?i64 {
    const text = arg(c, name) orelse return null;
    return std.fmt.parseInt(i64, std.mem.trim(u8, text, " \t\r\n"), 10) catch null;
}

/// 参数绑定（布尔；`true`/`1`/`yes` 为真，`false`/`0`/`no` 为假）。
pub fn argBool(c: *Ctx, name: []const u8) ?bool {
    const text = std.mem.trim(u8, arg(c, name) orelse return null, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(text, "true") or std.mem.eql(u8, text, "1") or std.ascii.eqlIgnoreCase(text, "yes")) return true;
    if (std.ascii.eqlIgnoreCase(text, "false") or std.mem.eql(u8, text, "0") or std.ascii.eqlIgnoreCase(text, "no")) return false;
    return null;
}

/// 控制器。
pub const Controller = struct {
    allocator: std.mem.Allocator,
    /// 小写前缀（如 `home`、`admin/dashboard`）
    prefix: []const u8,
    actions: std.StringHashMapUnmanaged(ActionEntry) = .empty,
    views: view.ViewRenderer,

    /// 新建控制器（`prefix` 如 `"home"`、`"admin/dashboard"`；两侧 `/` 自动去除并转小写）。
    pub fn init(allocator: std.mem.Allocator, io: std.Io, prefix: []const u8) !Controller {
        const trimmed = std.mem.trim(u8, prefix, "/");
        const normalized = try allocator.alloc(u8, trimmed.len);
        for (trimmed, 0..) |c, index| normalized[index] = std.ascii.toLower(c);
        return .{
            .allocator = allocator,
            .prefix = normalized,
            .views = view.ViewRenderer.init(allocator, io),
        };
    }

    /// 按区域约定新建控制器：区域 `Admin` + 控制器 `Home` → 前缀 `admin/home`，
    /// 视图默认在 `Areas/Admin/Views/Home/` 下查找。
    pub fn initArea(
        allocator: std.mem.Allocator,
        io: std.Io,
        area: []const u8,
        controller: []const u8,
    ) !Controller {
        const prefix = try std.fmt.allocPrint(allocator, "{s}/{s}", .{
            std.mem.trim(u8, area, "/"),
            std.mem.trim(u8, controller, "/"),
        });
        defer allocator.free(prefix);
        return init(allocator, io, prefix);
    }

    /// 释放动作表、前缀与视图缓存。
    pub fn deinit(self: *Controller) void {
        var it = self.actions.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.method);
        }
        self.actions.deinit(self.allocator);
        self.allocator.free(self.prefix);
        self.views.deinit();
    }

    /// 注册动作（`method` 为 `GET`/`POST`/…，`*` = 任意；动作名大小写不敏感）。
    ///
    /// `func` 支持两种签名：`fn (c: *Ctx) !ActionResult`（无状态）与
    /// `fn (self: ?*anyopaque, c: *Ctx) !ActionResult`（需要应用上下文）。
    pub fn map(self: *Controller, method: []const u8, action_name: []const u8, comptime func: anytype) !void {
        try self.mapWithContext(method, action_name, null, func);
    }

    /// 注册带上下文指针的动作（动作里可通过 `self` 取应用状态）。
    pub fn mapWithContext(
        self: *Controller,
        method: []const u8,
        action_name: []const u8,
        ctx: ?*anyopaque,
        comptime func: anytype,
    ) !void {
        const key = try self.allocator.alloc(u8, action_name.len);
        for (action_name, 0..) |c, index| key[index] = std.ascii.toLower(c);

        const method_copy = try self.allocator.dupe(u8, method);
        for (method_copy) |*c| c.* = std.ascii.toUpper(c.*);

        if (self.actions.fetchRemove(key)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value.method);
        }
        try self.actions.put(self.allocator, key, .{
            .method = method_copy,
            .func = toActionFn(func),
            .ctx = ctx,
        });
    }

    /// 注册 GET 动作（同时接受 HEAD）。
    pub fn get(self: *Controller, action_name: []const u8, comptime func: anytype) !void {
        try self.map("GET", action_name, func);
    }

    /// 注册 POST 动作。
    pub fn post(self: *Controller, action_name: []const u8, comptime func: anytype) !void {
        try self.map("POST", action_name, func);
    }

    /// 注册 PUT 动作。
    pub fn put(self: *Controller, action_name: []const u8, comptime func: anytype) !void {
        try self.map("PUT", action_name, func);
    }

    /// 注册 DELETE 动作。
    pub fn delete(self: *Controller, action_name: []const u8, comptime func: anytype) !void {
        try self.map("DELETE", action_name, func);
    }

    /// 注册任意方法的动作。
    pub fn any(self: *Controller, action_name: []const u8, comptime func: anytype) !void {
        try self.map("*", action_name, func);
    }

    /// 视图根（默认 `Views`）。
    pub fn setViewsRoot(self: *Controller, root: []const u8) void {
        self.views.setRoot(root);
    }

    /// 区域根（默认 `Areas`）。
    pub fn setAreasRoot(self: *Controller, root: []const u8) void {
        self.views.setAreasRoot(root);
    }

    /// 默认（回退）区域：区域视图缺失时回退到该区域。
    pub fn setFallbackArea(self: *Controller, area: ?[]const u8) void {
        self.views.setFallbackArea(area);
    }

    /// 注入组件注册表（通常由 `App.mountController` 自动完成）。
    pub fn setComponents(self: *Controller, registry: ?*view.ComponentRegistry) void {
        self.views.setComponents(registry);
    }

    /// 挂载到路由器：注册 `/{prefix}/{action}` 统一入口。
    pub fn mount(self: *Controller, r: *router.Router) !void {
        var buffer: [512]u8 = undefined;
        const pattern = std.fmt.bufPrint(&buffer, "/{s}/{{action}}", .{self.prefix}) catch
            return error.PrefixTooLong;
        try r.any(pattern, .{ .ctx = @ptrCast(self), .call = dispatchShim });
    }

    fn dispatchShim(raw: ?*anyopaque, c: *Ctx) anyerror!Response {
        const self: *Controller = @ptrCast(@alignCast(raw orelse return error.MissingController));
        return self.dispatch(c);
    }

    /// 分发：查动作 → 校验方法 → 执行（视图结果就地渲染）。
    pub fn dispatch(self: *Controller, c: *Ctx) anyerror!Response {
        const raw_action = c.param("action") orelse "";
        const action = try lowercaseArena(c.arena, raw_action);

        const entry = self.actions.get(action) orelse {
            const body = try std.fmt.allocPrint(
                c.arena,
                "{{\"code\":404,\"message\":\"未知动作：{s}\"}}",
                .{raw_action},
            );
            return Response.jsonStatus(.not_found, body);
        };

        if (!methodAllowed(entry.method, c.req.method)) {
            var headers = try c.arena.alloc(std.http.Header, 1);
            headers[0] = .{ .name = "allow", .value = if (std.mem.eql(u8, entry.method, "*")) "*" else entry.method };
            return .{
                .status = .method_not_allowed,
                .content_type = "text/plain; charset=utf-8",
                .body = "Method Not Allowed",
                .headers = headers,
            };
        }

        const result = try entry.func(entry.ctx, c);
        return switch (result) {
            .response => |response| response,
            .view => |view_result| blk: {
                const name = view_result.name orelse action;
                const response = switch (self.views.render(c.arena, self.prefix, name, view_result.model)) {
                    .html => |html| Response.html(html),
                    .fail => |message| try viewFailureResponse(c, message),
                };
                break :blk response;
            },
        };
    }
};

/// 视图渲染失败 → 500 信封（错误信息进 `message`，便于前端提示与日志定位）。
fn viewFailureResponse(c: *Ctx, message: []const u8) !Response {
    const detail = try std.fmt.allocPrint(c.arena, "视图渲染失败：{s}", .{message});
    const envelope = try jsonResult(c.arena, 500, detail, null);
    return .{
        .status = .internal_server_error,
        .content_type = envelope.content_type,
        .body = envelope.body,
    };
}

fn lowercaseArena(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    const out = try arena.alloc(u8, text.len);
    for (text, 0..) |c, index| out[index] = std.ascii.toLower(c);
    return out;
}

fn methodAllowed(route_method: []const u8, request_method: []const u8) bool {
    if (std.mem.eql(u8, route_method, "*")) return true;
    if (std.ascii.eqlIgnoreCase(route_method, request_method)) return true;
    if (std.ascii.eqlIgnoreCase(request_method, "HEAD") and std.ascii.eqlIgnoreCase(route_method, "GET")) return true;
    return false;
}

/// 动作包装：兼容 `fn (c)` 与 `fn (self, c)` 两种签名。
fn toActionFn(comptime func: anytype) ActionFn {
    const param_count = @typeInfo(@TypeOf(func)).@"fn".param_types.len;
    if (param_count >= 2) {
        const Wrap = struct {
            fn call(self: ?*anyopaque, c: *Ctx) anyerror!ActionResult {
                return func(self, c);
            }
        };
        return Wrap.call;
    }
    const Wrap = struct {
        fn call(_: ?*anyopaque, c: *Ctx) anyerror!ActionResult {
            return func(c);
        }
    };
    return Wrap.call;
}

const testing = std.testing;
const compat = @import("../compat.zig");
const fsio = @import("../file/fsio.zig");

fn buildCtx(arena: std.mem.Allocator, method: []const u8, path: []const u8, query: []const u8, body: []const u8) !Ctx {
    return Ctx.build(arena, .{ .method = method, .path = path, .query = query, .body = body });
}

test "controller：参数绑定顺序（查询 > 表单 > JSON）" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = compat.currentIo();

    var ctrl = try Controller.init(testing.allocator, io, "api");
    defer ctrl.deinit();

    const S = struct {
        fn echo(c: *Ctx) anyerror!ActionResult {
            const name = arg(c, "name") orelse "";
            const page = argInt(c, "page") orelse 0;
            const flag = argBool(c, "flag") orelse false;
            const body = try std.fmt.allocPrint(c.arena, "{{\"name\":\"{s}\",\"page\":{d},\"flag\":{s}}}", .{
                name,
                page,
                if (flag) "true" else "false",
            });
            return .{ .response = router.Response.json(body) };
        }
    };

    try ctrl.any("echo", S.echo);

    // 查询串优先于表单：name=query 胜出；flag 只在表单里
    var ctx = try Ctx.build(arena, .{
        .method = "POST",
        .path = "/api/echo",
        .query = "name=query&page=2",
        .body = "name=form&flag=true",
        .headers = &.{.{ .name = "content-type", .value = "application/x-www-form-urlencoded" }},
    });
    defer ctx.deinit();
    ctx.params = &.{.{ .name = "action", .value = "echo" }};
    const echoed = try ctrl.dispatch(&ctx);
    try testing.expectEqualStrings("{\"name\":\"query\",\"page\":2,\"flag\":true}", echoed.body);
}

test "controller：JSON body 绑定与未知动作/方法不符" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = compat.currentIo();

    var ctrl = try Controller.init(testing.allocator, io, "api");
    defer ctrl.deinit();

    const S = struct {
        fn save(c: *Ctx) anyerror!ActionResult {
            const title = arg(c, "Title") orelse "";
            const count = argInt(c, "count") orelse 0;
            return .{ .response = router.Response.json(try std.fmt.allocPrint(
                c.arena,
                "{{\"title\":\"{s}\",\"count\":{d}}}",
                .{ title, count },
            )) };
        }
    };
    try ctrl.post("save", S.save);

    var ctx = try Ctx.build(arena, .{
        .method = "POST",
        .path = "/api/save",
        .body = "{\"title\":\"面板\",\"count\":5}",
        .headers = &.{.{ .name = "content-type", .value = "application/json" }},
    });
    defer ctx.deinit();
    ctx.params = &.{.{ .name = "action", .value = "save" }};
    const saved = try ctrl.dispatch(&ctx);
    try testing.expectEqualStrings("{\"title\":\"面板\",\"count\":5}", saved.body);

    var unknown = try buildCtx(arena, "POST", "/api/nope", "", "");
    defer unknown.deinit();
    unknown.params = &.{.{ .name = "action", .value = "nope" }};
    const unknown_resp = try ctrl.dispatch(&unknown);
    try testing.expectEqual(std.http.Status.not_found, unknown_resp.status);

    var wrong_method = try buildCtx(arena, "GET", "/api/save", "", "");
    defer wrong_method.deinit();
    wrong_method.params = &.{.{ .name = "action", .value = "save" }};
    const wrong_resp = try ctrl.dispatch(&wrong_method);
    try testing.expectEqual(std.http.Status.method_not_allowed, wrong_resp.status);
}

test "controller：视图动作（区域约定）" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = compat.currentIo();

    const dir = try std.fmt.allocPrint(arena, ".zig-cache/tmp/ctrl-views-{d}", .{compat.nanoTimestamp()});
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    const view_path = try std.fmt.allocPrint(arena, "{s}/Areas/Admin/Views/Dashboard/Index.cshtml", .{dir});
    try fsio.ensureParent(io, view_path);
    try fsio.writeFile(io, view_path, "<h1>@Model.Title</h1>");

    var ctrl = try Controller.initArea(testing.allocator, io, "Admin", "Dashboard");
    defer ctrl.deinit();
    ctrl.setAreasRoot(try std.fmt.allocPrint(arena, "{s}/Areas", .{dir}));

    const S = struct {
        var title: []const u8 = "仪表盘";

        fn index(_: *Ctx) anyerror!ActionResult {
            const fields = [_]value.Field{value.field("Title", value.ofString("仪表盘"))};
            return .{ .view = .{ .model = value.ofObject(&fields) } };
        }
    };

    try ctrl.mapWithContext("GET", "index", null, S.index);

    var ctx = try buildCtx(arena, "GET", "/admin/dashboard/index", "", "");
    defer ctx.deinit();
    ctx.params = &.{.{ .name = "action", .value = "index" }};
    const response = try ctrl.dispatch(&ctx);
    try testing.expectEqualStrings("text/html; charset=utf-8", response.content_type);
    try testing.expectEqualStrings("<h1>仪表盘</h1>", response.body);
}
