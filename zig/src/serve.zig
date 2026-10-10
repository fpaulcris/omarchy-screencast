const std = @import("std");
const capture = @import("capture.zig");
const httpd = @import("httpd.zig");
const hypr = @import("hypr.zig");
const state = @import("state.zig");
const sys = @import("sys.zig");

const linux = std.os.linux;

fn onStop(_: linux.SIG) callconv(.c) void {
    state.shutdown.store(true, .release);
    const gsr = state.gsr_pid.load(.acquire);
    if (gsr > 0) _ = linux.kill(gsr, .KILL);
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
    try writeStatus(world, false);

    const forced = sys.envGet(env, "MIRROR_CAPTURE");
    var mode: capture.Mode = if (forced != null and std.mem.eql(u8, forced.?, "screencopy"))
        .screen
    else if (sys.exists(io, "/usr/bin/gpu-screen-recorder"))
        .gsr
    else
        .screen;
    hypr.wake(io, gpa);
    var pipe = capture.Pipeline.start(io, gpa, world, env, world.output, world.width, world.height, mode) catch |err| {
        log(io, "capture did not start: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    var pipe_live = true;
    defer if (pipe_live) {
        pipe.halt();
        gpa.destroy(pipe);
    };
    var started = sys.monoMs(io);
    var failures: u8 = 0;
    var window = started;

    const want = parsePorts(env);
    const bound = try httpd.bind(world, &want);
    if (bound.len == 0) {
        log(io, "screenmirror: the stream is already running.\n", .{});
        pipe.halt();
        std.process.exit(0);
    }
    world.ports = bound;
    world.listening = true;
    try writeStatus(world, false);
    log(io, "Primary URL: http://{s}:{d}/\n", .{ world.ip, world.ports[0] });

    var cast_mtime = sys.fileMtimeMs(io, cast_file) orelse 0;
    var marked = false;
    while (!state.shutdown.load(.acquire)) {
        sys.sleepMs(io, 400);
        if (state.shutdown.load(.acquire)) break;
        const now = sys.monoMs(io);
        const mtime = sys.fileMtimeMs(io, cast_file) orelse 0;
        const dead = pipe_live and pipe.captureExited();
        const produced = state.videoCount();
        const no_frame = produced == 0 and now - started > 4000 and mode == .gsr;
        if (mtime != cast_mtime or dead or no_frame) {
            if (now - window > 30000) {
                window = now;
                failures = 0;
            }
            failures += 1;
            if (failures > 3) {
                log(io, "capture stopped too many times\n", .{});
                state.shutdown.store(true, .release);
                break;
            }
            if (mode == .gsr and produced == 0 and (dead or no_frame)) {
                log(io, "capture: gpu-screen-recorder produced no frame, using screencopy\n", .{});
                mode = .screen;
            }
            cast_mtime = mtime;
            if (pipe_live) {
                pipe.halt();
                gpa.destroy(pipe);
                pipe_live = false;
            }
            _ = arena_state.reset(.retain_capacity);
            const next_cast = hypr.readCast(arena_state.allocator(), io, gpa, cast_file);
            if (hypr.plan(arena_state.allocator(), io, gpa, runtime, next_cast)) |next| {
                applyPlan(world, next) catch {
                    state.shutdown.store(true, .release);
                    break;
                };
                preferOutput(world, env) catch {
                    state.shutdown.store(true, .release);
                    break;
                };
            } else |_| {}
            hypr.wake(io, gpa);
            pipe = capture.Pipeline.start(io, gpa, world, env, world.output, world.width, world.height, mode) catch {
                log(io, "capture did not restart\n", .{});
                state.shutdown.store(true, .release);
                break;
            };
            pipe_live = true;
            started = sys.monoMs(io);
            marked = world.frame_id > 0 or state.videoCount() > 0;
            try writeStatus(world, marked);
            continue;
        }
        if (!marked and (world.frame_id > 0 or state.videoCount() > 0)) {
            try writeStatus(world, true);
            marked = true;
        }
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
