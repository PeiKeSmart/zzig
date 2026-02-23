// xml.zig
// XML 处理模块根文件
// 提供 XML 解析（流式读取 + DOM）和 XML 写入功能
// 设计原则：零外部依赖，跨平台，Zig 0.15.2+ 兼容
//
// 参考资料：
//   - XML 1.0 (Fifth Edition): https://www.w3.org/TR/2008/REC-xml-20081126/
//   - ianprime0509/zig-xml (0BSD License): https://github.com/ianprime0509/zig-xml
//
// 用法示例（流式读取）：
//   var reader = xml.Reader.initSlice(allocator, src);
//   defer reader.deinit();
//   while (true) {
//       const node = try reader.read();
//       if (node == .eof) break;
//       if (node == .element_start) {
//           std.debug.print("element: {s}\n", .{reader.elementName()});
//       }
//   }
//
// 用法示例（DOM 解析）：
//   var doc = try xml.Dom.parseSlice(allocator, src);
//   defer doc.deinit();
//   const root = doc.root;
//   const val = root.attr("key");
//
// 用法示例（写入）：
//   var w = xml.createWriter(allocator, file_writer, .{ .indent = "  " });
//   try w.xmlDeclaration("UTF-8", null);
//   try w.elementStart("root");
//   try w.text("Hello");
//   try w.elementEnd();
//   try w.eof();
const std = @import("std");

// ─────────────────────────── 子模块重导出 ───────────────────────────

/// 底层 XML 字节扫描器（低级 API，通常不直接使用）
pub const Scanner = @import("scanner.zig").Scanner;

/// 扫描器 Token 类型
pub const Token = @import("scanner.zig").Token;
pub const TokenType = @import("scanner.zig").TokenType;

/// 属性扫描结果
pub const AttrToken = @import("scanner.zig").AttrToken;

/// 行列位置信息
pub const Location = @import("scanner.zig").Location;

/// XML 声明解析结果
pub const XmlDeclInfo = @import("scanner.zig").XmlDeclInfo;

/// 从 <?xml ...?> 原始切片解析 XML 声明信息
pub const parseXmlDecl = @import("scanner.zig").parseXmlDecl;

/// 解析元素属性列表
pub const parseElementAttrs = @import("scanner.zig").parseElementAttrs;

/// 解码 XML 文本实体引用（&amp; &lt; &#x20; 等）
pub const decodeText = @import("scanner.zig").decodeText;

// ─────────────────────────── 流式 Reader ───────────────────────────

/// 流式事件驱动 XML 读取器
///
/// 节点类型 (Reader.Node):
///   .eof            — 文档结尾
///   .xml_declaration — XML 声明
///   .element_start  — 元素开始标签
///   .element_end    — 元素结束标签（空元素也会触发）
///   .text           — 文本内容
///   .cdata          — CDATA 节
///   .comment        — 注释
///   .pi             — 处理指令
///
/// 示例：
///   var reader = xml.Reader.initSlice(allocator, xml_bytes);
///   defer reader.deinit();
///   while (try reader.read() != .eof) {
///       // ...
///   }
pub const Reader = @import("reader.zig").Reader;

/// Reader 可读取的节点类型
pub const Node = @import("reader.zig").Node;

/// Reader 错误集合
pub const ReadError = @import("reader.zig").ReadError;

// ─────────────────────────── XML Writer ───────────────────────────

/// XML 写入器（泛型，支持任意 Writer 接口）
///
/// 创建方式：
///   var w = xml.createWriter(allocator, my_writer, .{});
///
/// 用法：
///   try w.xmlDeclaration("UTF-8", null);
///   try w.elementStart("root");
///   try w.attribute("id", "1");
///   try w.text("content");
///   try w.elementEnd();
///   try w.eof();
pub const WriterImpl = @import("writer.zig");

/// Writer 配置选项
pub const WriterOptions = @import("writer.zig").Options;

/// Writer 错误集合
pub const WriteError = @import("writer.zig").WriteError;

/// 创建一个写入到指定 Writer 的 XML Writer
/// out: 任意支持 writeAll / writeByte 方法的 Writer 实例
pub fn createWriter(
    allocator: std.mem.Allocator,
    out: anytype,
    options: WriterOptions,
) WriterImpl.Writer(@TypeOf(out)) {
    return WriterImpl.Writer(@TypeOf(out)).init(allocator, out, options);
}

/// 创建写入到 std.io.AnyWriter 的 XML Writer（动态分发版本）
pub fn createAnyWriter(
    allocator: std.mem.Allocator,
    out: std.io.AnyWriter,
    options: WriterOptions,
) WriterImpl.Writer(std.io.AnyWriter) {
    return WriterImpl.Writer(std.io.AnyWriter).init(allocator, out, options);
}

