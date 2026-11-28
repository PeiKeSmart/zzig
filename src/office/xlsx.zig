//! 最小 XLSX 写入（SpreadsheetML，单/多 sheet；**inlineStr** 存储，不建 sharedStrings）。
//!
//! 定位：给面板类项目做「导出 Excel / 下载导入模板」用，**不引第三方库**：
//! 底层是 `zzig.zip.Writer`，本文件只负责拼 OOXML 的 5 个必要部件。
//!
//! 为什么用 `inlineStr`：字符串直接写进单元格，省掉 `sharedStrings.xml` 与「共享表索引」这层，
//! 部件更少、出错面更小；代价是文件稍大（导出场景可接受）。
//!
//! 明确不支持（需要再加，不要假装支持）：公式、样式/字体/颜色、合并单元格、列宽自适应、
//! 日期格式化（日期请按文本输出，如 `2026-11-28 10:00:00`）、ZIP64（>4GB）。
//!
//! ```zig
//! var w = xlsx.Writer.init(gpa);
//! defer w.deinit();
//! try w.addHeader(&.{ "编号", "名称" });
//! try w.addRow(&.{ .{ .int = 1 }, .{ .text = "张三" } });
//! const bytes = try w.finishAlloc(arena); // 调用方负责 free（或放 arena）
//! ```

const std = @import("std");
const zip = @import("../archive/zip.zig");

pub const Cell = union(enum) {
    text: []const u8,
    int: i64,
    float: f64,
    boolean: bool,
    blank,
};

pub const Sheet = struct {
    name: []const u8,
    rows: std.ArrayListUnmanaged([]const Cell) = .empty,
};

pub const Writer = struct {
    gpa: std.mem.Allocator,
    sheets: std.ArrayListUnmanaged(Sheet) = .empty,

    pub fn init(gpa: std.mem.Allocator) Writer {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Writer) void {
        for (self.sheets.items) |*sheet| {
            for (sheet.rows.items) |row| {
                for (row) |cell| {
                    switch (cell) {
                        .text => |text| self.gpa.free(text),
                        else => {},
                    }
                }
                self.gpa.free(@constCast(row));
            }
            sheet.rows.deinit(self.gpa);
            self.gpa.free(sheet.name);
        }
        self.sheets.deinit(self.gpa);
    }

    /// 追加一个 sheet 并返回它的下标（第一个自动叫 `Sheet1`）。
    pub fn addSheet(self: *Writer, name: []const u8) !usize {
        const final_name = if (name.len > 0)
            try self.gpa.dupe(u8, name)
        else
            try std.fmt.allocPrint(self.gpa, "Sheet{d}", .{self.sheets.items.len + 1});
        errdefer self.gpa.free(final_name);
        try self.sheets.append(self.gpa, .{ .name = final_name });
        return self.sheets.items.len - 1;
    }

    /// 在指定 sheet 追加一行。
    ///
    /// **会复制** `cells` 与其中的字符串：调用方可以传栈上临时数组/临时文本，
    /// 只要在 `finishAlloc` 之前不必保活（不复制的话，临时数组出作用域后
    /// 读 union 的 tag 就是「switch on corrupt value」，2026-11-28 踩过）。
    pub fn addRow(self: *Writer, sheet_index: usize, cells: []const Cell) !void {
        if (sheet_index >= self.sheets.items.len) return error.SheetNotFound;
        const copy = try self.gpa.alloc(Cell, cells.len);
        errdefer self.gpa.free(copy);
        var copied: usize = 0;
        errdefer {
            for (copy[0..copied]) |item| {
                switch (item) {
                    .text => |text| self.gpa.free(text),
                    else => {},
                }
            }
        }
        for (cells, 0..) |cell, i| {
            copy[i] = switch (cell) {
                .text => |text| .{ .text = try self.gpa.dupe(u8, text) },
                else => cell,
            };
            copied += 1;
        }
        try self.sheets.items[sheet_index].rows.append(self.gpa, copy);
    }

    /// 第一行当表头（纯文本）。
    pub fn addHeader(self: *Writer, sheet_index: usize, names: []const []const u8) !void {
        const cells = try self.gpa.alloc(Cell, names.len);
        defer self.gpa.free(cells);
        for (names, 0..) |name, i| cells[i] = .{ .text = name };
        try self.addRow(sheet_index, cells);
    }
    /// 生成 xlsx 字节（调用方负责 free）。
    pub fn finishAlloc(self: *Writer, a: std.mem.Allocator) ![]u8 {
        if (self.sheets.items.len == 0) _ = try self.addSheet("Sheet1");

        var w = zip.Writer.init(self.gpa);
        defer w.deinit();

        // 每个部件的文本都要自己释放（`addEntry` 只读，不接管所有权）
        const content_types = try contentTypesAlloc(self.gpa, self.sheets.items.len);
        defer self.gpa.free(content_types);
        try w.addEntry("[Content_Types].xml", content_types, .deflate);

        const root_rels = try rootRelsAlloc(self.gpa);
        defer self.gpa.free(root_rels);
        try w.addEntry("_rels/.rels", root_rels, .deflate);

        const workbook = try workbookAlloc(self.gpa, self.sheets.items);
        defer self.gpa.free(workbook);
        try w.addEntry("xl/workbook.xml", workbook, .deflate);

        const workbook_rels = try workbookRelsAlloc(self.gpa, self.sheets.items.len);
        defer self.gpa.free(workbook_rels);
        try w.addEntry("xl/_rels/workbook.xml.rels", workbook_rels, .deflate);

        for (self.sheets.items, 0..) |sheet, index| {
            const path = try std.fmt.allocPrint(self.gpa, "xl/worksheets/sheet{d}.xml", .{index + 1});
            defer self.gpa.free(path);
            const xml = try sheetXmlAlloc(self.gpa, sheet);
            defer self.gpa.free(xml);
            try w.addEntry(path, xml, .deflate);
        }

        const bytes = try w.finish();
        defer self.gpa.free(bytes);
        return try a.dupe(u8, bytes);
    }
};

