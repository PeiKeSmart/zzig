const std = @import("std");

/// 菜单选项结构
pub const MenuItem = struct {
    key: []const u8, // 选项编号或按键
    label: []const u8, // 显示文本
    description: ?[]const u8 = null, // 可选的详细描述
};

/// 菜单配置
pub const MenuConfig = struct {
    title: []const u8, // 菜单标题
    prompt: []const u8 = "请选择: ", // 输入提示
    default_key: ?[]const u8 = null, // 默认选项
    show_keys: bool = true, // 是否显示按键提示
};

/// 读取单行输入（跨平台兼容）
/// 适用于 Zig 0.15.2+
pub fn readLine(allocator: std.mem.Allocator) ![]u8 {
    const builtin = @import("builtin");

    var buffer: [4096]u8 = undefined;
    const bytes_read = if (builtin.os.tag == .windows) blk: {
        const w = std.os.windows;
        const stdin_handle = w.kernel32.GetStdHandle(w.STD_INPUT_HANDLE) orelse return error.InvalidHandle;
        if (stdin_handle == w.INVALID_HANDLE_VALUE) return error.InvalidHandle;

        var bytes: w.DWORD = 0;
        if (w.kernel32.ReadFile(stdin_handle, &buffer, buffer.len, &bytes, null) == 0) {
            return error.ReadFailed;
        }
        break :blk @as(usize, bytes);
    } else blk: {
        break :blk try std.posix.read(std.posix.STDIN_FILENO, &buffer);
    };

    if (bytes_read == 0) return error.EndOfStream;

    // 去除换行符（\r\n 或 \n）
    const line = buffer[0..bytes_read];
    const trimmed = std.mem.trimRight(u8, line, &[_]u8{ '\r', '\n' });
    return try allocator.dupe(u8, trimmed);
}

/// 显示菜单并返回用户选择
/// 返回 null 表示用户输入为空且无默认值
pub fn showMenu(allocator: std.mem.Allocator, config: MenuConfig, items: []const MenuItem) !?[]u8 {
    // 显示标题
    std.debug.print("\n{s}\n", .{config.title});

    // 显示菜单项
    for (items) |item| {
        if (config.show_keys) {
            if (item.description) |desc| {
                std.debug.print("  {s}) {s} - {s}\n", .{ item.key, item.label, desc });
            } else {
                std.debug.print("  {s}) {s}\n", .{ item.key, item.label });
            }
        } else {
            std.debug.print("  {s}\n", .{item.label});
        }
    }

    // 显示提示
    if (config.default_key) |default| {
        std.debug.print("{s}(默认 {s}): ", .{ config.prompt, default });
    } else {
        std.debug.print("{s}", .{config.prompt});
    }

    // 读取输入
    const input = readLine(allocator) catch |err| {
        if (err == error.EndOfStream) {
            // EOF，使用默认值
            if (config.default_key) |default| {
                return try allocator.dupe(u8, default);
            }
            return null;
        }
        return err;
    };

    // 如果输入为空，使用默认值
    if (input.len == 0) {
        if (config.default_key) |default| {
            return try allocator.dupe(u8, default);
        }
        return null;
    }

    return input;
}

/// 查找菜单项（根据用户输入的 key）
pub fn findMenuItem(items: []const MenuItem, key: []const u8) ?MenuItem {
    for (items) |item| {
        if (std.mem.eql(u8, item.key, key)) {
            return item;
        }
    }
    return null;
}

/// 读取字符串输入（带提示和默认值）
pub fn readString(allocator: std.mem.Allocator, prompt: []const u8, default_value: ?[]const u8) ![]u8 {
    if (default_value) |default| {
        std.debug.print("{s}(默认 {s}): ", .{ prompt, default });
    } else {
        std.debug.print("{s}", .{prompt});
    }

    const input = try readLine(allocator);

    if (input.len == 0) {
        allocator.free(input);
        if (default_value) |default| {
            return try allocator.dupe(u8, default);
        }
        return error.EmptyInput;
    }

    return input;
}

/// 读取整数输入（带提示和默认值）
pub fn readInt(comptime T: type, allocator: std.mem.Allocator, prompt: []const u8, default_value: ?T) !T {
    if (default_value) |default| {
        std.debug.print("{s}(默认 {d}): ", .{ prompt, default });
    } else {
        std.debug.print("{s}", .{prompt});
    }

    const input = try readLine(allocator);
    defer allocator.free(input);

    if (input.len == 0) {
        if (default_value) |default| {
            return default;
        }
        return error.EmptyInput;
    }

    return try std.fmt.parseUnsigned(T, input, 10);
}

/// 读取布尔值输入（y/n，带默认值）
pub fn readBool(allocator: std.mem.Allocator, prompt: []const u8, default_value: ?bool) !bool {
    const default_str = if (default_value) |default|
        if (default) "y" else "n"
    else
        null;

    if (default_str) |str| {
        std.debug.print("{s} (y/n, 默认 {s}): ", .{ prompt, str });
    } else {
        std.debug.print("{s} (y/n): ", .{prompt});
    }

    const input = try readLine(allocator);
    defer allocator.free(input);

    if (input.len == 0) {
        if (default_value) |default| {
            return default;
        }
        return error.EmptyInput;
    }

    // 修复：使用局部缓冲区进行小写转换
    var lower_buf: [8]u8 = undefined;
    const len = @min(input.len, lower_buf.len);
    const lower = std.ascii.lowerString(lower_buf[0..len], input[0..len]);
    return std.mem.startsWith(u8, lower, "y") or std.mem.startsWith(u8, lower, "yes");
}

/// 确认操作（默认为否）
pub fn confirm(allocator: std.mem.Allocator, prompt: []const u8) !bool {
    return readBool(allocator, prompt, false);
}

/// 多级菜单导航结果
pub const MenuResult = union(enum) {
    selected: []const u8, // 选中的项
    back, // 返回上一级
    exit, // 退出
};

/// 清屏（跨平台）
pub fn clearScreen() void {
    const builtin = @import("builtin");
    if (builtin.os.tag == .windows) {
        _ = std.process.Child.run(.{
            .allocator = std.heap.page_allocator,
            .argv = &[_][]const u8{"cls"},
        }) catch {};
    } else {
        _ = std.process.Child.run(.{
            .allocator = std.heap.page_allocator,
            .argv = &[_][]const u8{"clear"},
        }) catch {};
    }
}

test "readLine basic" {
    // 测试基本的输入读取功能
    // 注意：由于需要实际输入，这里只做编译检查
    const allocator = std.testing.allocator;
    _ = allocator;
    // const input = try readLine(allocator);
    // defer allocator.free(input);
}

test "findMenuItem" {
    const items = [_]MenuItem{
        .{ .key = "1", .label = "选项1" },
        .{ .key = "2", .label = "选项2" },
        .{ .key = "3", .label = "选项3" },
    };

    const found = findMenuItem(&items, "2");
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("选项2", found.?.label);

    const not_found = findMenuItem(&items, "99");
    try std.testing.expect(not_found == null);
}

test "menu config creation" {
    const config = MenuConfig{
        .title = "测试菜单",
        .prompt = "请选择: ",
        .default_key = "1",
        .show_keys = true,
    };

    try std.testing.expectEqualStrings("测试菜单", config.title);
    try std.testing.expectEqualStrings("请选择: ", config.prompt);
    try std.testing.expectEqualStrings("1", config.default_key.?);
    try std.testing.expect(config.show_keys);
}
