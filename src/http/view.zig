//! 视图引擎与视图约定（Razor 子集 + ASP.NET Core MVC 目录约定）。
//!
//! 目录约定（全部按「逐段 Pascal 化 → 原样」两套候选查找，大小写宽容）：
//! - 常规：`Views/{Controller}/{Action}.cshtml`；
//! - 共享：`Views/Shared/{Action}.cshtml`；
//! - 区域（Areas）：`Areas/{Area}/Views/{Controller}/{Action}.cshtml`
//!   （兼容 DH.RustBase 的 `Views/{Area}/{Controller}/{Action}.cshtml`）；
//! - 区域回退：`{Area}/{Controller}` 找不到时可回退到默认区域（如 `Admin`）的同名视图；
//! - 显式：视图名以 `/` 开头视为视图根下的全路径，含 `/` 视为相对片段。
//!
//! 模板语法（Razor 子集，子集外语法**显式报错并带行列号**）：
//! - 隐式表达式 `@Model.X.Y`（默认 HTML 转义）、显式表达式 `@(表达式)`；
//! - 不转义 `@Raw(表达式)` / `@Html.Raw(表达式)`；
//! - 注释 `@* ... *@`；`@@` 输出字面 `@`；
//! - 控制流 `@if (条件) { } else if (条件) { } else { }`、`@foreach (var x in 表达式) { }`；
//! - 代码块 `@{ var a = 表达式; Layout = "Shared/_Layout"; }`；
//! - 布局与分区 `@RenderBody()`、`@section Name { }`、`@RenderSection("Name", true)`、
//!   `@await RenderSectionAsync("Name", false)`；
//! - 分部视图 `@Html.Partial("Name", 表达式)`、`@await Html.PartialAsync("Name", 表达式)`；
//! - 组件 `@await Component.InvokeAsync("Name", 参数)`（也可简写 `@Component("Name", 参数)`），
//!   按 ASP.NET Core View Components 约定渲染 `Views/Shared/Components/{Name}/Default.cshtml`。
//!
//! 表达式子集：路径访问（`.` / `[下标]`）、字面量（字符串/整数/浮点/`true`/`false`/`null`）、
//! `! - + * / %`、`== != < > <= >=`、`&& ||`、`? :`、`??`、括号。**不支持任意方法调用**。
//!
//! 缓存：按「文件修改时间 + 长度」失效；命中时零文件读取。旧模板在 `deinit` 统一释放
//! （热改期短时可接受；不在这里做引用计数）。

const std = @import("std");
const fsio = @import("../file/fsio.zig");
const value = @import("value.zig");

/// 视图模型值（复用 [`value.Value`]）。
pub const Value = value.Value;

/// 编译结果。
pub const CompileOutcome = union(enum) {
    ok: *Template,
    fail: []const u8,
};

/// 渲染结果。
pub const RenderOutcome = union(enum) {
    html: []const u8,
    fail: []const u8,
};

/// 编译后的模板（节点与字符串都来自编译期 arena）。
pub const Template = struct {
    nodes: []const Node,
};

// ————— 组件（对齐 ASP.NET Core View Components） —————

/// 组件渲染上下文。
pub const ComponentContext = struct {
    /// 请求级分配器（组件返回的模型/HTML 用它兜底）
    arena: std.mem.Allocator,
    /// 视图渲染器（组件内部可继续用 Partial 等能力）
    renderer: *ViewRenderer,
    /// 调用方控制器前缀（含区域，如 `admin/dashboard`），用于解析区域内的组件视图
    controller: []const u8,
    /// 调用方传入的参数；未传时为外层视图模型
    args: Value,
    /// 外层视图模型（无论是否传参都可用）
    parent_model: Value,
};

/// 组件返回值。
pub const ComponentResult = union(enum) {
    /// 渲染组件视图（`name` 缺省为 `Default`）
    view: struct {
        name: ?[]const u8 = null,
        model: Value = .null,
    },
    /// 直接返回 HTML（不需要视图文件的小组件）
    html: []const u8,
};

/// 组件处理函数（`self` 为注册时的上下文指针）。
pub const ComponentFn = *const fn (self: ?*anyopaque, c: *ComponentContext) anyerror!ComponentResult;

/// 已注册组件。
pub const ComponentEntry = struct {
    ctx: ?*anyopaque = null,
    func: ComponentFn,
};

/// 组件注册表（**启动期注册、运行期只读**；名称大小写不敏感）。
pub const ComponentRegistry = struct {
    allocator: std.mem.Allocator,
    entries: std.StringHashMapUnmanaged(ComponentEntry) = .empty,

    /// 创建空注册表。
    pub fn init(allocator: std.mem.Allocator) ComponentRegistry {
        return .{ .allocator = allocator };
    }

    /// 释放组件名与表。
    pub fn deinit(self: *ComponentRegistry) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.entries.deinit(self.allocator);
    }

    /// 注册组件（同名覆盖）。
    pub fn register(self: *ComponentRegistry, name: []const u8, ctx: ?*anyopaque, func: ComponentFn) !void {
        const key = try lowerAlloc(self.allocator, name);
        errdefer self.allocator.free(key);
        if (self.entries.fetchRemove(key)) |old| {
            self.allocator.free(old.key);
        }
        try self.entries.put(self.allocator, key, .{ .ctx = ctx, .func = func });
    }

    /// 取组件（大小写不敏感；未注册返回 `null`）。
    pub fn get(self: *const ComponentRegistry, name: []const u8) ?ComponentEntry {
        var buffer: [96]u8 = undefined;
        if (name.len <= buffer.len) {
            for (name, 0..) |c, index| buffer[index] = std.ascii.toLower(c);
            return self.entries.get(buffer[0..name.len]);
        }
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            if (std.ascii.eqlIgnoreCase(entry.key_ptr.*, name)) return entry.value_ptr.*;
        }
        return null;
    }

    /// 已注册组件数量。
    pub fn count(self: *const ComponentRegistry) usize {
        return self.entries.count();
    }
};

fn lowerAlloc(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    const out = try allocator.alloc(u8, text.len);
    for (text, 0..) |c, index| out[index] = std.ascii.toLower(c);
    return out;
}

// ————— AST —————

const Node = union(enum) {
    text: []const u8,
    write: Expr,
    write_raw: Expr,
    if_node: *const IfNode,
    foreach_node: *const ForeachNode,
    set_var: struct { name: []const u8, expr: Expr },
    set_layout: Expr,
    section: struct { name: []const u8, body: []const Node },
    render_body,
    render_section: SectionCall,
    partial: struct { name: Expr, model: ?Expr },
    component: ComponentCall,
};

/// 组件调用（名称在编译期固定为字符串字面量，参数在渲染期求值）。
const ComponentCall = struct {
    name: []const u8,
    args: ?Expr,
};

/// `@RenderSection(...)` / `@await RenderSectionAsync(...)` 参数。
const SectionCall = struct {
    name: []const u8,
    required: bool,
};

const IfNode = struct {
    branches: []const Branch,
    else_body: ?[]const Node,
};

const Branch = struct {
    cond: Expr,
    body: []const Node,
};

const ForeachNode = struct {
    var_name: []const u8,
    iterable: Expr,
    body: []const Node,
};

const Step = union(enum) {
    field: []const u8,
    index: *const Expr,
};

const Expr = union(enum) {
    null_lit,
    bool_lit: bool,
    int_lit: i64,
    float_lit: f64,
    str_lit: []const u8,
    path: struct { root: []const u8, steps: []const Step },
    unary: struct { op: enum { not, negate }, operand: *const Expr },
    binary: struct { op: BinaryOp, lhs: *const Expr, rhs: *const Expr },
    ternary: struct { cond: *const Expr, then_expr: *const Expr, else_expr: *const Expr },
};

const BinaryOp = enum { add, sub, mul, div, mod, eq, ne, lt, gt, le, ge, and_, or_, coalesce };

// ————— 编译 —————

/// 编译模板源码。
///
/// **源码会被复制进 `arena`**：AST 里的文本/标识符/字面量都是指向该副本的切片，
/// 因此调用方的源缓冲区可以立即释放（否则渲染期会读到悬垂内存）。
pub fn compile(arena: std.mem.Allocator, source: []const u8) CompileOutcome {
    const owned = arena.dupe(u8, source) catch return .{ .fail = "模板编译失败：内存不足" };
    var parser = Parser{ .src = owned, .arena = arena };
    const nodes = parser.parseNodes(false) catch |e| switch (e) {
        error.Syntax => return .{ .fail = parser.err_msg orelse "模板语法错误" },
        error.OutOfMemory => return .{ .fail = "模板编译失败：内存不足" },
    };
    const template = arena.create(Template) catch return .{ .fail = "模板编译失败：内存不足" };
    template.* = .{ .nodes = nodes };
    return .{ .ok = template };
}

const ParseError = error{ Syntax, OutOfMemory };

