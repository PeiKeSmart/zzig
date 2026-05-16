//! 网络工具模块 - 提供网络地址处理、接口检测等通用功能
//!
//! 设计目标：
//! 1. 跨平台：支持 Windows、Linux、macOS
//! 2. 轻量级：零外部依赖，纯 Zig 实现
//! 3. 高性能：避免不必要的内存分配
//! 4. 类型安全：充分利用 Zig 类型系统
//!
//! 主要功能：
//! - CIDR 解析和操作
//! - IPv4/IPv6 地址转换
//! - 网络接口检测和过滤
//! - 网络扫描辅助函数

const std = @import("std");
const compat = @import("../compat.zig");

// Windows ARP API 定义
const windows = if (@import("builtin").os.tag == .windows) struct {
    const DWORD = u32;
    const ULONG = u32;

    // iphlpapi.dll 中的 SendARP 函数
    pub extern "iphlpapi" fn SendARP(
        DestIP: DWORD,
        SrcIP: DWORD,
        pMacAddr: [*]u8,
        PhyAddrLen: *ULONG,
    ) DWORD;
} else struct {};

/// CIDR 信息结构
pub const CidrInfo = struct {
    base_ip: u32,          // 网络地址（主机字节序）
    host_count: u32,       // 可用主机数量
    prefix_len: u8,        // 前缀长度
};

/// 网络接口信息结构
pub const NetworkInterface = struct {
    name: []const u8,      // 适配器名称
    description: []const u8, // 网卡描述（用于判断类型）
    ip: u32,               // IP 地址（主机字节序）
    cidr: []const u8,      // CIDR 表示
    prefix_len: u8,        // 子网前缀长度
    is_virtual: bool,      // 是否为虚拟网卡
};

pub const RankedNetworkInterface = struct {
    iface: NetworkInterface,
    priority: u8,
};

pub const InterfaceSelectionResult = struct {
    interfaces: []const NetworkInterface,
    selected: ?NetworkInterface,

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        freeNetworkInterfaces(allocator, self.interfaces);
    }
};

pub const RankedInterfacesResult = struct {
    interfaces: []const NetworkInterface,
    ranked: []const RankedNetworkInterface,

    pub fn deinit(self: @This(), allocator: std.mem.Allocator) void {
        allocator.free(self.ranked);
        freeNetworkInterfaces(allocator, self.interfaces);
    }
};

/// 主机信息结构（用于扫描结果）
pub const HostInfo = struct {
    ip: u32,               // IP 地址（主机字节序）
    mac: [6]u8,            // MAC 地址
    hostname: ?[]const u8, // 可选的主机名
};

pub const ArpScanProgress = struct {
    completed: usize,
    total: usize,
    found: usize,
    elapsed_ms: i64,
};

pub const ArpScanProgressCallback = *const fn (ctx: ?*anyopaque, progress: ArpScanProgress) void;

pub const TcpPortScanProgress = struct {
    completed: usize,
    total: usize,
    found: usize,
    elapsed_ms: i64,
};

pub const TcpPortScanProgressCallback = *const fn (ctx: ?*anyopaque, progress: TcpPortScanProgress) void;

pub const ArpScanConfig = struct {
    thread_count: usize = 64,
    local_ip: ?u32 = null,
    progress_interval_ms: u64 = 0,
    progress_callback: ?ArpScanProgressCallback = null,
    progress_ctx: ?*anyopaque = null,
};

pub const TcpPortScanConfig = struct {
    timeout_ms: u32 = 200,
    progress_interval_hosts: usize = 10,
    progress_callback: ?TcpPortScanProgressCallback = null,
    progress_ctx: ?*anyopaque = null,
};

/// 计算子网掩码中 1 的位数
pub fn countMaskBits(mask: u32) u8 {
    var count: u8 = 0;
    var m = mask;
    while (m != 0) : (m <<= 1) {
        if ((m & 0x80000000) != 0) {
            count += 1;
        } else {
            break;
        }
    }
    return count;
}

/// 解析 IPv4 CIDR 格式（如 "192.168.1.0/24"）
pub fn parseCidr(cidr: []const u8) !CidrInfo {
    // 查找 '/' 分隔符
    const slash_pos = std.mem.indexOfScalar(u8, cidr, '/') orelse return error.InvalidCidr;

    const ip_str = cidr[0..slash_pos];
    const prefix_str = cidr[slash_pos + 1 ..];

    // 解析前缀长度
    const prefix_len = try std.fmt.parseUnsigned(u8, prefix_str, 10);
    if (prefix_len > 32) return error.InvalidPrefix;

    // 解析 IP 地址
    var octets: [4]u8 = undefined;
    var iter = std.mem.splitScalar(u8, ip_str, '.');
    var i: usize = 0;

    while (iter.next()) |octet_str| : (i += 1) {
        if (i >= 4) return error.InvalidIp;
        octets[i] = try std.fmt.parseUnsigned(u8, octet_str, 10);
    }

    if (i != 4) return error.InvalidIp;

    // 转换为 u32（大端序转主机序）
    const base_ip = (@as(u32, octets[0]) << 24) |
        (@as(u32, octets[1]) << 16) |
        (@as(u32, octets[2]) << 8) |
        @as(u32, octets[3]);

    // 计算网络地址和主机数量
    const host_bits: u5 = @intCast(32 - prefix_len);
    const mask: u32 = if (prefix_len == 0) 0 else ~@as(u32, 0) << host_bits;
    const network_addr = base_ip & mask;
    const host_count = if (prefix_len == 32) 1 else (@as(u32, 1) << host_bits) - 2; // 排除网络地址和广播地址

    return CidrInfo{
        .base_ip = network_addr,
        .host_count = host_count,
        .prefix_len = prefix_len,
    };
}

