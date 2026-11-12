# Web MVC 一体化（Controller / 视图 / 区域 / wwwroot）

> 参考实现：C# ASP.NET Core MVC 的目录与路由约定、`E:\Code\Rust\DH.RustBase\src\net\{router,controller,static_files}.rs`
> 与 `DH.RustBase/Doc/{Razor子集模板引擎需求,SPA与MVC一体化}.md`；Zig 侧按 0.17.1 重写，不引入任何外部依赖。

## 1. 模块划分

| 模块 | 职责 | 对齐对象 |
|---|---|---|
| `zzig.web.router` | 路由（`{name}` 段捕获、405/404、中间件洋葱链、fallback）、请求上下文 `Ctx` | ASP.NET Core 路由 + `dhrust::net::router` |
| `zzig.web.controller` | 控制器（`/{prefix}/{action}`）、参数绑定（路由→查询→表单→JSON）、`{code,message,data}` 信封、视图动作 | MVC Controller + `dhrust::net::controller` |
| `zzig.web.view` | Razor 子集模板引擎 + 视图解析（`Views/{Controller}/{Action}.cshtml`、`Areas/{Area}/Views/...`、`Shared`、回退区域）+ 布局/分区/Partial + 模板缓存 | C# Razor 子集 + `dhrust::razor` |
| `zzig.web.static_files` | `wwwroot` 静态资源：MIME、默认文档、目录穿越防护、ETag/304、区域多根、嵌入资源、SPA 回退 | `UseStaticFiles` + `dhrust::net::static_files` |
| `zzig.web.value` | 视图/动作值模型（对象/列表/标量 + JSON 解析/序列化 + C# 口径文本化 + HTML 转义） | `serde_json::Value` 的可读子集 |
| `zzig.web.App`（`http/web.zig`） | 装配：路由 + 静态资源 + 控制器 + 桥接 `http_server`（监听/线程/上限） | `WebApplication` 最小子集 |

处理顺序：**路由优先 → 静态资源兜底 → 404**。SPA 深链接回退在静态资源这一层。

## 2. 目录约定

```
项目根/
├─ Views/                          # 视图根（可配）
│  ├─ Shared/_Layout.cshtml        # 共享视图/布局/Partial
│  └─ Home/
│     ├─ Index.cshtml              # Views/{Controller}/{Action}.cshtml
│     └─ About.cshtml
├─ Areas/                          # 区域根（可配）
│  └─ Admin/
│     ├─ Views/Dashboard/Index.cshtml   # Areas/{Area}/Views/{Controller}/{Action}.cshtml
│     └─ wwwroot/admin.css              # 区域静态资源，URL 前缀 /admin
└─ wwwroot/                        # 主静态资源根
   ├─ index.html                   # 默认文档（SPA 回退也用它）
   └─ app.css
```

查找顺序（`controller = admin/dashboard`，`view = index`）：

1. `Areas/Admin/Views/Dashboard/Index.cshtml`
2. `Areas/Admin/Views/Shared/Index.cshtml`（含 Pascal/原样两套候选）
3. `Views/Admin/Dashboard/Index.cshtml`（DH.RustBase 的区域写法）
4. `Views/Admin/Dashboard/.../Shared`（区域在视图根下的写法）
5. `Views/Dashboard/Index.cshtml`
6. `Views/Shared/Index.cshtml`
7. 配置了 `setFallbackArea("Admin")` 时，再把区域换成 `Admin` 重试一遍

显式写法：视图名以 `/` 开头 = 视图根下的全路径；含 `/` = 相对片段（如 `"Shared/_Layout"`）。

## 3. 最小可用示例

```zig
var app = try zzig.web.App.init(allocator, io, .{
    .wwwroot = "wwwroot",
    .views_root = "Views",
    .areas_root = "Areas",
    .spa_fallback = true,
});
defer app.deinit();

var home = try zzig.web.Controller.init(allocator, io, "home");
defer home.deinit();
try home.get("index", Home.index);   // GET /home/index
try home.post("save", Home.save);    // POST /home/save
try app.mountController(&home);

var dashboard = try zzig.web.Controller.initArea(allocator, io, "Admin", "Dashboard");
defer dashboard.deinit();
try dashboard.get("index", Dashboard.index);   // GET /admin/dashboard/index
try app.mountController(&dashboard);
try app.addArea("Admin");                      // Areas/Admin/wwwroot → /admin

try app.run("127.0.0.1", 8080, .{});
```

动作签名支持两种（见 `Controller.toActionFn`）：

```zig
fn index(c: *zzig.web.Ctx) anyerror!zzig.web.ActionResult
fn index(self: ?*anyopaque, c: *zzig.web.Ctx) anyerror!zzig.web.ActionResult  // 需要应用状态
```

返回值：