fn contentTypesAlloc(gpa: std.mem.Allocator, sheet_count: usize) ![]u8 {
    var b: std.Io.Writer.Allocating = .init(gpa);
    defer b.deinit();
    try b.writer.writeAll(
        \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        \\<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        \\<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        \\<Default Extension="xml" ContentType="application/xml"/>
        \\<Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
        \\
    );
    var i: usize = 0;
    while (i < sheet_count) : (i += 1) {
        try b.writer.print(
            "<Override PartName=\"/xl/worksheets/sheet{d}.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>\n",
            .{i + 1},
        );
    }
    try b.writer.writeAll("</Types>\n");
    return b.toOwnedSlice();
}

fn rootRelsAlloc(gpa: std.mem.Allocator) ![]u8 {
    return gpa.dupe(u8,
        \\<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        \\<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        \\<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
        \\</Relationships>
        \\
    );
}

fn workbookAlloc(gpa: std.mem.Allocator, sheets: []const Sheet) ![]u8 {
    var b: std.Io.Writer.Allocating = .init(gpa);
    defer b.deinit();
    try b.writer.writeAll(
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" ++
            "<workbook xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\" " ++
            "xmlns:r=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships\">\n<sheets>\n",
    );
    for (sheets, 0..) |sheet, i| {
        try b.writer.writeAll("<sheet name=\"");
        try writeXmlEscaped(&b.writer, sheet.name);
        try b.writer.print("\" sheetId=\"{d}\" r:id=\"rId{d}\"/>\n", .{ i + 1, i + 1 });
    }
    try b.writer.writeAll("</sheets>\n</workbook>\n");
    return b.toOwnedSlice();
}