/// 将 u32 IP 转换为字符串（主机字节序）
pub fn ipToString(ip: u32, buf: []u8) ![]u8 {
    const a = @as(u8, @intCast((ip >> 24) & 0xFF));
    const b = @as(u8, @intCast((ip >> 16) & 0xFF));
    const c = @as(u8, @intCast((ip >> 8) & 0xFF));
    const d = @as(u8, @intCast(ip & 0xFF));

    return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ a, b, c, d });
}

/// 格式化 MAC 地址为字符串
pub fn macToString(mac: [6]u8, buf: []u8) ![]u8 {
    return std.fmt.bufPrint(buf, "{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}:{X:0>2}", .{ mac[0], mac[1], mac[2], mac[3], mac[4], mac[5] });
}

/// 判断是否为虚拟网卡（基于适配器名称关键词）
pub fn isVirtualAdapter(name: []const u8) bool {
    // 虚拟网卡常见关键词（不区分大小写）
    const virtual_keywords = [_][]const u8{
        "vEthernet", // Hyper-V 虚拟交换机
        "VirtualBox", // Oracle VirtualBox
        "VMware",     // VMware 虚拟网卡
        "Virtual",    // 通用虚拟标识
        "Loopback",   // 回环适配器
        "Tunnel",     // 隧道适配器
        "Teredo",     // IPv6 Teredo 隧道
        "6to4",       // IPv6 过渡
        "isatap",     // ISATAP 隧道
        "WSL",        // Windows Subsystem for Linux
        "vNIC",       // 虚拟网卡缩写
        "TAP",        // TAP 虚拟网卡
        "VPN",        // VPN 适配器
    };

    // 转换为小写进行比较
    var name_lower_buf: [256]u8 = undefined;
    if (name.len > name_lower_buf.len) return false;

    const name_lower = std.ascii.lowerString(&name_lower_buf, name);

    for (virtual_keywords) |keyword| {
        var keyword_lower_buf: [64]u8 = undefined;
        const keyword_lower = std.ascii.lowerString(&keyword_lower_buf, keyword);

        if (std.mem.indexOf(u8, name_lower, keyword_lower) != null) {
            return true;
        }
    }

    return false;
}

/// 不区分大小写的字符串包含判断
pub fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (std.mem.indexOf(u8, haystack, needle) != null) return true;
    if (needle.len > haystack.len) return false;

    for (0..haystack.len - needle.len + 1) |start| {
        if (std.ascii.eqlIgnoreCase(haystack[start .. start + needle.len], needle)) return true;
    }

    return false;
}

fn parseIpv4Text(ip_str: []const u8) ?u32 {
    var octets: [4]u8 = undefined;
    var iter = std.mem.splitScalar(u8, ip_str, '.');
    var index: usize = 0;

    while (iter.next()) |octet_str| : (index += 1) {
        if (index >= 4) return null;
        octets[index] = std.fmt.parseUnsigned(u8, octet_str, 10) catch return null;
    }

    if (index != 4) return null;

    return (@as(u32, octets[0]) << 24) |
        (@as(u32, octets[1]) << 16) |
        (@as(u32, octets[2]) << 8) |
        @as(u32, octets[3]);
}

fn parseLinuxInterfaceName(line: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, line, " \r\n\t");
    if (trimmed.len == 0 or !std.ascii.isDigit(trimmed[0])) return null;

    const first_colon = std.mem.indexOfScalar(u8, trimmed, ':') orelse return null;
    if (first_colon + 1 >= trimmed.len) return null;

    const after_index = std.mem.trimLeft(u8, trimmed[first_colon + 1 ..], " ");
    const second_colon = std.mem.indexOfScalar(u8, after_index, ':') orelse return null;
    const name = std.mem.trim(u8, after_index[0..second_colon], " ");
    if (name.len == 0) return null;

    return name;
}

fn appendInterface(allocator: std.mem.Allocator, interfaces: *std.ArrayList(NetworkInterface), name: []const u8, description: []const u8, ip: u32, prefix_len: u8) !void {
    const ip_octets = [4]u8{
        @intCast((ip >> 24) & 0xFF),
        @intCast((ip >> 16) & 0xFF),
        @intCast((ip >> 8) & 0xFF),
        @intCast(ip & 0xFF),
    };

    if (ip_octets[0] == 127 or (ip_octets[0] == 169 and ip_octets[1] == 254)) return;
    if (prefix_len > 32) return;

    const host_bits: u5 = @intCast(32 - prefix_len);
    const mask: u32 = if (prefix_len == 0) 0 else ~@as(u32, 0) << host_bits;
    const network_ip = ip & mask;

    const network_octets = [4]u8{
        @intCast((network_ip >> 24) & 0xFF),
        @intCast((network_ip >> 16) & 0xFF),
        @intCast((network_ip >> 8) & 0xFF),
        @intCast(network_ip & 0xFF),
    };

    var cidr_buf: [20]u8 = undefined;
    const cidr = try std.fmt.bufPrint(&cidr_buf, "{d}.{d}.{d}.{d}/{d}", .{ network_octets[0], network_octets[1], network_octets[2], network_octets[3], prefix_len });

    const resolved_description = if (description.len > 0) description else name;
    const is_virtual = isVirtualAdapter(resolved_description);

    try interfaces.append(allocator, .{
        .name = try allocator.dupe(u8, name),
        .description = try allocator.dupe(u8, resolved_description),
        .ip = ip,
        .cidr = try allocator.dupe(u8, cidr),
        .prefix_len = prefix_len,
        .is_virtual = is_virtual,
    });
}

