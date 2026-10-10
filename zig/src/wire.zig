const std = @import("std");
const sys = @import("sys.zig");

const linux = std.os.linux;

pub fn sock4(bytes: [4]u8, port: u16) linux.sockaddr.in {
    return .{
        .port = std.mem.nativeToBig(u16, port),
        // The kernel reads this u32 as network-order bytes.
        .addr = std.mem.nativeToBig(u32, std.mem.readInt(u32, &bytes, .big)),
    };
}

pub fn parse4(text: []const u8) ?[4]u8 {
    const parsed = std.Io.net.IpAddress.parse(text, 0) catch return null;
    return switch (parsed) {
        .ip4 => |ip| ip.bytes,
        .ip6 => null,
    };
}

pub fn openTcp(host: []const u8, port: u16, timeout_ms: i32) ?i32 {
    const parsed = std.Io.net.IpAddress.parse(host, port) catch return null;
    const stream = sys.connectStream(parsed, timeout_ms) orelse return null;
    return stream.socket.handle;
}

pub fn listenTcp(port: u16) ?struct { fd: i32, port: u16 } {
    const opened = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(opened) != .SUCCESS) return null;
    const fd: i32 = @intCast(opened);
    var one: i32 = 1;
    _ = linux.setsockopt(fd, linux.SOL.SOCKET, linux.SO.REUSEADDR, @ptrCast(&one), @sizeOf(i32));
    var sa = sock4(.{ 0, 0, 0, 0 }, port);
    const bound = linux.bind(fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.in));
    if (linux.errno(bound) != .SUCCESS) {
        _ = linux.close(fd);
        return null;
    }
    const queued = linux.listen(fd, 2);
    if (linux.errno(queued) != .SUCCESS) {
        _ = linux.close(fd);
        return null;
    }
    var len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    var got = linux.sockaddr.in{ .port = 0, .addr = 0 };
    const named = linux.getsockname(fd, @ptrCast(&got), &len);
    if (linux.errno(named) != .SUCCESS) {
        _ = linux.close(fd);
        return null;
    }
    return .{ .fd = fd, .port = std.mem.bigToNative(u16, got.port) };
}

pub fn openUdp(bytes: [4]u8, port: u16) ?i32 {
    const opened = linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(opened) != .SUCCESS) return null;
    const fd: i32 = @intCast(opened);
    var local = sock4(.{ 0, 0, 0, 0 }, 0);
    const bound = linux.bind(fd, @ptrCast(&local), @sizeOf(linux.sockaddr.in));
    if (linux.errno(bound) != .SUCCESS) {
        _ = linux.close(fd);
        return null;
    }
    var remote = sock4(bytes, port);
    const linked = linux.connect(fd, &remote, @sizeOf(linux.sockaddr.in));
    if (linux.errno(linked) != .SUCCESS) {
        _ = linux.close(fd);
        return null;
    }
    return fd;
}

pub fn udpPort(fd: i32) ?u16 {
    var len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    var got = linux.sockaddr.in{ .port = 0, .addr = 0 };
    const named = linux.getsockname(fd, @ptrCast(&got), &len);
    if (linux.errno(named) != .SUCCESS) return null;
    return std.mem.bigToNative(u16, got.port);
}

pub fn writeAll(fd: i32, data: []const u8) bool {
    var off: usize = 0;
    while (off < data.len) {
        const n = linux.write(fd, data[off..].ptr, data.len - off);
        if (linux.errno(n) != .SUCCESS or n == 0) return false;
        off += n;
    }
    return true;
}

pub fn pollIn(fd: i32, timeout_ms: i32) bool {
    var pfd = linux.pollfd{ .fd = fd, .events = linux.POLL.IN };
    const waited = linux.poll(@ptrCast(&pfd), 1, timeout_ms);
    if (linux.errno(waited) == .INTR) return false;
    return linux.errno(waited) == .SUCCESS and waited != 0;
}