const Parser = struct {
    src: []const u8,
    pos: usize = 0,
    arena: std.mem.Allocator,
    err_msg: ?[]const u8 = null,
    err_pos: usize = 0,

    fn peek(self: *Parser) ?u8 {
        return if (self.pos < self.src.len) self.src[self.pos] else null;
    }

    fn peekAt(self: *Parser, offset: usize) ?u8 {
        return if (self.pos + offset < self.src.len) self.src[self.pos + offset] else null;
    }

    fn fail(self: *Parser, comptime fmt: []const u8, args: anytype) ParseError {
        const detail = std.fmt.allocPrint(self.arena, fmt, args) catch "模板语法错误";
        var line: usize = 1;
        var column: usize = 1;
        var i: usize = 0;
        while (i < self.pos and i < self.src.len) : (i += 1) {
            if (self.src[i] == '\n') {
                line += 1;
                column = 1;
            } else {
                column += 1;
            }
        }
        self.err_msg = std.fmt.allocPrint(self.arena, "{s}（第 {d} 行第 {d} 列）", .{ detail, line, column }) catch detail;
        return error.Syntax;
    }

    fn skipSpace(self: *Parser) void {
        while (self.pos < self.src.len) : (self.pos += 1) {
            switch (self.src[self.pos]) {
                ' ', '\t', '\r', '\n' => {},
                else => return,
            }
        }
    }

    fn expect(self: *Parser, c: u8) ParseError!void {
        if (self.peek() != c) return self.fail("期望 '{c}'，实际是 {s}", .{ c, describeChar(self.peek()) });
        self.pos += 1;
    }

    fn startsWith(self: *Parser, text: []const u8) bool {
        if (self.pos + text.len > self.src.len) return false;
        return std.mem.eql(u8, self.src[self.pos .. self.pos + text.len], text);
    }

    fn parseNodes(self: *Parser, stop_at_rbrace: bool) ParseError![]const Node {
        var nodes: std.ArrayList(Node) = .empty;
        errdefer nodes.deinit(self.arena);
        var text: std.ArrayList(u8) = .empty;
        errdefer text.deinit(self.arena);

        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == '}' and stop_at_rbrace) break;

            if (c != '@') {
                try text.append(self.arena, c);
                self.pos += 1;
                continue;
            }

            // `@@` → 字面 `@`
            if (self.peekAt(1) == '@') {
                try text.append(self.arena, '@');
                self.pos += 2;
                continue;
            }

            if (text.items.len > 0) {
                try nodes.append(self.arena, .{ .text = try text.toOwnedSlice(self.arena) });
                text = .empty;
            }
            self.pos += 1;
            try self.parseRazor(&nodes);
        }

        if (text.items.len > 0) {
            try nodes.append(self.arena, .{ .text = try text.toOwnedSlice(self.arena) });
        }
        return nodes.toOwnedSlice(self.arena);
    }

    fn parseRazor(self: *Parser, nodes: *std.ArrayList(Node)) ParseError!void {
        const c = self.peek() orelse return self.fail("'@' 后缺少内容", .{});

        if (c == '*') {
            self.pos += 1;
            while (self.pos < self.src.len) {
                if (self.peek() == '*' and self.peekAt(1) == '@') {
                    self.pos += 2;
                    return;
                }
                self.pos += 1;
            }
            return self.fail("注释 `@* *@` 未闭合", .{});
        }

        if (c == '{') {
            self.pos += 1;
            return self.parseCodeBlock(nodes);
        }

        if (c == '(') {
            self.pos += 1;
            const expr = try self.parseExpr();
            self.skipSpace();
            try self.expect(')');
            try nodes.append(self.arena, .{ .write = expr });
            return;
        }

        if (!isIdentStart(c)) {
            return self.fail("'@' 后只能是标识符、`@(...)`、`@{{...}}` 或 `@*...*@`", .{});
        }

        const start = self.pos;
        const name = self.readIdent() orelse return self.fail("读取标识符失败", .{});
        self.pos = start;

        if (std.mem.eql(u8, name, "if")) return self.parseIf(nodes);
        if (std.mem.eql(u8, name, "foreach")) return self.parseForeach(nodes);
        if (std.mem.eql(u8, name, "section")) return self.parseSection(nodes);
        if (std.mem.eql(u8, name, "RenderBody")) {
            self.pos += name.len;
            self.skipSpace();
            try self.expect('(');
            self.skipSpace();
            try self.expect(')');
            try nodes.append(self.arena, .render_body);
            return;
        }
        if (std.mem.eql(u8, name, "RenderSection") or std.mem.eql(u8, name, "RenderSectionAsync")) {
            self.pos += name.len;
            const call = try self.parseRenderSectionArgs();
            try nodes.append(self.arena, .{ .render_section = call });
            return;
        }
        if (std.mem.eql(u8, name, "await")) {
            self.pos += name.len;
            return self.parseAwait(nodes);
        }
        if (std.mem.eql(u8, name, "Component")) {
            // `@await Component.InvokeAsync(...)` / `@Component("...")`
            const next = self.peekAt(name.len) orelse 0;
            if (next == '.' or next == '(') return self.parseComponentCall(nodes);
        }
        if (std.mem.eql(u8, name, "Html")) {
            // `@Html.Raw(...)` / `@Html.Partial(...)` / `@Html.PartialAsync(...)`
            if (self.peekAt(name.len) == '.') {
                return self.parseHtmlHelper(nodes);
            }
        }
        if (std.mem.eql(u8, name, "Raw")) {
            if (self.peekAt(name.len) == '(') {
                self.pos += name.len;
                self.skipSpace();
                try self.expect('(');
                const expr = try self.parseExpr();
                self.skipSpace();
                try self.expect(')');
                try nodes.append(self.arena, .{ .write_raw = expr });
                return;
            }
        }

        // 隐式表达式：`@Model.X`、`@item.Name`、`@i`
        const expr = try self.parseImplicitExpr();
        try nodes.append(self.arena, .{ .write = expr });
    }

    fn parseAwait(self: *Parser, nodes: *std.ArrayList(Node)) ParseError!void {
        self.skipSpace();
        const start = self.pos;
        const name = self.readIdent() orelse return self.fail("`@await` 后缺少调用", .{});
        self.pos = start;

        if (std.mem.eql(u8, name, "RenderSectionAsync")) {
            self.pos += name.len;
            const call = try self.parseRenderSectionArgs();
            try nodes.append(self.arena, .{ .render_section = call });
            return;
        }
        if (std.mem.eql(u8, name, "Html")) {
            return self.parseHtmlHelper(nodes);
        }
        if (std.mem.eql(u8, name, "Component")) {
            return self.parseComponentCall(nodes);
        }
        return self.fail("`@await` 只支持 `Html.PartialAsync(...)`、`RenderSectionAsync(...)` 与 `Component.InvokeAsync(...)`", .{});
    }

    /// 解析组件调用：`Component.InvokeAsync("Name"[, 参数])` / `Component.Invoke(...)` / `Component("Name"[, 参数])`。
    fn parseComponentCall(self: *Parser, nodes: *std.ArrayList(Node)) ParseError!void {
        self.pos += "Component".len;
        self.skipSpace();
        if (self.peek() == '.') {
            self.pos += 1;
            self.skipSpace();
            const method = self.readIdent() orelse return self.fail("`Component.` 后缺少方法名", .{});
            if (!std.mem.eql(u8, method, "InvokeAsync") and !std.mem.eql(u8, method, "Invoke")) {
                return self.fail("`Component.{s}` 不在子集内（仅支持 InvokeAsync / Invoke）", .{method});
            }
            self.skipSpace();
        }
        try self.expect('(');
        self.skipSpace();
        const name_expr = try self.parseExpr();
        const component_name = switch (name_expr) {
            .str_lit => |text| text,
            else => return self.fail("组件名称必须是字符串字面量（如 `Component.InvokeAsync(\"Stats\")`）", .{}),
        };
        self.skipSpace();
        var args: ?Expr = null;
        if (self.peek() == ',') {
            self.pos += 1;
            args = try self.parseExpr();
            self.skipSpace();
        }
        try self.expect(')');
        try nodes.append(self.arena, .{ .component = .{ .name = component_name, .args = args } });
    }

    fn parseHtmlHelper(self: *Parser, nodes: *std.ArrayList(Node)) ParseError!void {
        self.pos += "Html".len;
        self.skipSpace();
        try self.expect('.');
        self.skipSpace();
        const method = self.readIdent() orelse return self.fail("`Html.` 后缺少方法名", .{});
        if (std.mem.eql(u8, method, "Raw")) {
            self.skipSpace();
            try self.expect('(');
            const expr = try self.parseExpr();
            self.skipSpace();
            try self.expect(')');
            try nodes.append(self.arena, .{ .write_raw = expr });
            return;
        }
        if (std.mem.eql(u8, method, "Partial") or std.mem.eql(u8, method, "PartialAsync")) {
            self.skipSpace();
            try self.expect('(');
            self.skipSpace();
            const name_expr = try self.parseExpr();
            self.skipSpace();
            var model_expr: ?Expr = null;
            if (self.peek() == ',') {
                self.pos += 1;
                model_expr = try self.parseExpr();
                self.skipSpace();
            }
            try self.expect(')');
            try nodes.append(self.arena, .{ .partial = .{ .name = name_expr, .model = model_expr } });
            return;
        }
        return self.fail("`Html.{s}` 不在子集内（仅支持 Raw / Partial / PartialAsync）", .{method});
    }

    fn parseRenderSectionArgs(self: *Parser) ParseError!SectionCall {
        self.skipSpace();
        try self.expect('(');
        const name_expr = try self.parseExpr();
        const name = switch (name_expr) {
            .str_lit => |text| text,
            else => return self.fail("`RenderSection` 的名称必须是字符串字面量", .{}),
        };
        self.skipSpace();
        var required = true;
        if (self.peek() == ',') {
            self.pos += 1;
            self.skipSpace();
            if (self.startsWith("false")) {
                required = false;
                self.pos += "false".len;
            } else if (self.startsWith("true")) {
                self.pos += "true".len;
            } else {
                return self.fail("`RenderSection` 的第二个参数必须是 true/false", .{});
            }
            self.skipSpace();
        }
        try self.expect(')');
        return .{ .name = name, .required = required };
    }

    fn parseIf(self: *Parser, nodes: *std.ArrayList(Node)) ParseError!void {
        self.pos += "if".len;
        self.skipSpace();
        try self.expect('(');
        const first_cond = try self.parseExpr();
        self.skipSpace();
        try self.expect(')');
        var branches: std.ArrayList(Branch) = .empty;
        errdefer branches.deinit(self.arena);

        try branches.append(self.arena, .{ .cond = first_cond, .body = try self.parseBlockBody() });

        var else_body: ?[]const Node = null;
        while (true) {
            const save = self.pos;
            self.skipSpace();
            if (!self.startsWith("else")) {
                self.pos = save;
                break;
            }
            self.pos += "else".len;
            self.skipSpace();
            if (self.startsWith("if")) {
                self.pos += "if".len;
                self.skipSpace();
                try self.expect('(');
                const cond = try self.parseExpr();
                self.skipSpace();
                try self.expect(')');
                try branches.append(self.arena, .{ .cond = cond, .body = try self.parseBlockBody() });
                continue;
            }
            else_body = try self.parseBlockBody();
            break;
        }

        const node = try self.arena.create(IfNode);
        node.* = .{ .branches = try branches.toOwnedSlice(self.arena), .else_body = else_body };
        try nodes.append(self.arena, .{ .if_node = node });
    }

    fn parseForeach(self: *Parser, nodes: *std.ArrayList(Node)) ParseError!void {
        self.pos += "foreach".len;
        self.skipSpace();
        try self.expect('(');
        self.skipSpace();
        if (!self.startsWith("var")) return self.fail("`@foreach` 只支持 `var 名称 in 表达式`", .{});
        self.pos += "var".len;
        self.skipSpace();
        const var_name = self.readIdent() orelse return self.fail("`@foreach` 缺少循环变量名", .{});
        self.skipSpace();
        if (!self.startsWith("in")) return self.fail("`@foreach` 缺少 `in`", .{});
        self.pos += "in".len;
        self.skipSpace();
        const iterable = try self.parseExpr();
        self.skipSpace();
        try self.expect(')');
        const body = try self.parseBlockBody();

        const node = try self.arena.create(ForeachNode);
        node.* = .{ .var_name = var_name, .iterable = iterable, .body = body };
        try nodes.append(self.arena, .{ .foreach_node = node });
    }

    fn parseSection(self: *Parser, nodes: *std.ArrayList(Node)) ParseError!void {
        self.pos += "section".len;
        self.skipSpace();
        const name = self.readIdent() orelse return self.fail("`@section` 缺少名称", .{});
        self.skipSpace();
        const body = try self.parseBlockBody();
        try nodes.append(self.arena, .{ .section = .{ .name = name, .body = body } });
    }

    fn parseBlockBody(self: *Parser) ParseError![]const Node {
        self.skipSpace();
        try self.expect('{');
        const body = try self.parseNodes(true);
        try self.expect('}');
        return body;
    }

    fn parseCodeBlock(self: *Parser, nodes: *std.ArrayList(Node)) ParseError!void {
        while (true) {
            self.skipSpace();
            if (self.peek() == null) return self.fail("代码块 `@{{` 未闭合", .{});
            if (self.peek() == '}') {
                self.pos += 1;
                return;
            }

            const start = self.pos;
            const name = self.readIdent() orelse return self.fail("代码块内只支持 `var 名称 = 表达式;` 与 `Layout = \"...\";`", .{});
            self.pos = start;

            if (std.mem.eql(u8, name, "var")) {
                self.pos += "var".len;
                self.skipSpace();
                const var_name = self.readIdent() orelse return self.fail("`var` 后缺少变量名", .{});
                self.skipSpace();
                try self.expect('=');
                const expr = try self.parseExpr();
                self.skipSpace();
                try self.expect(';');
                try nodes.append(self.arena, .{ .set_var = .{ .name = var_name, .expr = expr } });
                continue;
            }

            if (std.mem.eql(u8, name, "Layout")) {
                self.pos += "Layout".len;
                self.skipSpace();
                try self.expect('=');
                const expr = try self.parseExpr();
                self.skipSpace();
                try self.expect(';');
                try nodes.append(self.arena, .{ .set_layout = expr });
                continue;
            }

            return self.fail("代码块内只支持 `var 名称 = 表达式;` 与 `Layout = \"...\";`（不支持 `{s}`）", .{name});
        }
    }

    fn readIdent(self: *Parser) ?[]const u8 {
        const start = self.pos;
        while (self.pos < self.src.len) : (self.pos += 1) {
            const c = self.src[self.pos];
            if (isIdentChar(c)) continue;
            break;
        }
        if (self.pos == start) return null;
        return self.src[start..self.pos];
    }

    fn parseImplicitExpr(self: *Parser) ParseError!Expr {
        const root = self.readIdent() orelse return self.fail("'@' 后缺少表达式", .{});
        var steps: std.ArrayList(Step) = .empty;
        errdefer steps.deinit(self.arena);

        while (true) {
            switch (self.peek() orelse break) {
                '.' => {
                    self.pos += 1;
                    const field = self.readIdent() orelse return self.fail("'.' 后缺少成员名", .{});
                    try steps.append(self.arena, .{ .field = field });
                },
                '[' => {
                    self.pos += 1;
                    const index = try self.parseExpr();
                    self.skipSpace();
                    try self.expect(']');
                    const index_ptr = try self.arena.create(Expr);
                    index_ptr.* = index;
                    try steps.append(self.arena, .{ .index = index_ptr });
                },
                else => break,
            }
        }
        return .{ .path = .{ .root = root, .steps = try steps.toOwnedSlice(self.arena) } };
    }

    // ————— 表达式 —————

    fn parseExpr(self: *Parser) ParseError!Expr {
        return self.parseTernary();
    }

    fn parseTernary(self: *Parser) ParseError!Expr {
        const cond = try self.parseCoalesce();
        self.skipSpace();
        if (self.peek() == '?') {
            self.pos += 1;
            const then_expr = try self.parseExpr();
            self.skipSpace();
            try self.expect(':');
            const else_expr = try self.parseExpr();
            return makeBinary3(self.arena, cond, then_expr, else_expr);
        }
        return cond;
    }

    fn parseCoalesce(self: *Parser) ParseError!Expr {
        var left = try self.parseOr();
        while (true) {
            self.skipSpace();
            if (!self.startsWith("??")) break;
            self.pos += 2;
            const right = try self.parseOr();
            left = try makeBinary(self.arena, .coalesce, left, right);
        }
        return left;
    }

    fn parseOr(self: *Parser) ParseError!Expr {
        var left = try self.parseAnd();
        while (true) {
            self.skipSpace();
            if (!self.startsWith("||")) break;
            self.pos += 2;
            const right = try self.parseAnd();
            left = try makeBinary(self.arena, .or_, left, right);
        }
        return left;
    }

    fn parseAnd(self: *Parser) ParseError!Expr {
        var left = try self.parseEquality();
        while (true) {
            self.skipSpace();
            if (!self.startsWith("&&")) break;
            self.pos += 2;
            const right = try self.parseEquality();
            left = try makeBinary(self.arena, .and_, left, right);
        }
        return left;
    }

    fn parseEquality(self: *Parser) ParseError!Expr {
        var left = try self.parseRelational();
        while (true) {
            self.skipSpace();
            if (self.startsWith("==")) {
                self.pos += 2;
                left = try makeBinary(self.arena, .eq, left, try self.parseRelational());
            } else if (self.startsWith("!=")) {
                self.pos += 2;
                left = try makeBinary(self.arena, .ne, left, try self.parseRelational());
            } else break;
        }
        return left;
    }

    fn parseRelational(self: *Parser) ParseError!Expr {
        var left = try self.parseAdditive();
        while (true) {
            self.skipSpace();
            if (self.startsWith("<=")) {
                self.pos += 2;
                left = try makeBinary(self.arena, .le, left, try self.parseAdditive());
            } else if (self.startsWith(">=")) {
                self.pos += 2;
                left = try makeBinary(self.arena, .ge, left, try self.parseAdditive());
            } else if (self.peek() == '<') {
                self.pos += 1;
                left = try makeBinary(self.arena, .lt, left, try self.parseAdditive());
            } else if (self.peek() == '>') {
                self.pos += 1;
                left = try makeBinary(self.arena, .gt, left, try self.parseAdditive());
            } else break;
        }
        return left;
    }

    fn parseAdditive(self: *Parser) ParseError!Expr {
        var left = try self.parseMultiplicative();
        while (true) {
            self.skipSpace();
            if (self.peek() == '+') {
                self.pos += 1;
                left = try makeBinary(self.arena, .add, left, try self.parseMultiplicative());
            } else if (self.peek() == '-') {
                self.pos += 1;
                left = try makeBinary(self.arena, .sub, left, try self.parseMultiplicative());
            } else break;
        }
        return left;
    }

    fn parseMultiplicative(self: *Parser) ParseError!Expr {
        var left = try self.parseUnary();
        while (true) {
            self.skipSpace();
            if (self.peek() == '*') {
                self.pos += 1;
                left = try makeBinary(self.arena, .mul, left, try self.parseUnary());
            } else if (self.peek() == '/') {
                self.pos += 1;
                left = try makeBinary(self.arena, .div, left, try self.parseUnary());
            } else if (self.peek() == '%') {
                self.pos += 1;
                left = try makeBinary(self.arena, .mod, left, try self.parseUnary());
            } else break;
        }
        return left;
    }

    fn parseUnary(self: *Parser) ParseError!Expr {
        self.skipSpace();
        if (self.peek() == '!') {
            self.pos += 1;
            const operand = try self.parseUnary();
            const expr = Expr{ .unary = .{ .op = .not, .operand = try self.makeExprPtr(operand) } };
            return expr;
        }
        if (self.peek() == '-') {
            self.pos += 1;
            const operand = try self.parseUnary();
            return Expr{ .unary = .{ .op = .negate, .operand = try self.makeExprPtr(operand) } };
        }
        return self.parsePostfix();
    }

    fn parsePostfix(self: *Parser) ParseError!Expr {
        var expr = try self.parsePrimary();
        while (true) {
            self.skipSpace();
            switch (self.peek() orelse break) {
                '.' => {
                    self.pos += 1;
                    const field = self.readIdent() orelse return self.fail("'.' 后缺少成员名", .{});
                    const new_step: Step = .{ .field = field };
                    expr = try appendStep(self.arena, expr, new_step);
                },
                '[' => {
                    self.pos += 1;
                    const index = try self.parseExpr();
                    self.skipSpace();
                    try self.expect(']');
                    const step: Step = .{ .index = try self.makeExprPtr(index) };
                    expr = try appendStep(self.arena, expr, step);
                },
                else => break,
            }
        }
        return expr;
    }

    fn parsePrimary(self: *Parser) ParseError!Expr {
        self.skipSpace();
        const c = self.peek() orelse return self.fail("表达式不完整", .{});

        if (c == '(') {
            self.pos += 1;
            const inner = try self.parseExpr();
            self.skipSpace();
            try self.expect(')');
            return inner;
        }

        if (c == '"') return self.parseStringLiteral();

        if (c == '-' or (c >= '0' and c <= '9')) return self.parseNumber();

        if (isIdentStart(c)) {
            const name = self.readIdent().?;
            if (std.mem.eql(u8, name, "true")) return .{ .bool_lit = true };
            if (std.mem.eql(u8, name, "false")) return .{ .bool_lit = false };
            if (std.mem.eql(u8, name, "null")) return .null_lit;
            if (self.peek() == '(') {
                return self.fail("不支持方法调用 `{s}(...)`（子集只允许 `Raw`/`Html.Raw`/`Html.Partial`）", .{name});
            }
            return .{ .path = .{ .root = name, .steps = &.{} } };
        }

        return self.fail("无法识别的表达式起始字符 {s}", .{describeChar(self.peek())});
    }

    fn parseStringLiteral(self: *Parser) ParseError!Expr {
        self.pos += 1;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.arena);
        while (true) {
            const c = self.peek() orelse return self.fail("字符串字面量未闭合", .{});
            self.pos += 1;
            switch (c) {
                '"' => return .{ .str_lit = try out.toOwnedSlice(self.arena) },
                '\\' => {
                    const esc = self.peek() orelse return self.fail("转义序列不完整", .{});
                    self.pos += 1;
                    switch (esc) {
                        '"' => try out.append(self.arena, '"'),
                        '\\' => try out.append(self.arena, '\\'),
                        'n' => try out.append(self.arena, '\n'),
                        'r' => try out.append(self.arena, '\r'),
                        't' => try out.append(self.arena, '\t'),
                        else => return self.fail("不支持的转义 `\\{c}`", .{esc}),
                    }
                },
                else => try out.append(self.arena, c),
            }
        }
    }

    fn parseNumber(self: *Parser) ParseError!Expr {
        const start = self.pos;
        if (self.peek() == '-') self.pos += 1;
        var is_float = false;
        while (self.pos < self.src.len) : (self.pos += 1) {
            const c = self.src[self.pos];
            switch (c) {
                '0'...'9' => {},
                '.' => is_float = true,
                else => break,
            }
        }
        const text = self.src[start..self.pos];
        if (text.len == 0 or std.mem.eql(u8, text, "-")) return self.fail("数字字面量不完整", .{});
        if (is_float) {
            const number = std.fmt.parseFloat(f64, text) catch return self.fail("非法数字 `{s}`", .{text});
            return .{ .float_lit = number };
        }
        const integer = std.fmt.parseInt(i64, text, 10) catch return self.fail("非法整数 `{s}`", .{text});
        return .{ .int_lit = integer };
    }

    fn makeExprPtr(self: *Parser, expr: Expr) ParseError!*const Expr {
        const ptr = try self.arena.create(Expr);
        ptr.* = expr;
        return ptr;
    }
};