/// 使用 ARP 检测主机并获取 MAC 地址
pub fn arpScan(ip: u32, mac_out: *[6]u8) bool {
    const builtin = @import("builtin");

    if (builtin.os.tag == .windows) {
        // Windows: 使用 SendARP API
        var mac_len: windows.ULONG = 6;

        // IP 需要转换为网络字节序
        const net_ip = @byteSwap(ip);

        const result = windows.SendARP(net_ip, 0, mac_out, &mac_len);

        // NO_ERROR = 0 表示成功
        return result == 0 and mac_len == 6;
    } else {
        // Linux/Unix: 使用 ping 作为后备（ARP 需要 root）
        // TODO: 实现 raw socket ARP 扫描
        return false;
    }
}

const ArpScanTask = struct {
    allocator: std.mem.Allocator,
    scan_list: []const u32,
    start_idx: usize,
    end_idx: usize,
    found_hosts: *std.ArrayList(HostInfo),
    mutex: *compat.Mutex,
    progress_counter: *usize,
};

fn arpWorker(task: *ArpScanTask) void {
    var local_hosts: std.ArrayList(HostInfo) = .empty;
    defer local_hosts.deinit(task.allocator);

    var local_progress: usize = 0;
    const batch_size: usize = 2;

    for (task.start_idx..task.end_idx) |idx| {
        const ip = task.scan_list[idx];
        local_progress += 1;

        var mac: [6]u8 = undefined;
        if (arpScan(ip, &mac)) {
            local_hosts.append(task.allocator, .{
                .ip = ip,
                .mac = mac,
                .hostname = null,
            }) catch {};
        }

        if (local_progress >= batch_size or idx == task.end_idx - 1) {
            task.mutex.lock();
            defer task.mutex.unlock();

            task.progress_counter.* += local_progress;
            local_progress = 0;

            for (local_hosts.items) |host| {
                task.found_hosts.append(task.allocator, host) catch {};
            }
            local_hosts.clearRetainingCapacity();
        }
    }
}

fn buildArpScanOrder(allocator: std.mem.Allocator, base_ip: u32, host_count: u32, local_ip: ?u32) ![]u32 {
    var scan_order = try allocator.alloc(u32, host_count);
    errdefer allocator.free(scan_order);

    if (host_count == 0) return scan_order;

    if (local_ip) |my_ip| {
        const my_offset = my_ip - base_ip - 1;
        var idx: usize = 0;

        if (my_offset < host_count) {
            scan_order[idx] = base_ip + my_offset + 1;
            idx += 1;
        }

        var radius: u32 = 1;
        while (radius <= host_count and idx < host_count) : (radius += 1) {
            if (my_offset >= radius) {
                const offset = my_offset - radius;
                if (offset < host_count and offset != my_offset) {
                    scan_order[idx] = base_ip + offset + 1;
                    idx += 1;
                }
            }

            if (my_offset + radius < host_count and idx < host_count) {
                const offset = my_offset + radius;
                if (offset != my_offset) {
                    scan_order[idx] = base_ip + offset + 1;
                    idx += 1;
                }
            }
        }

        for (0..host_count) |i| {
            const ip = base_ip + @as(u32, @intCast(i)) + 1;
            var already_added = false;
            for (scan_order[0..idx]) |added_ip| {
                if (added_ip == ip) {
                    already_added = true;
                    break;
                }
            }

            if (!already_added and idx < host_count) {
                scan_order[idx] = ip;
                idx += 1;
            }
        }
    } else {
        for (0..host_count) |i| {
            scan_order[i] = base_ip + @as(u32, @intCast(i)) + 1;
        }
    }

    return scan_order;
}

