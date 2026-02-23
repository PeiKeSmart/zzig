// dom.zig
// XML DOM（文档对象模型）
// 将 XML 文档解析为内存中的树形结构，支持遍历、查询和序列化
// 所有资源由 arena allocator 统一管理，释放时整体销毁
const std = @import("std");
const Allocator = std.mem.Allocator;

const reader_mod = @import("reader.zig");
pub const ReadError = reader_mod.ReadError;

const writer_mod = @import("writer.zig");
pub const WriteError = writer_mod.WriteError;

/// DOM 节点类型
pub const NodeKind = enum {
    element,
    text,
    cdata,
    comment,
    pi,
};

/// 属性键值对
pub const Attribute = struct {
    name: []const u8,
    value: []const u8,
};

/// DOM 节点（tagged union）
pub const Node = union(NodeKind) {
    element: *Element,
    text: []const u8,
    cdata: []const u8,
    comment: []const u8,
    pi: struct {
        target: []const u8,
        data: []const u8,
    },

    /// 若本节点是元素，返回指针；否则返回 null
    pub fn asElement(self: Node) ?*Element {
        return switch (self) {
            .element => |e| e,
            else => null,
        };
    }

    /// 若本节点是文本（含 CDATA），返回文本切片；否则返回 null
    pub fn asText(self: Node) ?[]const u8 {
        return switch (self) {
            .text => |t| t,
            .cdata => |c| c,
            else => null,
        };
    }
};

/// DOM 元素节点
pub const Element = struct {
    /// 元素名称
    name: []const u8,

    /// 属性列表（按文档顺序）
    attributes: []Attribute,

    /// 子节点列表（按文档顺序）
    children: []Node,

    /// 按名称查找属性值
    pub fn attr(self: *const Element, attr_name: []const u8) ?[]const u8 {
        for (self.attributes) |a| {
            if (std.mem.eql(u8, a.name, attr_name)) return a.value;
        }
        return null;
    }

    /// 返回第一个匹配名称的子元素，或 null
    pub fn child(self: *const Element, child_name: []const u8) ?*Element {
        for (self.children) |c| {
            if (c.asElement()) |e| {
                if (std.mem.eql(u8, e.name, child_name)) return e;
            }
        }
        return null;
    }

    /// 返回所有匹配名称的子元素列表（调用者负责释放 slice）
    pub fn childrenNamed(
        self: *const Element,
        child_name: []const u8,
        gpa: Allocator,
    ) Allocator.Error![]const *Element {
        var result: std.ArrayList(*Element) = .{};
        defer result.deinit(gpa);
        for (self.children) |c| {
            if (c.asElement()) |e| {
                if (std.mem.eql(u8, e.name, child_name)) {
                    try result.append(gpa, e);
                }
            }
        }
        return result.toOwnedSlice(gpa);
    }

    /// 返回所有子文本内容拼接（不递归，只看直接文本子节点）
    pub fn innerText(self: *const Element, gpa: Allocator) Allocator.Error![]u8 {
        var buf: std.ArrayList(u8) = .{};
        defer buf.deinit(gpa);
        for (self.children) |c| {
            if (c.asText()) |t| try buf.appendSlice(gpa, t);
        }
        return buf.toOwnedSlice(gpa);
    }

    /// 递归收集所有文本内容
    pub fn innerTextDeep(self: *const Element, gpa: Allocator) Allocator.Error![]u8 {
        var buf: std.ArrayList(u8) = .{};
        defer buf.deinit(gpa);
        try collectText(self, gpa, &buf);
        return buf.toOwnedSlice(gpa);
    }

    fn collectText(elem: *const Element, gpa: Allocator, buf: *std.ArrayList(u8)) Allocator.Error!void {
        for (elem.children) |c| {
            switch (c) {
                .text => |t| try buf.appendSlice(gpa, t),
                .cdata => |t| try buf.appendSlice(gpa, t),
                .element => |e| try collectText(e, gpa, buf),
                else => {},
            }
        }
    }
};