pub fn readSome(fd: i32, buf: []u8) ?[]u8 {
    const n = linux.read(fd, buf.ptr, buf.len);
    if (linux.errno(n) != .SUCCESS or n == 0) return null;
    return buf[0..n];
}

pub fn close(fd: i32) void {
    if (fd >= 0) _ = linux.close(fd);
}

pub fn statusCode(response: []const u8) ?u16 {
    const line_end = std.mem.indexOf(u8, response, "\r\n") orelse response.len;
    const line = response[0..line_end];
    const sp = std.mem.indexOfScalar(u8, line, ' ') orelse return null;
    const rest = std.mem.trim(u8, line[sp + 1 ..], " ");
    const end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
    if (end < 3) return null;
    return std.fmt.parseInt(u16, rest[0..3], 10) catch null;
}

pub fn headerValue(message: []const u8, name: []const u8) ?[]const u8 {
    const head_end = std.mem.indexOf(u8, message, "\r\n\r\n") orelse message.len;
    var lines = std.mem.splitScalar(u8, message[0..head_end], '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r");
        if (line.len < name.len + 1) continue;
        if (!std.ascii.eqlIgnoreCase(line[0..name.len], name)) continue;
        if (line[name.len] != ':') continue;
        return std.mem.trim(u8, line[name.len + 1 ..], " \t\"");
    }
    return null;
}

pub fn bodyOf(message: []const u8) []const u8 {
    const at = std.mem.indexOf(u8, message, "\r\n\r\n") orelse return "";
    return message[at + 4 ..];
}

pub fn exchange(io: std.Io, gpa: std.mem.Allocator, host: []const u8, port: u16, request: []const u8, timeout_ms: i32, limit: usize) ?[]u8 {
    const connect_ms: i32 = if (timeout_ms > 3000) 3000 else timeout_ms;
    const fd = openTcp(host, port, connect_ms) orelse return null;
    defer close(fd);
    if (!writeAll(fd, request)) return null;
    var inbox: std.ArrayList(u8) = .empty;
    defer inbox.deinit(gpa);
    const deadline = sys.monoMs(io) + timeout_ms;
    var tmp: [4096]u8 = undefined;
    while (sys.monoMs(io) < deadline and inbox.items.len < limit) {
        if (std.mem.indexOf(u8, inbox.items, "\r\n\r\n") != null) break;
        const left: i32 = @intCast(@max(deadline - sys.monoMs(io), 1));
        if (!pollIn(fd, @min(left, 1000))) {
            if (sys.monoMs(io) >= deadline) break;
            continue;
        }
        const got = readSome(fd, &tmp) orelse break;
        inbox.appendSlice(gpa, got) catch return null;
    }
    const split = std.mem.indexOf(u8, inbox.items, "\r\n\r\n") orelse return null;
    const need: ?usize = blk: {
        const raw = headerValue(inbox.items[0 .. split + 4], "Content-Length") orelse break :blk null;
        break :blk std.fmt.parseInt(usize, raw, 10) catch null;
    };
    if (need) |n| {
        const total = split + 4 + n;
        while (inbox.items.len < total and inbox.items.len < limit and sys.monoMs(io) < deadline) {
            const left: i32 = @intCast(@max(deadline - sys.monoMs(io), 1));
            if (!pollIn(fd, @min(left, 1000))) continue;
            const got = readSome(fd, &tmp) orelse break;
            inbox.appendSlice(gpa, got) catch return null;
        }
    } else {
        while (inbox.items.len < limit and sys.monoMs(io) < deadline) {
            if (!pollIn(fd, 200)) break;
            const got = readSome(fd, &tmp) orelse break;
            inbox.appendSlice(gpa, got) catch return null;
        }
    }
    if (statusCode(inbox.items) == null) return null;
    return inbox.toOwnedSlice(gpa) catch null;
}