pub fn discoverHostsByArpConcurrent(
    allocator: std.mem.Allocator,
    base_ip: u32,
    host_count: u32,
    config: ArpScanConfig,
) !std.ArrayList(HostInfo) {
    var found_hosts: std.ArrayList(HostInfo) = .empty;
    if (host_count == 0) return found_hosts;

    var mutex = compat.Mutex{};
    var progress_counter: usize = 0;

    const scan_order = try buildArpScanOrder(allocator, base_ip, host_count, config.local_ip);
    defer allocator.free(scan_order);

    const effective_thread_count = @max(@as(usize, 1), @min(config.thread_count, host_count));
    const ips_per_thread = (host_count + effective_thread_count - 1) / effective_thread_count;

    var threads = try allocator.alloc(std.Thread, effective_thread_count);
    defer allocator.free(threads);

    var tasks = try allocator.alloc(ArpScanTask, effective_thread_count);
    defer allocator.free(tasks);

    for (0..effective_thread_count) |i| {
        const start_idx = i * ips_per_thread;
        const end_idx = @min(start_idx + ips_per_thread, host_count);

        tasks[i] = .{
            .allocator = allocator,
            .scan_list = scan_order,
            .start_idx = start_idx,
            .end_idx = end_idx,
            .found_hosts = &found_hosts,
            .mutex = &mutex,
            .progress_counter = &progress_counter,
        };

        if (start_idx < end_idx) {
            threads[i] = try std.Thread.spawn(.{}, arpWorker, .{&tasks[i]});
        }
    }

    const start_time = compat.milliTimestamp();
    if (config.progress_interval_ms > 0 and config.progress_callback != null) {
        while (true) {
            compat.sleep(config.progress_interval_ms * std.time.ns_per_ms);

            mutex.lock();
            const current_progress = progress_counter;
            const current_found = found_hosts.items.len;
            const is_complete = current_progress >= host_count;
            mutex.unlock();

            config.progress_callback.?(config.progress_ctx, .{
                .completed = current_progress,
                .total = host_count,
                .found = current_found,
                .elapsed_ms = compat.milliTimestamp() - start_time,
            });

            if (is_complete) break;
        }
    }

    for (0..effective_thread_count) |i| {
        const start_idx = i * ips_per_thread;
        const end_idx = @min(start_idx + ips_per_thread, host_count);
        if (start_idx < end_idx) {
            threads[i].join();
        }
    }

    return found_hosts;
}

