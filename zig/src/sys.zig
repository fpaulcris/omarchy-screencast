const std = @import("std");

const linux = std.os.linux;

pub fn envGet(map: *const std.process.Environ.Map, key: []const u8) ?[]const u8 {
    return map.get(key);
}

pub fn runtimeDir(gpa: std.mem.Allocator, map: *const std.process.Environ.Map) ![]u8 {
    if (envGet(map, "XDG_RUNTIME_DIR")) |base| {
        if (base.len > 0) return std.fmt.allocPrint(gpa, "{s}/screenmirror", .{base});
    }
    const home = envGet(map, "HOME") orelse return error.NoHome;
    return std.fmt.allocPrint(gpa, "{s}/.cache/screenmirror", .{home});
}

pub fn castPath(gpa: std.mem.Allocator, map: *const std.process.Environ.Map) ![]u8 {
    const home = envGet(map, "HOME") orelse return error.NoHome;
    return std.fmt.allocPrint(gpa, "{s}/.config/screenmirror/cast.json", .{home});
}

pub fn join(gpa: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, name });
}

pub fn ensureDir(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().createDirPath(io, path) catch {};
}

pub fn readAll(io: std.Io, gpa: std.mem.Allocator, path: []const u8, limit: usize) ?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(limit)) catch null;
}

pub fn writeAll(io: std.Io, path: []const u8, data: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

pub fn flagOn(io: std.Io, gpa: std.mem.Allocator, path: []const u8) bool {
    const text = readAll(io, gpa, path, 16) orelse return false;
    defer gpa.free(text);
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    return trimmed.len > 0 and trimmed[0] == '1';
}

pub fn setFlag(io: std.Io, path: []const u8, on: bool) !void {
    try writeAll(io, path, if (on) "1\n" else "0\n");
}

pub fn removeFile(io: std.Io, path: []const u8) void {
    std.Io.Dir.cwd().deleteFile(io, path) catch {};
}

pub const Command = struct {
    term_ok: bool,
    stdout: []u8,
    stderr: []u8,
};

pub fn run(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8, timeout_ms: i64, stdout_limit: usize) !Command {
    const result = try std.process.run(gpa, io, .{
        .argv = argv,
        .stdout_limit = .limited(stdout_limit),
        .stderr_limit = .limited(256 * 1024),
        .timeout = .{ .duration = .{ .raw = .fromMilliseconds(timeout_ms), .clock = .awake } },
    });
    return .{
        .term_ok = result.term.success(),
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

pub fn runQuiet(gpa: std.mem.Allocator, io: std.Io, argv: []const []const u8, timeout_ms: i64) bool {
    const result = run(gpa, io, argv, timeout_ms, 64 * 1024) catch return false;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    return result.term_ok;
}

// Zig 0.17's Io connect panics when a timeout is set. Probe and Cast need one.
pub fn connectStream(address: std.Io.net.IpAddress, timeout_ms: i32) ?std.Io.net.Stream {
    const ip4 = switch (address) {
        .ip4 => |ip| ip,
        .ip6 => return null,
    };
    const opened = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, 0);
    if (linux.errno(opened) != .SUCCESS) return null;
    const fd: i32 = @intCast(opened);
    var sa = linux.sockaddr.in{
        .port = std.mem.nativeToBig(u16, ip4.port),
        // The kernel reads this u32 as network-order bytes. On little-endian
        // a plain readInt leaves 192.168.0.237 as 237.0.168.192.
        .addr = std.mem.nativeToBig(u32, std.mem.readInt(u32, &ip4.bytes, .big)),
    };
    const connected = linux.connect(fd, &sa, @sizeOf(linux.sockaddr.in));
    const err = linux.errno(connected);
    if (err != .SUCCESS) {
        if (err != .INPROGRESS and err != .AGAIN) {
            _ = linux.close(fd);
            return null;
        }
        var pfd = linux.pollfd{ .fd = fd, .events = linux.POLL.OUT };
        const waited = linux.poll(@ptrCast(&pfd), 1, timeout_ms);
        if (linux.errno(waited) != .SUCCESS or waited == 0) {
            _ = linux.close(fd);
            return null;
        }
        var so_error: i32 = 0;
        var so_len: linux.socklen_t = @sizeOf(i32);
        const got = linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.ERROR, @ptrCast(&so_error), &so_len);
        if (linux.errno(got) != .SUCCESS or so_error != 0) {
            _ = linux.close(fd);
            return null;
        }
    }
    const flags = linux.fcntl(fd, linux.F.GETFL, 0);
    if (linux.errno(flags) == .SUCCESS) {
        const nonblock: usize = 1 << @bitOffsetOf(linux.O, "NONBLOCK");
        _ = linux.fcntl(fd, linux.F.SETFL, flags & ~nonblock);
    }
    return .{ .socket = .{ .handle = fd, .address = address } };
}

pub fn sleepMs(io: std.Io, ms: i64) void {
    io.sleep(.fromMilliseconds(ms), .awake) catch {};
}

pub fn monoMs(io: std.Io) i64 {
    const now = std.Io.Timestamp.now(io, .awake);
    return @intCast(@divTrunc(now.nanoseconds, 1_000_000));
}

pub fn fileMtimeMs(io: std.Io, path: []const u8) ?i64 {
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch return null;
    return @intCast(@divTrunc(stat.mtime.nanoseconds, 1_000_000));
}

pub fn lanIp(gpa: std.mem.Allocator, io: std.Io) []u8 {
    const result = run(gpa, io, &.{ "ip", "-4", "route", "get", "1.1.1.1" }, 2000, 1024) catch {
        return gpa.dupe(u8, "127.0.0.1") catch unreachable;
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (std.mem.indexOf(u8, result.stdout, " src ")) |at| {
        const rest = result.stdout[at + 5 ..];
        const end = std.mem.indexOfScalar(u8, rest, ' ') orelse std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        if (end > 0) return gpa.dupe(u8, rest[0..end]) catch gpa.dupe(u8, "127.0.0.1") catch unreachable;
    }
    return gpa.dupe(u8, "127.0.0.1") catch unreachable;
}

pub fn exists(io: std.Io, path: []const u8) bool {
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

pub fn commandPath(gpa: std.mem.Allocator, io: std.Io, map: *const std.process.Environ.Map, name: []const u8) ?[]u8 {
    const path = envGet(map, "PATH") orelse return null;
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const full = std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, name }) catch return null;
        if (exists(io, full)) return full;
        gpa.free(full);
    }
    return null;
}

