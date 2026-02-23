// reader.zig
// XML 事件驱动读取器
// 提供类似 SAX 的流式读取接口，支持内存缓冲区和文件两种数据源
// 参考 ianprime0509/zig-xml 的 API 设计（0BSD License）
const std = @import("std");
const Allocator = std.mem.Allocator;

const scanner_mod = @import("scanner.zig");
pub const Scanner = scanner_mod.Scanner;
pub const Token = scanner_mod.Token;
pub const TokenType = scanner_mod.TokenType;
pub const AttrToken = scanner_mod.AttrToken;
pub const Location = scanner_mod.Location;

/// Reader 读取到的节点类型
pub const Node = enum {
    /// 文档结尾
    eof,
    /// XML 声明 <?xml ... ?>
    xml_declaration,
    /// 元素开始 <tag ...>
    element_start,
    /// 空元素 <tag ... />（同时触发 element_start 和 element_end）
    element_end,
    /// 注释 <!-- ... -->
    comment,
    /// 处理指令 <?target data?>
    pi,
    /// 文本内容
    text,
    /// CDATA 节 <![CDATA[ ... ]]>
    cdata,
};

/// Reader 可能的错误
pub const ReadError = error{
    /// XML 格式错误
    MalformedXml,
    /// 输入意外结束
    UnexpectedEof,
    /// 内存不足
    OutOfMemory,
    /// 文件读取失败
    ReadFailed,
};

/// 最大属性数量（单个元素）
pub const max_attrs = 64;
/// 最大元素名称长度
pub const max_name_len = 256;
/// 最大嵌套深度
pub const max_depth = 512;