/// 获取本机所有网卡信息
pub fn getNetworkInterfaces(allocator: std.mem.Allocator) ![]NetworkInterface {
    var interfaces: std.ArrayList(NetworkInterface) = .empty;
    errdefer interfaces.deinit(allocator);

    const builtin = @import("builtin");

    if (builtin.os.tag == .windows) {
        const ps_result = compat.process.run(allocator, .{
            .argv = &[_][]const u8{
                "powershell.exe",
                "-NoProfile",
                "-Command",
                "$OutputEncoding = [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false); Get-NetIPConfiguration | Where-Object { $_.IPv4Address -ne $null } | ForEach-Object { foreach ($ipv4 in $_.IPv4Address) { \"{0}`t{1}`t{2}`t{3}\" -f $_.InterfaceAlias, $_.InterfaceDescription, $ipv4.IPAddress, $ipv4.PrefixLength } }",
            },
        }) catch null;

        if (ps_result) |result| {
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);

            var lines = std.mem.splitScalar(u8, result.stdout, '\n');
            while (lines.next()) |line| {
                const trimmed = std.mem.trim(u8, line, " \r\n\t");
                if (trimmed.len == 0) continue;

                var parts = std.mem.splitScalar(u8, trimmed, '\t');
                const alias = std.mem.trim(u8, parts.next() orelse continue, " \r\n\t");
                const description = std.mem.trim(u8, parts.next() orelse continue, " \r\n\t");
                const ip_text = std.mem.trim(u8, parts.next() orelse continue, " \r\n\t");
                const prefix_text = std.mem.trim(u8, parts.next() orelse continue, " \r\n\t");

                const ip = parseIpv4Text(ip_text) orelse continue;
                const prefix_len = std.fmt.parseUnsigned(u8, prefix_text, 10) catch continue;
                const name = if (alias.len > 0) alias else description;
                if (name.len == 0) continue;

                try appendInterface(allocator, &interfaces, name, description, ip, prefix_len);
            }

            if (interfaces.items.len > 0) return try interfaces.toOwnedSlice(allocator);
        }

        // Windows: 使用 ipconfig /all 命令解析（获取描述信息）
        const result = try compat.process.run(allocator, .{
            .argv = &[_][]const u8{ "cmd", "/c", "chcp 65001 >nul && ipconfig /all" },
        });
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        var lines = std.mem.splitScalar(u8, result.stdout, '\n');
        var current_name: ?[]const u8 = null;
        var current_description: ?[]const u8 = null;
        var current_ip: ?u32 = null;
        var current_mask: ?u32 = null;

        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \r\n\t");

            // 跳过空行
            if (trimmed.len == 0) continue;

            // 匹配适配器名称（包含"适配器"或"adapter"且以冒号结尾）
            const has_adapter = std.mem.indexOf(u8, trimmed, "适配器") != null or std.mem.indexOf(u8, trimmed, "adapter") != null;
            const ends_with_colon = trimmed.len > 0 and trimmed[trimmed.len - 1] == ':';

            if (has_adapter and ends_with_colon) {
                // 释放之前的名称和描述
                if (current_name) |old_name| {
                    allocator.free(old_name);
                }
                if (current_description) |old_desc| {
                    allocator.free(old_desc);
                }
                current_name = try allocator.dupe(u8, trimmed);
                current_description = null; // 重置描述
                current_ip = null; // 重置 IP
                current_mask = null; // 重置子网掩码
            }

            // 匹配描述信息（用于判断虚拟网卡）
            if (std.mem.indexOf(u8, trimmed, "描述") != null or
                std.mem.indexOf(u8, trimmed, "Description") != null)
            {
                if (std.mem.indexOf(u8, trimmed, ":") != null) {
                    var parts = std.mem.splitScalar(u8, trimmed, ':');
                    _ = parts.next();
                    if (parts.next()) |desc_part| {
                        const desc_str = std.mem.trim(u8, desc_part, " \r\n\t");
                        if (desc_str.len > 0) {
                            if (current_description) |old_desc| {
                                allocator.free(old_desc);
                            }
                            current_description = try allocator.dupe(u8, desc_str);
                        }
                    }
                }
            }

            // 匹配 IPv4 地址（同时支持中英文）
            if (std.mem.indexOf(u8, trimmed, "IPv4") != null) {
                if (std.mem.indexOf(u8, trimmed, ":") != null) {
                    var parts = std.mem.splitScalar(u8, trimmed, ':');
                    _ = parts.next(); // 跳过标签
                    if (parts.next()) |ip_part| {
                        // 去除空格、括号、"(Preferred)" 等后缀
                        var ip_str = std.mem.trim(u8, ip_part, " \r\n\t");

                        // 查找括号，截取之前的部分
                        if (std.mem.indexOf(u8, ip_str, "(")) |paren_pos| {
                            ip_str = ip_str[0..paren_pos];
                        }

                        // 解析 IP
                        var octets: [4]u8 = undefined;
                        var iter = std.mem.splitScalar(u8, ip_str, '.');
                        var i: usize = 0;
                        var valid = true;

                        while (iter.next()) |octet_str| : (i += 1) {
                            if (i >= 4) {
                                valid = false;
                                break;
                            }
                            octets[i] = std.fmt.parseUnsigned(u8, octet_str, 10) catch {
                                valid = false;
                                break;
                            };
                        }

                        if (valid and i == 4) {
                            current_ip = (@as(u32, octets[0]) << 24) |
                                (@as(u32, octets[1]) << 16) |
                                (@as(u32, octets[2]) << 8) |
                                @as(u32, octets[3]);
                        }
                    }
                }
            }

            // 匹配子网掩码
            if (std.mem.indexOf(u8, trimmed, "子网掩码") != null or
                std.mem.indexOf(u8, trimmed, "Subnet Mask") != null)
            {
                if (std.mem.indexOf(u8, trimmed, ":") != null) {
                    var parts = std.mem.splitScalar(u8, trimmed, ':');
                    _ = parts.next();
                    if (parts.next()) |mask_part| {
                        const mask_str = std.mem.trim(u8, mask_part, " \r\n\t");

                        var octets: [4]u8 = undefined;
                        var iter = std.mem.splitScalar(u8, mask_str, '.');
                        var i: usize = 0;
                        var valid = true;

                        while (iter.next()) |octet_str| : (i += 1) {
                            if (i >= 4) {
                                valid = false;
                                break;
                            }
                            octets[i] = std.fmt.parseUnsigned(u8, octet_str, 10) catch {
                                valid = false;
                                break;
                            };
                        }

                        if (valid and i == 4) {
                            current_mask = (@as(u32, octets[0]) << 24) |
                                (@as(u32, octets[1]) << 16) |
                                (@as(u32, octets[2]) << 8) |
                                @as(u32, octets[3]);

                            // 当收集到 IP 和掩码后，保存网卡信息
                            if (current_name != null and current_ip != null and current_mask != null) {
                                const ip = current_ip.?;
                                const mask = current_mask.?;

                                // 提取 IP 的各个字节
                                const ip_octets = [4]u8{
                                    @intCast((ip >> 24) & 0xFF),
                                    @intCast((ip >> 16) & 0xFF),
                                    @intCast((ip >> 8) & 0xFF),
                                    @intCast(ip & 0xFF),
                                };

                                // 忽略 127.x.x.x 和 169.254.x.x (APIPA)
                                if (ip_octets[0] != 127 and !(ip_octets[0] == 169 and ip_octets[1] == 254)) {
                                    // 计算网络地址和前缀长度
                                    const network_ip = ip & mask;
                                    const prefix_len = countMaskBits(mask);

                                    const network_octets = [4]u8{
                                        @intCast((network_ip >> 24) & 0xFF),
                                        @intCast((network_ip >> 16) & 0xFF),
                                        @intCast((network_ip >> 8) & 0xFF),
                                        @intCast(network_ip & 0xFF),
                                    };

                                    var cidr_buf: [20]u8 = undefined;
                                    const cidr = try std.fmt.bufPrint(&cidr_buf, "{d}.{d}.{d}.{d}/{d}", .{ network_octets[0], network_octets[1], network_octets[2], network_octets[3], prefix_len });

                                    // 判断是否为虚拟网卡（优先使用描述，其次使用名称）
                                    const check_str = if (current_description) |desc| desc else current_name.?;
                                    const is_virtual = isVirtualAdapter(check_str);

                                    // 保存到列表
                                    const saved_description = if (current_description) |desc|
                                        try allocator.dupe(u8, desc)
                                    else
                                        try allocator.dupe(u8, current_name.?);

                                    try interfaces.append(allocator, .{
                                        .name = try allocator.dupe(u8, current_name.?),
                                        .description = saved_description,
                                        .ip = ip,
                                        .cidr = try allocator.dupe(u8, cidr),
                                        .prefix_len = prefix_len,
                                        .is_virtual = is_virtual,
                                    });

                                    // 释放临时保存的适配器名称和描述
                                    allocator.free(current_name.?);
                                    if (current_description) |desc| {
                                        allocator.free(desc);
                                    }
                                    current_name = null;
                                    current_description = null;
                                    current_ip = null;
                                    current_mask = null;
                                }
                            }
                        }
                    }
                }
            }
        }

        // 清理未使用的 current_name 和 current_description
        if (current_name) |name| {
            allocator.free(name);
        }
        if (current_description) |desc| {
            allocator.free(desc);
        }
    } else {
        // Unix/Linux: 使用 ip addr 或 ifconfig
        const result = compat.process.run(allocator, .{
            .argv = &[_][]const u8{ "ip", "addr" },
        }) catch |err| {
            // 尝试 ifconfig
            if (err == error.FileNotFound) {
                const ifconfig_result = try compat.process.run(allocator, .{
                    .argv = &[_][]const u8{"ifconfig"},
                });
                defer allocator.free(ifconfig_result.stdout);
                defer allocator.free(ifconfig_result.stderr);
                // 这里可以解析 ifconfig 输出，暂时返回空
                return try interfaces.toOwnedSlice(allocator);
            }
            return err;
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        // 简单解析 ip addr 输出
        // 格式示例:
        //   2: eth0: <...>
        //       inet 192.168.1.100/24 brd 192.168.1.255 scope global eth0
        var lines = std.mem.splitScalar(u8, result.stdout, '\n');
        var current_name: ?[]const u8 = null;

        while (lines.next()) |line| {
            if (parseLinuxInterfaceName(line)) |name| {
                current_name = name;
                continue;
            }

            if (std.mem.indexOf(u8, line, "inet ") != null) {
                var parts = std.mem.splitScalar(u8, line, ' ');
                var found_inet = false;

                while (parts.next()) |part| {
                    if (found_inet and part.len > 0) {
                        // 找到 IP/prefix
                        if (std.mem.indexOf(u8, part, ".") != null and std.mem.indexOf(u8, part, "/") != null) {
                            const cidr_str = std.mem.trim(u8, part, " \r\n\t");
                            const slash_pos = std.mem.indexOfScalar(u8, cidr_str, '/') orelse continue;
                            const ip_str = cidr_str[0..slash_pos];
                            const prefix_str = cidr_str[slash_pos + 1 ..];
                            const ip = parseIpv4Text(ip_str) orelse continue;
                            const first_octet = @as(u8, @intCast((ip >> 24) & 0xFF));
                            if (first_octet == 127) continue;

                            const prefix_len = std.fmt.parseUnsigned(u8, prefix_str, 10) catch continue;
                            if (prefix_len > 32) continue;

                            const host_bits: u5 = @intCast(32 - prefix_len);
                            const mask: u32 = if (prefix_len == 0) 0 else ~@as(u32, 0) << host_bits;
                            const network_ip = ip & mask;
                            const iface_name = current_name orelse "unknown";
                            const is_virtual = isVirtualAdapter(iface_name);

                            const network_octets = [4]u8{
                                @intCast((network_ip >> 24) & 0xFF),
                                @intCast((network_ip >> 16) & 0xFF),
                                @intCast((network_ip >> 8) & 0xFF),
                                @intCast(network_ip & 0xFF),
                            };

                            var normalized_cidr_buf: [20]u8 = undefined;
                            const normalized_cidr = try std.fmt.bufPrint(&normalized_cidr_buf, "{d}.{d}.{d}.{d}/{d}", .{ network_octets[0], network_octets[1], network_octets[2], network_octets[3], prefix_len });

                            try interfaces.append(allocator, .{
                                .name = try allocator.dupe(u8, iface_name),
                                .description = try allocator.dupe(u8, iface_name),
                                .ip = ip,
                                .cidr = try allocator.dupe(u8, normalized_cidr),
                                .prefix_len = prefix_len,
                                .is_virtual = is_virtual,
                            });
                        }
                        break;
                    }

                    if (std.mem.eql(u8, part, "inet")) {
                        found_inet = true;
                    }
                }
            }
        }
    }

    return try interfaces.toOwnedSlice(allocator);
}

