const std = @import("std");
const airplay = @import("airplay.zig");
const cast_session = @import("cast_session.zig");
const dial = @import("dial.zig");
const discover = @import("discover.zig");
const hls = @import("hls.zig");
const jsonx = @import("jsonx.zig");
const report = @import("report.zig");
const sys = @import("sys.zig");
const wfd = @import("wfd.zig");

const linux = std.os.linux;

pub const Listed = struct {
    state: []const u8,
    id: []const u8,
    name: []const u8,
    detail: []const u8,
    url: []const u8,
};

const Rec = struct {
    state: []const u8,
    id: []const u8,
    name: []const u8,
    detail: []const u8,
    url: []const u8,
    pid: i64,
    path: []const u8,
    legacy: bool,
};

pub fn detach(init: std.process.Init, id: []const u8) !void {
    if (id.len == 0 or id.len > 120 or std.mem.indexOfAny(u8, id, " \t\n\"'") != null) return error.BadId;
    const io = init.io;
    const gpa = init.gpa;
    const runtime = try sys.runtimeDir(gpa, init.environ_map);
    sys.ensureDir(io, runtime);
    try ensureMirrors(io, gpa, runtime);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const existing = try load(arena_state.allocator(), io, gpa, runtime);
    for (existing) |item| {
        if (!std.mem.eql(u8, item.id, id)) continue;
        if ((std.mem.eql(u8, item.state, "starting") or std.mem.eql(u8, item.state, "live")) and item.pid > 0 and sys.pidAlive(@intCast(item.pid))) {
            try writeLine(io, "Already mirroring.\n");
            return;
        }
        if (item.pid > 0) killPid(@intCast(item.pid));
        sys.removeFile(io, item.path);
    }
    var exe_buf: [4096]u8 = undefined;
    const exe_len = std.Io.Dir.readLinkAbsolute(io, "/proc/self/exe", &exe_buf) catch return error.Exec;
    exe_buf[exe_len] = 0;
    var id_buf: [128]u8 = undefined;
    @memcpy(id_buf[0..id.len], id);
    id_buf[id.len] = 0;
    const log_path = try sys.join(gpa, runtime, "mirror.log");
    defer gpa.free(log_path);
    var log_z: [512]u8 = undefined;
    if (log_path.len + 1 > log_z.len) return error.Exec;
    @memcpy(log_z[0..log_path.len], log_path);
    log_z[log_path.len] = 0;

    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) return error.Fork;
    if (pid == 0) {
        _ = linux.setsid();
        const devnull = linux.open("/dev/null", .{ .ACCMODE = .RDONLY }, 0);
        const log_fd = linux.open(@ptrCast(&log_z), .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o600);
        if (linux.errno(devnull) == .SUCCESS) _ = linux.dup2(@intCast(devnull), 0);
        if (linux.errno(log_fd) == .SUCCESS) {
            _ = linux.dup2(@intCast(log_fd), 1);
            _ = linux.dup2(@intCast(log_fd), 2);
        }
        const argv = [_:null]?[*:0]const u8{
            @ptrCast(&exe_buf),
            "mirror",
            "--session",
            @ptrCast(&id_buf),
        };
        _ = linux.execve(@ptrCast(&exe_buf), &argv, @ptrCast(std.c.environ));
        linux.exit_group(127);
    }
    try writeState(io, gpa, runtime, "starting", id, "", "Starting.", @intCast(pid), "");
    try writeLine(io, "Starting.\n");
}

pub fn stop(init: std.process.Init, quiet: bool) !void {
    const io = init.io;
    const gpa = init.gpa;
    const runtime = try sys.runtimeDir(gpa, init.environ_map);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const found = load(arena_state.allocator(), io, gpa, runtime) catch &.{};
    var pids: [32]i32 = undefined;
    var n: usize = 0;
    for (found) |item| {
        if (item.pid <= 0 or n >= pids.len) continue;
        pids[n] = @intCast(item.pid);
        n += 1;
    }
    killMany(pids[0..n]);
    for (found) |item| sys.removeFile(io, item.path);
    const token = sys.join(gpa, runtime, "hls.token") catch null;
    if (token) |path| {
        defer gpa.free(path);
        sys.removeFile(io, path);
    }
    if (!quiet) try writeLine(io, "Stopped.\n");
}

