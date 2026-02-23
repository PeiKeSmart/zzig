// scanner.zig
// XML 底层字节扫描器 / 标记化器
// 参考 XML 1.0 (Fifth Edition): https://www.w3.org/TR/2008/REC-xml-20081126
// 设计原则：零分配、低延迟、跨平台兼容
const std = @import("std");

/// XML 扫描器错误类型
pub const Error = error{
    /// XML 格式不合法
    MalformedXml,
    /// 意外的输入结束
    UnexpectedEof,
    /// 超出缓冲区限制
    BufferOverflow,
};

/// XML Token 类型枚举
pub const TokenType = enum {
    /// 文件结尾
    eof,
    /// XML 声明: <?xml ... ?>
    xml_declaration,
    /// 元素开始标签: <tag attr="val">
    element_start,
    /// 空元素标签: <tag />
    element_empty,
    /// 元素结束标签: </tag>
    element_end,
    /// 文本内容
    text,
    /// CDATA 节: <![CDATA[ ... ]]>
    cdata,
    /// 注释: <!-- ... -->
    comment,
    /// 处理指令: <?target data?>
    pi,
    /// DOCTYPE 声明（跳过）
    doctype,
};

/// 扫描结果 Token
pub const Token = struct {
    typ: TokenType,
    /// 在输入缓冲区中的起始偏移
    start: usize,
    /// 在输入缓冲区中的结束偏移（不含）
    end: usize,

    pub fn slice(self: Token, src: []const u8) []const u8 {
        return src[self.start..self.end];
    }
};

/// 属性 Token（名称 + 值的偏移对）
pub const AttrToken = struct {
    name_start: usize,
    name_end: usize,
    value_start: usize,
    value_end: usize,
    /// 引号字符（'"' 或 '\''）
    quote: u8,

    pub fn name(self: AttrToken, src: []const u8) []const u8 {
        return src[self.name_start..self.name_end];
    }

    pub fn value(self: AttrToken, src: []const u8) []const u8 {
        return src[self.value_start..self.value_end];
    }
};

/// XML 行列位置（1-based）
pub const Location = struct {
    line: usize = 1,
    column: usize = 1,

    /// 根据处理过的字节数更新位置
    pub fn update(self: *Location, data: []const u8) void {
        for (data) |c| {
            if (c == '\n') {
                self.line += 1;
                self.column = 1;
            } else {
                self.column += 1;
            }
        }
    }
};