/// 释放网络接口列表
pub fn freeNetworkInterfaces(allocator: std.mem.Allocator, interfaces: []const NetworkInterface) void {
    for (interfaces) |iface| {
        allocator.free(iface.name);
        allocator.free(iface.description);
        allocator.free(iface.cidr);
    }
    allocator.free(interfaces);
}

pub fn freeHostInfos(allocator: std.mem.Allocator, hosts: *std.ArrayList(HostInfo)) void {
    for (hosts.items) |host| {
        if (host.hostname) |name| {
            allocator.free(name);
        }
    }
    hosts.deinit(allocator);
}

/// 从网络接口列表中选择最佳接口
/// 根据优先级和可选的过滤器选择最适合的网络接口
///
/// 参数:
/// - interfaces: 网络接口列表
/// - iface_filter: 可选的过滤器字符串（匹配名称、描述或 CIDR），传 null 或空字符串表示不过滤
///
/// 返回:
/// - 最佳网络接口，如果没有匹配的接口则返回 null
pub fn selectBestInterface(interfaces: []const NetworkInterface, iface_filter: ?[]const u8) ?NetworkInterface {
    var selected: ?NetworkInterface = null;
    var best_priority: u8 = std.math.maxInt(u8);

    for (interfaces) |iface| {
        if (iface_filter) |filter| {
            if (filter.len > 0) {
                if (!containsIgnoreCase(iface.name, filter) and
                    !containsIgnoreCase(iface.description, filter) and
                    !containsIgnoreCase(iface.cidr, filter))
                {
                    continue;
                }
            }
        }

        const priority = getInterfacePriority(iface);
        if (selected == null or priority < best_priority) {
            selected = iface;
            best_priority = priority;
        }
    }

    return selected;
}

