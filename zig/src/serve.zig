const std = @import("std");
const capture = @import("capture.zig");
const httpd = @import("httpd.zig");
const hypr = @import("hypr.zig");
const jsonx = @import("jsonx.zig");
const mirror = @import("mirror.zig");
const mjpeg = @import("mjpeg.zig");
const state = @import("state.zig");
const sys = @import("sys.zig");

const linux = std.os.linux;

fn onStop(_: linux.SIG) callconv(.c) void {
    state.shutdown.store(true, .release);
    const gsr = state.gsr_pid.load(.acquire);
    if (gsr > 0) _ = linux.kill(gsr, .KILL);
    const jpeg = state.jpeg_pid.load(.acquire);
    if (jpeg > 0) _ = linux.kill(jpeg, .KILL);
    const audio = state.audio_pid.load(.acquire);
    if (audio > 0) _ = linux.kill(audio, .KILL);
}

pub fn run(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const env = init.environ_map;
    var act = std.posix.Sigaction{
        .handler = .{ .handler = onStop },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.TERM, &act, null);
    std.posix.sigaction(.INT, &act, null);

    const runtime = try sys.runtimeDir(gpa, env);
    sys.ensureDir(io, runtime);
    const world = try gpa.create(state.World);
    const frame = try gpa.alloc(u8, state.frame_cap);
    const ip = sys.lanIp(gpa, io);
    const output = try gpa.dupe(u8, "");
    world.* = .{
        .io = io,
        .gpa = gpa,
        .runtime = runtime,
        .frame = frame,
        .output = output,
        .ports = &.{},
        .ip = ip,
    };
    defer {
        gpa.free(world.frame);
        gpa.free(world.output);
        gpa.free(world.runtime);
        gpa.free(world.ip);
        if (world.ports.len > 0) gpa.free(world.ports);
        gpa.destroy(world);
    }

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const cast_file = try sys.castPath(gpa, env);
    defer gpa.free(cast_file);
    const cast = hypr.readCast(arena_state.allocator(), io, gpa, cast_file);
    const planned = hypr.plan(arena_state.allocator(), io, gpa, runtime, cast) catch hypr.Plan{
        .output = try gpa.dupe(u8, "HDMI-A-1"),
        .width = 1920,
        .height = 1080,
        .follow = true,
        .virtual_out = false,
        .workspace = 1,
    };
    try applyPlan(world, planned);
    try preferOutput(world, env);
    hypr.setWatch(if (planned.follow) 0 else planned.workspace, !planned.follow and !planned.virtual_out);
    hypr.startWatch(env);
    defer hypr.finishWatch();
    try writeStatus(world, false);

    const preferred: capture.Mode = if (forcedScreencopy(env))
        .screen
    else if (sys.exists(io, "/usr/bin/gpu-screen-recorder"))
        .gsr
    else
        .screen;
    var slot = Slot{
        .mode = preferred,
        .jpeg_window = sys.monoMs(io),
        .pipe_window = sys.monoMs(io),
    };
    defer {
        stopJpeg(gpa, &slot);
        stopPipe(gpa, &slot);
    }

    const want = parsePorts(env);
    const bound = try httpd.bind(world, &want);
    if (bound.len == 0) {
        log(io, "screenmirror: the stream is already running.\n", .{});
        std.process.exit(0);
    }
    world.ports = bound;
    world.listening = true;
    try writeStatus(world, false);
    log(io, "Primary URL: http://{s}:{d}/\n", .{ world.ip, world.ports[0] });

    var cast_mtime = sys.fileMtimeMs(io, cast_file) orelse 0;
    var reported: ?bool = null;
    var shown_virtual = world.virtual_out;
    var last_layout = sys.monoMs(io);
    var desk_seen = hypr.deskToken();
    while (!state.shutdown.load(.acquire)) {
        if (state.shutdown.load(.acquire)) break;
        const now = sys.monoMs(io);
        const mtime = sys.fileMtimeMs(io, cast_file) orelse 0;
        const mtime_changed = mtime != cast_mtime;
        if (hypr.takeDirty() or mtime_changed or now - last_layout >= 1000) {
            if (mtime_changed) cast_mtime = mtime;
            last_layout = now;
            hypr.setQuiet(true);
            defer hypr.setQuiet(false);
            _ = arena_state.reset(.retain_capacity);
            const next_cast = hypr.readCast(arena_state.allocator(), io, gpa, cast_file);
            const depart = hypr.takeDepart();
            const preview = hypr.previewTarget(arena_state.allocator(), io, gpa, next_cast) catch null;
            const switch_target = if (preview) |place| (place == .virtual) != world.virtual_out else false;
            if (depart or switch_target) {
                stopJpeg(gpa, &slot);
                stopPipe(gpa, &slot);
            }
            if (hypr.plan(arena_state.allocator(), io, gpa, runtime, next_cast)) |next| {
                const was_virtual = world.virtual_out;
                const was_follow = world.follow;
                applyPlan(world, next) catch {
                    state.shutdown.store(true, .release);
                    break;
                };
                preferOutput(world, env) catch {
                    state.shutdown.store(true, .release);
                    break;
                };
                hypr.setWatch(if (world.follow) 0 else world.workspace, !world.follow and !world.virtual_out);
                if (world.virtual_out != was_virtual or world.follow != was_follow) {
                    if (world.follow) {
                        log(io, "following this screen\n", .{});
                    } else if (world.virtual_out) {
                        log(io, "desktop {d} is on the virtual screen\n", .{world.workspace});
                    } else {
                        log(io, "showing desktop {d} on the laptop\n", .{world.workspace});
                    }
                }
            } else |err| {
                log(io, "desktop layout did not update: {s}\n", .{@errorName(err)});
            }
        }
        const want_jpeg = browserOn(io, gpa, env);
        const want_h264 = deviceOn(io, gpa, runtime);
        reconcile(io, gpa, env, world, &slot, preferred, want_jpeg, want_h264);
        if (captureGaveUp(&slot, want_jpeg, want_h264)) {
            log(io, "capture stopped too many times\n", .{});
            state.shutdown.store(true, .release);
            break;
        }
        const ready = pictureReady(world, &slot, want_jpeg, want_h264);
        if (reported == null or reported.? != ready or shown_virtual != world.virtual_out) {
            try writeStatus(world, ready);
            reported = ready;
            shown_virtual = world.virtual_out;
        }
        desk_seen = hypr.waitDesk(desk_seen, 200);
    }

    world.stop.store(true, .release);
    var cleanup = std.heap.ArenaAllocator.init(gpa);
    defer cleanup.deinit();
    hypr.release(cleanup.allocator(), io, gpa, world.runtime);
    const url_path = try sys.join(gpa, world.runtime, "url");
    defer gpa.free(url_path);
    const status_path = try sys.join(gpa, world.runtime, "status.json");
    defer gpa.free(status_path);
    sys.removeFile(io, url_path);
    sys.removeFile(io, status_path);
}