fn makeBinary(arena: std.mem.Allocator, op: BinaryOp, lhs: Expr, rhs: Expr) !Expr {
    const lhs_ptr = try arena.create(Expr);
    lhs_ptr.* = lhs;
    const rhs_ptr = try arena.create(Expr);
    rhs_ptr.* = rhs;
    return .{ .binary = .{ .op = op, .lhs = lhs_ptr, .rhs = rhs_ptr } };
}

fn makeBinary3(arena: std.mem.Allocator, cond: Expr, then_expr: Expr, else_expr: Expr) !Expr {
    const cond_ptr = try arena.create(Expr);
    cond_ptr.* = cond;
    const then_ptr = try arena.create(Expr);
    then_ptr.* = then_expr;
    const else_ptr = try arena.create(Expr);
    else_ptr.* = else_expr;
    return .{ .ternary = .{ .cond = cond_ptr, .then_expr = then_ptr, .else_expr = else_ptr } };
}

fn appendStep(arena: std.mem.Allocator, expr: Expr, step: Step) !Expr {
    var root: []const u8 = undefined;
    var steps: std.ArrayList(Step) = .empty;

    switch (expr) {
        .path => |path| {
            root = path.root;
            try steps.appendSlice(arena, path.steps);
        },
        else => return expr, // 非路径（如 `(a+b).x`）不支持后缀访问：原样返回，求值时自然不匹配
    }
    try steps.append(arena, step);
    return .{ .path = .{ .root = root, .steps = try steps.toOwnedSlice(arena) } };
}

fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_' or c >= 0x80;
}

fn isIdentChar(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}

fn describeChar(c: ?u8) []const u8 {
    if (c == null) return "文件结尾";
    return switch (c.?) {
        '\n' => "换行",
        else => "该字符",
    };
}

// ————— 渲染 —————

const Scope = struct {
    parent: ?*const Scope,
    name: []const u8,
    value: Value,
};

const RenderCtx = struct {
    allocator: std.mem.Allocator,
    renderer: *ViewRenderer,
    controller: []const u8,
    model: Value = .null,
    sections: std.StringHashMapUnmanaged([]const u8) = .empty,
    body: []const u8 = "",
    /// 当前模板声明的布局名（`null` = 无布局）
    layout_name: ?[]const u8 = null,
    depth: usize = 0,
    err: ?[]const u8 = null,
};

fn renderFail(rc: *RenderCtx, comptime fmt: []const u8, args: anytype) anyerror {
    rc.err = std.fmt.allocPrint(rc.allocator, fmt, args) catch "模板渲染失败";
    return error.Render;
}

fn renderNodes(
    rc: *RenderCtx,
    nodes: []const Node,
    scope: ?*const Scope,
    writer: *std.Io.Writer,
    layout_out: *?[]const u8,
) anyerror!void {
    var head = scope;

    for (nodes) |node| {
        switch (node) {
            .text => |text| try writer.writeAll(text),
            .write => |expr| {
                const v = try eval(rc, expr, head);
                const text = try v.textAlloc(rc.allocator);
                try value.writeEscapedHtml(writer, text);
                rc.allocator.free(text);
            },
            .write_raw => |expr| {
                const v = try eval(rc, expr, head);
                const text = try v.textAlloc(rc.allocator);
                try writer.writeAll(text);
                rc.allocator.free(text);
            },            .if_node => |node_ptr| {
                var matched = false;
                for (node_ptr.branches) |branch| {
                    const cond = try eval(rc, branch.cond, head);
                    const flag = cond.asBool() orelse
                        return renderFail(rc, "`@if` 条件必须是布尔值（实际为 {s}）", .{@tagName(cond)});
                    if (flag) {
                        try renderNodes(rc, branch.body, head, writer, layout_out);
                        matched = true;
                        break;
                    }
                }
                if (!matched) {
                    if (node_ptr.else_body) |body| try renderNodes(rc, body, head, writer, layout_out);
                }
            },
            .foreach_node => |node_ptr| {
                const list = try eval(rc, node_ptr.iterable, head);
                const items = switch (list) {
                    .list => |items| items,
                    .null => return renderFail(rc, "`@foreach` 的数据为 null", .{}),
                    else => return renderFail(rc, "`@foreach` 的数据必须是列表（实际为 {s}）", .{@tagName(list)}),
                };
                for (items) |item| {
                    const child = try rc.allocator.create(Scope);
                    child.* = .{ .parent = head, .name = node_ptr.var_name, .value = item };
                    try renderNodes(rc, node_ptr.body, child, writer, layout_out);
                }
            },
            .set_var => |decl| {
                const v = try eval(rc, decl.expr, head);
                const child = try rc.allocator.create(Scope);
                child.* = .{ .parent = head, .name = decl.name, .value = v };
                head = child;
            },
            .set_layout => |expr| {
                const v = try eval(rc, expr, head);
                layout_out.* = switch (v) {
                    .string => |text| text,
                    .null => null,
                    else => return renderFail(rc, "`Layout` 必须是字符串", .{}),
                };
            },
            .section => |section| {
                if (rc.sections.contains(section.name)) {
                    return renderFail(rc, "分区 `{s}` 重复定义", .{section.name});
                }
                var buffer: std.Io.Writer.Allocating = .init(rc.allocator);
                defer buffer.deinit();
                var ignored: ?[]const u8 = null;
                try renderNodes(rc, section.body, head, &buffer.writer, &ignored);
                try rc.sections.put(rc.allocator, section.name, try buffer.toOwnedSlice());
            },
            .render_body => try writer.writeAll(rc.body),
            .render_section => |section| {
                if (rc.sections.get(section.name)) |html| {
                    try writer.writeAll(html);
                } else if (section.required) {
                    return renderFail(rc, "布局要求分区 `{s}`，但页面未定义", .{section.name});
                }
            },
            .partial => |partial| {
                if (rc.depth >= 8) return renderFail(rc, "分部视图/布局/组件嵌套超过 8 层（可能存在循环引用）", .{});
                const name_value = try eval(rc, partial.name, head);
                const name = name_value.asString() orelse
                    return renderFail(rc, "`Html.Partial` 的视图名必须是字符串", .{});
                const model = if (partial.model) |expr| try eval(rc, expr, head) else rc.model;

                const path = switch (try rc.renderer.resolve(rc.allocator, rc.controller, name)) {
                    .path => |path| path,
                    .missing => |message| return renderFail(rc, "{s}", .{message}),
                };
                const template = switch (rc.renderer.loadTemplate(rc.allocator, path)) {
                    .ok => |template| template,
                    .fail => |message| return renderFail(rc, "{s}", .{message}),
                };
                try renderSubTemplate(rc, template, model, writer);
            },
            .component => |call| {
                if (rc.depth >= 8) return renderFail(rc, "分部视图/布局/组件嵌套超过 8 层（可能存在循环引用）", .{});
                const registry = rc.renderer.components orelse
                    return renderFail(rc, "未配置组件注册表：请在 App 上调用 `registerComponent`", .{});
                const entry = registry.get(call.name) orelse
                    return renderFail(rc, "未注册的组件 `{s}`（请先 `app.registerComponent(\"{s}\", ...)`）", .{ call.name, call.name });

                const args = if (call.args) |expr| try eval(rc, expr, head) else rc.model;
                var component_ctx = ComponentContext{
                    .arena = rc.allocator,
                    .renderer = rc.renderer,
                    .controller = rc.controller,
                    .args = args,
                    .parent_model = rc.model,
                };
                const result = entry.func(entry.ctx, &component_ctx) catch |e| {
                    return renderFail(rc, "组件 `{s}` 执行失败：{s}", .{ call.name, @errorName(e) });
                };

                switch (result) {
                    .html => |html| try writer.writeAll(html),
                    .view => |view_result| {
                        const view_name = view_result.name orelse "Default";
                        const path = switch (try rc.renderer.resolveComponent(
                            rc.allocator,
                            rc.controller,
                            call.name,
                            view_name,
                        )) {
                            .path => |path| path,
                            .missing => |message| return renderFail(rc, "{s}", .{message}),
                        };
                        const template = switch (rc.renderer.loadTemplate(rc.allocator, path)) {
                            .ok => |template| template,
                            .fail => |message| return renderFail(rc, "{s}", .{message}),
                        };
                        try renderSubTemplate(rc, template, view_result.model, writer);
                    },
                }
            },
        }
    }
}

