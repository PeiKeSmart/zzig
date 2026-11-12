//! 静态资源服务（默认约定 `wwwroot/`，对齐 ASP.NET Core `UseStaticFiles` + DH.RustBase `net::static_files`）。
//!
//! 口径：
//! - **多根**：`init("wwwroot")` 是主根；`addRoot("/admin", "Areas/Admin/wwwroot")` 支持区域各自的前端资源
//!   （对齐 ASP.NET Core Areas 的 `Areas/{Area}/wwwroot`），前缀匹配大小写不敏感，**最长前缀优先**；
//! - **默认文档**：路径为空或以 `/` 结尾时依次尝试 `default_documents`（默认 `index.html`）；
//! - **安全**：路径按 URL 解码后逐段校验，`..`/`.`/`\`/`:`/空段/NUL 一律拒绝（防目录穿越），
//!   拒绝返回 `null` 由上层决定 404；
//! - **条件请求**：磁盘文件用弱 ETag（长度+修改时间），嵌入资源用强 ETag（长度+内容哈希）；
//!   `If-None-Match` 命中返回 `304` 空体（刷新/重复打开零正文流量）；
//! - **嵌入资源**：`embed`/`embedMany` 显式注册（`include_bytes!`），与磁盘叠加且**优先命中**，
//!   用于单文件部署；默认**不**把 `wwwroot` 编进二进制；
//! - **SPA 回退**：`spaFallback(true)` 时，未命中的「无扩展名」前端路由回退 `index.html`，
//!   `spaExcludes(&.{"/api"})` 保证后端前缀仍是 JSON 404（对齐 `MapFallbackToFile`）；
//! - **不读进程级 io**：`io` 由构造参数传入，服务端多线程场景不会踩 `currentIo` 跨线程 panic。

const std = @import("std");
const fsio = @import("../file/fsio.zig");
const router = @import("router.zig");

/// 嵌入资源条目（编译期数据）。
pub const EmbeddedFile = struct {
    /// 相对路径（如 `/index.html` 或 `assets/app.js`）
    path: []const u8,
    /// 编译期数据（`include_bytes!`）
    data: []const u8,
    /// 响应 `Content-Type`
    content_type: []const u8,
};

const Embedded = struct {
    data: []const u8,
    content_type: []const u8,
    etag: []const u8,
};

const Root = struct {
    /// URL 前缀（已归一化：空串或 `/admin`）
    url_prefix: []const u8,
    /// 磁盘目录（支持相对路径与绝对路径，如 `D:\\downloads`）
    dir: []const u8,
    /// 单文件大小上限（覆盖全局；`null` = 用全局）
    max_bytes: ?usize = null,
    /// 超过此大小改为流式发送（覆盖全局；`null` = 用全局）
    stream_threshold: ?usize = null,
    /// 缓存头（覆盖全局；`null` = 用全局）
    cache_control: ?[]const u8 = null,
    /// 是否允许未知扩展名（覆盖全局；`null` = 用全局）
    serve_unknown_types: ?bool = null,
};

/// 静态根配置（供 `addRootOptions` / `App.Options.static_roots` 使用）。
pub const RootOptions = struct {
    /// URL 前缀（空串 = 网站根；`"/downloads"` = 该前缀下）
    url_prefix: []const u8 = "",
    /// 磁盘目录（相对项目目录或绝对路径均可）
    dir: []const u8,
    /// 单文件大小上限（字节；`null` = 全局默认）
    max_bytes: ?usize = null,
    /// 超过此大小改走文件流式（字节；`null` = 全局默认，默认 0 = 全部流式）
    stream_threshold: ?usize = null,
    /// 该根的 `Cache-Control`（`null` = 全局默认）
    cache_control: ?[]const u8 = null,
    /// 该根是否允许未知扩展名（`null` = 全局默认；下载目录可设 `true`）
    serve_unknown_types: ?bool = null,
};