pub fn udpExchange(io: std.Io, gpa: std.mem.Allocator, payload: []const u8, timeout_ms: i32, limit: usize) ?[]u8 {
    const opened = linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(opened) != .SUCCESS) return null;
    const fd: i32 = @intCast(opened);
    defer close(fd);
    var ttl: i32 = 2;
    _ = linux.setsockopt(fd, linux.SOL.IP, linux.IP.MULTICAST_TTL, @ptrCast(&ttl), @sizeOf(i32));
    var local = sock4(.{ 0, 0, 0, 0 }, 0);
    const bound = linux.bind(fd, @ptrCast(&local), @sizeOf(linux.sockaddr.in));
    if (linux.errno(bound) != .SUCCESS) return null;
    var dest = sock4(.{ 239, 255, 255, 250 }, 1900);
    const sent = linux.sendto(fd, payload.ptr, payload.len, 0, @ptrCast(&dest), @sizeOf(linux.sockaddr.in));
    if (linux.errno(sent) != .SUCCESS) return null;
    var inbox: std.ArrayList(u8) = .empty;
    errdefer inbox.deinit(gpa);
    const deadline = sys.monoMs(io) + timeout_ms;
    var tmp: [2048]u8 = undefined;
    while (sys.monoMs(io) < deadline and inbox.items.len + 1 < limit) {
        const left: i32 = @intCast(@max(deadline - sys.monoMs(io), 1));
        if (!pollIn(fd, @min(left, 400))) continue;
        var from = linux.sockaddr.in{ .port = 0, .addr = 0 };
        var from_len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
        const n = linux.recvfrom(fd, &tmp, tmp.len, 0, @ptrCast(&from), &from_len);
        if (linux.errno(n) != .SUCCESS or n == 0) continue;
        inbox.appendSlice(gpa, tmp[0..n]) catch return null;
        inbox.append(gpa, '\n') catch return null;
    }
    if (inbox.items.len == 0) {
        inbox.deinit(gpa);
        return null;
    }
    return inbox.toOwnedSlice(gpa) catch null;
}

test "http exchange reads a status and a header" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var port: u16 = 0;
    var ready = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, struct {
        fn serve(out_port: *u16, flag: *std.atomic.Value(bool)) void {
            const listener = listenTcp(0) orelse return;
            defer close(listener.fd);
            out_port.* = listener.port;
            flag.store(true, .release);
            if (!pollIn(listener.fd, 2000)) return;
            var sa = linux.sockaddr.in{ .port = 0, .addr = 0 };
            var slen: linux.socklen_t = @sizeOf(linux.sockaddr.in);
            const accepted = linux.accept4(listener.fd, @ptrCast(&sa), &slen, linux.SOCK.CLOEXEC);
            if (linux.errno(accepted) != .SUCCESS) return;
            const fd: i32 = @intCast(accepted);
            defer close(fd);
            var buf: [1024]u8 = undefined;
            var got: usize = 0;
            while (got < buf.len and std.mem.indexOf(u8, buf[0..got], "\r\n\r\n") == null) {
                if (!pollIn(fd, 1000)) break;
                const n = linux.read(fd, buf[got..].ptr, buf.len - got);
                if (linux.errno(n) != .SUCCESS or n == 0) break;
                got += n;
            }
            const reply = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nX-Test: yes\r\nConnection: close\r\n\r\nok";
            _ = writeAll(fd, reply);
        }
    }.serve, .{ &port, &ready });
    var spins: usize = 0;
    while (!ready.load(.acquire) and spins < 50) : (spins += 1) sys.sleepMs(io, 20);
    try std.testing.expect(port != 0);
    const response = exchange(io, gpa, "127.0.0.1", port, "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n", 2000, 4096) orelse return error.TestUnexpectedResult;
    defer gpa.free(response);
    thread.join();
    try std.testing.expectEqual(@as(u16, 200), statusCode(response).?);
    try std.testing.expectEqualStrings("yes", headerValue(response, "X-Test").?);
    try std.testing.expectEqualStrings("ok", bodyOf(response));
}