const Slot = struct {
    jpeg: ?*mjpeg.Pump = null,
    pipe: ?*capture.Pipeline = null,
    mode: capture.Mode,
    jpeg_fails: u8 = 0,
    pipe_fails: u8 = 0,
    jpeg_window: i64,
    pipe_window: i64,
    jpeg_gave_up: bool = false,
    pipe_gave_up: bool = false,
    jpeg_base: u64 = 0,
    pipe_base: u64 = 0,
    pipe_started: i64 = 0,
};

fn forcedScreencopy(env: *const std.process.Environ.Map) bool {
    const forced = sys.envGet(env, "MIRROR_CAPTURE") orelse return false;
    return std.mem.eql(u8, forced, "screencopy");
}

fn stopJpeg(gpa: std.mem.Allocator, slot: *Slot) void {
    const pump = slot.jpeg orelse return;
    slot.jpeg = null;
    pump.halt();
    gpa.destroy(pump);
}

fn stopPipe(gpa: std.mem.Allocator, slot: *Slot) void {
    const pipe = slot.pipe orelse return;
    slot.pipe = null;
    pipe.halt();
    gpa.destroy(pipe);
}

fn noteFail(io: std.Io, fails: *u8, window: *i64, gave_up: *bool) void {
    const now = sys.monoMs(io);
    if (now - window.* > 30000) {
        window.* = now;
        fails.* = 0;
    }
    fails.* += 1;
    if (fails.* > 3) gave_up.* = true;
}