/// XML DOM 文档
pub const Document = struct {
    /// 内存池（所有节点均从此分配）
    arena: std.heap.ArenaAllocator,

    /// XML 声明信息（若存在）
    version: ?[]const u8,
    encoding: ?[]const u8,
    standalone: ?bool,

    /// 文档根元素
    root: *Element,

    /// 销毁文档，释放所有内存
    pub fn deinit(self: *Document) void {
        self.arena.deinit();
    }

    /// 将文档序列化为 XML 字符串（调用者负责释放）
    pub fn toStringAlloc(self: *const Document, gpa: Allocator, options: writer_mod.Options) WriteError![]u8 {
        var buf: std.ArrayList(u8) = .{};
        errdefer buf.deinit(gpa);

        var w = writer_mod.Writer(std.io.AnyWriter).init(
            gpa,
            buf.writer(gpa).any(),
            options,
        );
        defer w.deinit();

        // XML 声明
        if (self.version != null) {
            try w.xmlDeclaration(self.encoding, self.standalone);
        }

        // 根元素
        try serializeElementImpl(&w, self.root);
        try w.eof();

        return buf.toOwnedSlice(gpa);
    }

    /// 将文档写入文件
    pub fn writeToFile(self: *const Document, gpa: Allocator, path: []const u8, options: writer_mod.Options) !void {
        // 先序列化到内存，再整块写入文件（与项目其他模块保持一致）
        const output = try self.toStringAlloc(gpa, options);
        defer gpa.free(output);
        const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(output);
    }
};

/// 递归序列化元素到 Writer
fn serializeElement(
    comptime W: type,
    w: *W,
    elem: *const Element,
) WriteError!void {
    _ = w;
    _ = elem;
    // 由于 Zig comptime 限制，此函数需要在调用处特化
    // 实际通过 Document.toStringAlloc 和 writeToFile 的拼写变体处理
    // 这里仅用于文档用途
}

/// 对任意 Writer 类型的递归序列化实现
fn serializeElementImpl(
    out: anytype,
    elem: *const Element,
) WriteError!void {
    try out.elementStart(elem.name);
    for (elem.attributes) |a| {
        try out.attribute(a.name, a.value);
    }
    for (elem.children) |child_node| {
        switch (child_node) {
            .element => |e| try serializeElementImpl(out, e),
            .text => |t| try out.text(t),
            .cdata => |c| try out.cdata(c),
            .comment => |c| try out.comment(c),
            .pi => |p| try out.pi(p.target, p.data),
        }
    }
    try out.elementEnd();
}

// ─────────────────────────── 解析函数 ───────────────────────────

/// 从内存切片解析 XML 文档，返回 Document
/// 所有内存由 Document 内部 arena 管理，调用 Document.deinit() 释放
pub fn parseSlice(gpa: Allocator, src: []const u8) (ReadError || Allocator.Error)!Document {
    var r = reader_mod.Reader.initSlice(gpa, src);
    defer r.deinit();
    return parseFromReader(gpa, &r);
}

/// 从文件路径解析 XML 文档
pub fn parseFile(gpa: Allocator, path: []const u8) (ReadError || Allocator.Error)!Document {
    var r = try reader_mod.Reader.initFile(gpa, path);
    defer r.deinit();
    return parseFromReader(gpa, &r);
}

/// 从 std.fs.File 解析 XML 文档
pub fn parseFileHandle(gpa: Allocator, file: std.fs.File) (ReadError || Allocator.Error)!Document {
    var r = try reader_mod.Reader.initFileHandle(gpa, file);
    defer r.deinit();
    return parseFromReader(gpa, &r);
}