fn workbookRelsAlloc(gpa: std.mem.Allocator, sheet_count: usize) ![]u8 {
    var b: std.Io.Writer.Allocating = .init(gpa);
    defer b.deinit();
    try b.writer.writeAll(
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" ++
            "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">\n",
    );
    var i: usize = 0;
    while (i < sheet_count) : (i += 1) {
        try b.writer.print(
            "<Relationship Id=\"rId{d}\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet{d}.xml\"/>\n",
            .{ i + 1, i + 1 },
        );
    }
    try b.writer.writeAll("</Relationships>\n");
    return b.toOwnedSlice();
}

fn sheetXmlAlloc(gpa: std.mem.Allocator, sheet: Sheet) ![]u8 {
    var b: std.Io.Writer.Allocating = .init(gpa);
    defer b.deinit();
    try b.writer.writeAll(
        "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n" ++
            "<worksheet xmlns=\"http://schemas.openxmlformats.org/spreadsheetml/2006/main\">\n<sheetData>\n",
    );
    for (sheet.rows.items, 0..) |cells, row_index| {
        const row_no = row_index + 1;
        try b.writer.print("<row r=\"{d}\">", .{row_no});
        for (cells, 0..) |cell, col_index| {
            const ref = try cellRefAlloc(gpa, col_index, row_no);
            defer gpa.free(ref);
            switch (cell) {
                .blank => {},
                .text => |text| {
                    try b.writer.print("<c r=\"{s}\" t=\"inlineStr\"><is><t xml:space=\"preserve\">", .{ref});
                    try writeXmlEscaped(&b.writer, text);
                    try b.writer.writeAll("</t></is></c>");
                },
                .int => |value| try b.writer.print("<c r=\"{s}\"><v>{d}</v></c>", .{ ref, value }),
                .float => |value| try b.writer.print("<c r=\"{s}\"><v>{d}</v></c>", .{ ref, value }),
                .boolean => |value| try b.writer.print("<c r=\"{s}\" t=\"b\"><v>{d}</v></c>", .{ ref, @intFromBool(value) }),
            }
        }
        try b.writer.writeAll("</row>\n");
    }
    try b.writer.writeAll("</sheetData>\n</worksheet>\n");
    return b.toOwnedSlice();
}

/// 0 → `A`、25 → `Z`、26 → `AA`（Excel 列名）。
fn cellRefAlloc(gpa: std.mem.Allocator, col_index: usize, row_no: usize) ![]u8 {
    var letters: [8]u8 = undefined;
    var n = col_index + 1;
    var len: usize = 0;
    while (n > 0) {
        const rem = (n - 1) % 26;
        letters[len] = @intCast('A' + rem);
        len += 1;
        n = (n - 1) / 26;
    }
    // 反转字母
    var i: usize = 0;
    while (i < len / 2) : (i += 1) {
        const tmp = letters[i];
        letters[i] = letters[len - 1 - i];
        letters[len - 1 - i] = tmp;
    }
    return std.fmt.allocPrint(gpa, "{s}{d}", .{ letters[0..len], row_no });
}

fn writeXmlEscaped(w: *std.Io.Writer, text: []const u8) !void {
    for (text) |ch| {
        switch (ch) {
            '&' => try w.writeAll("&amp;"),
            '<' => try w.writeAll("&lt;"),
            '>' => try w.writeAll("&gt;"),
            '"' => try w.writeAll("&quot;"),
            '\'' => try w.writeAll("&apos;"),
            // XML 1.0 不允许的控制字符：直接丢掉，避免整份文件损坏
            0...8, 11, 12, 14...31 => {},
            else => try w.writeByte(ch),
        }
    }
}

// ===========================================================================
// 读取（导入场景：把 sheet1 读成「行 × 列」文本）
// ===========================================================================

