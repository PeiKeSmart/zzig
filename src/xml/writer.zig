// writer.zig
// XML 写入器
// 支持生成格式化或紧凑 XML，输出到任意 Writer 接口
// 参考 ianprime0509/zig-xml 的 API 设计（0BSD License）
const std = @import("std");
const Allocator = std.mem.Allocator;

/// 写入过程中的错误类型
pub const WriteError = error{
    /// 底层输出错误
    WriteFailed,
    /// 内存不足
    OutOfMemory,
    /// 状态异常（如在非法位置调用某函数）
    IllegalState,
};

/// Writer 配置选项
pub const Options = struct {
    /// 缩进字符串，空串表示不格式化（紧凑输出）
    indent: []const u8 = "",
    /// 是否在元素结束后自动换行（仅 indent 非空时有效）
    trailing_newline: bool = true,
};

/// Writer 内部状态机
const State = enum {
    /// 文档开始（尚未写任何内容）
    start,
    /// 刚写完 BOM
    after_bom,
    /// 刚写完 XML 声明
    after_xml_declaration,
    /// 在元素开始标签内（< name ... 未关闭）
    element_start,
    /// 在元素内容中（已关闭开始标签，可写文本/子元素）
    in_element,
    /// 刚写完结束标签、注释、PI 等结构
    after_structure_end,
    /// 文档已结束
    eof,
};