/// XML Reader 主结构
/// 支持两种数据源：
///   1. `Reader.initSlice` — 直接读内存切片（零拷贝）
///   2. `Reader.initFile`  — 读取文件（内部分块缓冲）
pub const Reader = struct {
    gpa: Allocator,

    /// 当前读取缓冲区（可能是外部切片或内部分配的）
    buf: []const u8,
    /// 是否由 Reader 管理缓冲区生命周期
    owns_buf: bool,

    /// 底层扫描器
    sc: Scanner,

    /// 当前节点/事件类型
    node: Node,

    /// 当前 Token 在 buf 中的切片
    current_token: Token,

    /// 上次扫描是否为空元素（<tag />），需要额外触发 element_end
    pending_element_end: bool,
    pending_end_name: []const u8,

    /// 属性缓存（仅对 element_start/element_empty 有效）
    attrs: [max_attrs]AttrToken,
    attr_count: usize,

    /// 用于文本/CDATA 解码的临时缓冲区
    scratch: std.ArrayList(u8),

    /// 元素名称栈（用于验证嵌套）
    name_stack: std.ArrayList([]u8),

    /// XML 声明信息（若存在）
    xml_decl: ?scanner_mod.XmlDeclInfo,

    /// 是否已初始化（检查内部一致性）
    initialized: bool,

    // ─────────────────────────── 初始化 / 释放 ───────────────────────────

    /// 从内存切片初始化（零拷贝，不管理 src 的生命周期）
    pub fn initSlice(gpa: Allocator, src: []const u8) Reader {
        return .{
            .gpa = gpa,
            .buf = src,
            .owns_buf = false,
            .sc = Scanner.init(src),
            .node = .eof,
            .current_token = .{ .typ = .eof, .start = 0, .end = 0 },
            .pending_element_end = false,
            .pending_end_name = "",
            .attrs = undefined,
            .attr_count = 0,
            .scratch = .{},
            .name_stack = .{},
            .xml_decl = null,
            .initialized = true,
        };
    }

    /// 从文件路径读取全部内容并初始化（Reader 管理缓冲区生命周期）
    pub fn initFile(gpa: Allocator, path: []const u8) (ReadError || Allocator.Error)!Reader {
        const file = std.fs.cwd().openFile(path, .{}) catch return ReadError.ReadFailed;
        defer file.close();
        const content = file.readToEndAlloc(gpa, std.math.maxInt(usize)) catch |err| switch (err) {
            error.OutOfMemory => return ReadError.OutOfMemory,
            else => return ReadError.ReadFailed,
        };
        return .{
            .gpa = gpa,
            .buf = content,
            .owns_buf = true,
            .sc = Scanner.init(content),
            .node = .eof,
            .current_token = .{ .typ = .eof, .start = 0, .end = 0 },
            .pending_element_end = false,
            .pending_end_name = "",
            .attrs = undefined,
            .attr_count = 0,
            .scratch = .{},
            .name_stack = .{},
            .xml_decl = null,
            .initialized = true,
        };
    }

    /// 从 `std.fs.File` 初始化（Reader 管理缓冲区生命周期）
    pub fn initFileHandle(gpa: Allocator, file: std.fs.File) (ReadError || Allocator.Error)!Reader {
        const content = file.readToEndAlloc(gpa, std.math.maxInt(usize)) catch |err| switch (err) {
            error.OutOfMemory => return ReadError.OutOfMemory,
            else => return ReadError.ReadFailed,
        };
        return .{
            .gpa = gpa,
            .buf = content,
            .owns_buf = true,
            .sc = Scanner.init(content),
            .node = .eof,
            .current_token = .{ .typ = .eof, .start = 0, .end = 0 },
            .pending_element_end = false,
            .pending_end_name = "",
            .attrs = undefined,
            .attr_count = 0,
            .scratch = .{},
            .name_stack = .{},
            .xml_decl = null,
            .initialized = true,
        };
    }

    /// 释放 Reader 持有的所有资源
    pub fn deinit(self: *Reader) void {
        if (self.owns_buf) self.gpa.free(self.buf);
        self.scratch.deinit(self.gpa);
        for (self.name_stack.items) |name| self.gpa.free(name);
        self.name_stack.deinit(self.gpa);
        self.* = undefined;
    }

    // ─────────────────────────── 核心读取函数 ───────────────────────────

    /// 读取下一个节点，返回节点类型
    /// 循环调用直到返回 `.eof`
    pub fn read(self: *Reader) ReadError!Node {
        // 如果上次是空元素，触发对应的 element_end
        if (self.pending_element_end) {
            self.pending_element_end = false;
            self.node = .element_end;
            // 弹出名称栈
            if (self.name_stack.items.len > 0) {
                const name = self.name_stack.pop().?;
                self.gpa.free(name);
            }
            return .element_end;
        }

        // 循环跳过 DOCTYPE（已在 scanner 中标记为 .doctype）
        while (true) {
            const tok = self.sc.next() catch |err| return switch (err) {
                error.MalformedXml => ReadError.MalformedXml,
                error.UnexpectedEof => ReadError.UnexpectedEof,
                error.BufferOverflow => ReadError.MalformedXml,
            };

            if (tok == null) {
                self.node = .eof;
                return .eof;
            }

            const t = tok.?;
            self.current_token = t;

            switch (t.typ) {
                .doctype => continue, // 跳过 DOCTYPE

                .xml_declaration => {
                    self.xml_decl = scanner_mod.parseXmlDecl(t.slice(self.buf));
                    self.node = .xml_declaration;
                    return .xml_declaration;
                },

                .element_start => {
                    self.attr_count = scanner_mod.parseElementAttrs(t.slice(self.buf), &self.attrs);
                    self.node = .element_start;
                    // 将元素名压栈
                    const nr = scanner_mod.elementNameRange(t.slice(self.buf));
                    const name = t.slice(self.buf)[nr.@"0"..nr.@"1"];
                    const owned = self.gpa.dupe(u8, name) catch return ReadError.OutOfMemory;
                    self.name_stack.append(self.gpa, owned) catch {
                        self.gpa.free(owned);
                        return ReadError.OutOfMemory;
                    };
                    return .element_start;
                },

                .element_empty => {
                    self.attr_count = scanner_mod.parseElementAttrs(t.slice(self.buf), &self.attrs);
                    self.node = .element_start;
                    // 空元素：先触发 element_start，再在下次 read 触发 element_end
                    const nr = scanner_mod.elementNameRange(t.slice(self.buf));
                    const name = t.slice(self.buf)[nr.@"0"..nr.@"1"];
                    const owned = self.gpa.dupe(u8, name) catch return ReadError.OutOfMemory;
                    self.name_stack.append(self.gpa, owned) catch {
                        self.gpa.free(owned);
                        return ReadError.OutOfMemory;
                    };
                    self.pending_element_end = true;
                    return .element_start;
                },

                .element_end => {
                    self.node = .element_end;
                    // 弹出名称栈
                    if (self.name_stack.items.len > 0) {
                        const name = self.name_stack.pop().?;
                        self.gpa.free(name);
                    }
                    return .element_end;
                },

                .text => {
                    // 跳过纯空白文本节点（只含空格/换行/制表）
                    const raw = t.slice(self.buf);
                    var all_ws = true;
                    for (raw) |c| {
                        if (c != ' ' and c != '\t' and c != '\r' and c != '\n') {
                            all_ws = false;
                            break;
                        }
                    }
                    if (all_ws and raw.len > 0) continue;
                    self.node = .text;
                    return .text;
                },

                .cdata => {
                    self.node = .cdata;
                    return .cdata;
                },

                .comment => {
                    self.node = .comment;
                    return .comment;
                },

                .pi => {
                    self.node = .pi;
                    return .pi;
                },

                .eof => {
                    self.node = .eof;
                    return .eof;
                },
            }
        }
    }

    // ─────────────────────────── 节点数据访问 ───────────────────────────

    /// 返回当前元素的名称
    /// 仅在 element_start / element_end 节点有效
    pub fn elementName(self: *const Reader) []const u8 {
        std.debug.assert(self.node == .element_start or self.node == .element_end);
        const raw = self.current_token.slice(self.buf);
        const nr = switch (self.current_token.typ) {
            .element_start, .element_empty => scanner_mod.elementNameRange(raw),
            .element_end => scanner_mod.endElementNameRange(raw),
            else => unreachable,
        };
        return raw[nr.@"0"..nr.@"1"];
    }

    /// 返回当前节点的原始文本切片（element_end 时返回当前元素名）
    pub fn elementNameForEnd(self: *const Reader) []const u8 {
        std.debug.assert(self.node == .element_end);
        // 如果是空元素触发的 element_end，名称在 name_stack 已弹出，
        // 直接从 current_token 读取
        const raw = self.current_token.slice(self.buf);
        const nr = switch (self.current_token.typ) {
            .element_end => scanner_mod.endElementNameRange(raw),
            .element_empty => scanner_mod.elementNameRange(raw),
            else => scanner_mod.elementNameRange(raw),
        };
        return raw[nr.@"0"..nr.@"1"];
    }

    /// 返回属性数量（仅在 element_start 有效）
    pub fn attributeCount(self: *const Reader) usize {
        std.debug.assert(self.node == .element_start);
        return self.attr_count;
    }

    /// 返回第 n 个属性名（仅在 element_start 有效）
    pub fn attributeName(self: *const Reader, n: usize) []const u8 {
        std.debug.assert(self.node == .element_start);
        std.debug.assert(n < self.attr_count);
        return self.attrs[n].name(self.current_token.slice(self.buf));
    }

    /// 返回第 n 个属性值（原始，未解码实体）
    pub fn attributeValueRaw(self: *const Reader, n: usize) []const u8 {
        std.debug.assert(self.node == .element_start);
        std.debug.assert(n < self.attr_count);
        return self.attrs[n].value(self.current_token.slice(self.buf));
    }

    /// 返回第 n 个属性值（已解码实体引用，分配新内存）
    pub fn attributeValueAlloc(self: *Reader, n: usize) Allocator.Error![]u8 {
        const raw = self.attributeValueRaw(n);
        self.scratch.clearRetainingCapacity();
        scanner_mod.decodeText(raw, self.scratch.writer(self.gpa)) catch return Allocator.Error.OutOfMemory;
        return self.gpa.dupe(u8, self.scratch.items);
    }

    /// 按名称查找属性并返回值（原始）
    pub fn attribute(self: *const Reader, name: []const u8) ?[]const u8 {
        std.debug.assert(self.node == .element_start);
        for (0..self.attr_count) |i| {
            if (std.mem.eql(u8, self.attributeName(i), name)) {
                return self.attributeValueRaw(i);
            }
        }
        return null;
    }

    /// 返回当前文本节点的原始切片（未解码实体）
    /// 仅在 text 节点有效
    pub fn textRaw(self: *const Reader) []const u8 {
        std.debug.assert(self.node == .text);
        return self.current_token.slice(self.buf);
    }

    /// 返回当前文本节点解码后的内容（分配新内存）
    pub fn textAlloc(self: *Reader) Allocator.Error![]u8 {
        const raw = self.textRaw();
        self.scratch.clearRetainingCapacity();
        scanner_mod.decodeText(raw, self.scratch.writer(self.gpa)) catch return Allocator.Error.OutOfMemory;
        return self.gpa.dupe(u8, self.scratch.items);
    }

    /// 返回 CDATA 内容切片
    /// 仅在 cdata 节点有效
    pub fn cdataContent(self: *const Reader) []const u8 {
        std.debug.assert(self.node == .cdata);
        const raw = self.current_token.slice(self.buf);
        const r = scanner_mod.cdataContentRange(raw);
        return raw[r.@"0"..r.@"1"];
    }

    /// 返回注释内容切片
    /// 仅在 comment 节点有效
    pub fn commentContent(self: *const Reader) []const u8 {
        std.debug.assert(self.node == .comment);
        const raw = self.current_token.slice(self.buf);
        const r = scanner_mod.commentContentRange(raw);
        return raw[r.@"0"..r.@"1"];
    }

    /// 返回 PI 目标
    pub fn piTarget(self: *const Reader) []const u8 {
        std.debug.assert(self.node == .pi);
        const raw = self.current_token.slice(self.buf);
        // raw: <?target data?>
        var pos: usize = 2; // skip "<?"
        const start = pos;
        while (pos < raw.len and raw[pos] != ' ' and raw[pos] != '\t' and raw[pos] != '?')
            pos += 1;
        return raw[start..pos];
    }

    /// 返回 PI 数据
    pub fn piData(self: *const Reader) []const u8 {
        std.debug.assert(self.node == .pi);
        const raw = self.current_token.slice(self.buf);
        var pos: usize = 2;
        // 跳过目标名
        while (pos < raw.len and raw[pos] != ' ' and raw[pos] != '\t' and raw[pos] != '?')
            pos += 1;
        // 跳过空白
        while (pos < raw.len and (raw[pos] == ' ' or raw[pos] == '\t'))
            pos += 1;
        // 数据到 "?>"
        const start = pos;
        if (raw.len >= 2) {
            const end = raw.len - 2; // 去掉 "?>"
            if (start <= end) return raw[start..end];
        }
        return "";
    }

    /// XML 声明信息（若文档包含 <?xml ...?>）
    pub fn xmlDeclaration(self: *const Reader) ?scanner_mod.XmlDeclInfo {
        return self.xml_decl;
    }

    // ─────────────────────────── 辅助工具函数 ───────────────────────────

    /// 跳过序文（XML 声明、注释、PI），直到到达根元素开始
    /// 返回后当前节点为根元素的 element_start
    pub fn skipProlog(self: *Reader) ReadError!void {
        while (true) {
            const node = try self.read();
            switch (node) {
                .xml_declaration, .comment, .pi => continue,
                .element_start => return,
                .eof => return,
                else => return ReadError.MalformedXml,
            }
        }
    }

    /// 跳过当前元素及其所有子元素
    /// 断言当前节点为 element_start
    /// 返回后当前节点为配对的 element_end
    pub fn skipElement(self: *Reader) ReadError!void {
        std.debug.assert(self.node == .element_start);
        var skip_depth: usize = 1;
        while (skip_depth > 0) {
            const node = try self.read();
            switch (node) {
                .element_start => skip_depth += 1,
                .element_end => skip_depth -= 1,
                .eof => return ReadError.UnexpectedEof,
                else => {},
            }
        }
    }

    /// 读取当前元素的全部文本内容（含子元素内的文本，递归展开）
    /// 断言当前节点为 element_start
    /// 返回后当前节点为配对的 element_end
    /// 返回内存由调用者负责释放
    pub fn readElementTextAlloc(self: *Reader) ReadError![]u8 {
        std.debug.assert(self.node == .element_start);
        var text_buf: std.ArrayList(u8) = .{};
        defer text_buf.deinit(self.gpa);
        var skip_depth: usize = 1;
        while (skip_depth > 0) {
            const node = try self.read();
            switch (node) {
                .element_start => skip_depth += 1,
                .element_end => skip_depth -= 1,
                .text => {
                    const raw = self.textRaw();
                    scanner_mod.decodeText(raw, text_buf.writer(self.gpa)) catch
                        return ReadError.OutOfMemory;
                },
                .cdata => {
                    text_buf.appendSlice(self.gpa, self.cdataContent()) catch
                        return ReadError.OutOfMemory;
                },
                .eof => return ReadError.UnexpectedEof,
                else => {},
            }
        }
        return self.gpa.dupe(u8, text_buf.items) catch ReadError.OutOfMemory;
    }

    /// 跳过文档剩余所有内容（直到 eof）
    pub fn skipDocument(self: *Reader) ReadError!void {
        while (true) {
            if (try self.read() == .eof) return;
        }
    }

    /// 返回当前嵌套深度（根元素深度为 1）
    pub fn depth(self: *const Reader) usize {
        return self.name_stack.items.len;
    }
};