```zig
return zzig.web.viewResult(model);              // 渲染 {prefix}/{动作名}.cshtml
return zzig.web.viewNamed("Edit", model);       // 渲染指定视图
return .{ .response = try zzig.web.jsonResult(c.arena, 0, "", "{\"ok\":true}") };
```

**控制器对象必须比路由器活得久**（路由器只保存指针）：把 `defer ctrl.deinit()` 放在 `app.run(...)` 之后即可。

### 3.1 视图模型（注意生命周期）

动作返回后栈帧失效，所以**不要**用 `ofObject(&局部数组)` 直接拼模型——那会留下悬垂切片
（现象是页面输出空串或乱码数字）。统一用 arena 版构造器：

```zig
fn index(c: *zzig.web.Ctx) anyerror!zzig.web.ActionResult {
    var items: std.ArrayList(zzig.web.Value) = .empty;
    try items.append(c.arena, try zzig.web.value.strAlloc(c.arena, "第一项"));
    try items.append(c.arena, try zzig.web.value.strAlloc(c.arena, "第二项"));

    var model = zzig.web.value.ObjectBuilder.init(c.arena);
    try model.str("Title", "首页");                     // 字符串复制进 arena
    try model.int("Count", @intCast(items.items.len));
    try model.list("Items", items.items);               // 数组复制进 arena
    return zzig.web.viewResult(model.finish());
}
```

`Value.ofObject/ofList/ofString` 仍然保留（零拷贝），但只适合**渲染期仍存活**的数据（如静态常量）；
跨函数返回的一律用 `ObjectBuilder`。

## 4. 参数绑定

`zzig.web.arg(c, "name")` 依次取：**路由参数 → 查询串 → 表单 → JSON body 字段**（字段名大小写不敏感）。
另有 `argInt`（缺失/非法为 `null`）、`argBool`（`true/1/yes`、`false/0/no`）。

表单只在 `POST/PUT/PATCH` 且 `Content-Type: application/x-www-form-urlencoded` 时解析；
JSON body 懒解析并缓存在 `Ctx` 上（同一次请求只解析一次）。

`Ctx` 还提供：`param` / `queryValue` / `formValue` / `header` / `stateValue` / `setState` /
`formStr` / `formInt` / `formBool` / `jsonBody`。

## 5. 模板语法（Razor 子集）

| 语法 | 说明 |
|---|---|
| `@Model.X.Y` | 隐式表达式，默认 HTML 转义 |
| `@(表达式)` | 显式表达式（可写运算符） |
| `@Raw(x)` / `@Html.Raw(x)` | 原样输出（不转义，谨慎使用） |
| `@* ... *@` | 注释 |
| `@@` | 输出字面 `@` |
| `@if (cond) { } else if (cond) { } else { }` | 条件（条件必须是布尔值） |
| `@foreach (var item in 列表) { }` | 循环（变量在体内可见，可嵌套） |
| `@{ var a = 表达式; Layout = "Shared/_Layout"; }` | 代码块（**仅**这两种语句） |
| `@RenderBody()` | 布局中插入页面主体 |
| `@section Name { }` / `@RenderSection("Name", true)` / `@await RenderSectionAsync("Name", false)` | 分区 |
| `@Html.Partial("Name", 模型)` / `@await Html.PartialAsync("Name", 模型)` | 分部视图（默认继承当前模型） |
| `@await Component.InvokeAsync("Name", 参数)` / `@Component("Name", 参数)` | 视图组件（见 5.1） |

表达式子集：路径（`.` / `[下标]`）、字符串/整数/浮点/`true`/`false`/`null`、
`! - + * / %`、`== != < > <= >=`、`&& ||`、`? :`、`??`、括号。**不支持任意方法调用**——
子集外语法在编译期显式报错，带「第 N 行第 M 列」。

文本化对齐 C#：`bool` → `True`/`False`，`null` → 空串，整数无小数位；
对象/列表退化为 JSON（C# 会打印类型名，对页面无意义）。

缓存：按「文件修改时间 + 长度」失效，命中时零文件读取；热改产生的旧模板在 `ViewRenderer.deinit`
统一释放。分部视图/布局嵌套上限 8 层（防循环引用）。

### 5.1 组件（View Components）

组件 = **有逻辑的局部渲染单元**（对比 Partial：只有模板，没有处理函数）。对齐 ASP.NET Core View Components 的用法与目录约定。

**注册**（启动期注册、运行期只读，名称大小写不敏感）：