/// 静态文件服务。
pub const StaticFiles = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    roots: std.ArrayList(Root) = .empty,
    embedded: std.StringHashMapUnmanaged(Embedded) = .empty,
    default_documents: []const []const u8 = &.{"index.html"},
    spa: bool = false,
    spa_excludes: std.ArrayList([]const u8) = .empty,
    cache_control: []const u8 = "no-cache",
    /// 单文件大小上限（默认 1 GB；超过直接不返回，避免误传超大文件）
    max_bytes: usize = 1024 * 1024 * 1024,
    /// 超过此大小改走文件流式发送（默认 0 = **所有磁盘文件都不整读进内存**）。
    ///
    /// 内存开销恒定为「8 KB 发送缓冲 + 32 KB 读缓冲」，与文件大小无关；
    /// Linux 上进一步走 `sendfile` 零拷贝，Windows 回退为 32 KB 读-写循环。
    /// 若更在意「小文件一次 read 而不是 open+read+write」，可把阈值调高（如 64 KB）。
    stream_threshold: usize = 0,
    /// 是否允许下发**未知扩展名**文件（默认 `false`，对齐 ASP.NET Core `ServeUnknownFileTypes`）。
    ///
    /// 默认只服务 MIME 表已知的类型；`.bak`/`.db`/无扩展名这类“非常规文件”返回 404，
    /// 需用 [`StaticFiles.setMimeType`] 只放开指定格式，或 [`StaticFiles.serveUnknownFileTypes`]
    /// 全放开（下载目录）。**嵌入资源不受此限制**（注册即明确指定了 Content-Type）。
    serve_unknown_types: bool = false,
    /// 扩展名 → `Content-Type` 覆盖表（键：小写、不含点）
    mime_overrides: std.StringHashMapUnmanaged([]const u8) = .empty,

    /// 以目录为根创建（默认约定 `wwwroot`）。
    pub fn init(allocator: std.mem.Allocator, io: std.Io, dir: []const u8) !StaticFiles {
        var files = StaticFiles{ .allocator = allocator, .io = io };
        try files.addRoot("", dir);
        return files;
    }

    /// 释放（URL 前缀/目录/每根缓存头/嵌入表/排除前缀都归本对象所有）。
    pub fn deinit(self: *StaticFiles) void {
        for (self.roots.items) |root| {
            self.allocator.free(root.url_prefix);
            self.allocator.free(root.dir);
            if (root.cache_control) |value| self.allocator.free(value);
        }
        self.roots.deinit(self.allocator);

        var it = self.embedded.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.etag);
        }
        self.embedded.deinit(self.allocator);

        for (self.spa_excludes.items) |prefix| self.allocator.free(prefix);
        self.spa_excludes.deinit(self.allocator);

        var overrides = self.mime_overrides.iterator();
        while (overrides.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.mime_overrides.deinit(self.allocator);
    }

    /// 追加磁盘根（`url_prefix` 为空或 `/admin` 形式）。
    pub fn addRoot(self: *StaticFiles, url_prefix: []const u8, dir: []const u8) !void {
        try self.addRootOptions(.{ .url_prefix = url_prefix, .dir = dir });
    }

    /// 追加磁盘根（带每根配置：大小上限 / 流式阈值 / 缓存头）。
    pub fn addRootOptions(self: *StaticFiles, options: RootOptions) !void {
        const url_prefix = try normalizePrefix(self.allocator, options.url_prefix);
        errdefer self.allocator.free(url_prefix);

        const dir = try self.allocator.dupe(u8, std.mem.trimEnd(u8, options.dir, "/\\"));
        errdefer self.allocator.free(dir);

        const cache_control = if (options.cache_control) |value| try self.allocator.dupe(u8, value) else null;
        errdefer if (cache_control) |value| self.allocator.free(value);

        try self.roots.append(self.allocator, .{
            .url_prefix = url_prefix,
            .dir = dir,
            .max_bytes = options.max_bytes,
            .stream_threshold = options.stream_threshold,
            .cache_control = cache_control,
            .serve_unknown_types = options.serve_unknown_types,
        });
    }

    /// 已注册磁盘根数量。
    pub fn rootsCount(self: *const StaticFiles) usize {
        return self.roots.items.len;
    }

    /// 第 `index` 个根的 URL 前缀与目录（诊断/自检用）。
    pub fn rootAt(self: *const StaticFiles, index: usize) ?struct { url_prefix: []const u8, dir: []const u8 } {
        if (index >= self.roots.items.len) return null;
        const root = self.roots.items[index];
        return .{ .url_prefix = root.url_prefix, .dir = root.dir };
    }

    /// 设置默认文档（默认 `index.html`）。
    pub fn setDefaultDocuments(self: *StaticFiles, documents: []const []const u8) void {
        self.default_documents = documents;
    }

    /// 设置 `Cache-Control`（默认 `no-cache`；带哈希指纹的产物可设 `public, max-age=31536000, immutable`）。
    pub fn setCacheControl(self: *StaticFiles, value: []const u8) void {
        self.cache_control = value;
    }

    /// 设置单文件大小上限（默认 1 GB）。
    pub fn setMaxBytes(self: *StaticFiles, value: usize) void {
        self.max_bytes = value;
    }

    /// 设置文件流式阈值（默认 0 = 所有磁盘文件都走流式，内存恒定）。
    ///
    /// 调高它可让小于阈值的文件一次读完（更少 syscall），代价是每请求占用与文件同等大小的内存。
    pub fn setStreamThreshold(self: *StaticFiles, value: usize) void {
        self.stream_threshold = value;
    }

    /// 设置是否允许下发**未知扩展名**文件（默认 `false`）。
    ///
    /// 对齐 ASP.NET Core `StaticFileOptions.ServeUnknownFileTypes = false`：
    /// 默认只服务 MIME 表已知的类型；`.bak`/`.db`/无扩展名这类“非常规文件”返回 404。
    /// 只放开指定格式请用 [`StaticFiles.setMimeType`]；下载目录需全放开时用本方法。
    pub fn serveUnknownFileTypes(self: *StaticFiles, enable: bool) void {
        self.serve_unknown_types = enable;
    }

    /// 注册/覆盖扩展名的 `Content-Type`（`ext` 可带点、大小写不敏感）。
    ///
    /// 这是“只放开非常规格式”的入口（等价 ASP.NET 自定义 `ContentTypeProvider`）：
    /// ```zig
    /// try app.statics.setMimeType("apk", "application/vnd.android.package-archive");
    /// ```
    pub fn setMimeType(self: *StaticFiles, ext: []const u8, content_type: []const u8) !void {
        const raw = std.mem.trimStart(u8, ext, ".");
        if (raw.len == 0) return error.InvalidExtension;

        const key = try self.allocator.alloc(u8, raw.len);
        errdefer self.allocator.free(key);
        for (raw, 0..) |c, index| key[index] = std.ascii.toLower(c);

        const value = try self.allocator.dupe(u8, content_type);
        errdefer self.allocator.free(value);

        if (self.mime_overrides.fetchRemove(key)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value);
        }
        try self.mime_overrides.put(self.allocator, key, value);
    }

    /// 扩展名 → `Content-Type`（覆盖表 → 已知表 → 是否放开未知）。
    ///
    /// 未知且未放开时返回 `null`（调用方按“不服务”处理，即 404）。
    fn contentTypeFor(self: *const StaticFiles, root: Root, relative: []const u8) ?[]const u8 {
        var buffer: [32]u8 = undefined;
        const ext = extensionOf(relative, &buffer) orelse "";
        if (ext.len > 0) {
            if (self.mime_overrides.get(ext)) |content_type| return content_type;
        }
        if (knownMime(ext)) |content_type| return content_type;
        if (root.serve_unknown_types orelse self.serve_unknown_types) {
            return "application/octet-stream";
        }
        return null;
    }

    /// 启用 SPA 深链接回退（`MapFallbackToFile("index.html")` 等价）。
    pub fn spaFallback(self: *StaticFiles, enable: bool) void {
        self.spa = enable;
    }

    /// 追加 SPA 排除前缀（如 `/api`；前缀内未命中保持 404 而不是回退页面）。
    pub fn spaExcludes(self: *StaticFiles, prefixes: []const []const u8) !void {
        for (prefixes) |prefix| {
            try self.spa_excludes.append(self.allocator, try normalizePrefix(self.allocator, prefix));
        }
    }

    /// 注册单个嵌入资源（与磁盘叠加，**优先命中**）。
    pub fn embed(self: *StaticFiles, path: []const u8, data: []const u8, content_type: []const u8) !void {
        const key = try normalizeEmbeddedKey(self.allocator, path);
        errdefer self.allocator.free(key);

        const etag = try std.fmt.allocPrint(self.allocator, "\"{x}-{x}\"", .{ data.len, fnv1a64(data) });
        errdefer self.allocator.free(etag);

        if (self.embedded.fetchRemove(key)) |old| {
            self.allocator.free(old.key);
            self.allocator.free(old.value.etag);
        }
        try self.embedded.put(self.allocator, key, .{
            .data = data,
            .content_type = content_type,
            .etag = etag,
        });
    }

    /// 批量注册嵌入资源（`build.zig`/`build.rs` 生成的资源表直接传入）。
    pub fn embedMany(self: *StaticFiles, files: []const EmbeddedFile) !void {
        for (files) |file| try self.embed(file.path, file.data, file.content_type);
    }

    /// 已注册嵌入资源数量（`0` = 纯磁盘模式）。
    pub fn embeddedCount(self: *const StaticFiles) usize {
        return self.embedded.count();
    }

    /// 按请求提供静态资源（方法不是 GET/HEAD、或未命中返回 `null`）。
    pub fn serveRequest(
        self: *const StaticFiles,
        arena: std.mem.Allocator,
        req: router.Request,
    ) !?router.Response {
        if (!std.ascii.eqlIgnoreCase(req.method, "GET") and !std.ascii.eqlIgnoreCase(req.method, "HEAD")) {
            return null;
        }
        const response = try self.serve(arena, req.path, req.header("if-none-match"));
        if (response) |resp| {
            if (std.ascii.eqlIgnoreCase(req.method, "HEAD")) {
                return .{
                    .status = resp.status,
                    .content_type = resp.content_type,
                    .body = "",
                    .headers = resp.headers,
                    .file = resp.file,
                    // HEAD 不发正文，但长度要准（下载器/代理会读它）
                    .content_length = if (resp.file) |file| file.length else resp.body.len,
                };
            }
        }
        return response;
    }

    /// 按路径提供静态资源（未命中返回 `null`）。
    pub fn serve(
        self: *const StaticFiles,
        arena: std.mem.Allocator,
        raw_path: []const u8,
        if_none_match: ?[]const u8,
    ) !?router.Response {
        const decoded = try router.percentDecode(arena, if (raw_path.len == 0) "/" else raw_path, false);
        if (!isSafePath(decoded)) return null;

        if (try self.serveEmbedded(arena, decoded, if_none_match)) |response| return response;
        if (try self.serveDisk(arena, decoded, if_none_match)) |response| return response;

        if (self.spa and isSpaCandidate(decoded) and !self.isSpaExcluded(decoded)) {
            if (try self.serveEmbedded(arena, "/", if_none_match)) |response| return response;
            if (try self.serveDisk(arena, "/", if_none_match)) |response| return response;
        }
        return null;
    }

    fn isSpaExcluded(self: *const StaticFiles, path: []const u8) bool {
        for (self.spa_excludes.items) |prefix| {
            if (prefix.len == 0) return true;
            if (std.ascii.startsWithIgnoreCase(path, prefix)) {
                if (path.len == prefix.len) return true;
                const next = path[prefix.len];
                if (next == '/' or next == '?') return true;
            }
        }
        return false;
    }

    fn serveEmbedded(
        self: *const StaticFiles,
        arena: std.mem.Allocator,
        path: []const u8,
        if_none_match: ?[]const u8,
    ) !?router.Response {
        if (self.embedded.count() == 0) return null;

        const key = std.mem.trim(u8, path, "/");
        if (try self.embeddedResponse(arena, key, if_none_match)) |response| return response;

        // 目录请求：逐个默认文档
        if (path.len == 0 or path[path.len - 1] == '/') {
            for (self.default_documents) |doc| {
                const full = if (key.len == 0)
                    try arena.dupe(u8, doc)
                else
                    try std.fmt.allocPrint(arena, "{s}/{s}", .{ key, doc });
                if (try self.embeddedResponse(arena, full, if_none_match)) |response| return response;
            }
        }
        return null;
    }

    fn embeddedResponse(
        self: *const StaticFiles,
        arena: std.mem.Allocator,
        key: []const u8,
        if_none_match: ?[]const u8,
    ) !?router.Response {
        const asset = self.embedded.get(key) orelse return null;
        if (etagMatches(if_none_match, asset.etag)) {
            return try buildResponse(arena, .not_modified, asset.content_type, "", asset.etag, self.cache_control);
        }
        return try buildResponse(arena, .ok, asset.content_type, asset.data, asset.etag, self.cache_control);
    }

    fn serveDisk(
        self: *const StaticFiles,
        arena: std.mem.Allocator,
        path: []const u8,
        if_none_match: ?[]const u8,
    ) !?router.Response {
        // 最长前缀优先：根 "" 永远匹配，其余按前缀长度从长到短尝试
        var best: ?Root = null;
        for (self.roots.items) |root| {
            if (!prefixMatches(root.url_prefix, path)) continue;
            if (best == null or root.url_prefix.len > best.?.url_prefix.len) best = root;
        }
        const root = best orelse return null;

        const rel = std.mem.trimStart(u8, path[root.url_prefix.len..], "/");
        if (rel.len > 0) {
            if (try self.diskResponse(arena, root, rel, if_none_match)) |response| return response;
        }

        if (rel.len == 0 or path[path.len - 1] == '/') {
            for (self.default_documents) |doc| {
                const full = if (rel.len == 0)
                    try arena.dupe(u8, doc)
                else
                    try std.fmt.allocPrint(arena, "{s}/{s}", .{ rel, doc });
                if (try self.diskResponse(arena, root, full, if_none_match)) |response| return response;
            }
        }
        return null;
    }

    fn diskResponse(
        self: *const StaticFiles,
        arena: std.mem.Allocator,
        root: Root,
        rel: []const u8,
        if_none_match: ?[]const u8,
    ) !?router.Response {
        if (!isSafePath(rel)) return null;

        const full = try std.fmt.allocPrint(arena, "{s}/{s}", .{ root.dir, rel });
        const stat = fsio.statFile(self.io, full) catch |e| {
            if (e != error.FileNotFound) {
                std.debug.print("[zzig.static] 读取文件信息失败：{s}（{s}）\n", .{ full, @errorName(e) });
            }
            return null;
        };
        if (stat.kind != .file) return null;

        const max_bytes = root.max_bytes orelse self.max_bytes;
        if (stat.size > max_bytes) {
            std.debug.print(
                "[zzig.static] 文件超过上限，未发送：{s}（{d} 字节 > {d} 字节；可调 setMaxBytes 或根级 max_bytes）\n",
                .{ full, stat.size, max_bytes },
            );
            return null;
        }

        const cache_control = root.cache_control orelse self.cache_control;
        const etag = try std.fmt.allocPrint(arena, "W/\"{x}-{x}\"", .{ stat.size, stat.mtime.toMilliseconds() });
        // 扩展名不在白名单：不下发（对齐 ASP.NET Core 默认行为）
        const content_type = self.contentTypeFor(root, rel) orelse {
            std.debug.print(
                "[zzig.static] 扩展名不在服务白名单，未下发：{s}（可用 setMimeType 或 serveUnknownFileTypes(true) 放开）\n",
                .{full},
            );
            return null;
        };
        if (etagMatches(if_none_match, etag)) {
            return try buildResponse(arena, .not_modified, content_type, "", etag, cache_control);
        }

        // 大文件流式发送（不整读进内存）；小文件仍然一次读完（少一次打开/循环）
        const threshold = root.stream_threshold orelse self.stream_threshold;
        if (stat.size > threshold) {
            const file = fsio.cwd().openFile(self.io, full, .{}) catch |e| {
                std.debug.print("[zzig.static] 打开文件失败：{s}（{s}）\n", .{ full, @errorName(e) });
                return null;
            };
            const headers = try buildStaticHeaders(arena, etag, cache_control);
            return .{
                .status = .ok,
                .content_type = content_type,
                .body = "",
                .headers = headers,
                .file = .{ .file = file, .length = stat.size },
            };
        }

        const body = fsio.readFileAlloc(self.io, arena, full, max_bytes) catch |e| {
            std.debug.print("[zzig.static] 读取文件失败：{s}（{s}）\n", .{ full, @errorName(e) });
            return null;
        };
        return try buildResponse(arena, .ok, content_type, body, etag, cache_control);
    }

    /// 按扩展名推断 `Content-Type`（未知按 `application/octet-stream`）。
    ///
    /// 注意：这是**纯查询**（总是返回值）；磁盘下发是否允许未知扩展名由
    /// [`StaticFiles.serveUnknownFileTypes`] / [`StaticFiles.setMimeType`] 决定。
    pub fn mimeType(path: []const u8) []const u8 {
        const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return "application/octet-stream";
        return knownMime(path[dot + 1 ..]) orelse "application/octet-stream";
    }

    /// 已知扩展名 → `Content-Type`（未知返回 `null`；大小写不敏感）。
    fn knownMime(ext: []const u8) ?[]const u8 {
        const table = .{
            .{ "html", "text/html; charset=utf-8" },
            .{ "htm", "text/html; charset=utf-8" },
            .{ "css", "text/css; charset=utf-8" },
            .{ "js", "text/javascript; charset=utf-8" },
            .{ "mjs", "text/javascript; charset=utf-8" },
            .{ "json", "application/json; charset=utf-8" },
            .{ "map", "application/json; charset=utf-8" },
            .{ "txt", "text/plain; charset=utf-8" },
            .{ "md", "text/markdown; charset=utf-8" },
            .{ "xml", "application/xml; charset=utf-8" },
            .{ "csv", "text/csv; charset=utf-8" },
            .{ "svg", "image/svg+xml" },
            .{ "png", "image/png" },
            .{ "jpg", "image/jpeg" },
            .{ "jpeg", "image/jpeg" },
            .{ "gif", "image/gif" },
            .{ "webp", "image/webp" },
            .{ "avif", "image/avif" },
            .{ "ico", "image/x-icon" },
            .{ "woff", "font/woff" },
            .{ "woff2", "font/woff2" },
            .{ "ttf", "font/ttf" },
            .{ "otf", "font/otf" },
            .{ "eot", "application/vnd.ms-fontobject" },
            .{ "wasm", "application/wasm" },
            .{ "pdf", "application/pdf" },
            .{ "zip", "application/zip" },
            .{ "mp3", "audio/mpeg" },
            .{ "wav", "audio/wav" },
            .{ "mp4", "video/mp4" },
            .{ "webm", "video/webm" },
            .{ "webmanifest", "application/manifest+json" },
            .{ "manifest", "application/manifest+json" },
        };
        inline for (table) |entry| {
            if (std.ascii.eqlIgnoreCase(ext, entry[0])) return entry[1];
        }
        return null;
    }
};