/// 读取结果：`rows[i][j]` 是单元格文本（空单元格是空串）。
pub const Reader = struct {
    gpa: std.mem.Allocator,
    /// 共享字符串表（`xl/sharedStrings.xml`；没有该部件时为空）
    shared: []const []const u8 = &.{},
    sheet_xml: []const u8 = "",
    rows: []const []const []const u8 = &.{},

    /// 解析 xlsx 字节（默认取 `xl/worksheets/sheet1.xml`）。
    ///
    /// 只支持导入需要的子集：`t="s"`（共享串）、`t="inlineStr"`、`t="str"`、`t="b"`、
    /// 以及无 `t` 的数值单元格。样式、公式**不求值**（公式单元格取缓存的 `<v>`）。
    pub fn init(gpa: std.mem.Allocator, bytes: []const u8) !Reader {
        var self = Reader{ .gpa = gpa };
        errdefer self.deinit();

        var zip_reader = try zip.Reader.init(gpa, bytes);
        defer zip_reader.deinit();

        if (zip_reader.find("xl/sharedStrings.xml")) |index| {
            const xml = try zip_reader.extractAlloc(index);
            defer gpa.free(xml);
            self.shared = try parseSharedStrings(gpa, xml);
        }

        const sheet_index = zip_reader.find("xl/worksheets/sheet1.xml") orelse blk: {
            // 单 sheet 但名字不叫 sheet1 的极端情况：取第一个 worksheets/*.xml
            for (0..zip_reader.entries.len) |i| {
                if (std.mem.startsWith(u8, zip_reader.entries[i].name, "xl/worksheets/") and
                    std.mem.endsWith(u8, zip_reader.entries[i].name, ".xml"))
                {
                    break :blk i;
                }
            }
            return error.SheetNotFound;
        };
        const xml = try zip_reader.extractAlloc(sheet_index);
        defer gpa.free(xml);
        self.sheet_xml = try gpa.dupe(u8, xml);

        self.rows = try parseSheet(gpa, self.sheet_xml, self.shared);
        return self;
    }

    pub fn deinit(self: *Reader) void {
        for (self.shared) |item| self.gpa.free(item);
        if (self.shared.len > 0) self.gpa.free(self.shared);
        for (self.rows) |cells_line| {
            for (cells_line) |text| self.gpa.free(text);
            self.gpa.free(cells_line);
        }
        if (self.rows.len > 0) self.gpa.free(self.rows);
        if (self.sheet_xml.len > 0) self.gpa.free(self.sheet_xml);
        self.* = .{ .gpa = self.gpa };
    }

    pub fn rowCount(self: Reader) usize {
        return self.rows.len;
    }

    /// 取一行（越界返回空）。
    pub fn row(self: Reader, index: usize) []const []const u8 {
        if (index >= self.rows.len) return &.{};
        return self.rows[index];
    }

    /// 单元格文本（越界返回空串）。
    pub fn cell(self: Reader, row_index: usize, col_index: usize) []const u8 {
        const r = self.row(row_index);
        if (col_index >= r.len) return "";
        return r[col_index];
    }

    /// 第一行是否就是表头（非空单元格数 > 0）。
    pub fn hasHeader(self: Reader) bool {
        for (self.row(0)) |text| {
            if (std.mem.trim(u8, text, " \t\r\n").len > 0) return true;
        }
        return false;
    }
};

fn parseSharedStrings(gpa: std.mem.Allocator, xml: []const u8) ![]const []const u8 {
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (list.items) |item| gpa.free(item);
        list.deinit(gpa);
    }

    var pos: usize = 0;
    while (nextTag(xml, &pos, "si")) |block| {
        // `<si>` 内可能有多个 `<t>`（富文本分段），拼成一段
        const text = try collectTexts(gpa, block);
        try list.append(gpa, text);
    }
    return try list.toOwnedSlice(gpa);
}