/// 用指定模型渲染子模板（分部视图 / 组件视图；不参与布局）。
fn renderSubTemplate(rc: *RenderCtx, template: *Template, model: Value, writer: *std.Io.Writer) anyerror!void {
    const saved_model = rc.model;
    const saved_body = rc.body;
    rc.model = model;
    rc.body = "";
    rc.depth += 1;
    defer {
        rc.model = saved_model;
        rc.body = saved_body;
        rc.depth -= 1;
    }
    var ignored: ?[]const u8 = null;
    try renderNodes(rc, template.nodes, null, writer, &ignored);
}

fn eval(rc: *RenderCtx, expr: Expr, scope: ?*const Scope) anyerror!Value {
    switch (expr) {
        .null_lit => return .null,
        .bool_lit => |b| return .{ .boolean = b },
        .int_lit => |i| return .{ .integer = i },
        .float_lit => |f| return .{ .number = f },
        .str_lit => |s| return .{ .string = s },
        .path => |path| {
            var current: Value = blk: {
                if (std.mem.eql(u8, path.root, "Model")) break :blk rc.model;
                var cursor = scope;
                while (cursor) |node| {
                    if (std.mem.eql(u8, node.name, path.root)) break :blk node.value;
                    cursor = node.parent;
                }
                return renderFail(rc, "未定义的变量 `{s}`", .{path.root});
            };
            for (path.steps) |step| {
                switch (step) {
                    .field => |name| current = current.get(name) orelse .null,
                    .index => |index_expr| {
                        const index_value = try eval(rc, index_expr.*, scope);
                        const index = index_value.asInt() orelse
                            return renderFail(rc, "下标必须是整数（实际为 {s}）", .{@tagName(index_value)});
                        if (index < 0) return .null;
                        current = current.at(@intCast(index)) orelse .null;
                    },
                }
            }
            return current;
        },
        .unary => |unary| {
            const operand = try eval(rc, unary.operand.*, scope);
            switch (unary.op) {
                .not => {
                    const flag = operand.asBool() orelse
                        return renderFail(rc, "`!` 的操作数必须是布尔值（实际为 {s}）", .{@tagName(operand)});
                    return .{ .boolean = !flag };
                },
                .negate => switch (operand) {
                    .integer => |i| return .{ .integer = -i },
                    .number => |f| return .{ .number = -f },
                    else => return renderFail(rc, "`-` 的操作数必须是数字", .{}),
                },
            }
        },
        .binary => |binary| {
            if (binary.op == .and_) {
                const lhs = try eval(rc, binary.lhs.*, scope);
                const left = lhs.asBool() orelse return renderFail(rc, "`&&` 的操作数必须是布尔值", .{});
                if (!left) return .{ .boolean = false };
                const rhs = try eval(rc, binary.rhs.*, scope);
                return .{ .boolean = rhs.asBool() orelse return renderFail(rc, "`&&` 的操作数必须是布尔值", .{}) };
            }
            if (binary.op == .or_) {
                const lhs = try eval(rc, binary.lhs.*, scope);
                const left = lhs.asBool() orelse return renderFail(rc, "`||` 的操作数必须是布尔值", .{});
                if (left) return .{ .boolean = true };
                const rhs = try eval(rc, binary.rhs.*, scope);
                return .{ .boolean = rhs.asBool() orelse return renderFail(rc, "`||` 的操作数必须是布尔值", .{}) };
            }
            if (binary.op == .coalesce) {
                const lhs = try eval(rc, binary.lhs.*, scope);
                if (lhs != .null) return lhs;
                return eval(rc, binary.rhs.*, scope);
            }

            const lhs = try eval(rc, binary.lhs.*, scope);
            const rhs = try eval(rc, binary.rhs.*, scope);

            switch (binary.op) {
                .eq => return .{ .boolean = value.eql(lhs, rhs) },
                .ne => return .{ .boolean = !value.eql(lhs, rhs) },
                .lt, .gt, .le, .ge => {
                    const order = value.compare(lhs, rhs) orelse {
                        return renderFail(rc, "无法比较 {s} 与 {s}", .{ @tagName(lhs), @tagName(rhs) });
                    };
                    return .{ .boolean = switch (binary.op) {
                        .lt => order == .lt,
                        .gt => order == .gt,
                        .le => order != .gt,
                        .ge => order != .lt,
                        else => unreachable,
                    } };
                },
                .add => {
                    if (lhs == .string or rhs == .string) {
                        const left_text = try lhs.textAlloc(rc.allocator);
                        defer rc.allocator.free(left_text);
                        const right_text = try rhs.textAlloc(rc.allocator);
                        defer rc.allocator.free(right_text);
                        return .{ .string = try std.fmt.allocPrint(rc.allocator, "{s}{s}", .{ left_text, right_text }) };
                    }
                    return arithmetic(rc, binary.op, lhs, rhs);
                },
                .sub, .mul, .div, .mod => return arithmetic(rc, binary.op, lhs, rhs),
                .and_, .or_, .coalesce => unreachable,
            }
        },
        .ternary => |ternary| {
            const cond = try eval(rc, ternary.cond.*, scope);
            const flag = cond.asBool() orelse
                return renderFail(rc, "三元条件必须是布尔值（实际为 {s}）", .{@tagName(cond)});
            return eval(rc, if (flag) ternary.then_expr.* else ternary.else_expr.*, scope);
        },
    }
}

fn arithmetic(rc: *RenderCtx, op: BinaryOp, lhs: Value, rhs: Value) anyerror!Value {
    const left_int = switch (lhs) {
        .integer => |i| i,
        else => null,
    };
    const right_int = switch (rhs) {
        .integer => |i| i,
        else => null,
    };

    if (left_int != null and right_int != null) {
        const a = left_int.?;
        const b = right_int.?;
        switch (op) {
            .add => return .{ .integer = a +% b },
            .sub => return .{ .integer = a -% b },
            .mul => return .{ .integer = a *% b },
            .div => {
                if (b == 0) return renderFail(rc, "整数除零", .{});
                return .{ .integer = @divTrunc(a, b) };
            },
            .mod => {
                if (b == 0) return renderFail(rc, "整数取模除零", .{});
                return .{ .integer = @rem(a, b) };
            },
            else => unreachable,
        }
    }

    const a = lhs.asFloat() orelse return renderFail(rc, "算术操作数必须是数字（实际为 {s}）", .{@tagName(lhs)});
    const b = rhs.asFloat() orelse return renderFail(rc, "算术操作数必须是数字（实际为 {s}）", .{@tagName(rhs)});
    switch (op) {
        .add => return .{ .number = a + b },
        .sub => return .{ .number = a - b },
        .mul => return .{ .number = a * b },
        .div => {
            if (b == 0) return renderFail(rc, "除零", .{});
            return .{ .number = a / b };
        },
        .mod => {
            if (b == 0) return renderFail(rc, "取模除零", .{});
            return .{ .number = @rem(a, b) };
        },
        else => unreachable,
    }
}

// ————— 视图解析与缓存 —————

const ResolveResult = union(enum) {
    path: []const u8,
    missing: []const u8,
};

const CacheEntry = struct {
    mtime_ms: i64,
    size: u64,
    template: *Template,
};

/// 模板加载结果。
pub const LoadOutcome = union(enum) {
    ok: *Template,
    fail: []const u8,
};