fn normalizePrefix(allocator: std.mem.Allocator, prefix: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, prefix, "/");
    if (trimmed.len == 0) return allocator.dupe(u8, "");
    return std.fmt.allocPrint(allocator, "/{s}", .{trimmed});
}

/// 取扩展名并小写化到 `buffer`（无扩展名或超长时返回 `null` = 未知）。
fn extensionOf(path: []const u8, buffer: []u8) ?[]const u8 {
    const dot = std.mem.lastIndexOfScalar(u8, path, '.') orelse return null;
    const raw = path[dot + 1 ..];
    if (raw.len == 0 or raw.len > buffer.len) return null;
    for (raw, 0..) |c, index| buffer[index] = std.ascii.toLower(c);
    return buffer[0..raw.len];
}

fn normalizeEmbeddedKey(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    return allocator.dupe(u8, std.mem.trim(u8, path, "/"));
}

fn prefixMatches(url_prefix: []const u8, path: []const u8) bool {
    if (url_prefix.len == 0) return true;
    if (!std.ascii.startsWithIgnoreCase(path, url_prefix)) return false;
    if (path.len == url_prefix.len) return true;
    return path[url_prefix.len] == '/';
}

fn isSafePath(path: []const u8) bool {
    var trimmed = path;
    while (trimmed.len > 0 and trimmed[0] == '/') trimmed = trimmed[1..];
    while (trimmed.len > 0 and trimmed[trimmed.len - 1] == '/') trimmed = trimmed[0 .. trimmed.len - 1];
    if (trimmed.len == 0) return true;

    var iter = std.mem.splitScalar(u8, trimmed, '/');
    while (iter.next()) |segment| {
        if (segment.len == 0) return false;
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
        for (segment) |c| {
            if (c == '\\' or c == ':' or c == 0) return false;
            if (c < 0x20) return false;
        }
    }
    return true;
}

