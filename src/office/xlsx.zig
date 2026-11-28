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