pub fn stopOne(init: std.process.Init, id: []const u8) !void {
    if (id.len == 0 or id.len > 120) return error.BadId;
    const io = init.io;
    const gpa = init.gpa;
    const runtime = try sys.runtimeDir(gpa, init.environ_map);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const found = load(arena_state.allocator(), io, gpa, runtime) catch &.{};
    var pids: [8]i32 = undefined;
    var n: usize = 0;
    for (found) |item| {
        if (!std.mem.eql(u8, item.id, id)) continue;
        if (item.pid > 0 and n < pids.len) {
            pids[n] = @intCast(item.pid);
            n += 1;
        }
    }
    killMany(pids[0..n]);
    for (found) |item| if (std.mem.eql(u8, item.id, id)) sys.removeFile(io, item.path);
    var still = false;
    const left = load(arena_state.allocator(), io, gpa, runtime) catch &.{};
    for (left) |item| {
        if (std.mem.eql(u8, item.state, "starting") or std.mem.eql(u8, item.state, "live")) still = true;
    }
    if (!still) {
        const token = sys.join(gpa, runtime, "hls.token") catch null;
        if (token) |path| {
            defer gpa.free(path);
            sys.removeFile(io, path);
        }
    }
    try writeLine(io, "Stopped.\n");
}

pub fn listed(arena: std.mem.Allocator, io: std.Io, gpa: std.mem.Allocator, runtime: []const u8) ![]Listed {
    const found = try load(arena, io, gpa, runtime);
    var out: std.ArrayList(Listed) = .empty;
    for (found) |item| {
        if (std.mem.eql(u8, item.state, "stopped")) continue;
        var state_name = item.state;
        var detail = item.detail;
        var pid = item.pid;
        if ((std.mem.eql(u8, state_name, "starting") or std.mem.eql(u8, state_name, "live")) and pid > 0 and !sys.pidAlive(@intCast(pid))) {
            state_name = "failed";
            detail = "The cast ended.";
            pid = 0;
            writeState(io, gpa, runtime, state_name, item.id, item.name, detail, 0, item.url) catch {};
            if (item.legacy) sys.removeFile(io, item.path);
        }
        try out.append(arena, .{
            .state = state_name,
            .id = item.id,
            .name = item.name,
            .detail = detail,
            .url = item.url,
        });
    }
    return out.items;
}

pub fn status(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const runtime = try sys.runtimeDir(gpa, init.environ_map);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const sessions = listed(arena_state.allocator(), io, gpa, runtime) catch &.{};
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try body.appendSlice(gpa, "{\"sessions\":[");
    for (sessions, 0..) |item, index| {
        if (index != 0) try body.appendSlice(gpa, ",");
        try appendSession(gpa, &body, item);
    }
    try body.appendSlice(gpa, "]}\n");
    try writeLine(io, body.items);
}

var mirror_stop = std.atomic.Value(bool).init(false);

fn onMirrorStop(_: linux.SIG) callconv(.c) void {
    mirror_stop.store(true, .release);
}

pub fn session(init: std.process.Init, id: []const u8) void {
    var act = std.posix.Sigaction{
        .handler = .{ .handler = onMirrorStop },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.TERM, &act, null);
    std.posix.sigaction(.INT, &act, null);
    runSession(init, id) catch |err| {
        const io = init.io;
        const gpa = init.gpa;
        const runtime = sys.runtimeDir(gpa, init.environ_map) catch return;
        const detail = report.get();
        const text = if (detail.len > 0) detail else @errorName(err);
        writeState(io, gpa, runtime, "failed", id, "", text, 0, "") catch {};
    };
}

const Active = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    runtime: []const u8,
    id: []const u8,
    name: []const u8,
    url: []const u8,
};

var active: ?*Active = null;

fn publishActive(state_name: []const u8, detail: []const u8, pid: i32) void {
    const here = active orelse return;
    const url = if (std.mem.eql(u8, state_name, "live")) here.url else "";
    writeState(here.io, here.gpa, here.runtime, state_name, here.id, here.name, detail, pid, url) catch {};
}