/// 低级 XML 字节扫描器（无内存分配）
/// 从输入切片逐步扫描，返回 Token 偏移量
pub const Scanner = struct {
    src: []const u8,
    pos: usize,
    loc: Location,

    pub fn init(src: []const u8) Scanner {
        return .{
            .src = src,
            .pos = 0,
            .loc = .{},
        };
    }

    /// 返回当前位置（1-based 行列）
    pub fn location(self: *const Scanner) Location {
        return self.loc;
    }

    /// 查看当前字节，不消耗
    fn peek(self: *const Scanner) ?u8 {
        if (self.pos >= self.src.len) return null;
        return self.src[self.pos];
    }

    /// 查看指定偏移量处的字节
    fn peekAt(self: *const Scanner, offset: usize) ?u8 {
        const idx = self.pos + offset;
        if (idx >= self.src.len) return null;
        return self.src[idx];
    }

    /// 消耗一个字节并更新位置
    fn consume(self: *Scanner) void {
        if (self.pos < self.src.len) {
            const c = self.src[self.pos];
            self.pos += 1;
            if (c == '\n') {
                self.loc.line += 1;
                self.loc.column = 1;
            } else {
                self.loc.column += 1;
            }
        }
    }

    /// 消耗 n 个字节
    fn consumeN(self: *Scanner, n: usize) void {
        var i: usize = 0;
        while (i < n) : (i += 1) self.consume();
    }

    /// 尝试消耗特定字符串前缀，成功返回 true
    fn eat(self: *Scanner, comptime s: []const u8) bool {
        if (self.pos + s.len > self.src.len) return false;
        if (!std.mem.eql(u8, self.src[self.pos .. self.pos + s.len], s)) return false;
        self.pos += s.len;
        // 编译期判断前缀是否含换行：若无则批量加列号，避免逐字节循环
        const has_nl = comptime blk: {
            for (s) |c| {
                if (c == '\n') break :blk true;
            }
            break :blk false;
        };
        if (comptime has_nl) {
            for (s) |c| {
                if (c == '\n') {
                    self.loc.line += 1;
                    self.loc.column = 1;
                } else {
                    self.loc.column += 1;
                }
            }
        } else {
            self.loc.column += s.len;
        }
        return true;
    }

    /// 跳过空白字符（0x20、0x09、0x0D、0x0A）
    fn skipWhitespace(self: *Scanner) void {
        const start = self.pos;
        // 直接 pos++ 无函数调用开销，最后统一 loc.update
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c != ' ' and c != '\t' and c != '\r' and c != '\n') break;
            self.pos += 1;
        }
        if (self.pos > start) self.loc.update(self.src[start..self.pos]);
    }

    /// 检查字节是否为 XML 名称起始字符
    fn isNameStart(c: u8) bool {
        return std.ascii.isAlphabetic(c) or c == '_' or c == ':' or c > 0x7F;
    }

    /// 检查字节是否为 XML 名称字符
    fn isNameChar(c: u8) bool {
        return isNameStart(c) or std.ascii.isDigit(c) or c == '-' or c == '.' or c > 0x7F;
    }

    /// 扫描 XML 名称，返回 (start, end) 偏移
    fn scanName(self: *Scanner) Error!struct { usize, usize } {
        const start = self.pos;
        if (self.pos >= self.src.len) return Error.UnexpectedEof;
        if (!isNameStart(self.src[self.pos])) return Error.MalformedXml;
        self.pos += 1;
        // 直接 pos++ 无函数调用开销，最后统一 loc.update
        while (self.pos < self.src.len and isNameChar(self.src[self.pos])) {
            self.pos += 1;
        }
        self.loc.update(self.src[start..self.pos]);
        return .{ start, self.pos };
    }

    /// 扫描带引号的属性值，返回值内容的 (start, end, quote)
    /// 返回的范围不含引号字符本身
    fn scanQuotedValue(self: *Scanner) Error!struct { usize, usize, u8 } {
        const q = self.peek() orelse return Error.UnexpectedEof;
        if (q != '"' and q != '\'') return Error.MalformedXml;
        self.consume(); // consume opening quote
        const start = self.pos;
        // 用 indexOfScalarPos 直接定位闭合引号，避免逐字节 consume
        const end = std.mem.indexOfScalarPos(u8, self.src, self.pos, q) orelse
            return Error.UnexpectedEof;
        self.loc.update(self.src[self.pos .. end + 1]); // +1 将闭合引号计入位置
        self.pos = end + 1; // 跳过闭合引号
        return .{ start, end, q };
    }

    /// 扫描下一个 Token（主扫描函数）
    pub fn next(self: *Scanner) Error!?Token {
        if (self.pos >= self.src.len) return null;

        // 跳过 BOM（UTF-8: EF BB BF）
        if (self.pos == 0 and self.src.len >= 3 and
            self.src[0] == 0xEF and self.src[1] == 0xBB and self.src[2] == 0xBF)
        {
            self.consumeN(3);
        }

        if (self.pos >= self.src.len) return null;

        const start = self.pos;
        const c = self.src[self.pos];

        // 标签类型处理
        if (c == '<') {
            self.consume();

            // 注释: <!--
            if (self.eat("!--")) {
                // 用 indexOfPos 直接定位 "-->"，避免逐字节扫描
                const end_pos = std.mem.indexOfPos(u8, self.src, self.pos, "-->") orelse
                    return Error.UnexpectedEof;
                self.loc.update(self.src[self.pos .. end_pos + 3]);
                self.pos = end_pos + 3;
                return Token{ .typ = .comment, .start = start, .end = self.pos };
            }

            // CDATA: <![CDATA[
            if (self.eat("![CDATA[")) {
                // 用 indexOfPos 直接定位 "]]>"，避免逐字节扫描
                const end_pos = std.mem.indexOfPos(u8, self.src, self.pos, "]]>") orelse
                    return Error.UnexpectedEof;
                self.loc.update(self.src[self.pos .. end_pos + 3]);
                self.pos = end_pos + 3;
                return Token{ .typ = .cdata, .start = start, .end = self.pos };
            }

            // DOCTYPE: <!DOCTYPE (简单跳过)
            if (self.eat("!DOCTYPE") or self.eat("!doctype")) {
                // 跳过至 '>' 或内部子集 [...]>
                var depth: usize = 0;
                while (self.peek()) |ch| {
                    if (ch == '[') {
                        depth += 1;
                        self.consume();
                    } else if (ch == ']') {
                        if (depth > 0) depth -= 1;
                        self.consume();
                    } else if (ch == '>' and depth == 0) {
                        self.consume();
                        break;
                    } else {
                        self.consume();
                    }
                }
                return Token{ .typ = .doctype, .start = start, .end = self.pos };
            }

            // 处理指令: <?
            if (self.eat("?")) {
                // 检查是否是 XML 声明
                const is_xml_decl = if (self.pos + 3 <= self.src.len)
                    std.ascii.eqlIgnoreCase(self.src[self.pos .. self.pos + 3], "xml") and
                        (self.pos + 3 >= self.src.len or !isNameChar(self.src[self.pos + 3]))
                else
                    false;

                // 扫描至 ?>：用 indexOfPos 一次命中，避免逐字节循环
                const pi_end = std.mem.indexOfPos(u8, self.src, self.pos, "?>") orelse
                    return Error.UnexpectedEof;
                self.loc.update(self.src[self.pos .. pi_end + 2]);
                self.pos = pi_end + 2;
                return Token{
                    .typ = if (is_xml_decl) .xml_declaration else .pi,
                    .start = start,
                    .end = self.pos,
                };
            }

            // 结束标签: </
            if (self.eat("/")) {
                _ = try self.scanName();
                self.skipWhitespace();
                if (self.peek() != @as(?u8, '>')) return Error.MalformedXml;
                self.consume();
                return Token{ .typ = .element_end, .start = start, .end = self.pos };
            }

            // 开始标签: <name ...> 或 <name ... />
            _ = try self.scanName();
            // 扫描属性（直到 > 或 />）
            while (true) {
                self.skipWhitespace();
                const ch = self.peek() orelse return Error.UnexpectedEof;
                if (ch == '>') {
                    self.consume();
                    return Token{ .typ = .element_start, .start = start, .end = self.pos };
                }
                if (ch == '/') {
                    self.consume();
                    if (self.peek() != @as(?u8, '>')) return Error.MalformedXml;
                    self.consume();
                    return Token{ .typ = .element_empty, .start = start, .end = self.pos };
                }
                // 属性名
                _ = try self.scanName();
                self.skipWhitespace();
                if (self.peek() != @as(?u8, '=')) return Error.MalformedXml;
                self.consume();
                self.skipWhitespace();
                _ = try self.scanQuotedValue();
            }
        }

        // 文本内容（非标签字符）：用 indexOfScalarPos 加速（stdlib 内部可 SIMD 化）
        const text_end = std.mem.indexOfScalarPos(u8, self.src, self.pos, '<') orelse self.src.len;
        self.loc.update(self.src[self.pos..text_end]);
        self.pos = text_end;
        return Token{ .typ = .text, .start = start, .end = self.pos };
    }
};

