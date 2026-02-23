// xml_example.zig
// XML 模块完整使用示例
// 演示三种 API 层次：底层扫描器、流式 Reader、DOM 树
const std = @import("std");
const zzig = @import("zzig");
const xml = zzig.xml;

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    std.debug.print("\n╔══════════════════════════════════════╗\n", .{});
    std.debug.print("║       ZZig XML 模块演示              ║\n", .{});
    std.debug.print("╚══════════════════════════════════════╝\n\n", .{});

    // ─────────────────── 1. XML Writer：构建文档 ───────────────────

    std.debug.print("── 1. 使用 Writer 构建 XML 文档 ──\n\n", .{});

    var xml_buf: std.ArrayList(u8) = .{};
    defer xml_buf.deinit(gpa);

    {
        var w = xml.createWriter(gpa, xml_buf.writer(gpa).any(), .{ .indent = "  " });
        defer w.deinit();

        try w.xmlDeclaration("UTF-8", null);
        try w.comment(" PeiKeSmart 书目管理数据 ");
        try w.elementStart("catalog");
        try w.attribute("version", "1.0");

        // 第一本书
        try w.elementStart("book");
        try w.attribute("id", "101");
        try w.attribute("lang", "zh");
        try w.elementStart("title");
        try w.text("Zig 系统编程实战");
        try w.elementEnd();
        try w.elementStart("author");
        try w.text("张三");
        try w.elementEnd();
        try w.elementStart("price");
        try w.attribute("currency", "CNY");
        try w.text("89.00");
        try w.elementEnd();
        try w.elementStart("tags");
        try w.elementStart("tag");
        try w.text("编程");
        try w.elementEnd();
        try w.elementStart("tag");
        try w.text("系统");
        try w.elementEnd();
        try w.elementEnd(); // </tags>
        try w.elementEnd(); // </book>

        // 第二本书（含特殊字符）
        try w.elementStart("book");
        try w.attribute("id", "102");
        try w.attribute("lang", "en");
        try w.elementStart("title");
        try w.text("Programming Zig: Memory & Safety");
        try w.elementEnd();
        try w.elementStart("author");
        try w.text("John Doe");
        try w.elementEnd();
        try w.elementStart("description");
        try w.cdata("<A comprehensive guide> & more!");
        try w.elementEnd();
        try w.elementEnd(); // </book>

        try w.elementEnd(); // </catalog>
        try w.eof();
    }

    std.debug.print("{s}\n", .{xml_buf.items});

    // 将生成的 XML 写入临时文件
    const tmp_path = "xml_example_output.xml";
    {
        const f = try std.fs.cwd().createFile(tmp_path, .{ .truncate = true });
        defer f.close();
        try f.writeAll(xml_buf.items);
    }
    std.debug.print("-> 已写入文件: {s}\n\n", .{tmp_path});

    // ─────────────────── 2. 流式 Reader：解析上面生成的文档 ───────────────────

    std.debug.print("── 2. 使用流式 Reader 扫描文档 ──\n\n", .{});

    {
        var reader = xml.Reader.initSlice(gpa, xml_buf.items);
        defer reader.deinit();

        var elem_count: usize = 0;
        while (true) {
            const node = try reader.read();
            switch (node) {
                .eof => break,
                .xml_declaration => {
                    const decl = reader.xmlDeclaration().?;
                    std.debug.print("  XML声明: version={s}", .{decl.version orelse "?"});
                    if (decl.encoding) |enc| std.debug.print(" encoding={s}", .{enc});
                    std.debug.print("\n", .{});
                },
                .element_start => {
                    elem_count += 1;
                    const name = reader.elementName();
                    const ac = reader.attributeCount();
                    std.debug.print("  <{s}", .{name});
                    for (0..ac) |i| {
                        std.debug.print(" {s}=\"{s}\"", .{
                            reader.attributeName(i),
                            reader.attributeValueRaw(i),
                        });
                    }
                    std.debug.print(">\n", .{});
                },
                .element_end => {
                    // 简洁，不逐一打印结束标签
                },
                .text => {
                    const t = reader.textRaw();
                    if (t.len > 0) std.debug.print("    TEXT: {s}\n", .{t});
                },
                .cdata => {
                    std.debug.print("    CDATA: {s}\n", .{reader.cdataContent()});
                },
                .comment => {
                    std.debug.print("  <!-- {s} -->\n", .{reader.commentContent()});
                },
                else => {},
            }
        }
        std.debug.print("\n  共扫描到 {d} 个元素开始标签\n\n", .{elem_count});
    }

    // ─────────────────── 3. DOM 解析：导航树结构 ───────────────────

    std.debug.print("── 3. 使用 DOM 树导航 ──\n\n", .{});

    {
        var doc = try xml.Dom.parseSlice(gpa, xml_buf.items);
        defer doc.deinit();

        std.debug.print("  根元素: <{s}>\n", .{doc.root.name});
        if (doc.root.attr("version")) |v| {
            std.debug.print("  版本属性: {s}\n", .{v});
        }

        const books = try doc.root.childrenNamed("book", gpa);
        defer gpa.free(books);
        std.debug.print("  共 {d} 本书:\n", .{books.len});

        for (books) |book| {
            const id = book.attr("id") orelse "?";
            const lang = book.attr("lang") orelse "?";
            std.debug.print("    [id={s}, lang={s}]\n", .{ id, lang });

            if (book.child("title")) |title_elem| {
                const title_text = try title_elem.innerText(gpa);
                defer gpa.free(title_text);
                std.debug.print("      标题: {s}\n", .{title_text});
            }
            if (book.child("author")) |author_elem| {
                const author_text = try author_elem.innerText(gpa);
                defer gpa.free(author_text);
                std.debug.print("      作者: {s}\n", .{author_text});
            }
            if (book.child("price")) |price_elem| {
                const price_text = try price_elem.innerText(gpa);
                defer gpa.free(price_text);
                const currency = price_elem.attr("currency") orelse "USD";
                std.debug.print("      价格: {s} {s}\n", .{ price_text, currency });
            }
        }

        // ─── 3b. DOM 序列化回 XML 字符串 ───
        std.debug.print("\n── 4. DOM 序列化（格式化输出）──\n\n", .{});

        const output = try xml.Dom.documentToString(&doc, gpa, .{ .indent = "    " });
        defer gpa.free(output);
        std.debug.print("{s}", .{output});

        // ─── 3c. DOM 写入文件 ───
        const dom_out_path = "xml_dom_roundtrip.xml";
        try xml.Dom.documentWriteToFile(&doc, gpa, dom_out_path, .{ .indent = "  " });
        std.debug.print("\n→ DOM 输出已写入文件: {s}\n", .{dom_out_path});
    }

    // ─────────────────── 5. 文件读取示例 ───────────────────

    std.debug.print("\n── 5. 从文件解析 XML ──\n\n", .{});

    {
        var doc = try xml.parseFile(gpa, tmp_path);
        defer doc.deinit();

        std.debug.print("  从文件 '{s}' 解析成功\n", .{tmp_path});
        std.debug.print("  根元素: {s}，子元素数: {d}\n", .{
            doc.root.name,
            doc.root.children.len,
        });
    }

    // 清理临时文件
    std.fs.cwd().deleteFile(tmp_path) catch {};
    std.fs.cwd().deleteFile("xml_dom_roundtrip.xml") catch {};

    std.debug.print("\n✓ XML 模块演示完成\n\n", .{});
}