/// 计算网卡优先级（用于智能选择）
pub fn getInterfacePriority(iface: NetworkInterface) u8 {
    const last_octet = @as(u8, @intCast(iface.ip & 0xFF));
    var priority: u8 = if (iface.is_virtual) 200 else 100;

    if (!iface.is_virtual) {
        if (last_octet >= 10 and last_octet <= 253)
            priority = 0
        else if (last_octet >= 2 and last_octet <= 9)
            priority = 30
        else if (last_octet == 1 or last_octet == 254)
            priority = 50;
    }

    if (iface.prefix_len < 20 and priority <= 245) priority += 10;
    return priority;
}

pub fn getInterfaceTag(iface: NetworkInterface) []const u8 {
    if (iface.is_virtual) return "⚙️  虚拟网卡";

    const last_octet = @as(u8, @intCast(iface.ip & 0xFF));
    if (last_octet >= 10 and last_octet <= 253) return "🌟 物理网卡 - 常见局域网子网";
    if (last_octet == 1) return "🔧 物理网卡 - 可能是网关";
    return "📡 物理网卡";
}

pub fn rankInterfacesByPriority(allocator: std.mem.Allocator, interfaces: []const NetworkInterface) ![]RankedNetworkInterface {
    var ranked = try allocator.alloc(RankedNetworkInterface, interfaces.len);

    for (interfaces, 0..) |iface, index| {
        ranked[index] = .{ .iface = iface, .priority = getInterfacePriority(iface) };
    }

    for (0..ranked.len) |i| {
        for (i + 1..ranked.len) |j| {
            if (ranked[i].priority > ranked[j].priority) {
                const temp = ranked[i];
                ranked[i] = ranked[j];
                ranked[j] = temp;
            }
        }
    }

    return ranked;
}

pub fn selectSystemInterface(allocator: std.mem.Allocator, iface_filter: ?[]const u8) !InterfaceSelectionResult {
    const interfaces = try getNetworkInterfaces(allocator);
    return .{
        .interfaces = interfaces,
        .selected = selectBestInterface(interfaces, iface_filter),
    };
}

pub fn getRankedSystemInterfaces(allocator: std.mem.Allocator) !RankedInterfacesResult {
    const interfaces = try getNetworkInterfaces(allocator);
    errdefer freeNetworkInterfaces(allocator, interfaces);

    const ranked = try rankInterfacesByPriority(allocator, interfaces);
    return .{
        .interfaces = interfaces,
        .ranked = ranked,
    };
}

/// 测试 TCP 端口连通性
pub fn testTcpPort(allocator: std.mem.Allocator, ip_str: []const u8, port: u16, timeout_ms: u32) bool {
    _ = allocator;

    const poll_interval_ms: u64 = if (timeout_ms > 0 and timeout_ms < 50) timeout_ms else 50;
    const stream = compat.net.connectTcpWithTimeout(ip_str, port, timeout_ms, poll_interval_ms) catch return false;
    defer stream.close(compat.currentIo());

    return true;
}

pub fn scanOpenTcpHostsInRange(
    allocator: std.mem.Allocator,
    base_ip: u32,
    host_count: u32,
    port: u16,
    config: TcpPortScanConfig,
) !std.ArrayList(u32) {
    var found_ips: std.ArrayList(u32) = .empty;
    if (host_count == 0) return found_ips;

    const start_time = compat.milliTimestamp();
    const progress_interval_hosts = @max(@as(usize, 1), config.progress_interval_hosts);
    var ip = base_ip + 1;
    const end_ip = base_ip + host_count + 1;
    var completed: usize = 0;

    while (ip < end_ip) : (ip += 1) {
        var ip_buf: [16]u8 = undefined;
        const ip_str = try ipToString(ip, &ip_buf);
        completed += 1;

        if (testTcpPort(allocator, ip_str, port, config.timeout_ms)) {
            try found_ips.append(allocator, ip);
        }

        if (config.progress_callback) |callback| {
            if (completed % progress_interval_hosts == 0 or completed == host_count) {
                callback(config.progress_ctx, .{
                    .completed = completed,
                    .total = host_count,
                    .found = found_ips.items.len,
                    .elapsed_ms = compat.milliTimestamp() - start_time,
                });
            }
        }
    }

    return found_ips;
}

// ============================================================================
// 测试用例
// ============================================================================

test "countMaskBits" {
    // 标准子网掩码测试
    try std.testing.expectEqual(@as(u8, 24), countMaskBits(0xFFFFFF00)); // 255.255.255.0
    try std.testing.expectEqual(@as(u8, 16), countMaskBits(0xFFFF0000)); // 255.255.0.0
    try std.testing.expectEqual(@as(u8, 8), countMaskBits(0xFF000000));  // 255.0.0.0
    try std.testing.expectEqual(@as(u8, 0), countMaskBits(0x00000000));  // 0.0.0.0
}