// ─────────────────────────── 单元测试 ───────────────────────────

test "Reader - basic document" {
    const src =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<root>
        \\  <child id="1">Hello</child>
        \\  <child id="2"/>
        \\</root>
    ;
    var reader = Reader.initSlice(std.testing.allocator, src);
    defer reader.deinit();

    // XML 声明
    try std.testing.expectEqual(Node.xml_declaration, try reader.read());
    const decl = reader.xmlDeclaration().?;
    try std.testing.expectEqualStrings("1.0", decl.version.?);
    try std.testing.expectEqualStrings("UTF-8", decl.encoding.?);

    // <root>
    try std.testing.expectEqual(Node.element_start, try reader.read());
    try std.testing.expectEqualStrings("root", reader.elementName());

    // <child id="1">
    try std.testing.expectEqual(Node.element_start, try reader.read());
    try std.testing.expectEqualStrings("child", reader.elementName());
    try std.testing.expectEqual(@as(usize, 1), reader.attributeCount());
    try std.testing.expectEqualStrings("id", reader.attributeName(0));
    try std.testing.expectEqualStrings("1", reader.attributeValueRaw(0));

    // "Hello"
    try std.testing.expectEqual(Node.text, try reader.read());
    try std.testing.expectEqualStrings("Hello", reader.textRaw());

    // </child>
    try std.testing.expectEqual(Node.element_end, try reader.read());

    // <child id="2"/> — 空元素，先 element_start 再 element_end
    try std.testing.expectEqual(Node.element_start, try reader.read());
    try std.testing.expectEqualStrings("child", reader.elementName());
    try std.testing.expectEqual(Node.element_end, try reader.read());

    // </root>
    try std.testing.expectEqual(Node.element_end, try reader.read());

    // eof
    try std.testing.expectEqual(Node.eof, try reader.read());
}