fn isSpaCandidate(path: []const u8) bool {
    // 有扩展名的按“静态文件缺失”处理（不回退 index.html，避免 JS/CSS 404 变成 HTML）
    const last = std.mem.lastIndexOfScalar(u8, path, '/') orelse 0;
    return std.mem.indexOfScalar(u8, path[last..], '.') == null;
}

fn etagMatches(if_none_match: ?[]const u8, etag: []const u8) bool {
    const header = if_none_match orelse return false;
    if (std.mem.eql(u8, std.mem.trim(u8, header, " \t"), "*")) return true;
    var iter = std.mem.splitScalar(u8, header, ',');
    while (iter.next()) |item| {
        if (std.mem.eql(u8, std.mem.trim(u8, item, " \t"), etag)) return true;
    }
    return false;
}

fn buildResponse(
    arena: std.mem.Allocator,
    status: std.http.Status,
    content_type: []const u8,
    body: []const u8,
    etag: []const u8,
    cache_control: []const u8,
) !router.Response {
    return .{
        .status = status,
        .content_type = content_type,
        .body = body,
        .headers = try buildStaticHeaders(arena, etag, cache_control),
    };
}

/// 静态资源统一响应头（`ETag` + `Cache-Control`）。
fn buildStaticHeaders(
    arena: std.mem.Allocator,
    etag: []const u8,
    cache_control: []const u8,
) ![]const std.http.Header {
    const headers = try arena.alloc(std.http.Header, 2);
    headers[0] = .{ .name = "etag", .value = etag };
    headers[1] = .{ .name = "cache-control", .value = cache_control };
    return headers;
}