fn runSession(init: std.process.Init, id: []const u8) !void {
    report.clear();
    const io = init.io;
    const gpa = init.gpa;
    const runtime = try sys.runtimeDir(gpa, init.environ_map);
    sys.ensureDir(io, runtime);
    try ensureMirrors(io, gpa, runtime);
    try writeState(io, gpa, runtime, "starting", id, "", "Looking for the receiver.", @intCast(linux.getpid()), "");
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const found = try discover.browse(arena_state.allocator(), gpa, io);
    var device: ?discover.Receiver = null;
    for (found.receivers) |item| if (std.mem.eql(u8, item.id, id)) {
        device = item;
    };
    const receiver = device orelse return error.NoReceiver;
    if (!receiver.can_mirror) return error.CannotMirror;
    const server_up = sys.runQuiet(gpa, io, &.{ "systemctl", "--user", "is-active", "--quiet", "screenmirror.service" }, 3000);
    if (!server_up) {
        if (!sys.runQuiet(gpa, io, &.{ "systemctl", "--user", "start", "screenmirror.service" }, 8000)) return error.NoServer;
    }
    const url_path = try sys.join(gpa, runtime, "url");
    defer gpa.free(url_path);
    var port: u16 = 0;
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        if (sys.readAll(io, gpa, url_path, 256)) |text| {
            defer gpa.free(text);
            port = portFromUrl(text) orelse 0;
            if (port != 0) break;
        }
        sys.sleepMs(io, 150);
    }
    if (port == 0) return error.NoServer;
    var output: []const u8 = "";
    const status_path = try sys.join(gpa, runtime, "status.json");
    defer gpa.free(status_path);
    if (sys.readAll(io, gpa, status_path, 8192)) |text| {
        defer gpa.free(text);
        if (jsonx.parse(arena_state.allocator(), text)) |value| {
            output = (value.get("output") orelse jsonx.Value{ .string = "" }).asString() orelse "";
        } else |_| {}
    }
    const token = try hls.ensureToken(io, gpa, runtime);
    const playlist = try sys.join(gpa, runtime, "hls/live.m3u8");
    defer gpa.free(playlist);
    try writeState(io, gpa, runtime, "starting", id, receiver.name, "Encoding the screen.", @intCast(linux.getpid()), "");
    if (!waitPlaylist(io, playlist)) return error.NoPlaylist;
    const ip = sys.lanIp(gpa, io);
    defer gpa.free(ip);
    const watch = try std.fmt.allocPrint(gpa, "http://{s}:{d}/hls/{s}/live.m3u8", .{ ip, port, token });
    defer gpa.free(watch);
    const page = try std.fmt.allocPrint(gpa, "http://{s}:{d}/", .{ ip, port });
    defer gpa.free(page);
    const hls_dir = try sys.join(gpa, runtime, "hls");
    defer gpa.free(hls_dir);
    try writeState(io, gpa, runtime, "starting", id, receiver.name, "Connecting.", @intCast(linux.getpid()), watch);
    report.bind(publishActive, stateStop);
    defer report.unbind();
    var here = Active{
        .io = io,
        .gpa = gpa,
        .runtime = runtime,
        .id = id,
        .name = receiver.name,
        .url = watch,
    };
    active = &here;
    defer active = null;
    if (std.mem.eql(u8, receiver.protocol, "Chromecast")) {
        try runCast(io, gpa, arena_state.allocator(), runtime, id, receiver.name, receiver.address, receiver.port, watch, playlist, status_path, output);
    } else if (std.mem.eql(u8, receiver.protocol, "AirPlay")) {
        try airplay.run(io, gpa, receiver.address, receiver.port, watch, playlist);
    } else if (std.mem.eql(u8, receiver.protocol, "Miracast")) {
        try wfd.run(io, gpa, receiver.address, receiver.port, ip, hls_dir, playlist);
    } else if (std.mem.eql(u8, receiver.protocol, "Fire TV")) {
        try dial.runDesktop(io, gpa, receiver.address, receiver.port, receiver.uuid, page, watch, playlist);
    } else return error.CannotMirror;
}

fn runCast(
    io: std.Io,
    gpa: std.mem.Allocator,
    arena: std.mem.Allocator,
    runtime: []const u8,
    id: []const u8,
    name: []const u8,
    address: []const u8,
    port: u16,
    watch: []const u8,
    playlist: []const u8,
    status_path: []const u8,
    output: []const u8,
) !void {
    const session_ptr = try cast_session.Session.open(gpa, io, address, port);
    defer session_ptr.close();
    defer gpa.destroy(session_ptr);
    session_ptr.getStatus() catch |err| {
        note(session_ptr);
        return err;
    };
    session_ptr.launch() catch |err| {
        note(session_ptr);
        return err;
    };
    session_ptr.load(watch) catch |err| {
        note(session_ptr);
        return err;
    };
    try writeState(io, gpa, runtime, "live", id, name, "Mirroring.", @intCast(linux.getpid()), watch);
    var stall = sys.monoMs(io);
    var seen_output = output;
    while (!stateStop()) {
        try session_ptr.pump();
        if (session_ptr.failure_len != 0) return error.CastClosed;
        if (session_ptr.playbackFailure()) |_| return error.Playback;
        if (fresh(io, playlist, 8000)) stall = sys.monoMs(io) else if (sys.monoMs(io) - stall > 12000) return error.Stalled;
        if (sys.readAll(io, gpa, status_path, 8192)) |text| {
            defer gpa.free(text);
            if (jsonx.parse(arena, text)) |value| {
                const current = (value.get("output") orelse jsonx.Value{ .string = "" }).asString() orelse "";
                if (current.len > 0 and !std.mem.eql(u8, current, seen_output)) {
                    seen_output = try arena.dupe(u8, current);
                    session_ptr.load(watch) catch |err| return err;
                    stall = sys.monoMs(io);
                }
            } else |_| {}
        }
        sys.sleepMs(io, 200);
    }
    session_ptr.stopApp();
    try writeState(io, gpa, runtime, "stopped", id, name, "Stopped.", 0, "");
}

