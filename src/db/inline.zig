//! SQL 参数**客户端内联**（把 `?` 按出现顺序替换成字面量）。
//!
//! 为什么需要：有些库/通道**没有预处理语句**，服务端根本不认 `?`——
//! - TDengine REST（`POST /rest/sql`，只有纯文本 SQL）；
//! - ClickHouse HTTP（`POST /?database=...`，也不做参数绑定）。
//!
//! 这两家只能把参数渲染成字面量再发。渲染走 `Value.toSqlLiteralAlloc`（字符串单引号双写、
//! 时间按方言文本、NULL 写 `NULL`），扫描时**跳过** `'...'`（含 `''` 转义）、`"..."`、
//! `` `...` ``、`--` 行注释、`/* */` 块注释里的 `?`——否则 `WHERE Note LIKE '%?%'` 会被改坏。
//!
//! 口径与 `dialect.rewritePlaceholdersAlloc` 不同：那个是**换占位符写法**（`?` → `$1`/`@p0`），
//! 这个是**换成立面量**（只有真没有绑定的通道才用，安全性依赖调用方不做字符串拼接）。

const std = @import("std");
const Value = @import("value.zig").Value;

pub fn inlineParamsAlloc(a: std.mem.Allocator, sql: []const u8, params: []const Value) ![]u8 {
    if (params.len == 0) return a.dupe(u8, sql);

    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(a);

    var i: usize = 0;
    var next: usize = 0;
    while (i < sql.len) {
        const c = sql[i];
        switch (c) {
            '\'', '"', '`' => {
                const quote = c;
                try out.append(a, c);
                i += 1;
                while (i < sql.len) {
                    try out.append(a, sql[i]);
                    if (sql[i] == quote) {
                        // 双写转义：`''` 是一个引号，仍在字符串内
                        if (i + 1 < sql.len and sql[i + 1] == quote) {
                            try out.append(a, sql[i + 1]);
                            i += 2;
                            continue;
                        }
                        i += 1;
                        break;
                    }
                    i += 1;
                }
            },
            '-' => {
                if (i + 1 < sql.len and sql[i + 1] == '-') {
                    while (i < sql.len and sql[i] != '\n') : (i += 1) try out.append(a, sql[i]);
                } else {
                    try out.append(a, c);
                    i += 1;
                }
            },
            '/' => {
                if (i + 1 < sql.len and sql[i + 1] == '*') {
                    try out.appendSlice(a, "/*");
                    i += 2;
                    while (i + 1 < sql.len and !(sql[i] == '*' and sql[i + 1] == '/')) : (i += 1) try out.append(a, sql[i]);
                    if (i + 1 < sql.len) {
                        try out.appendSlice(a, "*/");
                        i += 2;
                    }
                } else {
                    try out.append(a, c);
                    i += 1;
                }
            },
            '?' => {
                if (next >= params.len) {
                    // 占位符多于参数：原样留下，让服务端报错（比静默吞掉更可诊断）
                    try out.append(a, '?');
                    i += 1;
                    continue;
                }
                const lit = try params[next].toSqlLiteralAlloc(a);
                defer a.free(lit);
                try out.appendSlice(a, lit);
                next += 1;
                i += 1;
            },
            else => {
                try out.append(a, c);
                i += 1;
            },
        }
    }
    return out.toOwnedSlice(a);
}

// ── 测试 ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "参数内联：字符串转义与注释保护" {
    const a = testing.allocator;

    const got = try inlineParamsAlloc(a, "INSERT INTO t VALUES (?, 'a?b', ?, \"c?d\") -- e?\n", &.{
        .{ .int = 7 },
        .{ .text = "O'Reilly" },
    });
    defer a.free(got);

    // 字符串里的 ? 与注释里的 ? 都不能被替换
    try testing.expect(std.mem.indexOf(u8, got, "7, 'a?b', 'O''Reilly', \"c?d\"") != null);
}

test "参数内联：无参数原样返回；多余占位符原样保留" {
    const a = testing.allocator;

    const same = try inlineParamsAlloc(a, "SELECT ?", &.{});
    defer a.free(same);
    try testing.expectEqualStrings("SELECT ?", same);

    const extra = try inlineParamsAlloc(a, "SELECT ?, ?", &.{.{ .int = 1 }});
    defer a.free(extra);
    try testing.expectEqualStrings("SELECT 1, ?", extra);
}

test "参数内联：块注释里的占位符不被替换" {
    const a = testing.allocator;
    const got = try inlineParamsAlloc(a, "SELECT /* ? */ ? /* ? */", &.{.{ .text = "x" }});
    defer a.free(got);
    try testing.expectEqualStrings("SELECT /* ? */ 'x' /* ? */", got);
}