/// 视图渲染器（目录约定 + 模板缓存）。
pub const ViewRenderer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8 = "Views",
    areas_root: []const u8 = "Areas",
    fallback_area: ?[]const u8 = null,
    max_bytes: usize = 4 * 1024 * 1024,

    cache: std.StringHashMapUnmanaged(CacheEntry) = .empty,
    arenas: std.ArrayList(*std.heap.ArenaAllocator) = .empty,
    mutex: std.Io.Mutex = .init,
    /// 组件注册表（由 App 注入；`null` 时模板里的组件调用会报错）
    components: ?*ComponentRegistry = null,

    /// 创建渲染器（`io` 用于读模板，跨线程安全）。
    pub fn init(allocator: std.mem.Allocator, io: std.Io) ViewRenderer {
        return .{ .allocator = allocator, .io = io };
    }

    /// 释放缓存与模板 arena。
    pub fn deinit(self: *ViewRenderer) void {
        var it = self.cache.iterator();
        while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.cache.deinit(self.allocator);

        for (self.arenas.items) |arena| {
            arena.deinit();
            self.allocator.destroy(arena);
        }
        self.arenas.deinit(self.allocator);
    }

    /// 设置视图根（默认 `Views`）。
    pub fn setRoot(self: *ViewRenderer, root: []const u8) void {
        self.root = root;
    }

    /// 设置区域根（默认 `Areas`）。
    pub fn setAreasRoot(self: *ViewRenderer, root: []const u8) void {
        self.areas_root = root;
    }

    /// 设置默认（回退）区域：区域视图缺失时回退到该区域的同名视图。
    pub fn setFallbackArea(self: *ViewRenderer, area: ?[]const u8) void {
        self.fallback_area = area;
    }

    /// 注入组件注册表（`null` = 禁用组件调用）。
    pub fn setComponents(self: *ViewRenderer, registry: ?*ComponentRegistry) void {
        self.components = registry;
    }

    /// 渲染视图（`controller` 可含区域前缀，如 `admin/home`）。
    ///
    /// 返回的 HTML 与错误信息都由 `arena` 承载。
    pub fn render(
        self: *ViewRenderer,
        arena: std.mem.Allocator,
        controller: []const u8,
        view: []const u8,
        model: Value,
    ) RenderOutcome {
        const path = switch (self.resolve(arena, controller, view) catch |e| {
            return .{ .fail = std.fmt.allocPrint(arena, "视图解析失败：{s}", .{@errorName(e)}) catch "视图解析失败" };
        }) {
            .path => |path| path,
            .missing => |message| return .{ .fail = message },
        };

        const template = switch (self.loadTemplate(arena, path)) {
            .ok => |template| template,
            .fail => |message| return .{ .fail = message },
        };

        var rc = RenderCtx{
            .allocator = arena,
            .renderer = self,
            .controller = controller,
            .model = model,
        };

        var html = renderOnce(&rc, template, arena) catch |e| {
            return .{ .fail = rc.err orelse std.fmt.allocPrint(arena, "视图渲染失败：{s}", .{@errorName(e)}) catch "视图渲染失败" };
        };

        // 布局链：页面 → Layout → Layout 的 Layout（上限 8 层）
        var layout_name = rc.layout_name;
        var depth: usize = 0;
        while (layout_name) |name| {
            if (depth >= 8) return .{ .fail = "布局嵌套超过 8 层（可能存在循环引用）" };
            depth += 1;

            const layout_path = switch (self.resolve(arena, controller, name) catch |e| {
                return .{ .fail = std.fmt.allocPrint(arena, "布局解析失败：{s}", .{@errorName(e)}) catch "布局解析失败" };
            }) {
                .path => |p| p,
                .missing => |message| return .{ .fail = message },
            };
            const layout_template = switch (self.loadTemplate(arena, layout_path)) {
                .ok => |t| t,
                .fail => |message| return .{ .fail = message },
            };

            rc.body = html;
            rc.layout_name = null;
            html = renderOnce(&rc, layout_template, arena) catch |e| {
                return .{ .fail = rc.err orelse std.fmt.allocPrint(arena, "布局渲染失败：{s}", .{@errorName(e)}) catch "布局渲染失败" };
            };
            layout_name = rc.layout_name;
        }

        return .{ .html = html };
    }

    /// 按约定解析视图路径（返回第一条存在的）。
    pub fn resolve(
        self: *const ViewRenderer,
        arena: std.mem.Allocator,
        controller: []const u8,
        view: []const u8,
    ) !ResolveResult {
        var tried: std.ArrayList([]const u8) = .empty;

        const trimmed_view = std.mem.trim(u8, view, "/");
        const ctrl = std.mem.trim(u8, controller, "/");
        const area = if (std.mem.indexOfScalar(u8, ctrl, '/')) |index| ctrl[0..index] else null;
        const ctrl_leaf = if (std.mem.indexOfScalar(u8, ctrl, '/')) |index| ctrl[index + 1 ..] else ctrl;

        var candidates: std.ArrayList([]const u8) = .empty;

        if (view.len > 0 and view[0] == '/') {
            try pushCandidate(&candidates, arena, self.root, trimmed_view);
        } else if (std.mem.indexOfScalar(u8, trimmed_view, '/') != null) {
            if (area) |area_name| {
                try pushCandidate(&candidates, arena, try std.fmt.allocPrint(arena, "{s}/{s}", .{ self.areas_root, pascal(arena, area_name) }), try std.fmt.allocPrint(arena, "Views/{s}", .{trimmed_view}));
            }
            try pushCandidate(&candidates, arena, self.root, trimmed_view);
        } else {
            if (area) |area_name| {
                try self.pushAreaCandidates(&candidates, arena, area_name, ctrl_leaf, trimmed_view);
                if (self.fallback_area) |fallback| {
                    if (!std.ascii.eqlIgnoreCase(fallback, area_name)) {
                        try self.pushAreaCandidates(&candidates, arena, fallback, ctrl_leaf, trimmed_view);
                    }
                }
            }
            try pushCandidate(&candidates, arena, try std.fmt.allocPrint(arena, "{s}/{s}", .{ self.root, pascal(arena, ctrl_leaf) }), trimmed_view);
            try pushCandidate(&candidates, arena, try std.fmt.allocPrint(arena, "{s}/Shared", .{self.root}), trimmed_view);
            if (area) |area_name| {
                try pushCandidate(&candidates, arena, try std.fmt.allocPrint(arena, "{s}/{s}/Views/Shared", .{ self.areas_root, pascal(arena, area_name) }), trimmed_view);
            }
        }

        for (candidates.items) |candidate| {
            if (!isCandidateSafe(candidate)) continue;
            if (fsio.exists(self.io, candidate)) return .{ .path = candidate };
            try tried.append(arena, candidate);
        }

        var message: std.Io.Writer.Allocating = .init(arena);
        defer message.deinit();
        try message.writer.print("视图不存在：{s}（控制器 {s}）；已尝试：", .{ view, controller });
        for (tried.items, 0..) |candidate, index| {
            if (index >= 8) {
                try message.writer.writeAll(" …");
                break;
            }
            if (index > 0) try message.writer.writeAll("、");
            try message.writer.writeAll(candidate);
        }
        return .{ .missing = try message.toOwnedSlice() };
    }

    fn pushAreaCandidates(
        self: *const ViewRenderer,
        candidates: *std.ArrayList([]const u8),
        arena: std.mem.Allocator,
        area_name: []const u8,
        ctrl_leaf: []const u8,
        view: []const u8,
    ) !void {
        const area_root = try std.fmt.allocPrint(arena, "{s}/{s}", .{ self.areas_root, pascal(arena, area_name) });
        const views_dir = try std.fmt.allocPrint(arena, "{s}/Views/{s}", .{ area_root, pascal(arena, ctrl_leaf) });
        try pushCandidate(candidates, arena, views_dir, view);
        try pushCandidate(candidates, arena, try std.fmt.allocPrint(arena, "{s}/Views/Shared", .{area_root}), view);
        try pushCandidate(candidates, arena, try std.fmt.allocPrint(arena, "{s}/{s}/{s}", .{ self.root, pascal(arena, area_name), pascal(arena, ctrl_leaf) }), view);
        try pushCandidate(candidates, arena, try std.fmt.allocPrint(arena, "{s}/{s}/Shared", .{ self.root, pascal(arena, area_name) }), view);
    }

    /// 解析组件视图（对齐 ASP.NET Core View Components 约定）：
    ///
    /// 1. `Areas/{Area}/Views/{Controller}/Components/{Name}/{View}.cshtml`
    /// 2. `Views/{Controller}/Components/{Name}/{View}.cshtml`
    /// 3. `Areas/{Area}/Views/Shared/Components/{Name}/{View}.cshtml`
    /// 4. `Views/Shared/Components/{Name}/{View}.cshtml`
    ///
    /// 配了回退区域时，再把区域换成回退区域重试一遍。
    pub fn resolveComponent(
        self: *const ViewRenderer,
        arena: std.mem.Allocator,
        controller: []const u8,
        component: []const u8,
        view: []const u8,
    ) !ResolveResult {
        var candidates: std.ArrayList([]const u8) = .empty;
        var tried: std.ArrayList([]const u8) = .empty;

        const ctrl = std.mem.trim(u8, controller, "/");
        const area = if (std.mem.indexOfScalar(u8, ctrl, '/')) |index| ctrl[0..index] else null;
        const ctrl_leaf = if (std.mem.indexOfScalar(u8, ctrl, '/')) |index| ctrl[index + 1 ..] else ctrl;
        const name_path = try std.fmt.allocPrint(arena, "Components/{s}", .{pascal(arena, component)});

        if (area) |area_name| {
            try self.pushAreaComponentCandidates(&candidates, arena, area_name, ctrl_leaf, name_path, view);
            if (self.fallback_area) |fallback| {
                if (!std.ascii.eqlIgnoreCase(fallback, area_name)) {
                    try self.pushAreaComponentCandidates(&candidates, arena, fallback, ctrl_leaf, name_path, view);
                }
            }
        }

        try pushCandidate(&candidates, arena, try std.fmt.allocPrint(arena, "{s}/{s}/{s}", .{ self.root, pascal(arena, ctrl_leaf), name_path }), view);
        try pushCandidate(&candidates, arena, try std.fmt.allocPrint(arena, "{s}/Shared/{s}", .{ self.root, name_path }), view);

        for (candidates.items) |candidate| {
            if (!isCandidateSafe(candidate)) continue;
            if (fsio.exists(self.io, candidate)) return .{ .path = candidate };
            try tried.append(arena, candidate);
        }

        var message: std.Io.Writer.Allocating = .init(arena);
        defer message.deinit();
        try message.writer.print("组件视图不存在：Components/{s}/{s}.cshtml（控制器 {s}）；已尝试：", .{
            pascal(arena, component),
            pascal(arena, view),
            controller,
        });
        for (tried.items, 0..) |candidate, index| {
            if (index >= 8) {
                try message.writer.writeAll(" …");
                break;
            }
            if (index > 0) try message.writer.writeAll("、");
            try message.writer.writeAll(candidate);
        }
        return .{ .missing = try message.toOwnedSlice() };
    }

    fn pushAreaComponentCandidates(
        self: *const ViewRenderer,
        candidates: *std.ArrayList([]const u8),
        arena: std.mem.Allocator,
        area_name: []const u8,
        ctrl_leaf: []const u8,
        name_path: []const u8,
        view: []const u8,
    ) !void {
        const area_root = try std.fmt.allocPrint(arena, "{s}/{s}", .{ self.areas_root, pascal(arena, area_name) });
        try pushCandidate(candidates, arena, try std.fmt.allocPrint(arena, "{s}/Views/{s}/{s}", .{ area_root, pascal(arena, ctrl_leaf), name_path }), view);
        try pushCandidate(candidates, arena, try std.fmt.allocPrint(arena, "{s}/Views/Shared/{s}", .{ area_root, name_path }), view);
    }

    /// 读取并编译模板（按「修改时间 + 长度」缓存；命中零文件读取）。
    pub fn loadTemplate(self: *ViewRenderer, arena: std.mem.Allocator, path: []const u8) LoadOutcome {
        const stat = fsio.statFile(self.io, path) catch |e| {
            return .{ .fail = std.fmt.allocPrint(arena, "读取视图失败：{s}（{s}）", .{ path, @errorName(e) }) catch "读取视图失败" };
        };
        const mtime_ms = stat.mtime.toMilliseconds();

        self.mutex.lockUncancelable(self.io);
        if (self.cache.get(path)) |entry| {
            if (entry.mtime_ms == mtime_ms and entry.size == stat.size) {
                const template = entry.template;
                self.mutex.unlock(self.io);
                return .{ .ok = template };
            }
        }
        self.mutex.unlock(self.io);

        const source = fsio.readFileAlloc(self.io, self.allocator, path, self.max_bytes) catch |e| {
            return .{ .fail = std.fmt.allocPrint(arena, "读取视图失败：{s}（{s}）", .{ path, @errorName(e) }) catch "读取视图失败" };
        };
        defer self.allocator.free(source);

        const template_arena = self.allocator.create(std.heap.ArenaAllocator) catch {
            return .{ .fail = "视图编译失败：内存不足" };
        };
        template_arena.* = std.heap.ArenaAllocator.init(self.allocator);

        const template = switch (compile(template_arena.allocator(), source)) {
            .ok => |t| t,
            .fail => |message| {
                const detail = std.fmt.allocPrint(arena, "{s}：{s}", .{ path, message }) catch "模板编译失败";
                template_arena.deinit();
                self.allocator.destroy(template_arena);
                return .{ .fail = detail };
            },
        };

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        self.arenas.append(self.allocator, template_arena) catch {
            return .{ .fail = "视图编译失败：内存不足" };
        };

        const key = self.allocator.dupe(u8, path) catch return .{ .fail = "视图缓存失败：内存不足" };
        if (self.cache.getEntry(path)) |existing| {
            self.allocator.free(existing.key_ptr.*);
            existing.key_ptr.* = key;
            existing.value_ptr.* = .{ .mtime_ms = mtime_ms, .size = stat.size, .template = template };
        } else {
            self.cache.put(self.allocator, key, .{
                .mtime_ms = mtime_ms,
                .size = stat.size,
                .template = template,
            }) catch return .{ .fail = "视图缓存失败：内存不足" };
        }
        return .{ .ok = template };
    }
};