fn stateStop() bool {
    return mirror_stop.load(.acquire);
}

fn note(session_ptr: *cast_session.Session) void {
    if (session_ptr.failure_len == 0) return;
    var buf: [400]u8 = undefined;
    var err_w: std.Io.File.Writer = .init(.stderr(), session_ptr.io, &buf);
    err_w.interface.print("cast failed {s}\n", .{session_ptr.failure[0..session_ptr.failure_len]}) catch {};
    err_w.interface.flush() catch {};
}

fn waitPlaylist(io: std.Io, path: []const u8) bool {
    var i: usize = 0;
    while (i < 80) : (i += 1) {
        if (sys.readAll(io, std.heap.page_allocator, path, 64 * 1024)) |text| {
            defer std.heap.page_allocator.free(text);
            if (std.mem.count(u8, text, "#EXTINF") >= 16 and std.mem.indexOf(u8, text, ".ts") != null) return true;
        }
        sys.sleepMs(io, 200);
    }
    return false;
}

fn fresh(io: std.Io, path: []const u8, window: i64) bool {
    const mtime = sys.fileMtimeMs(io, path) orelse return false;
    return sys.monoMs(io) - mtime <= window;
}

fn portFromUrl(text: []const u8) ?u16 {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    const mark = std.mem.lastIndexOfScalar(u8, trimmed, ':') orelse return null;
    const rest = trimmed[mark + 1 ..];
    const end = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    return std.fmt.parseInt(u16, rest[0..end], 10) catch null;
}

fn writeState(io: std.Io, gpa: std.mem.Allocator, runtime: []const u8, state_name: []const u8, id: []const u8, name: []const u8, detail: []const u8, pid: i32, url: []const u8) !void {
    ensureMirrors(io, gpa, runtime) catch {};
    const path = try sessionFile(gpa, runtime, id);
    defer gpa.free(path);
    var buf: [2048]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.writeAll("{\"state\":");
    try jsonx.escape(&w, state_name);
    try w.writeAll(",\"id\":");
    try jsonx.escape(&w, id);
    try w.writeAll(",\"name\":");
    try jsonx.escape(&w, name);
    try w.writeAll(",\"detail\":");
    try jsonx.escape(&w, detail);
    try w.print(",\"pid\":{d},\"url\":", .{pid});
    try jsonx.escape(&w, url);
    try w.writeAll("}\n");
    try sys.writeAll(io, path, w.buffered());
}

fn ensureMirrors(io: std.Io, gpa: std.mem.Allocator, runtime: []const u8) !void {
    const dir = try sys.join(gpa, runtime, "mirrors");
    defer gpa.free(dir);
    sys.ensureDir(io, dir);
}

fn sessionFile(gpa: std.mem.Allocator, runtime: []const u8, id: []const u8) ![]u8 {
    var name_buf: [128]u8 = undefined;
    const name = try fileName(id, &name_buf);
    const dir = try sys.join(gpa, runtime, "mirrors");
    defer gpa.free(dir);
    return sys.join(gpa, dir, name);
}

fn fileName(id: []const u8, buf: *[128]u8) ![]const u8 {
    if (id.len == 0 or id.len > 120 or id.len + 5 > buf.len) return error.BadId;
    for (id, 0..) |byte, index| {
        const ok = std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '_' or byte == '-';
        buf[index] = if (ok) byte else '_';
    }
    @memcpy(buf[id.len..][0..5], ".json");
    return buf[0 .. id.len + 5];
}