/// 从 XML 声明 Token 中解析属性列表
/// 使用 comptime 已知的小缓冲区存储解析结果
pub const XmlDeclInfo = struct {
    version: ?[]const u8 = null,
    encoding: ?[]const u8 = null,
    standalone: ?bool = null,
};

/// 从 <?xml ... ?> token 的原始切片解析声明信息
/// raw：完整的 <?xml ... ?> 切片
pub fn parseXmlDecl(raw: []const u8) XmlDeclInfo {
    var info = XmlDeclInfo{};
    // raw 形如 "<?xml version="1.0" encoding="UTF-8"?>"
    // 跳过 "<?xml"
    var pos: usize = 5;
    while (pos < raw.len) {
        // 跳过空白
        while (pos < raw.len and (raw[pos] == ' ' or raw[pos] == '\t' or raw[pos] == '\r' or raw[pos] == '\n'))
            pos += 1;
        if (pos >= raw.len or raw[pos] == '?' or raw[pos] == '>') break;

        // 属性名
        const name_start = pos;
        while (pos < raw.len and raw[pos] != '=' and raw[pos] != ' ' and raw[pos] != '\t')
            pos += 1;
        const name_end = pos;

        // '='
        while (pos < raw.len and raw[pos] != '=') pos += 1;
        if (pos >= raw.len) break;
        pos += 1; // consume '='

        // 引号
        if (pos >= raw.len) break;
        const q = raw[pos];
        if (q != '"' and q != '\'') break;
        pos += 1;
        const val_start = pos;
        while (pos < raw.len and raw[pos] != q) pos += 1;
        const val_end = pos;
        if (pos < raw.len) pos += 1; // consume closing quote

        const attr_name = raw[name_start..name_end];
        const attr_value = raw[val_start..val_end];

        if (std.mem.eql(u8, attr_name, "version")) {
            info.version = attr_value;
        } else if (std.mem.eql(u8, attr_name, "encoding")) {
            info.encoding = attr_value;
        } else if (std.mem.eql(u8, attr_name, "standalone")) {
            info.standalone = std.mem.eql(u8, attr_value, "yes");
        }
    }
    return info;
}