pub fn hexToken(io: std.Io, out: []u8) !void {
    var raw: [16]u8 = undefined;
    try io.randomSecure(raw[0..out.len / 2]);
    const hex = "0123456789abcdef";
    for (raw[0 .. out.len / 2], 0..) |byte, i| {
        out[i * 2] = hex[byte >> 4];
        out[i * 2 + 1] = hex[byte & 0xf];
    }
}

pub fn pidAlive(pid: i32) bool {
    if (pid <= 0) return false;
    const rc = linux.kill(pid, @enumFromInt(0));
    return linux.errno(rc) == .SUCCESS;
}

pub fn clearDir(io: std.Io, path: []const u8) void {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        dir.deleteFile(io, entry.name) catch {};
    }
}

pub fn h264Level(width: u32, height: u32) []const u8 {
    const blocks = ((width + 15) / 16) * ((height + 15) / 16);
    if (width <= 1280 and height <= 720 and blocks <= 3600) return "3.1";
    if (width <= 1920 and height <= 1088 and blocks <= 8192) return "4.0";
    if (blocks <= 22080) return "5.0";
    return "5.1";
}

pub fn safeName(text: []const u8) bool {
    if (text.len == 0 or text.len > 64) return false;
    for (text) |byte| {
        const ok = std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '.' or byte == '-';
        if (!ok) return false;
    }
    return true;
}

test "preview flag round trip" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const path = ".zig-cache/preview.on";
    std.Io.Dir.cwd().createDirPath(io, ".zig-cache") catch {};
    removeFile(io, path);
    try std.testing.expect(!flagOn(io, gpa, path));
    try setFlag(io, path, true);
    try std.testing.expect(flagOn(io, gpa, path));
    try setFlag(io, path, false);
    try std.testing.expect(!flagOn(io, gpa, path));
    removeFile(io, path);
}

test "h264 level follows the frame size" {
    try std.testing.expectEqualStrings("3.1", h264Level(1280, 720));
    try std.testing.expectEqualStrings("4.0", h264Level(1920, 1080));
    try std.testing.expectEqualStrings("5.0", h264Level(2560, 1440));
    try std.testing.expectEqualStrings("5.1", h264Level(3840, 2160));
}
