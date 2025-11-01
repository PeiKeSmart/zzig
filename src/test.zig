const std = @import("std");
const testing = std.testing;
const zzig = @import("zzig");

// 字符串处理测试
test "Strings - AddString concatenates two strings" {
    const allocator = testing.allocator;

    const result = try zzig.Strings.AddString(allocator, "Hello", "World");
    defer allocator.free(result);

    try testing.expectEqualStrings("HelloWorld", result);
}

test "Strings - AddStrings concatenates multiple strings" {
    const allocator = testing.allocator;

    const slices = [_][]const u8{ "Hello", " ", "Zig", " ", "World" };
    const result = try zzig.Strings.AddStrings(allocator, &slices);
    defer allocator.free(result);

    try testing.expectEqualStrings("Hello Zig World", result);
}

test "Strings - Contains returns true for existing substring" {
    const str = "Hello Zig World";
    try testing.expect(zzig.Strings.Contains(str, "Zig"));
    try testing.expect(zzig.Strings.Contains(str, "World"));
}

test "Strings - Contains returns false for non-existing substring" {
    const str = "Hello Zig World";
    try testing.expect(!zzig.Strings.Contains(str, "Python"));
}

test "Strings - CompareStrings compares lexicographically" {
    try testing.expect(zzig.Strings.CompareStrings({}, "abc", "xyz"));
    try testing.expect(!zzig.Strings.CompareStrings({}, "xyz", "abc"));
}

// 随机数处理测试
test "Randoms - RandomString generates string of correct length" {
    const allocator = testing.allocator;

    const len: usize = 10;
    const result = try zzig.Randoms.RandomString(allocator, len);
    defer allocator.free(result);

    try testing.expectEqual(len, result.len);
}

test "Randoms - RandomString contains valid characters" {
    const allocator = testing.allocator;

    const result = try zzig.Randoms.RandomString(allocator, 20);
    defer allocator.free(result);

    // 验证所有字符都是有效的字母数字字符
    for (result) |char| {
        const is_valid = (char >= 'A' and char <= 'Z') or
            (char >= 'a' and char <= 'z') or
            (char >= '0' and char <= '9');
        try testing.expect(is_valid);
    }
}

// 文件处理测试
test "File - CurrentPath returns non-empty path" {
    const allocator = testing.allocator;

    const path = try zzig.File.CurrentPath(allocator);
    defer allocator.free(path);

    try testing.expect(path.len > 0);
}