fn renderOnce(rc: *RenderCtx, template: *Template, arena: std.mem.Allocator) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    var layout: ?[]const u8 = null;
    try renderNodes(rc, template.nodes, null, &out.writer, &layout);
    rc.layout_name = layout;
    return out.toOwnedSlice();
}

fn pushCandidate(candidates: *std.ArrayList([]const u8), arena: std.mem.Allocator, dir: []const u8, view: []const u8) !void {
    const pascal_view = try pascalPath(arena, view);
    try candidates.append(arena, try std.fmt.allocPrint(arena, "{s}/{s}.cshtml", .{ dir, pascal_view }));
    if (!std.mem.eql(u8, pascal_view, view)) {
        try candidates.append(arena, try std.fmt.allocPrint(arena, "{s}/{s}.cshtml", .{ dir, view }));
    }
}

fn pascal(arena: std.mem.Allocator, text: []const u8) []const u8 {
    if (text.len == 0) return text;
    const first = text[0];
    if (first >= 'A' and first <= 'Z') return text;
    if (first >= 'a' and first <= 'z') {
        const out = arena.alloc(u8, text.len) catch return text;
        out[0] = first - ('a' - 'A');
        @memcpy(out[1..], text[1..]);
        return out;
    }
    return text;
}

fn pascalPath(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var iter = std.mem.splitScalar(u8, text, '/');
    var first = true;
    while (iter.next()) |segment| {
        if (!first) try out.append(arena, '/');
        first = false;
        try out.appendSlice(arena, pascal(arena, segment));
    }
    return out.toOwnedSlice(arena);
}

fn isCandidateSafe(path: []const u8) bool {
    var iter = std.mem.splitScalar(u8, path, '/');
    while (iter.next()) |segment| {
        if (std.mem.eql(u8, segment, "..")) return false;
    }
    return true;
}

const testing = std.testing;
const compat = @import("../compat.zig");

fn renderSource(arena: std.mem.Allocator, source: []const u8, model: Value) ![]const u8 {
    var renderer = ViewRenderer.init(testing.allocator, compat.currentIo());
    defer renderer.deinit();

    const template = switch (compile(arena, source)) {
        .ok => |t| t,
        .fail => |message| {
            std.debug.print("编译失败：{s}\n", .{message});
            return error.CompileFailed;
        },
    };

    var rc = RenderCtx{
        .allocator = arena,
        .renderer = &renderer,
        .controller = "home",
        .model = model,
    };
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    var layout: ?[]const u8 = null;
    try renderNodes(&rc, template.nodes, null, &out.writer, &layout);
    return out.toOwnedSlice();
}

test "view：转义 / Raw / 注释 / @@ / 显式表达式" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const fields = [_]value.Field{
        value.field("Title", value.ofString("<b>面板</b>")),
        value.field("Count", value.ofInt(2)),
    };
    const model = value.ofObject(&fields);

    const html = try renderSource(arena,
        \\<h1>@Model.Title</h1>@Raw(Model.Title)@* 注释 *@@Model.Count@@x
    , model);
    try testing.expectEqualStrings("<h1>&lt;b&gt;面板&lt;/b&gt;</h1><b>面板</b>2@x", html);
}

test "view：if / else if / else 与比较运算" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const source =
        \\@if (Model.Count > 5) {大} else if (Model.Count == 2) {中} else {小}
    ;
    const fields = [_]value.Field{value.field("Count", value.ofInt(2))};
    const html = try renderSource(arena, source, value.ofObject(&fields));
    try testing.expectEqualStrings("中", html);

    const fields2 = [_]value.Field{value.field("Count", value.ofInt(9))};
    const html2 = try renderSource(arena, source, value.ofObject(&fields2));
    try testing.expectEqualStrings("大", html2);
}

test "view：foreach 嵌套与下标访问" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const item_a = [_]value.Field{value.field("Name", value.ofString("a"))};
    const item_b = [_]value.Field{value.field("Name", value.ofString("b"))};
    const items = [_]Value{ value.ofObject(&item_a), value.ofObject(&item_b) };
    const fields = [_]value.Field{value.field("Items", value.ofList(&items))};
    const model = value.ofObject(&fields);

    const html = try renderSource(arena,
        \\@foreach (var item in Model.Items) {<li>@item.Name</li>}
    , model);
    try testing.expectEqualStrings("<li>a</li><li>b</li>", html);

    const html_index = try renderSource(arena, "@Model.Items[1].Name", model);
    try testing.expectEqualStrings("b", html_index);
}

test "view：@{ var } 与算术/三元/字符串拼接" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const fields = [_]value.Field{value.field("Name", value.ofString("首页"))};
    const html = try renderSource(arena,
        \\@{ var total = 1 + 2 * 3; }@total|@(total / 2)|@(total > 3 ? "多" : "少")|@("标题：" + Model.Name)
    , value.ofObject(&fields));
    try testing.expectEqualStrings("7|3|多|标题：首页", html);
}

test "view：语法错误带行列号" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    switch (compile(arena, "第一行\n@if (Model.X { \n")) {
        .ok => return error.TestUnexpectedResult,
        .fail => |message| {
            try testing.expect(std.mem.indexOf(u8, message, "第 2 行") != null);
        },
    }
}

test "view：不支持的语法显式报错" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    switch (compile(arena, "@(Foo(1))")) {
        .ok => return error.TestUnexpectedResult,
        .fail => |message| try testing.expect(std.mem.indexOf(u8, message, "不支持方法调用") != null),
    }
    switch (compile(arena, "@{ System.Console.WriteLine(1); }")) {
        .ok => return error.TestUnexpectedResult,
        .fail => |message| try testing.expect(std.mem.indexOf(u8, message, "代码块内只支持") != null),
    }
    switch (compile(arena, "@await Foo()")) {
        .ok => return error.TestUnexpectedResult,
        .fail => |message| try testing.expect(std.mem.indexOf(u8, message, "@await") != null),
    }
}

fn makeTempDir(name: []const u8) ![]const u8 {
    const io = compat.currentIo();
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}-{d}", .{ name, compat.nanoTimestamp() });
    try fsio.makePath(io, path);
    return path;
}

fn writeView(path: []const u8, content: []const u8) !void {
    const io = compat.currentIo();
    try fsio.ensureParent(io, path);
    try fsio.writeFile(io, path, content);
}

test "view：布局 / 分区 / RenderBody / Shared（文件系统）" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = compat.currentIo();

    const dir = try makeTempDir("views-layout");
    defer {
        std.Io.Dir.cwd().deleteTree(io, dir) catch {};
        testing.allocator.free(dir);
    }

    try writeView(try std.fmt.allocPrint(arena, "{s}/Views/Shared/_Layout.cshtml", .{dir}),
        \\<html><title>@Model.Title</title><body>@RenderBody()<footer>@RenderSection("Scripts", false)</footer></body></html>
    );
    try writeView(try std.fmt.allocPrint(arena, "{s}/Views/Home/Index.cshtml", .{dir}),
        \\@{ Layout = "Shared/_Layout"; }<p>@Model.Title</p>@section Scripts {<script>x()</script>}
    );

    var renderer = ViewRenderer.init(testing.allocator, io);
    defer renderer.deinit();
    renderer.setRoot(try std.fmt.allocPrint(arena, "{s}/Views", .{dir}));

    const fields = [_]value.Field{value.field("Title", value.ofString("首页"))};
    const result = renderer.render(arena, "home", "index", value.ofObject(&fields));
    switch (result) {
        .html => |html| try testing.expectEqualStrings(
            "<html><title>首页</title><body><p>首页</p><footer><script>x()</script></footer></body></html>",
            html,
        ),
        .fail => |message| {
            std.debug.print("渲染失败：{s}\n", .{message});
            return error.RenderFailed;
        },
    }
}