/// 从 Reader 解析 XML 文档（内部实现）
fn parseFromReader(gpa: Allocator, r: *reader_mod.Reader) (ReadError || Allocator.Error)!Document {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const alloc = arena.allocator();

    var version: ?[]const u8 = null;
    var encoding: ?[]const u8 = null;
    var standalone: ?bool = null;
    var root_elem: *Element = undefined;
    var found_root = false;

    // 读取序文
    outer: while (true) {
        const node = try r.read();
        switch (node) {
            .xml_declaration => {
                if (r.xmlDeclaration()) |decl| {
                    version = if (decl.version) |v| try alloc.dupe(u8, v) else null;
                    encoding = if (decl.encoding) |e| try alloc.dupe(u8, e) else null;
                    standalone = decl.standalone;
                }
            },
            .comment, .pi => continue,
            .element_start => {
                root_elem = try parseElement(alloc, r);
                found_root = true;
                break :outer;
            },
            .eof => return ReadError.UnexpectedEof,
            else => return ReadError.MalformedXml,
        }
    }

    if (!found_root) return ReadError.UnexpectedEof;

    // 所有分配完成后再复制 arena，确保 doc.arena 包含完整的内存节点链表
    return Document{
        .arena = arena,
        .version = version,
        .encoding = encoding,
        .standalone = standalone,
        .root = root_elem,
    };
}

/// 递归解析一个元素（当前节点必须为 element_start）
fn parseElement(alloc: Allocator, r: *reader_mod.Reader) (ReadError || Allocator.Error)!*Element {
    const elem = try alloc.create(Element);

    // 保存元素名
    const raw_name = r.elementName();
    elem.name = try alloc.dupe(u8, raw_name);

    // 保存属性
    const ac = r.attributeCount();
    var attrs_list: std.ArrayList(Attribute) = .{};
    defer attrs_list.deinit(alloc);
    for (0..ac) |i| {
        const a_name = try alloc.dupe(u8, r.attributeName(i));
        const a_raw_val = r.attributeValueRaw(i);
        // 解码实体引用
        var scratch: std.ArrayList(u8) = .{};
        defer scratch.deinit(alloc);
        const scanner_src = @import("scanner.zig");
        scanner_src.decodeText(a_raw_val, scratch.writer(alloc)) catch return ReadError.OutOfMemory;
        const a_val = try alloc.dupe(u8, scratch.items);
        try attrs_list.append(alloc, .{ .name = a_name, .value = a_val });
    }
    elem.attributes = try attrs_list.toOwnedSlice(alloc);

    // 解析子节点
    var children_list: std.ArrayList(Node) = .{};
    defer children_list.deinit(alloc);

    var text_buf: std.ArrayList(u8) = .{};
    defer text_buf.deinit(alloc);

    while (true) {
        const node = try r.read();
        switch (node) {
            .element_start => {
                // 先提交累积文本
                if (text_buf.items.len > 0) {
                    const t = try alloc.dupe(u8, text_buf.items);
                    try children_list.append(alloc, .{ .text = t });
                    text_buf.clearRetainingCapacity();
                }
                const child_elem = try parseElement(alloc, r);
                try children_list.append(alloc, .{ .element = child_elem });
            },
            .element_end => break,
            .text => {
                // 解码文本实体并追加到 text_buf
                const raw = r.textRaw();
                const scanner_src = @import("scanner.zig");
                scanner_src.decodeText(raw, text_buf.writer(alloc)) catch return ReadError.OutOfMemory;
            },
            .cdata => {
                if (text_buf.items.len > 0) {
                    const t = try alloc.dupe(u8, text_buf.items);
                    try children_list.append(alloc, .{ .text = t });
                    text_buf.clearRetainingCapacity();
                }
                const cd = try alloc.dupe(u8, r.cdataContent());
                try children_list.append(alloc, .{ .cdata = cd });
            },
            .comment => {
                if (text_buf.items.len > 0) {
                    const t = try alloc.dupe(u8, text_buf.items);
                    try children_list.append(alloc, .{ .text = t });
                    text_buf.clearRetainingCapacity();
                }
                const cm = try alloc.dupe(u8, r.commentContent());
                try children_list.append(alloc, .{ .comment = cm });
            },
            .pi => {
                if (text_buf.items.len > 0) {
                    const t = try alloc.dupe(u8, text_buf.items);
                    try children_list.append(alloc, .{ .text = t });
                    text_buf.clearRetainingCapacity();
                }
                const pt = try alloc.dupe(u8, r.piTarget());
                const pd = try alloc.dupe(u8, r.piData());
                try children_list.append(alloc, .{ .pi = .{ .target = pt, .data = pd } });
            },
            .eof => return ReadError.UnexpectedEof,
            .xml_declaration => return ReadError.MalformedXml,
        }
    }

    // 提交最后的文本
    if (text_buf.items.len > 0) {
        const t = try alloc.dupe(u8, text_buf.items);
        try children_list.append(alloc, .{ .text = t });
    }

    elem.children = try children_list.toOwnedSlice(alloc);
    return elem;
}