/// 解析开始标签的属性列表
/// raw: 完整标签切片，如 "<tag attr="val" />" 或 "<tag attr="val">"
/// out_attrs: 输出属性数组（调用者提供缓冲区）
/// 返回实际解析到的属性数量
pub fn parseElementAttrs(raw: []const u8, out_attrs: []AttrToken) usize {
    var count: usize = 0;
    var pos: usize = 1; // skip '<'

    // 跳过标签名
    while (pos < raw.len and raw[pos] != ' ' and raw[pos] != '\t' and
        raw[pos] != '\r' and raw[pos] != '\n' and raw[pos] != '>' and
        raw[pos] != '/')
    {
        pos += 1;
    }

    while (pos < raw.len and count < out_attrs.len) {
        // 跳过空白
        while (pos < raw.len and (raw[pos] == ' ' or raw[pos] == '\t' or raw[pos] == '\r' or raw[pos] == '\n'))
            pos += 1;

        if (pos >= raw.len) break;
        if (raw[pos] == '>' or raw[pos] == '/') break;

        // 属性名
        const name_start = pos;
        while (pos < raw.len and raw[pos] != '=' and raw[pos] != ' ' and
            raw[pos] != '\t' and raw[pos] != '>' and raw[pos] != '/')
        {
            pos += 1;
        }
        const name_end = pos;
        if (name_start == name_end) break;

        // 跳过空白
        while (pos < raw.len and (raw[pos] == ' ' or raw[pos] == '\t')) pos += 1;
        if (pos >= raw.len or raw[pos] != '=') break;
        pos += 1; // consume '='

        // 跳过空白
        while (pos < raw.len and (raw[pos] == ' ' or raw[pos] == '\t')) pos += 1;
        if (pos >= raw.len) break;

        const q = raw[pos];
        if (q != '"' and q != '\'') break;
        pos += 1;
        const val_start = pos;
        while (pos < raw.len and raw[pos] != q) pos += 1;
        const val_end = pos;
        if (pos < raw.len) pos += 1;

        out_attrs[count] = AttrToken{
            .name_start = name_start,
            .name_end = name_end,
            .value_start = val_start,
            .value_end = val_end,
            .quote = q,
        };
        count += 1;
    }
    return count;
}

/// 从开始/空元素标签中获取元素名称范围
/// raw: 完整标签切片
pub fn elementNameRange(raw: []const u8) struct { usize, usize } {
    var pos: usize = 1; // skip '<'
    const start = pos;
    while (pos < raw.len and raw[pos] != ' ' and raw[pos] != '\t' and
        raw[pos] != '\r' and raw[pos] != '\n' and raw[pos] != '>' and
        raw[pos] != '/')
    {
        pos += 1;
    }
    return .{ start, pos };
}

/// 从结束标签中获取元素名称范围
/// raw: 形如 "</name>" 的切片
pub fn endElementNameRange(raw: []const u8) struct { usize, usize } {
    var pos: usize = 2; // skip '</'
    const start = pos;
    while (pos < raw.len and raw[pos] != ' ' and raw[pos] != '\t' and raw[pos] != '>') {
        pos += 1;
    }
    return .{ start, pos };
}

/// 从 CDATA 节中提取内容范围
/// raw: 形如 "<![CDATA[ ... ]]>" 的切片
pub fn cdataContentRange(raw: []const u8) struct { usize, usize } {
    const prefix = "<![CDATA[";
    const suffix = "]]>";
    if (raw.len < prefix.len + suffix.len) return .{ 0, 0 };
    return .{ prefix.len, raw.len - suffix.len };
}

/// 从注释中提取内容范围
/// raw: 形如 "<!-- ... -->" 的切片
pub fn commentContentRange(raw: []const u8) struct { usize, usize } {
    const prefix = "<!--";
    const suffix = "-->";
    if (raw.len < prefix.len + suffix.len) return .{ 0, 0 };
    return .{ prefix.len, raw.len - suffix.len };
}