/// XML Writer 结构体
/// 通过泛型 `anytype` 输出到任意实现 `writeAll` 的 Writer
pub fn Writer(comptime OutWriter: type) type {
    return struct {
        out: OutWriter,
        options: Options,
        state: State,
        /// 当前嵌套深度（用于缩进）
        indent_depth: usize,
        /// 元素名称栈（验证嵌套完整性）
        gpa: Allocator,
        element_names: std.ArrayList([]u8),

        const Self = @This();

        // ─────────────────────────── 初始化 / 释放 ───────────────────────────

        pub fn init(gpa: Allocator, out: OutWriter, options: Options) Self {
            return .{
                .out = out,
                .options = options,
                .state = .start,
                .indent_depth = 0,
                .gpa = gpa,
                .element_names = .{},
            };
        }

        pub fn deinit(self: *Self) void {
            for (self.element_names.items) |name| self.gpa.free(name);
            self.element_names.deinit(self.gpa);
        }

        // ─────────────────────────── 私有辅助函数 ───────────────────────────

        fn write(self: *Self, s: []const u8) WriteError!void {
            self.out.writeAll(s) catch return WriteError.WriteFailed;
        }

        fn writeByte(self: *Self, b: u8) WriteError!void {
            self.out.writeByte(b) catch return WriteError.WriteFailed;
        }

        fn writeNewlineAndIndent(self: *Self) WriteError!void {
            if (self.options.indent.len == 0) return;
            try self.write("\n");
            var i: usize = 0;
            while (i < self.indent_depth) : (i += 1) {
                try self.write(self.options.indent);
            }
        }

        /// 输出文本内容时转义 XML 特殊字符
        fn escapeText(self: *Self, s: []const u8) WriteError!void {
            var pos: usize = 0;
            while (pos < s.len) {
                const c = s[pos];
                switch (c) {
                    '&' => try self.write("&amp;"),
                    '<' => try self.write("&lt;"),
                    '>' => try self.write("&gt;"),
                    '\r' => {}, // 忽略 CR（规范化）
                    else => try self.writeByte(c),
                }
                pos += 1;
            }
        }

        /// 输出属性值时转义
        fn escapeAttr(self: *Self, s: []const u8) WriteError!void {
            var pos: usize = 0;
            while (pos < s.len) {
                const c = s[pos];
                switch (c) {
                    '&' => try self.write("&amp;"),
                    '<' => try self.write("&lt;"),
                    '"' => try self.write("&quot;"),
                    '\t' => try self.write("&#9;"),
                    '\n' => try self.write("&#10;"),
                    '\r' => try self.write("&#13;"),
                    else => try self.writeByte(c),
                }
                pos += 1;
            }
        }

        // ─────────────────────────── 公共 API ───────────────────────────

        /// 写入 UTF-8 BOM（\uFEFF）
        /// 必须在文档最开始调用
        pub fn bom(self: *Self) WriteError!void {
            std.debug.assert(self.state == .start);
            try self.write("\xEF\xBB\xBF");
            self.state = .after_bom;
        }

        /// 写入 XML 声明 <?xml version="1.0" ...?>
        /// encoding: 编码名称（如 "UTF-8"），null 则省略
        /// standalone: 独立文档声明，null 则省略
        pub fn xmlDeclaration(
            self: *Self,
            encoding: ?[]const u8,
            standalone: ?bool,
        ) WriteError!void {
            std.debug.assert(self.state == .start or self.state == .after_bom);
            try self.write("<?xml version=\"1.0\"");
            if (encoding) |enc| {
                try self.write(" encoding=\"");
                try self.write(enc);
                try self.write("\"");
            }
            if (standalone) |sa| {
                try self.write(if (sa) " standalone=\"yes\"" else " standalone=\"no\"");
            }
            try self.write("?>");
            if (self.options.indent.len > 0) try self.write("\n");
            self.state = .after_xml_declaration;
        }

        /// 开始写入一个元素的开始标签 <name
        /// 后续可调用 attribute() 追加属性
        /// 必须调用 elementEnd() 或 elementEndEmpty() 关闭
        pub fn elementStart(self: *Self, name: []const u8) WriteError!void {
            switch (self.state) {
                .start, .after_bom, .after_xml_declaration => {},
                .in_element, .after_structure_end => {
                    try self.writeNewlineAndIndent();
                },
                .element_start => {
                    // 前一个元素还在 element_start 状态，需先关闭
                    try self.write(">");
                    self.indent_depth += 1;
                    try self.writeNewlineAndIndent();
                },
                .eof => unreachable,
            }
            try self.writeByte('<');
            try self.write(name);
            // 压栈元素名
            const owned = self.gpa.dupe(u8, name) catch return WriteError.OutOfMemory;
            self.element_names.append(self.gpa, owned) catch {
                self.gpa.free(owned);
                return WriteError.OutOfMemory;
            };
            self.state = .element_start;
        }

        /// 向当前元素开始标签追加一个属性
        /// 仅在 elementStart() 之后、elementEnd() 之前有效
        pub fn attribute(self: *Self, name: []const u8, value: []const u8) WriteError!void {
            std.debug.assert(self.state == .element_start);
            try self.writeByte(' ');
            try self.write(name);
            try self.write("=\"");
            try self.escapeAttr(value);
            try self.writeByte('"');
        }

        /// 关闭当前元素（写入 </name>）
        /// 若当前状态是 element_start（无内容），则生成 <name />
        pub fn elementEnd(self: *Self) WriteError!void {
            const name = if (self.element_names.items.len > 0)
                self.element_names.pop().?
            else
                return WriteError.IllegalState;
            defer self.gpa.free(name);

            switch (self.state) {
                .element_start => {
                    // 自闭合
                    try self.write("/>");
                    self.state = .after_structure_end;
                },
                .in_element, .after_structure_end => {
                    if (self.indent_depth > 0) self.indent_depth -= 1;
                    if (self.state == .after_structure_end) {
                        try self.writeNewlineAndIndent();
                    }
                    try self.write("</");
                    try self.write(name);
                    try self.write(">");
                    self.state = .after_structure_end;
                },
                else => return WriteError.IllegalState,
            }
        }

        /// 强制写入自闭合标签 <name .../>（无论有无属性）
        /// 等价于 elementEnd() 在无内容时的行为
        pub fn elementEndEmpty(self: *Self) WriteError!void {
            std.debug.assert(self.state == .element_start);
            const name = if (self.element_names.items.len > 0)
                self.element_names.pop().?
            else
                return WriteError.IllegalState;
            defer self.gpa.free(name);
            try self.write("/>");
            self.state = .after_structure_end;
        }

        /// 写入文本内容（自动转义 XML 特殊字符）
        /// 仅在元素内部有效
        pub fn text(self: *Self, s: []const u8) WriteError!void {
            switch (self.state) {
                .in_element, .after_structure_end => {},
                .element_start => {
                    try self.write(">");
                    self.indent_depth += 1;
                    self.state = .in_element;
                },
                else => return WriteError.IllegalState,
            }
            try self.escapeText(s);
            self.state = .in_element;
        }

        /// 写入原始文本（不转义，慎用）
        pub fn rawText(self: *Self, s: []const u8) WriteError!void {
            switch (self.state) {
                .in_element, .after_structure_end => {},
                .element_start => {
                    try self.write(">");
                    self.indent_depth += 1;
                    self.state = .in_element;
                },
                else => return WriteError.IllegalState,
            }
            try self.write(s);
            self.state = .in_element;
        }

        /// 写入 CDATA 节 <![CDATA[ ... ]]>
        pub fn cdata(self: *Self, s: []const u8) WriteError!void {
            switch (self.state) {
                .in_element, .after_structure_end => {},
                .element_start => {
                    try self.write(">");
                    self.indent_depth += 1;
                    self.state = .in_element;
                },
                else => return WriteError.IllegalState,
            }
            try self.write("<![CDATA[");
            try self.write(s);
            try self.write("]]>");
            self.state = .in_element;
        }

        /// 写入注释 <!-- s -->
        pub fn comment(self: *Self, s: []const u8) WriteError!void {
            switch (self.state) {
                .start, .after_bom, .after_xml_declaration, .after_structure_end => {},
                .element_start => {
                    try self.write(">");
                    self.indent_depth += 1;
                    try self.writeNewlineAndIndent();
                    self.state = .in_element;
                },
                .in_element => {
                    if (self.options.indent.len > 0) try self.writeNewlineAndIndent();
                },
                .eof => unreachable,
            }
            try self.write("<!--");
            try self.write(s);
            try self.write("-->");
            self.state = .after_structure_end;
        }

        /// 写入处理指令 <?target data?>
        pub fn pi(self: *Self, target: []const u8, data: []const u8) WriteError!void {
            switch (self.state) {
                .start, .after_bom, .after_xml_declaration, .after_structure_end => {},
                .element_start => {
                    try self.write(">");
                    self.indent_depth += 1;
                    try self.writeNewlineAndIndent();
                    self.state = .in_element;
                },
                .in_element => {
                    if (self.options.indent.len > 0) try self.writeNewlineAndIndent();
                },
                .eof => unreachable,
            }
            try self.write("<?");
            try self.write(target);
            if (data.len > 0) {
                try self.writeByte(' ');
                try self.write(data);
            }
            try self.write("?>");
            self.state = .after_structure_end;
        }

        /// 完成文档写入（断言元素栈已清空）
        /// 如果 trailing_newline 选项为 true 则追加换行
        pub fn eof(self: *Self) WriteError!void {
            std.debug.assert(self.element_names.items.len == 0);
            if (self.options.trailing_newline and self.options.indent.len > 0) {
                try self.write("\n");
            }
            self.state = .eof;
        }

        /// 便捷方法：写入一个只含文本内容的完整元素
        /// 等价于 elementStart + text + elementEnd
        pub fn textElement(self: *Self, name: []const u8, content: []const u8) WriteError!void {
            try self.elementStart(name);
            try self.text(content);
            // text() 会将状态改为 in_element，但当前没有子元素
            // 直接写入结束标签
            const stored_name = if (self.element_names.items.len > 0)
                self.element_names.pop().?
            else
                return WriteError.IllegalState;
            defer self.gpa.free(stored_name);
            try self.write("</");
            try self.write(stored_name);
            try self.write(">");
            if (self.indent_depth > 0) self.indent_depth -= 1;
            self.state = .after_structure_end;
        }
    };
}