fn fnv1a64(data: []const u8) u64 {
    var hash: u64 = 0xcbf29ce484222325;
    for (data) |byte| {
        hash ^= byte;
        hash *%= 0x100000001b3;
    }
    return hash;
}

const testing = std.testing;
const compat = @import("../compat.zig");

/// 取响应正文（磁盘文件现在是文件流，需要从句柄读出来校对）。
fn responseBody(io: std.Io, arena: std.mem.Allocator, response: router.Response) ![]const u8 {
    const file_body = response.file orelse return response.body;
    defer file_body.file.close(io);

    const size: usize = @intCast(file_body.length);
    const out = try arena.alloc(u8, size);
    var buffer: [4096]u8 = undefined;
    var reader = file_body.file.reader(io, &buffer);
    var got: usize = 0;
    while (got < size) {
        const n = try reader.interface.readSliceShort(out[got..]);
        if (n == 0) break;
        got += n;
    }
    return out[0..got];
}

test "static：未知扩展名默认拒绝（可按格式/按根放开）" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = compat.currentIo();

    const site_dir = try makeTempDir("static-ext-site");
    defer {
        std.Io.Dir.cwd().deleteTree(io, site_dir) catch {};
        testing.allocator.free(site_dir);
    }
    const dl_dir = try makeTempDir("static-ext-dl");
    defer {
        std.Io.Dir.cwd().deleteTree(io, dl_dir) catch {};
        testing.allocator.free(dl_dir);
    }

    try fsio.writeFile(io, try std.fmt.allocPrint(arena, "{s}/app.js", .{site_dir}), "js");
    try fsio.writeFile(io, try std.fmt.allocPrint(arena, "{s}/data.bak", .{site_dir}), "secret");
    try fsio.writeFile(io, try std.fmt.allocPrint(arena, "{s}/README", .{site_dir}), "no-ext");
    try fsio.writeFile(io, try std.fmt.allocPrint(arena, "{s}/data.bak", .{dl_dir}), "download-backup");
    try fsio.writeFile(io, try std.fmt.allocPrint(arena, "{s}/pkg.7z", .{dl_dir}), "archive-7z");

    var files = try StaticFiles.init(testing.allocator, io, site_dir);
    defer files.deinit();

    // 已知类型正常；未知 / 无扩展名默认 404
    try testing.expect((try files.serve(arena, "/app.js", null)) != null);
    try testing.expect((try files.serve(arena, "/data.bak", null)) == null);
    try testing.expect((try files.serve(arena, "/README", null)) == null);

    // 只放开指定格式（等价 ASP.NET 自定义 ContentTypeProvider）
    try files.setMimeType("bak", "application/x-test-backup");
    const mapped = (try files.serve(arena, "/data.bak", null)).?;
    try testing.expectEqualStrings("application/x-test-backup", mapped.content_type);
    try testing.expectEqualStrings("secret", try responseBody(io, arena, mapped));

    // 全部放开：未知扩展名按 octet-stream 下发
    files.serveUnknownFileTypes(true);
    const open = (try files.serve(arena, "/README", null)).?;
    try testing.expectEqualStrings("application/octet-stream", open.content_type);
    files.serveUnknownFileTypes(false);

    // 按根放开：下载目录允许未知类型，主站仍严格
    try files.addRootOptions(.{ .url_prefix = "/downloads", .dir = dl_dir, .serve_unknown_types = true });
    const archive = (try files.serve(arena, "/downloads/pkg.7z", null)).?;
    try testing.expectEqualStrings("archive-7z", try responseBody(io, arena, archive));
    // 同一个未知扩展名在主站根上仍然被拒
    try testing.expect((try files.serve(arena, "/README", null)) == null);
}