fn reconcile(
    io: std.Io,
    gpa: std.mem.Allocator,
    env: *const std.process.Environ.Map,
    world: *state.World,
    slot: *Slot,
    preferred: capture.Mode,
    want_jpeg: bool,
    want_h264: bool,
) void {
    const now = sys.monoMs(io);
    if (want_jpeg) {
        const pump = slot.jpeg;
        const died = if (pump) |item| item.exited() else false;
        const moved = if (pump) |item| !item.matches(world.output, world.width, world.height) else false;
        const current = pump != null and !died and !moved;
        if (!current) {
            const had = pump != null;
            stopJpeg(gpa, slot);
            if (!slot.jpeg_gave_up) {
                hypr.wake(io, gpa);
                slot.jpeg = mjpeg.Pump.start(io, gpa, world, env, world.output, world.width, world.height) catch |err| blk: {
                    log(io, "browser capture did not start: {s}\n", .{@errorName(err)});
                    break :blk null;
                };
                if (slot.jpeg != null) slot.jpeg_base = world.frameCount();
            }
            if (slot.jpeg == null or (had and died and !moved)) noteFail(io, &slot.jpeg_fails, &slot.jpeg_window, &slot.jpeg_gave_up);
        }
    } else {
        if (slot.jpeg != null) {
            stopJpeg(gpa, slot);
            world.clearFrame();
        }
        slot.jpeg_fails = 0;
        slot.jpeg_gave_up = false;
    }

    if (want_h264) {
        var restart = slot.pipe == null;
        var failed = false;
        if (slot.pipe) |pipe| {
            const dead = pipe.captureExited();
            const stale = slot.mode == .gsr and now - slot.pipe_started > 4000 and state.videoCount() == slot.pipe_base;
            const moved = !std.mem.eql(u8, pipe.output, world.output) or pipe.width != world.width or pipe.height != world.height;
            if (dead or stale or moved) {
                if ((dead or stale) and slot.mode == .gsr and state.videoCount() == slot.pipe_base) {
                    log(io, "capture: gpu-screen-recorder produced no frame, using screencopy\n", .{});
                    slot.mode = .screen;
                }
                stopPipe(gpa, slot);
                restart = true;
                failed = (dead or stale) and !moved;
            }
        }
        if (restart and !slot.pipe_gave_up) {
            if (failed) noteFail(io, &slot.pipe_fails, &slot.pipe_window, &slot.pipe_gave_up);
            if (!slot.pipe_gave_up) {
                hypr.wake(io, gpa);
                slot.pipe = capture.Pipeline.start(io, gpa, world, env, world.output, world.width, world.height, slot.mode) catch |err| blk: {
                    log(io, "capture did not start: {s}\n", .{@errorName(err)});
                    break :blk null;
                };
                slot.pipe_base = state.videoCount();
                slot.pipe_started = now;
                if (slot.pipe == null) noteFail(io, &slot.pipe_fails, &slot.pipe_window, &slot.pipe_gave_up);
            }
        }
    } else {
        if (slot.pipe != null) stopPipe(gpa, slot);
        slot.pipe_fails = 0;
        slot.pipe_gave_up = false;
        slot.mode = preferred;
    }
}

fn captureGaveUp(slot: *const Slot, want_jpeg: bool, want_h264: bool) bool {
    const jpeg_dead = want_jpeg and slot.jpeg_gave_up;
    const pipe_dead = want_h264 and slot.pipe_gave_up;
    if (want_jpeg and want_h264) return jpeg_dead and pipe_dead;
    return jpeg_dead or pipe_dead;
}

fn pictureReady(world: *state.World, slot: *const Slot, want_jpeg: bool, want_h264: bool) bool {
    const jpeg_ready = !want_jpeg or (slot.jpeg != null and world.frameCount() != slot.jpeg_base);
    const pipe_ready = !want_h264 or (slot.pipe != null and state.videoCount() != slot.pipe_base);
    return jpeg_ready and pipe_ready;
}

fn browserOn(io: std.Io, gpa: std.mem.Allocator, env: *const std.process.Environ.Map) bool {
    const home = sys.envGet(env, "HOME") orelse return true;
    const path = std.fmt.allocPrint(gpa, "{s}/.config/screenmirror/panel.json", .{home}) catch return true;
    defer gpa.free(path);
    const text = sys.readAll(io, gpa, path, 512) orelse return true;
    defer gpa.free(text);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const value = jsonx.parse(arena_state.allocator(), text) catch return true;
    const item = value.get("browser") orelse return true;
    return item.asBool() orelse true;
}

fn deviceOn(io: std.Io, gpa: std.mem.Allocator, runtime: []const u8) bool {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const sessions = mirror.listed(arena_state.allocator(), io, gpa, runtime) catch return false;
    for (sessions) |item| {
        if (std.mem.eql(u8, item.state, "live") or std.mem.eql(u8, item.state, "starting")) return true;
    }
    return false;
}