/// 创建输出到 `std.ArrayList(u8)` 的 Writer 便捷函数
/// 返回值包含 Writer 本身和底层 ArrayList
pub fn bufferWriter(gpa: Allocator, options: Options) BufferWriterResult {
    const al: std.ArrayList(u8) = .{};
    return .{ .buf = al, .options = options, .gpa = gpa };
}

/// `bufferWriter` 的辅助结构（已废弃，改用 createBufferWriter）
pub const BufferWriterResult = struct {
    buf: std.ArrayList(u8),
    options: Options,
    gpa: Allocator,
};

/// 创建写入 `std.ArrayList(u8)` 的 XmlWriter，方便测试和内存中构建
pub fn XmlWriter(comptime OutWriterT: type) type {
    return Writer(OutWriterT);
}

/// 将 XML 文档写入文件（创建或覆盖）
/// content_fn: 回调函数，接收 Writer 指针，在其中写入文档内容
pub fn writeToFile(
    gpa: Allocator,
    path: []const u8,
    options: Options,
    context: anytype,
    comptime content_fn: fn (ctx: @TypeOf(context), w: *Writer(std.io.AnyWriter)) WriteError!void,
) !void {
    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    var bw = std.io.bufferedWriter(file.deprecatedWriter());
    var w = Writer(std.io.AnyWriter).init(gpa, bw.writer().any(), options);
    defer w.deinit();
    try content_fn(context, &w);
    try bw.flush();
}