test "view：区域视图 Areas/{Area}/Views 与回退区域" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = compat.currentIo();

    const dir = try makeTempDir("views-area");
    defer {
        std.Io.Dir.cwd().deleteTree(io, dir) catch {};
        testing.allocator.free(dir);
    }

    try writeView(try std.fmt.allocPrint(arena, "{s}/Areas/Admin/Views/Dashboard/Index.cshtml", .{dir}), "admin-dashboard");
    try writeView(try std.fmt.allocPrint(arena, "{s}/Views/Admin/Home/Index.cshtml", .{dir}), "area-in-views");

    var renderer = ViewRenderer.init(testing.allocator, io);
    defer renderer.deinit();
    renderer.setRoot(try std.fmt.allocPrint(arena, "{s}/Views", .{dir}));
    renderer.setAreasRoot(try std.fmt.allocPrint(arena, "{s}/Areas", .{dir}));

    switch (renderer.render(arena, "admin/dashboard", "index", value.ofNull())) {
        .html => |html| try testing.expectEqualStrings("admin-dashboard", html),
        .fail => |message| {
            std.debug.print("{s}\n", .{message});
            return error.RenderFailed;
        },
    }

    switch (renderer.render(arena, "admin/home", "index", value.ofNull())) {
        .html => |html| try testing.expectEqualStrings("area-in-views", html),
        .fail => |message| {
            std.debug.print("{s}\n", .{message});
            return error.RenderFailed;
        },
    }
}

test "view：模板缓存按修改时间失效" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = compat.currentIo();

    const dir = try makeTempDir("views-cache");
    defer {
        std.Io.Dir.cwd().deleteTree(io, dir) catch {};
        testing.allocator.free(dir);
    }

    const view_path = try std.fmt.allocPrint(arena, "{s}/Views/Home/Index.cshtml", .{dir});
    try writeView(view_path, "v1");

    var renderer = ViewRenderer.init(testing.allocator, io);
    defer renderer.deinit();
    renderer.setRoot(try std.fmt.allocPrint(arena, "{s}/Views", .{dir}));

    switch (renderer.render(arena, "home", "index", value.ofNull())) {
        .html => |html| try testing.expectEqualStrings("v1", html),
        .fail => return error.RenderFailed,
    }

    // 改文件（内容长度变化即可命中「长度+时间」失效条件）
    try writeView(view_path, "v2-longer");
    switch (renderer.render(arena, "home", "index", value.ofNull())) {
        .html => |html| try testing.expectEqualStrings("v2-longer", html),
        .fail => return error.RenderFailed,
    }
}

fn renderSourceWith(
    arena: std.mem.Allocator,
    renderer: *ViewRenderer,
    controller: []const u8,
    source: []const u8,
    model: Value,
) RenderOutcome {
    const template = switch (compile(arena, source)) {
        .ok => |template| template,
        .fail => |message| return .{ .fail = message },
    };
    var rc = RenderCtx{
        .allocator = arena,
        .renderer = renderer,
        .controller = controller,
        .model = model,
    };
    var out: std.Io.Writer.Allocating = .init(arena);
    defer out.deinit();
    var layout: ?[]const u8 = null;
    renderNodes(&rc, template.nodes, null, &out.writer, &layout) catch |e| {
        return .{ .fail = rc.err orelse std.fmt.allocPrint(arena, "渲染失败：{s}", .{@errorName(e)}) catch "渲染失败" };
    };
    return .{ .html = out.toOwnedSlice() catch "内存不足" };
}

test "view：组件式调用（返回 HTML / 名称大小写不敏感）" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var renderer = ViewRenderer.init(testing.allocator, compat.currentIo());
    defer renderer.deinit();

    var registry = ComponentRegistry.init(testing.allocator);
    defer registry.deinit();

    const S = struct {
        fn hello(_: ?*anyopaque, c: *ComponentContext) anyerror!ComponentResult {
            return .{ .html = try std.fmt.allocPrint(c.arena, "<em>{s}</em>", .{c.args.asString() orelse ""}) };
        }
    };
    try registry.register("Hello", null, S.hello);
    renderer.setComponents(&registry);

    switch (renderSourceWith(arena, &renderer, "home", "<div>@await Component.InvokeAsync(\"hello\", \"世界\")</div>", value.ofNull())) {
        .html => |html| try testing.expectEqualStrings("<div><em>世界</em></div>", html),
        .fail => |message| {
            std.debug.print("组件渲染失败：{s}\n", .{message});
            return error.RenderFailed;
        },
    }

    // 简写 `@Component(...)` 也可用
    switch (renderSourceWith(arena, &renderer, "home", "@Component(\"HELLO\")", value.ofString("x"))) {
        .html => |html| try testing.expectEqualStrings("<em>x</em>", html),
        .fail => return error.RenderFailed,
    }
}

test "view：组件返回视图（Shared/Components/{Name}/Default.cshtml + 参数模型）" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = compat.currentIo();

    const dir = try makeTempDir("views-component");
    defer {
        std.Io.Dir.cwd().deleteTree(io, dir) catch {};
        testing.allocator.free(dir);
    }
    try writeView(try std.fmt.allocPrint(arena, "{s}/Views/Shared/Components/Stats/Default.cshtml", .{dir}),
        \\<span class="count">@Model.Count</span>
    );

    var renderer = ViewRenderer.init(testing.allocator, io);
    defer renderer.deinit();
    renderer.setRoot(try std.fmt.allocPrint(arena, "{s}/Views", .{dir}));

    var registry = ComponentRegistry.init(testing.allocator);
    defer registry.deinit();

    const S = struct {
        fn stats(_: ?*anyopaque, c: *ComponentContext) anyerror!ComponentResult {
            return .{ .view = .{ .model = c.args } };
        }
    };
    try registry.register("Stats", null, S.stats);
    renderer.setComponents(&registry);

    var model_builder = value.ObjectBuilder.init(arena);
    try model_builder.int("Count", 7);
    const model = model_builder.finish();

    switch (renderSourceWith(arena, &renderer, "home", "@await Component.InvokeAsync(\"Stats\", Model)", model)) {
        .html => |html| try testing.expectEqualStrings("<span class=\"count\">7</span>", html),
        .fail => |message| {
            std.debug.print("组件视图渲染失败：{s}\n", .{message});
            return error.RenderFailed;
        },
    }
}

test "view：区域内组件视图优先于共享组件视图" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = compat.currentIo();

    const dir = try makeTempDir("views-component-area");
    defer {
        std.Io.Dir.cwd().deleteTree(io, dir) catch {};
        testing.allocator.free(dir);
    }
    try writeView(try std.fmt.allocPrint(arena, "{s}/Views/Shared/Components/Badge/Default.cshtml", .{dir}), "root-badge");
    try writeView(try std.fmt.allocPrint(arena, "{s}/Areas/Admin/Views/Shared/Components/Badge/Default.cshtml", .{dir}), "admin-badge");

    var renderer = ViewRenderer.init(testing.allocator, io);
    defer renderer.deinit();
    renderer.setRoot(try std.fmt.allocPrint(arena, "{s}/Views", .{dir}));
    renderer.setAreasRoot(try std.fmt.allocPrint(arena, "{s}/Areas", .{dir}));

    var registry = ComponentRegistry.init(testing.allocator);
    defer registry.deinit();
    const S = struct {
        fn badge(_: ?*anyopaque, _: *ComponentContext) anyerror!ComponentResult {
            return .{ .view = .{} };
        }
    };
    try registry.register("Badge", null, S.badge);
    renderer.setComponents(&registry);

    switch (renderSourceWith(arena, &renderer, "admin/dashboard", "@Component(\"Badge\")", value.ofNull())) {
        .html => |html| try testing.expectEqualStrings("admin-badge", html),
        .fail => |message| {
            std.debug.print("区域组件渲染失败：{s}\n", .{message});
            return error.RenderFailed;
        },
    }

    switch (renderSourceWith(arena, &renderer, "home", "@Component(\"Badge\")", value.ofNull())) {
        .html => |html| try testing.expectEqualStrings("root-badge", html),
        .fail => return error.RenderFailed,
    }
}

test "view：未注册组件 / 未配置注册表都显式报错" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var renderer = ViewRenderer.init(testing.allocator, compat.currentIo());
    defer renderer.deinit();

    switch (renderSourceWith(arena, &renderer, "home", "@Component(\"Missing\")", value.ofNull())) {
        .html => return error.TestUnexpectedResult,
        .fail => |message| try testing.expect(std.mem.indexOf(u8, message, "未配置组件注册表") != null),
    }

    var registry = ComponentRegistry.init(testing.allocator);
    defer registry.deinit();
    renderer.setComponents(&registry);

    switch (renderSourceWith(arena, &renderer, "home", "@Component(\"Missing\")", value.ofNull())) {
        .html => return error.TestUnexpectedResult,
        .fail => |message| try testing.expect(std.mem.indexOf(u8, message, "未注册的组件") != null),
    }
}

test "view：组件语法子集外显式报错" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    switch (compile(arena, "@Component.InvokeAsync(Model.Name)")) {
        .ok => return error.TestUnexpectedResult,
        .fail => |message| try testing.expect(std.mem.indexOf(u8, message, "字符串字面量") != null),
    }
    switch (compile(arena, "@await Component.RenderAsync(\"X\")")) {
        .ok => return error.TestUnexpectedResult,
        .fail => |message| try testing.expect(std.mem.indexOf(u8, message, "仅支持 InvokeAsync / Invoke") != null),
    }
}