test "parseCidr" {
    const cidr = try parseCidr("192.168.1.0/24");
    try std.testing.expectEqual(@as(u32, 0xC0A80100), cidr.base_ip); // 192.168.1.0
    try std.testing.expectEqual(@as(u32, 254), cidr.host_count);      // 可用主机数
    try std.testing.expectEqual(@as(u8, 24), cidr.prefix_len);        // 前缀长度
}

test "ipToString" {
    var buf: [16]u8 = undefined;
    const ip_str = try ipToString(0xC0A80164, &buf); // 192.168.1.100
    try std.testing.expectEqualStrings("192.168.1.100", ip_str);
}

test "macToString" {
    var buf: [18]u8 = undefined;
    const mac = [6]u8{ 0x00, 0x50, 0x56, 0xC0, 0x00, 0x01 };
    const mac_str = try macToString(mac, &buf);
    try std.testing.expectEqualStrings("00:50:56:C0:00:01", mac_str);
}

test "isVirtualAdapter" {
    // 虚拟网卡检测测试
    try std.testing.expect(isVirtualAdapter("vEthernet (Default Switch)"));
    try std.testing.expect(isVirtualAdapter("VirtualBox Host-Only Network"));
    try std.testing.expect(isVirtualAdapter("VMware Network Adapter VMnet1"));
    try std.testing.expect(isVirtualAdapter("Teredo Tunneling Pseudo-Interface"));

    // 物理网卡不应被检测为虚拟
    try std.testing.expect(!isVirtualAdapter("Ethernet"));
    try std.testing.expect(!isVirtualAdapter("Wi-Fi"));
}

test "containsIgnoreCase" {
    try std.testing.expect(containsIgnoreCase("Hello World", "hello"));
    try std.testing.expect(containsIgnoreCase("HELLO WORLD", "world"));
    try std.testing.expect(containsIgnoreCase("Mixed Case", "CASE"));
    try std.testing.expect(!containsIgnoreCase("Hello World", "foo"));
}

test "parseIpv4Text" {
    try std.testing.expectEqual(@as(?u32, 0xC0A80164), parseIpv4Text("192.168.1.100"));
    try std.testing.expectEqual(@as(?u32, null), parseIpv4Text("192.168.1"));
    try std.testing.expectEqual(@as(?u32, null), parseIpv4Text("999.168.1.100"));
}

test "parseLinuxInterfaceName" {
    try std.testing.expectEqualStrings("eth0", parseLinuxInterfaceName("2: eth0: <BROADCAST,MULTICAST>").?);
    try std.testing.expectEqualStrings("wlp2s0", parseLinuxInterfaceName("3: wlp2s0: <BROADCAST,MULTICAST>").?);
    try std.testing.expect(parseLinuxInterfaceName("    inet 192.168.1.10/24") == null);
}

test "buildArpScanOrder prefers local ip" {
    const allocator = std.testing.allocator;
    const order = try buildArpScanOrder(allocator, 0xC0A80100, 5, 0xC0A80103);
    defer allocator.free(order);

    try std.testing.expectEqual(@as(u32, 0xC0A80103), order[0]);
    try std.testing.expectEqual(@as(u32, 0xC0A80102), order[1]);
    try std.testing.expectEqual(@as(u32, 0xC0A80104), order[2]);
}

test "rankInterfacesByPriority sorts physical lan before virtual" {
    const allocator = std.testing.allocator;
    const interfaces = [_]NetworkInterface{
        .{
            .name = "vmnet",
            .description = "VMware Network Adapter",
            .ip = 0xC0A80101,
            .cidr = "192.168.1.0/24",
            .prefix_len = 24,
            .is_virtual = true,
        },
        .{
            .name = "eth0",
            .description = "Ethernet",
            .ip = 0xC0A80164,
            .cidr = "192.168.1.0/24",
            .prefix_len = 24,
            .is_virtual = false,
        },
        .{
            .name = "wifi",
            .description = "Wi-Fi",
            .ip = 0xC0A80101,
            .cidr = "192.168.1.0/24",
            .prefix_len = 24,
            .is_virtual = false,
        },
    };

    const ranked = try rankInterfacesByPriority(allocator, &interfaces);
    defer allocator.free(ranked);

    try std.testing.expectEqualStrings("eth0", ranked[0].iface.name);
    try std.testing.expectEqualStrings("wifi", ranked[1].iface.name);
    try std.testing.expectEqualStrings("vmnet", ranked[2].iface.name);
}

test "getInterfaceTag distinguishes virtual and common lan" {
    try std.testing.expectEqualStrings("⚙️  虚拟网卡", getInterfaceTag(.{
        .name = "vmnet",
        .description = "VMware Network Adapter",
        .ip = 0xC0A80101,
        .cidr = "192.168.1.0/24",
        .prefix_len = 24,
        .is_virtual = true,
    }));

    try std.testing.expectEqualStrings("🌟 物理网卡 - 常见局域网子网", getInterfaceTag(.{
        .name = "eth0",
        .description = "Ethernet",
        .ip = 0xC0A80164,
        .cidr = "192.168.1.0/24",
        .prefix_len = 24,
        .is_virtual = false,
    }));
}

test "scanOpenTcpHostsInRange zero host count" {
    const allocator = std.testing.allocator;
    var found_ips = try scanOpenTcpHostsInRange(allocator, 0xC0A80100, 0, 80, .{});
    defer found_ips.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), found_ips.items.len);
}