// ─────────────────────────── 单元测试 ───────────────────────────

test "Writer - basic document" {
    var buf = std.ArrayList(u8){};
    defer buf.deinit(std.testing.allocator);

    var w = Writer(std.io.AnyWriter).init(
        std.testing.allocator,
        buf.writer(std.testing.allocator).any(),
        .{ .indent = "  " },
    );
    defer w.deinit();

    try w.xmlDeclaration("UTF-8", null);
    try w.elementStart("root");
    try w.elementStart("child");
    try w.attribute("id", "1");
    try w.text("Hello, World!");
    try w.elementEnd();
    try w.elementStart("empty");
    try w.elementEndEmpty();
    try w.elementEnd();
    try w.eof();

    const expected =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<root>
        \\  <child id="1">Hello, World!</child>
        \\  <empty/>
        \\</root>
        \\
    ;
    try std.testing.expectEqualStrings(expected, buf.items);
}

test "Writer - text escaping" {
    var buf = std.ArrayList(u8){};
    defer buf.deinit(std.testing.allocator);

    var w = Writer(std.io.AnyWriter).init(
        std.testing.allocator,
        buf.writer(std.testing.allocator).any(),
        .{ .indent = "" },
    );
    defer w.deinit();

    try w.elementStart("root");
    try w.text("a & b < c > d \"e\"");
    try w.elementEnd();
    try w.eof();

    try std.testing.expectEqualStrings(
        "<root>a &amp; b &lt; c &gt; d \"e\"</root>",
        buf.items,
    );
}

test "Writer - cdata and comment" {
    var buf = std.ArrayList(u8){};
    defer buf.deinit(std.testing.allocator);

    var w = Writer(std.io.AnyWriter).init(
        std.testing.allocator,
        buf.writer(std.testing.allocator).any(),
        .{ .indent = "" },
    );
    defer w.deinit();

    try w.elementStart("root");
    try w.comment(" test ");
    try w.cdata("<raw>data</raw>");
    try w.elementEnd();
    try w.eof();

    try std.testing.expectEqualStrings(
        "<root><!-- test --><![CDATA[<raw>data</raw>]]></root>",
        buf.items,
    );
}