fn makeTempDir(name: []const u8) ![]const u8 {
    const io = compat.currentIo();
    const path = try std.fmt.allocPrint(testing.allocator, ".zig-cache/tmp/{s}-{d}", .{ name, compat.nanoTimestamp() });
    try fsio.makePath(io, path);
    return path;
}

test "static：MIME 推断" {
    try testing.expectEqualStrings("text/html; charset=utf-8", StaticFiles.mimeType("/a/index.html"));
    try testing.expectEqualStrings("text/javascript; charset=utf-8", StaticFiles.mimeType("app.js"));
    try testing.expectEqualStrings("image/svg+xml", StaticFiles.mimeType("logo.svg"));
    try testing.expectEqualStrings("application/octet-stream", StaticFiles.mimeType("blob"));
}

test "static：目录根 + index.html + ETag 304" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = compat.currentIo();

    const dir = try makeTempDir("static");
    defer {
        std.Io.Dir.cwd().deleteTree(io, dir) catch {};
        testing.allocator.free(dir);
    }
    try fsio.writeFile(io, try std.fmt.allocPrint(arena, "{s}/index.html", .{dir}), "<h1>home</h1>");
    try fsio.writeFile(io, try std.fmt.allocPrint(arena, "{s}/app.css", .{dir}), "body{}");

    var files = try StaticFiles.init(testing.allocator, io, dir);
    defer files.deinit();

    const home = (try files.serve(arena, "/", null)).?;
    try testing.expectEqual(std.http.Status.ok, home.status);
    try testing.expectEqualStrings("<h1>home</h1>", try responseBody(io, arena, home));
    try testing.expectEqualStrings("text/html; charset=utf-8", home.content_type);

    const css = (try files.serve(arena, "/app.css", null)).?;
    try testing.expectEqualStrings("body{}", try responseBody(io, arena, css));

    // ETag 命中 → 304 空体
    var etag: []const u8 = "";
    for (css.headers) |h| {
        if (std.mem.eql(u8, h.name, "etag")) etag = h.value;
    }
    try testing.expect(etag.len > 0);
    const cached = (try files.serve(arena, "/app.css", etag)).?;
    try testing.expectEqual(std.http.Status.not_modified, cached.status);
    try testing.expectEqualStrings("", cached.body);
}