/// 解析 sheet 的 `<row>` / `<c>`，按 `r="A1"` 里的列字母定位（缺列补空）。
fn parseSheet(
    gpa: std.mem.Allocator,
    xml: []const u8,
    shared: []const []const u8,
) ![]const []const []const u8 {
    var rows: std.ArrayListUnmanaged([]const []const u8) = .empty;
    errdefer {
        for (rows.items) |row| {
            for (row) |cell| gpa.free(cell);
            gpa.free(row);
        }
        rows.deinit(gpa);
    }

    var pos: usize = 0;
    while (nextTag(xml, &pos, "row")) |row_block| {
        var cells: std.ArrayListUnmanaged([]const u8) = .empty;
        errdefer {
            for (cells.items) |cell| gpa.free(cell);
            cells.deinit(gpa);
        }

        var cpos: usize = 0;
        while (nextElement(row_block, &cpos, "c")) |element| {
            const col = columnIndex(element.open) orelse cells.items.len;
            // 中间缺列要补空串
            while (cells.items.len < col) try cells.append(gpa, try gpa.dupe(u8, ""));
            const text = try cellText(gpa, element.open, element.inner, shared);
            if (cells.items.len == col) {
                try cells.append(gpa, text);
            } else {
                gpa.free(cells.items[col]);
                cells.items[col] = text;
            }
        }

        try rows.append(gpa, try cells.toOwnedSlice(gpa));
    }
    return try rows.toOwnedSlice(gpa);
}

/// 单元格文本。`t="s"` 查共享串；`inlineStr` 取 `<is>` 里的 `<t>`；其余取 `<v>`。
///
/// 注意：属性（`r` / `t`）在**开标签**上，所以 `open` 与 `inner` 分开传。
fn cellText(
    gpa: std.mem.Allocator,
    open: []const u8,
    inner: []const u8,
    shared: []const []const u8,
) ![]const u8 {
    const kind = attrValue(open, "t") orelse "";
    if (std.mem.eql(u8, kind, "s")) {
        const raw = innerValue(inner, "v") orelse return try gpa.dupe(u8, "");
        const index = std.fmt.parseInt(usize, std.mem.trim(u8, raw, " \t\r\n"), 10) catch return try gpa.dupe(u8, "");
        if (index >= shared.len) return try gpa.dupe(u8, "");
        return try gpa.dupe(u8, shared[index]);
    }
    if (std.mem.eql(u8, kind, "inlineStr")) {
        var pos: usize = 0;
        if (nextTag(inner, &pos, "is")) |is_block| return try collectTexts(gpa, is_block);
        return try gpa.dupe(u8, "");
    }
    if (std.mem.eql(u8, kind, "b")) {
        const raw = innerValue(inner, "v") orelse return try gpa.dupe(u8, "");
        const truthy = !std.mem.eql(u8, std.mem.trim(u8, raw, " \t\r\n"), "0");
        return try gpa.dupe(u8, if (truthy) "1" else "0");
    }
    // `t="str"`（公式文本结果）与无 t（数值）：都走 `<v>`
    const raw = innerValue(inner, "v") orelse return try gpa.dupe(u8, "");
    return try gpa.dupe(u8, std.mem.trim(u8, raw, " \t\r\n"));
}

/// 收集一段 XML 里所有 `<t ...>text</t>` 并拼接（富文本分段会合并）。
fn collectTexts(gpa: std.mem.Allocator, block: []const u8) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(gpa);

    var pos: usize = 0;
    while (nextTag(block, &pos, "t")) |text| {
        try appendUnescaped(gpa, &out, text);
    }
    return try out.toOwnedSlice(gpa);
}

const Element = struct { open: []const u8 = "", inner: []const u8 = "" };

/// 找下一个 `<tag ...>inner</tag>`，同时给出**开标签**（属性在它上面）与 inner。
/// 自闭合返回 `inner = ""`；`pos` 返回后指向 `</tag>` 之后。
fn nextElement(xml: []const u8, pos: *usize, comptime tag: []const u8) ?Element {
    const open_pat = "<" ++ tag;
    const close_pat = "</" ++ tag ++ ">";
    const start = std.mem.indexOfPos(u8, xml, pos.*, open_pat) orelse return null;
    const after = start + open_pat.len;
    if (after < xml.len) {
        const ch = xml[after];
        if (ch != '>' and ch != '/' and ch != ' ' and ch != '\t' and ch != '\r' and ch != '\n') {
            pos.* = after;
            return nextElement(xml, pos, tag);
        }
    }
    const gt = std.mem.indexOfScalarPos(u8, xml, after, '>') orelse return null;
    const open = xml[start .. gt + 1];
    if (gt > 0 and xml[gt - 1] == '/') {
        pos.* = gt + 1;
        return .{ .open = open, .inner = "" };
    }
    if (std.mem.indexOfPos(u8, xml, gt, close_pat)) |close| {
        pos.* = close + close_pat.len;
        return .{ .open = open, .inner = xml[gt + 1 .. close] };
    }
    pos.* = gt + 1;
    return .{ .open = open, .inner = "" };
}