fn preferOutput(world: *state.World, env: *const std.process.Environ.Map) !void {
    const name = sys.envGet(env, "MIRROR_OUTPUT") orelse return;
    if (!sys.safeName(name) or std.mem.eql(u8, name, world.output)) return;
    const copy = try world.gpa.dupe(u8, name);
    world.gpa.free(world.output);
    world.output = copy;
}

fn applyPlan(world: *state.World, planned: hypr.Plan) !void {
    world.frame_mu.lockUncancelable(world.io);
    defer world.frame_mu.unlock(world.io);
    world.gpa.free(world.output);
    world.output = try world.gpa.dupe(u8, planned.output);
    world.width = planned.width;
    world.height = planned.height;
    world.follow = planned.follow;
    world.virtual_out = planned.virtual_out;
    world.workspace = planned.workspace;
}

fn writeStatus(world: *state.World, ready: bool) !void {
    const snap = world.snapshot();
    if (snap.ports.len == 0) {
        const path = try sys.join(world.gpa, world.runtime, "status.json");
        defer world.gpa.free(path);
        const body = try std.fmt.allocPrint(world.gpa,
            "{{\n  \"listening\": false,\n  \"ready\": false,\n  \"ip\": \"{s}\",\n  \"output\": \"{s}\",\n  \"workspace\": {d},\n  \"virtual\": {s},\n  \"follow\": {s},\n  \"width\": {d},\n  \"height\": {d}\n}}\n",
            .{
                snap.ip,
                snap.output,
                snap.workspace,
                if (snap.virtual_out) "true" else "false",
                if (snap.follow) "true" else "false",
                snap.width,
                snap.height,
            },
        );
        defer world.gpa.free(body);
        try sys.writeAll(world.io, path, body);
        return;
    }
    var urls: std.ArrayList(u8) = .empty;
    defer urls.deinit(world.gpa);
    for (snap.ports, 0..) |port, index| {
        if (index != 0) try urls.appendSlice(world.gpa, ", ");
        try urls.print(world.gpa, "\"http://{s}:{d}/\"", .{ snap.ip, port });
    }
    const primary = try std.fmt.allocPrint(world.gpa, "http://{s}:{d}/", .{ snap.ip, snap.ports[0] });
    defer world.gpa.free(primary);
    const body = try std.fmt.allocPrint(world.gpa,
        "{{\n  \"listening\": {s},\n  \"ready\": {s},\n  \"ip\": \"{s}\",\n  \"output\": \"{s}\",\n  \"workspace\": {d},\n  \"virtual\": {s},\n  \"follow\": {s},\n  \"width\": {d},\n  \"height\": {d},\n  \"urls\": [{s}],\n  \"primary\": \"{s}\"\n}}\n",
        .{
            if (snap.listening) "true" else "false",
            if (ready or snap.ready) "true" else "false",
            snap.ip,
            snap.output,
            snap.workspace,
            if (snap.virtual_out) "true" else "false",
            if (snap.follow) "true" else "false",
            snap.width,
            snap.height,
            urls.items,
            primary,
        },
    );
    defer world.gpa.free(body);
    const status_path = try sys.join(world.gpa, world.runtime, "status.json");
    defer world.gpa.free(status_path);
    const url_path = try sys.join(world.gpa, world.runtime, "url");
    defer world.gpa.free(url_path);
    try sys.writeAll(world.io, status_path, body);
    const url_line = try std.fmt.allocPrint(world.gpa, "{s}\n", .{primary});
    defer world.gpa.free(url_line);
    try sys.writeAll(world.io, url_path, url_line);
}

fn parsePorts(env: *const std.process.Environ.Map) [3]u16 {
    var ports = [_]u16{ 8080, 8000, 8090 };
    const raw = sys.envGet(env, "MIRROR_PORTS") orelse return ports;
    var it = std.mem.splitScalar(u8, raw, ',');
    var n: usize = 0;
    while (it.next()) |part| {
        if (n >= ports.len) break;
        const port = std.fmt.parseInt(u16, std.mem.trim(u8, part, " "), 10) catch continue;
        if (port == 0) continue;
        ports[n] = port;
        n += 1;
    }
    return ports;
}

fn log(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    var err_w: std.Io.File.Writer = .initStreaming(.stderr(), io, &buf);
    err_w.interface.print(fmt, args) catch {};
    err_w.interface.flush() catch {};
}