```zig
const Stats = struct {
    fn render(_: ?*anyopaque, c: *zzig.web.ComponentContext) anyerror!zzig.web.ComponentResult {
        const count = (c.args.get("Count") orelse zzig.web.value.ofInt(0)).asInt() orelse 0;
        var model = zzig.web.value.ObjectBuilder.init(c.arena);
        try model.int("Count", count);
        try model.str("Label", if (count > 2) "条目较多" else "条目较少");
        return .{ .view = .{ .model = model.finish() } };  // 也可以 `.{ .html = "<span>…</span>" }`
    }
};

try app.registerComponent("Stats", null, Stats.render);
```

`registerComponent` 的第二个参数是注册时携带的上下文指针（组件里通过 `self` 取应用状态），无状态传 `null`。

**调用**（两种写法等价，可写在页面、布局、Partials、其他组件里）：

```html
@await Component.InvokeAsync("Stats", Model)
@Component("Stats", Model)          <!-- 简写 -->
@Component("Stats")                  <!-- 不传参：参数默认为外层模型 -->
```

**视图查找顺序**（`Default` 为未指定视图名时的默认名；全部支持 Pascal/原样两套候选）：

1. `Areas/{Area}/Views/{Controller}/Components/{Name}/{View}.cshtml`
2. `Views/{Controller}/Components/{Name}/{View}.cshtml`
3. `Areas/{Area}/Views/Shared/Components/{Name}/{View}.cshtml`
4. `Views/Shared/Components/{Name}/{View}.cshtml`

配了回退区域时，再把区域换成回退区域重试一遍（同视图解析规则）。

**`ComponentContext` 提供的字段**：`arena`（请求 arena）、`renderer`（可继续用 Partial）、
`controller`（调用方控制器前缀，含区域）、`args`（调用方传入的参数）、`parent_model`（外层模型）。

**边界**：
- 组件视图**不参与布局链**（`@{ Layout = ... }` 在组件里被忽略）；
- 分部视图与组件内**不允许定义 `@section`**（显式报错，与 ASP.NET 一致），分区只写在页面或布局里；
- 组件可嵌套组件，但整体嵌套（布局/Partial/组件）上限 8 层，超出显式报错；
- 组件返回 `error` 时渲染失败信息会带上组件名与错误名，便于定位。

## 6. 静态资源（wwwroot）

- 默认文档：路径为空或以 `/` 结尾时依次尝试 `index.html`（`setDefaultDocuments` 可改）；
- 条件请求：磁盘文件弱 ETag（长度 + 修改时间），嵌入资源强 ETag（长度 + 内容哈希），
  `If-None-Match` 命中返回 `304` 空体；
- 安全：路径 URL 解码后逐段校验，`..` / `.` / `\` / `:` / 空段 / NUL / 控制字符一律拒绝；
- 区域多根：`addRoot("/admin", "Areas/Admin/wwwroot")`，**最长前缀优先**；
- 嵌入资源：`embed("/index.html", data, "text/html; charset=utf-8")`，与磁盘叠加且优先命中
  （单文件部署），默认**不**把 `wwwroot` 编进二进制；
- SPA 回退：`spaFallback(true)` + `spaExcludes(&.{"/api"})`，只回退**无扩展名**的路径，
  避免缺失的 `.js/.css` 被返回成 HTML；
- 缓存头：默认 `Cache-Control: no-cache`，带哈希指纹的产物可 `setCacheControl("public, max-age=31536000, immutable")`。
- 磁盘文件默认走文件流式（内存恒定、不整读），详见 6.1。

### 6.1 目录配置（改默认目录 / 追加目录）

**默认目录可改**（相对项目目录或绝对路径都行）：

```zig
var app = try zzig.web.App.init(allocator, io, .{
    .wwwroot = "assets/public",        // 不再用 wwwroot
    // .wwwroot = null,                // 完全不提供静态资源
});
```

**追加额外静态根**（例如下载目录）；`url_prefix` 为空串则与主根合并按最长前缀匹配：

```zig
var app = try zzig.web.App.init(allocator, io, .{
    .wwwroot = "wwwroot",
    .static_roots = &.{
        .{ .url_prefix = "/downloads", .dir = "data/downloads" },
        .{ .url_prefix = "/files", .dir = "D:\\exports" },              // 绝对路径
        .{ .url_prefix = "/pkg", .dir = "data/pkg", .cache_control = "public, max-age=3600" },
    },
});
```

运行期追加同样可用：

```zig
try app.addStaticRoot("/downloads", "data/downloads");
try app.addStaticRootOptions(.{ .url_prefix = "/pkg", .dir = "data/pkg", .max_bytes = 8 * 1024 * 1024 * 1024 });
```

**每根可覆盖的选项**（`static_files.RootOptions`）：

| 字段 | 含义 | 默认 |
|---|---|---|
| `url_prefix` | URL 前缀（`""` = 站点根） | `""` |
| `dir` | 磁盘目录（相对项目目录或绝对路径） | 必填 |
| `max_bytes` | 该根允许发送的单文件上限 | 全局 `1 GB` |
| `stream_threshold` | 超过该大小改走**文件流式**；`0` = 全部流式 | 全局 `0` |
| `cache_control` | 该根的 `Cache-Control` | 全局 `no-cache` |
| `serve_unknown_types` | 该根是否允许**未知扩展名**（下载目录常用） | 全局 `false` |

全局调整：`app.statics.setMaxBytes(...)`、`app.statics.setStreamThreshold(...)`、`app.statics.setCacheControl(...)`。

**内存口径（默认全流式）**：磁盘静态文件默认**一律不进请求内存**——只开文件句柄，
每请求固定「8 KB 发送缓冲 + 32 KB 读缓冲」，与文件大小无关；
Linux（有 libc）优先走 `sendfile` **零拷贝**（内核直接 file→socket），`Unimplemented` 的平台（如 Windows）
回退为 32 KB 读-写循环。需要「小文件一次 read 搞定」时再把阈值调高（如 `64 * 1024`）：

```zig
app.statics.setStreamThreshold(64 * 1024);   // 64 KB 以下整读（换取更少 syscall）
```

**下载场景**：把备份包/安装包目录挂成 `/downloads` 不需要额外配置；上限与阈值可按根单独调。

**优先级**：嵌入资源 → 磁盘根（**最长 URL 前缀优先**，`""` 主根兜底）→ SPA 回退。
不同根之间互不可见（`/downloads` 根里的文件不能通过 `/a.txt` 访问）。

### 6.2 扩展名策略（对齐 ASP.NET Core）

磁盘静态文件**默认只下发 MIME 表已知的扩展名**（对齐 `StaticFileOptions.ServeUnknownFileTypes = false`）：
`.bak` / `.db` / 无扩展名这类“非常规文件”返回 404，避免任意文件被猜到 URL 直接下载。
嵌入资源不受此限（注册时已明确指定 `Content-Type`）。

三种放开方式：

```zig
// ① 只放开指定格式（等价 ASP.NET 自定义 ContentTypeProvider）
try app.statics.setMimeType("apk", "application/vnd.android.package-archive");