test "static：目录穿越被拒绝" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = compat.currentIo();

    const dir = try makeTempDir("static-safe");
    defer {
        std.Io.Dir.cwd().deleteTree(io, dir) catch {};
        testing.allocator.free(dir);
    }

    var files = try StaticFiles.init(testing.allocator, io, dir);
    defer files.deinit();

    try testing.expect((try files.serve(arena, "/../secret.txt", null)) == null);
    try testing.expect((try files.serve(arena, "/%2e%2e/secret.txt", null)) == null);
    try testing.expect((try files.serve(arena, "/a%5c..%5cb.txt", null)) == null);
}

test "static：嵌入资源优先 + 区域前缀根" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = compat.currentIo();

    var files = try StaticFiles.init(testing.allocator, io, "not-exists-wwwroot");
    defer files.deinit();
    try files.embed("/index.html", "<embedded/>", "text/html; charset=utf-8");
    try files.addRoot("/admin", "not-exists-area-wwwroot");
    try files.embed("/admin/index.html", "<admin/>", "text/html; charset=utf-8");

    const home = (try files.serve(arena, "/index.html", null)).?;
    try testing.expectEqualStrings("<embedded/>", home.body);

    const admin = (try files.serve(arena, "/admin/", null)).?;
    try testing.expectEqualStrings("<admin/>", admin.body);
}