/// 只要 inner 的便捷版（`parseSharedStrings` / `collectTexts` / `innerValue` 用）。
fn nextTag(xml: []const u8, pos: *usize, comptime tag: []const u8) ?[]const u8 {
    const element = nextElement(xml, pos, tag) orelse return null;
    return element.inner;
}

/// `<c r="B3" t="s">` 里的列号（A=0、B=1、AA=26）。
fn columnIndex(cell_block: []const u8) ?usize {
    const ref = attrValue(cell_block[0..@min(cell_block.len, 200)], "r") orelse return null;
    var value: usize = 0;
    var seen: usize = 0;
    for (ref) |ch| {
        if (ch >= 'A' and ch <= 'Z') {
            value = value * 26 + (ch - 'A' + 1);
            seen += 1;
        } else if (ch >= 'a' and ch <= 'z') {
            value = value * 26 + (ch - 'a' + 1);
            seen += 1;
        } else break;
    }
    if (seen == 0) return null;
    return value - 1;
}

fn attrValue(tag_text: []const u8, name: []const u8) ?[]const u8 {
    const pattern = std.fmt.allocPrint(std.heap.page_allocator, "{s}=\"", .{name}) catch return null;
    defer std.heap.page_allocator.free(pattern);

    const idx = std.mem.indexOf(u8, tag_text, pattern) orelse return null;
    const value_start = idx + pattern.len;
    const value_end = std.mem.indexOfScalarPos(u8, tag_text, value_start, '"') orelse return null;
    return tag_text[value_start..value_end];
}

fn innerValue(block: []const u8, comptime tag: []const u8) ?[]const u8 {
    var pos: usize = 0;
    return nextTag(block, &pos, tag);
}

/// 把 XML 文本反转义后写入 `out`（只处理 5 个预定义实体与数字实体）。
fn appendUnescaped(gpa: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '&') {
            if (std.mem.indexOfScalarPos(u8, text, i, ';')) |semi| {
                const entity = text[i + 1 .. semi];
                const replacement: ?u8 = if (std.mem.eql(u8, entity, "amp"))
                    '&'
                else if (std.mem.eql(u8, entity, "lt"))
                    '<'
                else if (std.mem.eql(u8, entity, "gt"))
                    '>'
                else if (std.mem.eql(u8, entity, "quot"))
                    '"'
                else if (std.mem.eql(u8, entity, "apos"))
                    '\''
                else if (std.mem.startsWith(u8, entity, "#x") or std.mem.startsWith(u8, entity, "#X"))
                    decodeCodePoint(entity[2..], 16)
                else if (std.mem.startsWith(u8, entity, "#"))
                    decodeCodePoint(entity[1..], 10)
                else
                    null;
                if (replacement) |byte| {
                    try out.append(gpa, byte);
                    i = semi + 1;
                    continue;
                }
            }
        }
        try out.append(gpa, text[i]);
        i += 1;
    }
}

fn decodeCodePoint(digits: []const u8, base: u8) ?u8 {
    const value = std.fmt.parseInt(u21, digits, base) catch return null;
    if (value > 0x7F) return null; // 只处理 ASCII（导入字段用不到更高位）
    return @intCast(value);
}