// ─────────────────────────── DOM ───────────────────────────

/// DOM 文档对象模型命名空间
///
/// 解析示例：
///   var doc = try xml.Dom.parseSlice(allocator, src);
///   defer doc.deinit();
///   const root = doc.root;
///   const val = root.attr("key");
///
/// 序列化示例：
///   const xml_str = try xml.Dom.documentToString(&doc, allocator, .{ .indent = "  " });
///   defer allocator.free(xml_str);
pub const Dom = struct {
    const dom_mod = @import("dom.zig");

    /// DOM 节点类型枚举
    pub const NodeKind = dom_mod.NodeKind;
    /// 属性键值对
    pub const Attribute = dom_mod.Attribute;
    /// DOM 节点（tagged union）
    pub const Node = dom_mod.Node;
    /// DOM 元素节点
    pub const Element = dom_mod.Element;
    /// XML 文档（含 arena）
    pub const Document = dom_mod.Document;

    /// 从内存切片解析 XML 为 DOM 文档
    pub const parseSlice = dom_mod.parseSlice;
    /// 从文件路径解析 XML 为 DOM 文档
    pub const parseFile = dom_mod.parseFile;
    /// 从 std.fs.File 解析 XML 为 DOM 文档
    pub const parseFileHandle = dom_mod.parseFileHandle;

    /// 将 DOM 文档序列化为 XML 字符串（调用者释放）
    pub const documentToString = dom_mod.documentToString;
    /// 将 DOM 文档写入文件
    pub const documentWriteToFile = dom_mod.documentWriteToFile;
};

// ─────────────────────────── 便捷函数 ───────────────────────────

/// 一次性将 XML 文件读取并解析为 DOM 文档
/// 等价于 Dom.parseFile，提供顶层快捷访问
pub inline fn parseFile(
    allocator: std.mem.Allocator,
    path: []const u8,
) (ReadError || std.mem.Allocator.Error)!Dom.Document {
    return Dom.parseFile(allocator, path);
}

/// 一次性从内存切片解析为 DOM 文档
pub inline fn parse(
    allocator: std.mem.Allocator,
    src: []const u8,
) (ReadError || std.mem.Allocator.Error)!Dom.Document {
    return Dom.parseSlice(allocator, src);
}

/// 将 DOM 文档写入文件（格式化）
/// path：目标文件路径（如不存在则创建）
/// options：Writer 配置（如缩进）
pub inline fn writeToFile(
    doc: *const Dom.Document,
    allocator: std.mem.Allocator,
    path: []const u8,
    options: WriterOptions,
) !void {
    return Dom.documentWriteToFile(doc, allocator, path, options);
}

/// 将 DOM 文档转为字符串（调用者负责释放）
pub inline fn toString(
    doc: *const Dom.Document,
    allocator: std.mem.Allocator,
    options: WriterOptions,
) WriteError![]u8 {
    return Dom.documentToString(doc, allocator, options);
}

// ─────────────────────────── 测试汇总 ───────────────────────────

test {
    // 引入各子模块的测试
    _ = @import("scanner.zig");
    _ = @import("reader.zig");
    _ = @import("writer.zig");
    _ = @import("dom.zig");
}

test "xml - end-to-end parse and serialize" {
    const src =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<library>
        \\  <book id="101">
        \\    <title>Learning Zig</title>
        \\    <author>Someone</author>
        \\  </book>
        \\</library>
    ;

    // 解析
    var doc = try Dom.parseSlice(std.testing.allocator, src);
    defer doc.deinit();

    const root = doc.root;
    try std.testing.expectEqualStrings("library", root.name);

    const book = root.child("book").?;
    try std.testing.expectEqualStrings("101", book.attr("id").?);

    const title = book.child("title").?;
    const title_text = try title.innerText(std.testing.allocator);
    defer std.testing.allocator.free(title_text);
    try std.testing.expectEqualStrings("Learning Zig", title_text);

    // 序列化
    const output = try Dom.documentToString(&doc, std.testing.allocator, .{ .indent = "  " });
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "<library>") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Learning Zig") != null);
}

test "xml - streaming reader end-to-end" {
    const src =
        \\<items>
        \\  <item key="a">Alpha</item>
        \\  <item key="b">Beta</item>
        \\</items>
    ;

    var reader = Reader.initSlice(std.testing.allocator, src);
    defer reader.deinit();

    var item_count: usize = 0;
    while (true) {
        const n = try reader.read();
        if (n == .eof) break;
        if (n == .element_start and std.mem.eql(u8, reader.elementName(), "item")) {
            item_count += 1;
            const key = reader.attribute("key").?;
            _ = key;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), item_count);
}