// ② 全站放开未知类型（按 octet-stream 下发）
app.statics.serveUnknownFileTypes(true);

// ③ 只让下载目录放开，主站仍严格
var app = try zzig.web.App.init(allocator, io, .{
    .wwwroot = "wwwroot",
    .static_roots = &.{
        .{ .url_prefix = "/downloads", .dir = "data/downloads", .serve_unknown_types = true },
    },
});
```

已知类型表含：`html/htm/css/js/mjs/json/map/txt/md/csv/xml`、`svg/png/jpg/jpeg/gif/webp/avif/ico`、
`woff/woff2/ttf/otf/eot`、`wasm/pdf/zip/mp3/wav/mp4/webm`、`webmanifest/manifest`。
其余扩展名走上面的放开口径；命中白名单失败时日志会打印具体路径与放开方式。

## 7. 与 `http/server.zig` 的桥接

`App.makeServer(server_options)` 返回底层 `Server`（需要自己控制 `run`/`stop` 时用）；
`App.run(host, port, options)` 直接阻塞运行。桥接函数 `App.serverHandler` 会把
`Response.headers`（`location` / `etag` / `allow` …）一并写回响应——为此 `server.Reply`
新增了 `headers` 字段（与 `content-type`/`connection` 重名时忽略业务侧的同名头）。
`Response.file`（大文件流式）也会转为 `server.Reply.file`，由服务端 `respondStreaming` 发送并关闭句柄。

处理中抛错时：日志打印 `方法 + 路径 + 错误名`，响应 `500` 且 `detail` 带错误名（可定位，不是笼统文案）。

## 8. 已知边界

- 不做多段路由参数之外的复杂约束（正则/可选段/默认值）；需要时在动作里自行校验；
- 静态文件不支持 `Range`（断点续传/分片下载）；大文件是整文件顺序流式发送；
- 不做 `multipart/form-data` 解析（文件上传）——这是下一批工作；
- 模板不支持 `@using`/`@inject`/`@functions`/`@switch`/LINQ/任意方法调用，子集外**报错不静默**；
- 控制器/区域需显式注册（Zig 无反射，不存在按程序集扫描）；
- 分区内容在页面渲染时**立即求值**（C# 是延迟到布局渲染时），因此分区里不要引用布局渲染期才有的变量。

## 9. 示例与验证

```powershell
# 单元测试（路由/控制器/视图/静态资源/装配）
zig build test --summary all

# 端到端示例（examples/web_mvc_example.zig + examples/web/**）
zig build web-demo
```

示例路由：`/home/index`、`/home/about`、`/api/ping`、`/admin/dashboard/index`、
`/app.css`、`/admin/admin.css`、`/user/42`（SPA 回退）。