test "xlsx.Reader：写出去的能读回来（表头/数字/空单元格/转义/共享串）" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var w = Writer.init(std.testing.allocator);
    defer w.deinit();
    const sheet = try w.addSheet("导入");
    try w.addHeader(sheet, &.{ "帐号", "姓名", "年龄" });
    try w.addRow(sheet, &.{ .{ .text = "zhangsan" }, .{ .text = "张<三>&\"x\"" }, .{ .int = 30 } });
    try w.addRow(sheet, &.{ .{ .text = "" }, .{ .text = "李四" }, .blank });
    const bytes = try w.finishAlloc(a);

    var reader = try Reader.init(std.testing.allocator, bytes);
    defer reader.deinit();

    try std.testing.expectEqual(@as(usize, 3), reader.rowCount());
    try std.testing.expect(reader.hasHeader());
    try std.testing.expectEqualStrings("帐号", reader.cell(0, 0));
    try std.testing.expectEqualStrings("zhangsan", reader.cell(1, 0));
    try std.testing.expectEqualStrings("张<三>&\"x\"", reader.cell(1, 1));
    try std.testing.expectEqualStrings("30", reader.cell(1, 2));
    try std.testing.expectEqualStrings("", reader.cell(2, 0));
    try std.testing.expectEqualStrings("李四", reader.cell(2, 1));
    try std.testing.expectEqualStrings("", reader.cell(2, 2));
}

test "xlsx.Reader：A/B/AA 列定位与缺失列补空" {
    const gpa = std.testing.allocator;
    var list: std.ArrayListUnmanaged(u8) = .empty;
    defer list.deinit(gpa);

    const xml =
        \\<row r="1"><c r="A1" t="inlineStr"><is><t>a</t></is></c><c r="C1" t="inlineStr"><is><t>c</t></is></c></row>
    ;
    const rows = try parseSheet(gpa, xml, &.{});
    defer {
        for (rows) |row| {
            for (row) |cell| gpa.free(cell);
            gpa.free(row);
        }
        gpa.free(rows);
    }
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqual(@as(usize, 3), rows[0].len);
    try std.testing.expectEqualStrings("a", rows[0][0]);
    try std.testing.expectEqualStrings("", rows[0][1]);
    try std.testing.expectEqualStrings("c", rows[0][2]);
}

test "xlsx：生成后能被 zip 读回，含 5 个必要部件与 inlineStr" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var w = Writer.init(std.testing.allocator);
    defer w.deinit();
    const sheet = try w.addSheet("白名单");
    try w.addHeader(sheet, &.{ "SN", "备注" });
    try w.addRow(sheet, &.{ .{ .text = "SN123" }, .{ .text = "含 <尖括号> & 符号" } });
    try w.addRow(sheet, &.{ .{ .int = 42 }, .blank });

    const bytes = try w.finishAlloc(a);
    try std.testing.expect(bytes.len > 500);

    var reader = try zip.Reader.init(std.testing.allocator, bytes);
    defer reader.deinit();
    try std.testing.expect(reader.find("[Content_Types].xml") != null);
    try std.testing.expect(reader.find("_rels/.rels") != null);
    try std.testing.expect(reader.find("xl/workbook.xml") != null);
    try std.testing.expect(reader.find("xl/_rels/workbook.xml.rels") != null);
    const sheet_index = reader.find("xl/worksheets/sheet1.xml") orelse return error.MissingSheet;
    const xml = try reader.extractAlloc(sheet_index);
    defer std.testing.allocator.free(xml);

    try std.testing.expect(std.mem.indexOf(u8, xml, "t=\"inlineStr\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "SN123") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "&lt;尖括号&gt;") != null);
    try std.testing.expect(std.mem.indexOf(u8, xml, "<v>42</v>") != null);
}

test "xlsx：列名进位（0→A、25→Z、26→AA、27→AB）" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { idx: usize, expect: []const u8 }{
        .{ .idx = 0, .expect = "A1" },
        .{ .idx = 25, .expect = "Z1" },
        .{ .idx = 26, .expect = "AA1" },
        .{ .idx = 27, .expect = "AB1" },
    };
    for (cases) |item| {
        const ref = try cellRefAlloc(gpa, item.idx, 1);
        defer gpa.free(ref);
        try std.testing.expectEqualStrings(item.expect, ref);
    }
}