test "static：SPA 回退与排除前缀" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = compat.currentIo();

    var files = try StaticFiles.init(testing.allocator, io, "not-exists-wwwroot");
    defer files.deinit();
    try files.embed("/index.html", "<spa/>", "text/html; charset=utf-8");
    files.spaFallback(true);
    try files.spaExcludes(&.{"/api"});

    const deep = (try files.serve(arena, "/user/42", null)).?;
    try testing.expectEqualStrings("<spa/>", deep.body);

    try testing.expect((try files.serve(arena, "/api/orders", null)) == null);
    try testing.expect((try files.serve(arena, "/app.js", null)) == null);
}

test "static：额外静态根（前缀隔离 + 最长前缀优先）" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = compat.currentIo();

    const site_dir = try makeTempDir("static-site");
    defer {
        std.Io.Dir.cwd().deleteTree(io, site_dir) catch {};
        testing.allocator.free(site_dir);
    }
    const dl_dir = try makeTempDir("static-downloads");
    defer {
        std.Io.Dir.cwd().deleteTree(io, dl_dir) catch {};
        testing.allocator.free(dl_dir);
    }
    const dl_admin_dir = try makeTempDir("static-downloads-admin");
    defer {
        std.Io.Dir.cwd().deleteTree(io, dl_admin_dir) catch {};
        testing.allocator.free(dl_admin_dir);
    }

    try fsio.writeFile(io, try std.fmt.allocPrint(arena, "{s}/app.js", .{site_dir}), "site-app");
    try fsio.writeFile(io, try std.fmt.allocPrint(arena, "{s}/a.txt", .{dl_dir}), "download-a");
    try fsio.writeFile(io, try std.fmt.allocPrint(arena, "{s}/a.txt", .{dl_admin_dir}), "admin-a");

    var files = try StaticFiles.init(testing.allocator, io, site_dir);
    defer files.deinit();
    try files.addRoot("/downloads", dl_dir);
    try files.addRoot("/downloads/admin", dl_admin_dir);

    const site = (try files.serve(arena, "/app.js", null)).?;
    try testing.expectEqualStrings("site-app", try responseBody(io, arena, site));

    const download = (try files.serve(arena, "/downloads/a.txt", null)).?;
    try testing.expectEqualStrings("download-a", try responseBody(io, arena, download));

    // 最长前缀优先
    const admin = (try files.serve(arena, "/downloads/admin/a.txt", null)).?;
    try testing.expectEqualStrings("admin-a", try responseBody(io, arena, admin));

    // 根目录不能越前缀取到下载目录的文件
    try testing.expect((try files.serve(arena, "/a.txt", null)) == null);
}

test "static：根级 max_bytes 与 Cache-Control 覆盖" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = compat.currentIo();

    const dir = try makeTempDir("static-root-opts");
    defer {
        std.Io.Dir.cwd().deleteTree(io, dir) catch {};
        testing.allocator.free(dir);
    }
    try fsio.writeFile(io, try std.fmt.allocPrint(arena, "{s}/big.zip", .{dir}), "0123456789");

    var files = try StaticFiles.init(testing.allocator, io, "not-exists-wwwroot");
    defer files.deinit();
    try files.addRootOptions(.{
        .url_prefix = "/dl",
        .dir = dir,
        .max_bytes = 4,
        .cache_control = "public, max-age=60",
    });

    // 超过根级上限：不返回
    try testing.expect((try files.serve(arena, "/dl/big.zip", null)) == null);

    try files.addRootOptions(.{
        .url_prefix = "/dl2",
        .dir = dir,
        .cache_control = "public, max-age=60",
    });
    const ok = (try files.serve(arena, "/dl2/big.zip", null)).?;
    try testing.expectEqualStrings("0123456789", try responseBody(io, arena, ok));

    var cache: ?[]const u8 = null;
    for (ok.headers) |header| {
        if (std.mem.eql(u8, header.name, "cache-control")) cache = header.value;
    }
    try testing.expectEqualStrings("public, max-age=60", cache.?);
}

test "static：大文件走流式（不整读进内存）" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const io = compat.currentIo();

    const dir = try makeTempDir("static-stream");
    defer {
        std.Io.Dir.cwd().deleteTree(io, dir) catch {};
        testing.allocator.free(dir);
    }
    try fsio.writeFile(io, try std.fmt.allocPrint(arena, "{s}/pkg.zip", .{dir}), "0123456789");

    var files = try StaticFiles.init(testing.allocator, io, dir);
    defer files.deinit();
    files.setStreamThreshold(1);

    const response = (try files.serve(arena, "/pkg.zip", null)).?;
    try testing.expect(response.file != null);
    try testing.expectEqualStrings("", response.body);
    try testing.expectEqual(@as(u64, 10), response.file.?.length);
    response.file.?.file.close(io);
}