test "Reader - readElementTextAlloc" {
    const src = "<root><a>Hello </a><b>&amp; World</b></root>";
    var reader = Reader.initSlice(std.testing.allocator, src);
    defer reader.deinit();

    try std.testing.expectEqual(Node.element_start, try reader.read());
    const text = try reader.readElementTextAlloc();
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("Hello & World", text);
}

test "Reader - skipElement" {
    const src = "<root><skip><inner>data</inner></skip><after/></root>";
    var reader = Reader.initSlice(std.testing.allocator, src);
    defer reader.deinit();

    try std.testing.expectEqual(Node.element_start, try reader.read()); // root
    try std.testing.expectEqual(Node.element_start, try reader.read()); // skip
    try reader.skipElement();
    try std.testing.expectEqual(Node.element_end, reader.node);

    try std.testing.expectEqual(Node.element_start, try reader.read()); // after
    try std.testing.expectEqual(Node.element_end, try reader.read()); // /after
    try std.testing.expectEqual(Node.element_end, try reader.read()); // /root
    try std.testing.expectEqual(Node.eof, try reader.read());
}

test "Reader - comment and cdata" {
    const src = "<root><!-- my comment --><![CDATA[raw & data]]></root>";
    var reader = Reader.initSlice(std.testing.allocator, src);
    defer reader.deinit();

    try std.testing.expectEqual(Node.element_start, try reader.read());
    try std.testing.expectEqual(Node.comment, try reader.read());
    try std.testing.expectEqualStrings(" my comment ", reader.commentContent());
    try std.testing.expectEqual(Node.cdata, try reader.read());
    try std.testing.expectEqualStrings("raw & data", reader.cdataContent());
    try std.testing.expectEqual(Node.element_end, try reader.read());
}

test "Reader - attribute decoding" {
    const src = "<elem attr=\"hello &amp; &lt;world&gt;\"/>";
    var reader = Reader.initSlice(std.testing.allocator, src);
    defer reader.deinit();

    try std.testing.expectEqual(Node.element_start, try reader.read());
    const val = try reader.attributeValueAlloc(0);
    defer std.testing.allocator.free(val);
    try std.testing.expectEqualStrings("hello & <world>", val);
}