// ─────────────────────────── Document 序列化实现（填充内部函数） ───────────────────────────

/// 重新实现 Document.toStringAlloc，绕过泛型 Writer 问题
pub fn documentToString(doc: *const Document, gpa: Allocator, options: writer_mod.Options) WriteError![]u8 {
    var buf: std.ArrayList(u8) = .{};
    errdefer buf.deinit(gpa);

    const AnyW = std.io.AnyWriter;
    var w = writer_mod.Writer(AnyW).init(
        gpa,
        buf.writer(gpa).any(),
        options,
    );
    defer w.deinit();

    if (doc.version != null) {
        try w.xmlDeclaration(doc.encoding, doc.standalone);
    }
    try serializeElementImpl(&w, doc.root);
    try w.eof();

    return buf.toOwnedSlice(gpa);
}

/// 将 Document 写入文件（实现版）
pub fn documentWriteToFile(doc: *const Document, gpa: Allocator, path: []const u8, options: writer_mod.Options) !void {
    // 先序列化到内存，再整块写入文件
    const output = try documentToString(doc, gpa, options);
    defer gpa.free(output);
    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(output);
}

// ─────────────────────────── 单元测试 ───────────────────────────

test "DOM - parse and navigate" {
    const src =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<catalog>
        \\  <book id="1" lang="zh">
        \\    <title>Zig 编程</title>
        \\    <price>99.00</price>
        \\  </book>
        \\  <book id="2" lang="en">
        \\    <title>Programming Zig</title>
        \\    <price>49.99</price>
        \\  </book>
        \\</catalog>
    ;

    var doc = try parseSlice(std.testing.allocator, src);
    defer doc.deinit();

    try std.testing.expectEqualStrings("1.0", doc.version.?);
    try std.testing.expectEqualStrings("UTF-8", doc.encoding.?);

    const root = doc.root;
    try std.testing.expectEqualStrings("catalog", root.name);

    const books = try root.childrenNamed("book", std.testing.allocator);
    defer std.testing.allocator.free(books);
    try std.testing.expectEqual(@as(usize, 2), books.len);

    const b1 = books[0];
    try std.testing.expectEqualStrings("1", b1.attr("id").?);
    try std.testing.expectEqualStrings("zh", b1.attr("lang").?);

    const title = b1.child("title").?;
    const title_text = try title.innerText(std.testing.allocator);
    defer std.testing.allocator.free(title_text);
    try std.testing.expectEqualStrings("Zig 编程", title_text);
}

test "DOM - serialize to string" {
    const src = "<root><item key=\"v\">text</item></root>";
    var doc = try parseSlice(std.testing.allocator, src);
    defer doc.deinit();

    const output = try documentToString(&doc, std.testing.allocator, .{ .indent = "" });
    defer std.testing.allocator.free(output);

    // 序列化输出应包含关键元素
    try std.testing.expect(std.mem.indexOf(u8, output, "<root>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "<item") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "text") != null);
}

test "DOM - entity decoding in attributes" {
    const src = "<root attr=\"a &amp; b &lt; c\"/>";
    var doc = try parseSlice(std.testing.allocator, src);
    defer doc.deinit();
    try std.testing.expectEqualStrings("a & b < c", doc.root.attr("attr").?);
}