/// XML 实体引用解码
/// 将 &amp; &lt; &gt; &apos; &quot; 替换为对应字符
/// 输出写入 writer；*已分配* 的返回为 true，直接切片引用返回为 false
pub fn decodeText(src: []const u8, writer: anytype) !void {
    var pos: usize = 0;
    while (pos < src.len) {
        const amp_pos = std.mem.indexOfScalarPos(u8, src, pos, '&') orelse {
            try writer.writeAll(src[pos..]);
            break;
        };
        try writer.writeAll(src[pos..amp_pos]);
        pos = amp_pos + 1;

        // 找到 ';'
        const semi = std.mem.indexOfScalarPos(u8, src, pos, ';') orelse {
            try writer.writeAll("&");
            continue;
        };
        const entity = src[pos..semi];
        pos = semi + 1;

        if (std.mem.eql(u8, entity, "amp")) {
            try writer.writeByte('&');
        } else if (std.mem.eql(u8, entity, "lt")) {
            try writer.writeByte('<');
        } else if (std.mem.eql(u8, entity, "gt")) {
            try writer.writeByte('>');
        } else if (std.mem.eql(u8, entity, "apos")) {
            try writer.writeByte('\'');
        } else if (std.mem.eql(u8, entity, "quot")) {
            try writer.writeByte('"');
        } else if (entity.len > 1 and entity[0] == '#') {
            // 字符引用
            const num_str = entity[1..];
            const code_point: u21 = blk: {
                if (num_str.len > 1 and (num_str[0] == 'x' or num_str[0] == 'X')) {
                    break :blk @intCast(std.fmt.parseInt(u32, num_str[1..], 16) catch 0xFFFD);
                } else {
                    break :blk @intCast(std.fmt.parseInt(u32, num_str, 10) catch 0xFFFD);
                }
            };
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(code_point, &buf) catch 1;
            try writer.writeAll(buf[0..len]);
        } else {
            // 未知实体，原样输出
            try writer.writeByte('&');
            try writer.writeAll(entity);
            try writer.writeByte(';');
        }
    }
}

test "scanner - basic element" {
    const src = "<root><child>text</child></root>";
    var scanner = Scanner.init(src);

    const t1 = (try scanner.next()).?;
    try std.testing.expectEqual(TokenType.element_start, t1.typ);
    try std.testing.expectEqualStrings("<root>", t1.slice(src));

    const t2 = (try scanner.next()).?;
    try std.testing.expectEqual(TokenType.element_start, t2.typ);
    try std.testing.expectEqualStrings("<child>", t2.slice(src));

    const t3 = (try scanner.next()).?;
    try std.testing.expectEqual(TokenType.text, t3.typ);
    try std.testing.expectEqualStrings("text", t3.slice(src));

    const t4 = (try scanner.next()).?;
    try std.testing.expectEqual(TokenType.element_end, t4.typ);

    const t5 = (try scanner.next()).?;
    try std.testing.expectEqual(TokenType.element_end, t5.typ);

    try std.testing.expect(try scanner.next() == null);
}

test "scanner - xml declaration" {
    const src = "<?xml version=\"1.0\" encoding=\"UTF-8\"?><root/>";
    var scanner = Scanner.init(src);

    const t1 = (try scanner.next()).?;
    try std.testing.expectEqual(TokenType.xml_declaration, t1.typ);

    const decl = parseXmlDecl(t1.slice(src));
    try std.testing.expectEqualStrings("1.0", decl.version.?);
    try std.testing.expectEqualStrings("UTF-8", decl.encoding.?);

    const t2 = (try scanner.next()).?;
    try std.testing.expectEqual(TokenType.element_empty, t2.typ);
}

test "scanner - attributes" {
    const src = "<element id=\"42\" name='hello'/>";
    var scanner = Scanner.init(src);

    const tok = (try scanner.next()).?;
    try std.testing.expectEqual(TokenType.element_empty, tok.typ);

    var attrs: [8]AttrToken = undefined;
    const count = parseElementAttrs(tok.slice(src), &attrs);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqualStrings("id", attrs[0].name(src));
    try std.testing.expectEqualStrings("42", attrs[0].value(src));
    try std.testing.expectEqualStrings("name", attrs[1].name(src));
    try std.testing.expectEqualStrings("hello", attrs[1].value(src));
}

test "scanner - cdata and comment" {
    const src = "<!-- comment --><![CDATA[raw <data>]]>";
    var scanner = Scanner.init(src);

    const t1 = (try scanner.next()).?;
    try std.testing.expectEqual(TokenType.comment, t1.typ);
    const cr = commentContentRange(t1.slice(src));
    try std.testing.expectEqualStrings(" comment ", t1.slice(src)[cr.@"0"..cr.@"1"]);

    const t2 = (try scanner.next()).?;
    try std.testing.expectEqual(TokenType.cdata, t2.typ);
    const cr2 = cdataContentRange(t2.slice(src));
    try std.testing.expectEqualStrings("raw <data>", t2.slice(src)[cr2.@"0"..cr2.@"1"]);
}

test "decodeText" {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(std.testing.allocator);
    try decodeText("hello &amp; &lt;world&gt;", buf.writer(std.testing.allocator));
    try std.testing.expectEqualStrings("hello & <world>", buf.items);
}