fn load(arena: std.mem.Allocator, io: std.Io, gpa: std.mem.Allocator, runtime: []const u8) ![]Rec {
    var items: std.ArrayList(Rec) = .empty;
    const dir_path = try sys.join(gpa, runtime, "mirrors");
    defer gpa.free(dir_path);
    if (std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true })) |dir_open| {
        var dir = dir_open;
        defer dir.close(io);
        var names: std.ArrayList([]u8) = .empty;
        defer {
            for (names.items) |name| gpa.free(name);
            names.deinit(gpa);
        }
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
            try names.append(gpa, try gpa.dupe(u8, entry.name));
        }
        for (names.items) |name| {
            const path = try sys.join(gpa, dir_path, name);
            defer gpa.free(path);
            try appendParsed(arena, io, gpa, &items, path, false);
        }
    } else |_| {}
    const legacy = try sys.join(gpa, runtime, "mirror.json");
    defer gpa.free(legacy);
    try appendParsed(arena, io, gpa, &items, legacy, true);
    return items.items;
}

fn appendParsed(arena: std.mem.Allocator, io: std.Io, gpa: std.mem.Allocator, items: *std.ArrayList(Rec), path: []const u8, legacy: bool) !void {
    const text = sys.readAll(io, gpa, path, 8192) orelse return;
    defer gpa.free(text);
    const value = jsonx.parse(arena, text) catch return;
    const id = (value.get("id") orelse jsonx.Value{ .string = "" }).asString() orelse "";
    if (id.len == 0) return;
    if (legacy) {
        for (items.items) |item| if (std.mem.eql(u8, item.id, id)) return;
    }
    const state_name = (value.get("state") orelse jsonx.Value{ .string = "" }).asString() orelse "stopped";
    if (std.mem.eql(u8, state_name, "stopped")) {
        sys.removeFile(io, path);
        return;
    }
    try items.append(arena, .{
        .state = state_name,
        .id = id,
        .name = (value.get("name") orelse jsonx.Value{ .string = "" }).asString() orelse "",
        .detail = (value.get("detail") orelse jsonx.Value{ .string = "" }).asString() orelse "",
        .url = (value.get("url") orelse jsonx.Value{ .string = "" }).asString() orelse "",
        .pid = if (value.get("pid")) |item| item.asInt() orelse 0 else 0,
        .path = try arena.dupe(u8, path),
        .legacy = legacy,
    });
}

fn appendSession(gpa: std.mem.Allocator, body: *std.ArrayList(u8), item: Listed) !void {
    var buf: [1024]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try w.writeAll("{\"state\":");
    try jsonx.escape(&w, item.state);
    try w.writeAll(",\"id\":");
    try jsonx.escape(&w, item.id);
    try w.writeAll(",\"name\":");
    try jsonx.escape(&w, item.name);
    try w.writeAll(",\"detail\":");
    try jsonx.escape(&w, item.detail);
    try w.writeAll(",\"url\":");
    try jsonx.escape(&w, item.url);
    try w.writeAll("}");
    try body.appendSlice(gpa, w.buffered());
}

fn killMany(pids: []const i32) void {
    for (pids) |pid| if (pid > 0) {
        _ = linux.kill(pid, .TERM);
    };
    var left: usize = 0;
    while (left < 30) : (left += 1) {
        var alive = false;
        for (pids) |pid| if (pid > 0 and sys.pidAlive(pid)) {
            alive = true;
        };
        if (!alive) return;
        var req = linux.timespec{ .sec = 0, .nsec = 100 * 1000 * 1000 };
        _ = linux.nanosleep(&req, null);
    }
    for (pids) |pid| if (pid > 0 and sys.pidAlive(pid)) {
        _ = linux.kill(pid, .KILL);
    };
}

fn killPid(pid: i32) void {
    if (pid <= 0) return;
    var one = [_]i32{pid};
    killMany(&one);
}

fn writeLine(io: std.Io, text: []const u8) !void {
    var out_buf: [1024]u8 = undefined;
    var out_w: std.Io.File.Writer = .init(.stdout(), io, &out_buf);
    var off: usize = 0;
    while (off < text.len) {
        const n = @min(out_buf.len, text.len - off);
        try out_w.interface.writeAll(text[off .. off + n]);
        try out_w.interface.flush();
        off += n;
    }
}

test "session file name keeps the address" {
    var buf: [128]u8 = undefined;
    const name = try fileName("Chromecast:192.168.0.190", &buf);
    try std.testing.expectEqualStrings("Chromecast_192.168.0.190.json", name);
}
