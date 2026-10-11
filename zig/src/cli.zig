//! Panel commands. The Quickshell plugin calls `screencast` and never the daemon.
const std = @import("std");
const dial = @import("dial.zig");
const discover = @import("discover.zig");
const host = @import("host.zig");
const hypr = @import("hypr.zig");
const jsonx = @import("jsonx.zig");
const mirror = @import("mirror.zig");
const sys = @import("sys.zig");

const linux = std.os.linux;

const unit = "screenmirror.service";
const same_wifi = "The TV or phone has to be on the same Wi-Fi as this computer.";
const browser_note = "This is a browser address, so it will not show up in the TV's screen-cast menu.";

const usage_text =
    \\Screen Cast — cast this screen to a smart TV browser over Wi-Fi.
    \\The command is screencast.
    \\
    \\Usage:
    \\  screencast            Start in the background. The panel is on the bar.
    \\  screencast open       Start in the background. Does not open a window.
    \\  screencast start      Start in the background
    \\  screencast stop       Stop
    \\  screencast status     Running or not, plus the URL
    \\  screencast status --json
    \\                          One JSON object: state, url, detail, preview, mirrors
    \\  screencast url        Print the TV address
    \\  screencast copy       Copy the TV address to the clipboard
    \\  screencast desktops --json
    \\                          Desktops that can be cast
    \\  screencast cast --json
    \\                          Chosen desktop and resolution
    \\  screencast cast --workspace follow
    \\                          Follow this laptop's screen
    \\  screencast cast --workspace 2
    \\                          Cast desktop 2 from its own virtual screen
    \\  screencast cast --size auto
    \\  screencast cast --size 1920x1080
    \\                          1280x720, 1920x1080, 2560x1440, or 3840x2160
    \\  screencast qr         Write a QR code for the address and print its path
    \\  screencast receivers --json
    \\                          AirPlay, Chromecast, Miracast, Android TV, and Fire TV
    \\  screencast mirror <id>  Send the picture to that receiver. Others can stay on
    \\  screencast mirror stop <id>
    \\                          Stop that screen
    \\  screencast mirror stop  Stop every screen. The browser stream keeps going
    \\  screencast mirror status
    \\  screencast dial         List DIAL receivers
    \\  screencast dial apps <id-or-ip>
    \\                          Apps that receiver offers
    \\  screencast dial launch <id-or-ip> <App> [payload]
    \\                          Start an app. The payload is the app's extra text
    \\  screencast dial stop <id-or-ip> <App>
    \\  screencast preview [on|off|toggle]
    \\                          Frame rate and delay on the browser picture
    \\  screencast help
    \\
;

var ui_stop = std.atomic.Value(bool).init(false);

fn onUiStop(_: linux.SIG) callconv(.c) void {
    ui_stop.store(true, .release);
}

pub fn run(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const cmd = if (args.len > 1) args[1] else "open";
    if (eql(cmd, "start")) return cmdStart(init, false);
    if (eql(cmd, "open")) return cmdOpen(init);
    if (eql(cmd, "ui")) return cmdUi(init);
    if (eql(cmd, "stop")) return cmdStop(init);
    if (eql(cmd, "status")) return cmdStatus(init, args);
    if (eql(cmd, "url")) return cmdUrl(init);
    if (eql(cmd, "copy")) return cmdCopy(init);
    if (eql(cmd, "desktops")) return cmdDesktops(init);
    if (eql(cmd, "cast")) return cmdCast(init, args[2..]);
    if (eql(cmd, "qr")) return cmdQr(init);
    if (eql(cmd, "receivers")) return cmdReceivers(init);
    if (eql(cmd, "mirror")) return cmdMirror(init, args[2..]);
    if (eql(cmd, "dial")) return dial.command(init, args[2..]);
    if (eql(cmd, "preview")) return cmdPreview(init, args[2..]);
    if (eql(cmd, "help") or eql(cmd, "-h") or eql(cmd, "--help")) {
        try writeStdout(init.io, usage_text);
        try writeStdout(init.io, same_wifi);
        try writeStdout(init.io, "\n");
        try writeStdout(init.io, browser_note);
        try writeStdout(init.io, "\n");
        return;
    }
    if (eql(cmd, "version")) {
        try writeStdout(init.io, "screencast 0.0.0\n");
        return;
    }
    if (eql(cmd, "host")) {
        var buf: [256]u8 = undefined;
        const name = host.hostname(&buf) catch "unknown";
        try printStdout(init.io, "{s}\n", .{name});
        return;
    }
    try printStderr(init.io, "Unknown command: {s}\n", .{cmd});
    try writeStderr(init.io, usage_text);
    std.process.exit(1);
}

fn cmdStart(init: std.process.Init, quiet: bool) !void {
    const io = init.io;
    const gpa = init.gpa;
    _ = sys.runQuiet(gpa, io, &.{ "systemctl", "--user", "start", unit }, 8000);
    const runtime = try sys.runtimeDir(gpa, init.environ_map);
    defer gpa.free(runtime);
    const url = waitUrl(io, gpa, runtime) orelse {
        try writeStderr(io, "Screen Cast started, but the URL file is not ready yet.\n");
        try printStderr(io, "Check: systemctl --user status {s}\n", .{unit});
        std.process.exit(1);
    };
    defer gpa.free(url);
    copyClipboard(init, url);
    notify(init, url);
    if (!quiet) try printStdout(io, "{s}\n", .{url});
}

fn cmdOpen(init: std.process.Init) !void {
    closeCastWindows(init.io, init.gpa);
    if (!isActive(init.gpa, init.io)) try cmdStart(init, false);
}

fn cmdStop(init: std.process.Init) !void {
    try mirror.stop(init, true);
    _ = sys.runQuiet(init.gpa, init.io, &.{ "systemctl", "--user", "stop", unit }, 4000);
    _ = sys.runQuiet(init.gpa, init.io, &.{ "systemctl", "--user", "reset-failed", unit }, 4000);
    try writeStdout(init.io, "Screen Cast stopped.\n");
}

fn cmdStatus(init: std.process.Init, args: []const []const u8) !void {
    if (args.len > 2 and eql(args[2], "--json")) return cmdStatusJson(init);
    if (isActive(init.gpa, init.io)) {
        try writeStdout(init.io, "running\n");
        const runtime = try sys.runtimeDir(init.gpa, init.environ_map);
        defer init.gpa.free(runtime);
        const url_path = try sys.join(init.gpa, runtime, "url");
        defer init.gpa.free(url_path);
        if (sys.readAll(init.io, init.gpa, url_path, 512)) |text| {
            defer init.gpa.free(text);
            const trimmed = std.mem.trim(u8, text, " \t\r\n");
            if (trimmed.len > 0) try printStdout(init.io, "url {s}\n", .{trimmed});
        }
        const status_path = try sys.join(init.gpa, runtime, "status.json");
        defer init.gpa.free(status_path);
        if (sys.readAll(init.io, init.gpa, status_path, 8192)) |text| {
            defer init.gpa.free(text);
            try writeStdout(init.io, text);
            if (text.len == 0 or text[text.len - 1] != '\n') try writeStdout(init.io, "\n");
        }
        return;
    }
    try writeStdout(init.io, "stopped\n");
    std.process.exit(1);
}

fn cmdStatusJson(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const runtime = try sys.runtimeDir(gpa, init.environ_map);
    defer gpa.free(runtime);
    const active = isActive(gpa, io);
    const failed = sys.runQuiet(gpa, io, &.{ "systemctl", "--user", "is-failed", "--quiet", unit }, 3000);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const status_path = try sys.join(gpa, runtime, "status.json");
    defer gpa.free(status_path);
    var data = jsonx.Value{ .null = {} };
    if (sys.readAll(io, gpa, status_path, 8192)) |text| {
        defer gpa.free(text);
        data = jsonx.parse(arena, text) catch .{ .null = {} };
    }
    const url_path = try sys.join(gpa, runtime, "url");
    defer gpa.free(url_path);
    var url_buf: []const u8 = "";
    var url_owned: ?[]u8 = null;
    defer if (url_owned) |text| gpa.free(text);
    if (sys.readAll(io, gpa, url_path, 512)) |text| {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len > 0) {
            url_owned = try gpa.dupe(u8, trimmed);
            url_buf = url_owned.?;
        }
        gpa.free(text);
    }
    if (url_buf.len == 0) {
        if (data.get("primary")) |item| if (item.asString()) |text| {
            if (text.len > 0) url_buf = text;
        };
    }
    if (url_buf.len == 0) {
        url_owned = try predictedUrl(gpa, io, init.environ_map);
        url_buf = url_owned.?;
    }
    const state_name: []const u8 = if (failed and !active)
        "failed"
    else if (active and boolField(data, "ready") and boolField(data, "listening"))
        "live"
    else if (active)
        "starting"
    else
        "stopped";
    const cast_file = try sys.castPath(gpa, init.environ_map);
    defer gpa.free(cast_file);
    const cast = hypr.readCast(arena, io, gpa, cast_file);
    const follow = wantsFollow(data, cast);
    var workspace_store: [16]u8 = undefined;
    const workspace = if (follow) "follow" else workspaceLabel(data, cast, &workspace_store);
    const width = intField(data, "width") orelse cast.width;
    const height = intField(data, "height") orelse cast.height;
    const virtual_out = boolField(data, "virtual");
    var detail_buf: [400]u8 = undefined;
    var detail: []const u8 = "";
    if (eql(state_name, "failed")) {
        detail = "The stream stopped.";
    } else if (follow) {
        detail = std.fmt.bufPrint(&detail_buf, "Following this screen, {d}×{d}.", .{ width, height }) catch "";
    } else if (workspace.len > 0) {
        const place = if (virtual_out) "a virtual screen" else "this screen";
        detail = std.fmt.bufPrint(&detail_buf, "Desktop {s} on {s}, {d}×{d}.", .{ workspace, place, width, height }) catch "";
    }
    const sessions = mirror.listed(arena, io, gpa, runtime) catch &.{};
    var live_count: usize = 0;
    var name_buf: [160]u8 = undefined;
    var name_len: usize = 0;
    var names_fit = true;
    for (sessions) |item| {
        if (!eql(item.state, "live") and !eql(item.state, "starting")) continue;
        live_count += 1;
        const label = if (item.name.len > 0) item.name else item.id;
        if (!names_fit or label.len == 0) continue;
        const need = label.len + (if (name_len == 0) @as(usize, 0) else 2);
        if (name_len + need > name_buf.len) {
            names_fit = false;
            continue;
        }
        if (name_len != 0) {
            name_buf[name_len] = ',';
            name_buf[name_len + 1] = ' ';
            name_len += 2;
        }
        @memcpy(name_buf[name_len..][0..label.len], label);
        name_len += label.len;
    }
    var detail_extra: [500]u8 = undefined;
    if (live_count > 0 and names_fit and name_len > 0) {
        detail = std.fmt.bufPrint(&detail_extra, "{s} Mirroring to {s}.", .{ detail, name_buf[0..name_len] }) catch detail;
    } else if (live_count > 0) {
        detail = std.fmt.bufPrint(&detail_extra, "{s} Mirroring to {d} screens.", .{ detail, live_count }) catch detail;
    }
    var out_buf: [8192]u8 = undefined;
    var out_w: std.Io.File.Writer = .init(.stdout(), io, &out_buf);
    const out = &out_w.interface;
    try out.writeAll("{\"state\":");
    try jsonx.escape(out, state_name);
    try out.writeAll(",\"url\":");
    try jsonx.escape(out, url_buf);
    try out.writeAll(",\"detail\":");
    try jsonx.escape(out, detail);
    try out.writeAll(",\"workspace\":");
    try jsonx.escape(out, workspace);
    const preview_path = try sys.join(gpa, runtime, "preview.on");
    defer gpa.free(preview_path);
    const preview_on = sys.flagOn(io, gpa, preview_path);
    try out.print(",\"follow\":{s},\"size\":\"{d}x{d}\",\"preview\":{s},\"mirrors\":[", .{
        if (follow) "true" else "false",
        width,
        height,
        if (preview_on) "true" else "false",
    });
    var mirror_i: usize = 0;
    for (sessions) |item| {
        if (mirror_i != 0) try out.writeAll(",");
        mirror_i += 1;
        try out.writeAll("{\"state\":");
        try jsonx.escape(out, item.state);
        try out.writeAll(",\"id\":");
        try jsonx.escape(out, item.id);
        try out.writeAll(",\"name\":");
        try jsonx.escape(out, item.name);
        try out.writeAll(",\"detail\":");
        try jsonx.escape(out, item.detail);
        try out.writeAll("}");
    }
    try out.writeAll("]}\n");
    try out.flush();
}

fn cmdPreview(init: std.process.Init, args: []const []const u8) !void {
    const io = init.io;
    const gpa = init.gpa;
    const runtime = try sys.runtimeDir(gpa, init.environ_map);
    defer gpa.free(runtime);
    sys.ensureDir(io, runtime);
    const path = try sys.join(gpa, runtime, "preview.on");
    defer gpa.free(path);
    var on = sys.flagOn(io, gpa, path);
    if (args.len == 0) {
        try writeStdout(io, if (on) "on\n" else "off\n");
        return;
    }
    if (args.len != 1 or (!eql(args[0], "on") and !eql(args[0], "off") and !eql(args[0], "toggle"))) {
        try writeStderr(io, "usage: screencast preview [on|off|toggle]\n");
        std.process.exit(2);
    }
    if (eql(args[0], "on")) on = true else if (eql(args[0], "off")) on = false else on = !on;
    try sys.setFlag(io, path, on);
    try writeStdout(io, if (on) "on\n" else "off\n");
}

fn cmdUrl(init: std.process.Init) !void {
    const url = try currentUrl(init);
    defer init.gpa.free(url);
    try printStdout(init.io, "{s}\n", .{url});
}

fn cmdCopy(init: std.process.Init) !void {
    const url = try currentUrl(init);
    defer init.gpa.free(url);
    copyClipboard(init, url);
    try printStdout(init.io, "{s}\n", .{url});
}

fn cmdDesktops(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const seen = hypr.monitors(arena, io, gpa) catch &.{};
    const screen = hypr.laptop(seen);
    const active_id: i64 = if (screen) |item| if (item.workspace > 0) item.workspace else 1 else 1;
    var present: [11]bool = .{ false, false, false, false, false, false, false, false, false, false, false };
    var n: usize = 1;
    while (n <= 5) : (n += 1) present[n] = true;
    const ids = hypr.workspaces(arena, io, gpa) catch &.{};
    for (ids) |id| {
        if (id >= 1 and id <= 10) present[@intCast(id)] = true;
    }
    var out_buf: [1024]u8 = undefined;
    var out_w: std.Io.File.Writer = .init(.stdout(), io, &out_buf);
    const out = &out_w.interface;
    try out.print("{{\"active\":\"{d}\",\"desktops\":[{{\"value\":\"follow\",\"label\":\"Follow Screen\"}}", .{active_id});
    var id: usize = 1;
    while (id <= 10) : (id += 1) {
        if (!present[id]) continue;
        try out.print(",{{\"value\":\"{d}\",\"label\":\"Desktop {d}\"}}", .{ id, id });
    }
    try out.writeAll("]}\n");
    try out.flush();
}

fn cmdCast(init: std.process.Init, args: []const []const u8) !void {
    const io = init.io;
    const gpa = init.gpa;
    var workspace: []const u8 = "";
    var size: []const u8 = "";
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (eql(args[i], "--json")) continue;
        if (eql(args[i], "--workspace")) {
            i += 1;
            if (i >= args.len) {
                try writeStderr(io, "Desktop must be from 1 to 10, or follow.\n");
                std.process.exit(1);
            }
            workspace = args[i];
            continue;
        }
        if (eql(args[i], "--size")) {
            i += 1;
            if (i >= args.len) {
                try writeStderr(io, "Resolution must be auto, 1280x720, 1920x1080, 2560x1440, or 3840x2160.\n");
                std.process.exit(1);
            }
            size = args[i];
            continue;
        }
        try printStderr(io, "Unknown option: {s}\n", .{args[i]});
        std.process.exit(1);
    }
    const path = try sys.castPath(gpa, init.environ_map);
    defer gpa.free(path);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    var cast = hypr.readCast(arena_state.allocator(), io, gpa, path);
    if (workspace.len > 0) {
        if (eql(workspace, "follow")) {
            cast.follow = true;
            cast.workspace = 0;
        } else {
            const chosen = std.fmt.parseInt(i32, workspace, 10) catch 0;
            if (chosen < 1 or chosen > 10) {
                try writeStderr(io, "Desktop must be from 1 to 10, or follow.\n");
                std.process.exit(1);
            }
            cast.workspace = chosen;
            cast.follow = false;
        }
    }
    if (size.len > 0) {
        if (eql(size, "auto")) {
            cast.auto = true;
        } else if (parseSize(size)) |pair| {
            cast.auto = false;
            cast.width = pair.w;
            cast.height = pair.h;
        } else {
            try writeStderr(io, "Resolution must be auto, 1280x720, 1920x1080, 2560x1440, or 3840x2160.\n");
            std.process.exit(1);
        }
    }
    if (workspace.len > 0 or size.len > 0) {
        if (std.fs.path.dirname(path)) |dir| sys.ensureDir(io, dir);
        var body_buf: [256]u8 = undefined;
        const body = if (cast.follow)
            try std.fmt.bufPrint(&body_buf, "{{\"width\":{d},\"height\":{d},\"auto\":{s},\"follow\":true}}\n", .{
                cast.width,
                cast.height,
                if (cast.auto) "true" else "false",
            })
        else
            try std.fmt.bufPrint(&body_buf, "{{\"width\":{d},\"height\":{d},\"auto\":{s},\"follow\":false,\"workspace\":{d}}}\n", .{
                cast.width,
                cast.height,
                if (cast.auto) "true" else "false",
                cast.workspace,
            });
        const tmp = try std.fmt.allocPrint(gpa, "{s}.tmp", .{path});
        defer gpa.free(tmp);
        try sys.writeAll(io, tmp, body);
        std.Io.Dir.renameAbsolute(tmp, path, io) catch {
            try sys.writeAll(io, path, body);
            sys.removeFile(io, tmp);
        };
    }
    const shown = if (cast.follow or cast.workspace <= 0) "follow" else workspaceText(cast.workspace);
    const shown_size = if (cast.auto) "auto" else sizeText(cast.width, cast.height);
    if (cast.follow or cast.workspace <= 0) {
        try printStdout(io, "{{\"workspace\":\"follow\",\"follow\":true,\"auto\":{s},\"size\":\"{s}\"}}\n", .{
            if (cast.auto) "true" else "false",
            shown_size,
        });
    } else {
        try printStdout(io, "{{\"workspace\":\"{s}\",\"follow\":false,\"auto\":{s},\"size\":\"{s}\"}}\n", .{
            shown,
            if (cast.auto) "true" else "false",
            shown_size,
        });
    }
}

fn cmdQr(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    if (sys.commandPath(gpa, io, init.environ_map, "qrencode") == null) {
        try writeStderr(io, "qrencode is not installed.\n");
        std.process.exit(1);
    }
    const url = try currentUrl(init);
    defer gpa.free(url);
    const runtime = try sys.runtimeDir(gpa, init.environ_map);
    defer gpa.free(runtime);
    sys.ensureDir(io, runtime);
    const path = try sys.join(gpa, runtime, "qr.png");
    defer gpa.free(path);
    const ok = sys.runQuiet(gpa, io, &.{ "qrencode", "-t", "PNG", "-o", path, "-s", "8", "-m", "2", "--", url }, 4000);
    if (!ok) {
        try writeStderr(io, "qrencode is not installed.\n");
        std.process.exit(1);
    }
    try printStdout(io, "{s}\n", .{path});
}

fn cmdReceivers(init: std.process.Init) !void {
    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const found = discover.browse(arena_state.allocator(), init.gpa, init.io) catch discover.Browse{
        .receivers = &.{},
        .failure = "",
    };
    var buf: [65536]u8 = undefined;
    var out_w: std.Io.File.Writer = .init(.stdout(), init.io, &buf);
    try discover.writeJson(&out_w.interface, found.receivers, found.failure);
    try out_w.interface.flush();
}

fn cmdMirror(init: std.process.Init, args: []const []const u8) !void {
    if (args.len == 0 or eql(args[0], "-h") or eql(args[0], "--help")) {
        try writeStderr(init.io, "usage: screencast mirror <id>|stop [id]|status\n");
        std.process.exit(2);
    }
    if (eql(args[0], "stop")) {
        if (args.len > 1) return mirror.stopOne(init, args[1]);
        return mirror.stop(init, false);
    }
    if (eql(args[0], "status")) return mirror.status(init);
    const id = if (eql(args[0], "start") and args.len > 1) args[1] else args[0];
    if (eql(id, "start") or eql(id, "--id") or id.len == 0) {
        try writeStderr(init.io, "usage: screencast mirror <id>|stop [id]|status\n");
        std.process.exit(2);
    }
    try mirror.detach(init, id);
}

fn cmdUi(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const runtime = try sys.runtimeDir(gpa, init.environ_map);
    defer gpa.free(runtime);
    sys.ensureDir(io, runtime);
    const lock_path = try sys.join(gpa, runtime, "ui.lock");
    defer gpa.free(lock_path);
    var zbuf: [512]u8 = undefined;
    if (lock_path.len + 1 > zbuf.len) return error.NameTooLong;
    @memcpy(zbuf[0..lock_path.len], lock_path);
    zbuf[lock_path.len] = 0;
    const opened = linux.open(@ptrCast(&zbuf), .{ .ACCMODE = .RDWR, .CREAT = true, .CLOEXEC = true }, 0o600);
    if (linux.errno(opened) != .SUCCESS) return error.Lock;
    const fd: i32 = @intCast(opened);
    defer _ = linux.close(fd);
    const locked = linux.flock(fd, 2 | 4);
    if (linux.errno(locked) != .SUCCESS) {
        focusCastWindow(io, gpa);
        try writeStdout(io, "Screen Cast is already open.\n");
        return;
    }
    if (!isActive(gpa, io)) try cmdStart(init, true);
    const url = currentUrl(init) catch try predictedUrl(gpa, io, init.environ_map);
    defer gpa.free(url);
    copyClipboard(init, url);
    const ip = sys.lanIp(gpa, io);
    defer gpa.free(ip);
    const port = primaryPort(init.environ_map);
    try printStdout(io,
        \\
        \\  Screen Cast
        \\  ------------
        \\
        \\  On the TV:
        \\    1. Open the internet browser
        \\    2. Go to this address:
        \\
        \\       {s}
        \\
        \\  {s}
        \\  {s}
        \\
        \\  Fallback:  http://{s}:{d}/
        \\             http://{s}:8000/
        \\
    , .{ url, same_wifi, browser_note, ip, port, ip });
    if (sys.commandPath(gpa, io, init.environ_map, "qrencode")) |bin| {
        defer gpa.free(bin);
        const ran = sys.run(gpa, io, &.{ bin, "-t", "ansiutf8", url }, 3000, 64 * 1024) catch null;
        if (ran) |result| {
            defer gpa.free(result.stdout);
            defer gpa.free(result.stderr);
            try writeStdout(io, result.stdout);
            try writeStdout(io, "\n");
        }
    }
    try writeStdout(io, "  URL copied to the clipboard.\n  Press q to stop and quit.  Ctrl-C also stops.\n\n");
    var act = std.posix.Sigaction{
        .handler = .{ .handler = onUiStop },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(.TERM, &act, null);
    std.posix.sigaction(.INT, &act, null);
    var saved: Termios = undefined;
    const raw = linux.ioctl(0, 0x5401, @intFromPtr(&saved));
    var restore = false;
    if (linux.errno(raw) == .SUCCESS) {
        var next = saved;
        next.c_lflag &= ~@as(u32, 2 | 8);
        next.c_cc[6] = 0;
        next.c_cc[5] = 10;
        if (linux.errno(linux.ioctl(0, 0x5402, @intFromPtr(&next))) == .SUCCESS) restore = true;
    }
    defer if (restore) {
        _ = linux.ioctl(0, 0x5402, @intFromPtr(&saved));
    };
    var missed = false;
    while (!ui_stop.load(.acquire)) {
        if (!isActive(gpa, io)) {
            if (missed) {
                try writeStdout(io, "Stream ended.\n");
                break;
            }
            missed = true;
            sys.sleepMs(io, 2000);
            continue;
        }
        missed = false;
        var key: [1]u8 = undefined;
        const n = linux.read(0, &key, 1);
        if (linux.errno(n) == .SUCCESS and n == 1 and (key[0] == 'q' or key[0] == 'Q')) break;
    }
    try mirror.stop(init, true);
    _ = sys.runQuiet(gpa, io, &.{ "systemctl", "--user", "stop", unit }, 4000);
    _ = sys.runQuiet(gpa, io, &.{ "systemctl", "--user", "reset-failed", unit }, 4000);
}

const Termios = extern struct {
    c_iflag: u32,
    c_oflag: u32,
    c_cflag: u32,
    c_lflag: u32,
    c_line: u8,
    c_cc: [32]u8,
    c_ispeed: u32,
    c_ospeed: u32,
};

fn wantsFollow(data: jsonx.Value, cast: hypr.Cast) bool {
    if (data.get("follow")) |item| if (item.asBool()) |bit| return bit;
    if (boolField(data, "virtual")) return false;
    if (data.get("workspace")) |item| {
        if (item.asString()) |text| if (text.len > 0 and !eql(text, "0")) return false;
        if (item.asInt()) |n| if (n != 0) return false;
    }
    if (cast.follow) return true;
    if (cast.workspace > 0) return false;
    return true;
}

fn workspaceLabel(data: jsonx.Value, cast: hypr.Cast, buf: *[16]u8) []const u8 {
    if (data.get("workspace")) |item| {
        if (item.asString()) |text| if (text.len > 0 and !eql(text, "0")) return text;
        if (item.asInt()) |n| if (n != 0) {
            return std.fmt.bufPrint(buf, "{d}", .{n}) catch "";
        };
    }
    if (cast.workspace > 0) return std.fmt.bufPrint(buf, "{d}", .{cast.workspace}) catch "";
    return "";
}

fn boolField(value: jsonx.Value, key: []const u8) bool {
    const item = value.get(key) orelse return false;
    return item.asBool() orelse false;
}

fn intField(value: jsonx.Value, key: []const u8) ?u32 {
    const item = value.get(key) orelse return null;
    const n = item.asInt() orelse return null;
    if (n <= 0) return null;
    return @intCast(n);
}

fn parseSize(text: []const u8) ?struct { w: u32, h: u32 } {
    if (eql(text, "1280x720")) return .{ .w = 1280, .h = 720 };
    if (eql(text, "1920x1080")) return .{ .w = 1920, .h = 1080 };
    if (eql(text, "2560x1440")) return .{ .w = 2560, .h = 1440 };
    if (eql(text, "3840x2160")) return .{ .w = 3840, .h = 2160 };
    return null;
}

fn workspaceText(id: i32) []const u8 {
    return switch (id) {
        1 => "1",
        2 => "2",
        3 => "3",
        4 => "4",
        5 => "5",
        6 => "6",
        7 => "7",
        8 => "8",
        9 => "9",
        10 => "10",
        else => "",
    };
}

fn sizeText(width: u32, height: u32) []const u8 {
    if (width == 1280 and height == 720) return "1280x720";
    if (width == 1920 and height == 1080) return "1920x1080";
    if (width == 2560 and height == 1440) return "2560x1440";
    if (width == 3840 and height == 2160) return "3840x2160";
    return "1920x1080";
}

fn isActive(gpa: std.mem.Allocator, io: std.Io) bool {
    return sys.runQuiet(gpa, io, &.{ "systemctl", "--user", "is-active", "--quiet", unit }, 3000);
}

fn primaryPort(env: *const std.process.Environ.Map) u16 {
    const raw = sys.envGet(env, "MIRROR_PORTS") orelse return 8080;
    const end = std.mem.indexOfScalar(u8, raw, ',') orelse raw.len;
    return std.fmt.parseInt(u16, std.mem.trim(u8, raw[0..end], " "), 10) catch 8080;
}

fn predictedUrl(gpa: std.mem.Allocator, io: std.Io, env: *const std.process.Environ.Map) ![]u8 {
    const ip = sys.lanIp(gpa, io);
    defer gpa.free(ip);
    return std.fmt.allocPrint(gpa, "http://{s}:{d}/", .{ ip, primaryPort(env) });
}

fn currentUrl(init: std.process.Init) ![]u8 {
    const runtime = try sys.runtimeDir(init.gpa, init.environ_map);
    defer init.gpa.free(runtime);
    const path = try sys.join(init.gpa, runtime, "url");
    defer init.gpa.free(path);
    if (sys.readAll(init.io, init.gpa, path, 512)) |text| {
        defer init.gpa.free(text);
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len > 0) return init.gpa.dupe(u8, trimmed);
    }
    return predictedUrl(init.gpa, init.io, init.environ_map);
}

fn waitUrl(io: std.Io, gpa: std.mem.Allocator, runtime: []const u8) ?[]u8 {
    const path = sys.join(gpa, runtime, "url") catch return null;
    defer gpa.free(path);
    var i: usize = 0;
    while (i < 40) : (i += 1) {
        if (sys.readAll(io, gpa, path, 512)) |text| {
            const trimmed = std.mem.trim(u8, text, " \t\r\n");
            if (trimmed.len > 0) {
                const owned = gpa.dupe(u8, trimmed) catch {
                    gpa.free(text);
                    return null;
                };
                gpa.free(text);
                return owned;
            }
            gpa.free(text);
        }
        sys.sleepMs(io, 150);
    }
    return null;
}

fn copyClipboard(init: std.process.Init, url: []const u8) void {
    const bin = sys.commandPath(init.gpa, init.io, init.environ_map, "wl-copy") orelse return;
    defer init.gpa.free(bin);
    var child = std.process.spawn(init.io, .{
        .argv = &.{bin},
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
    }) catch return;
    if (child.stdin) |file| {
        file.writeStreamingAll(init.io, url) catch {};
        file.close(init.io);
        child.stdin = null;
    }
    _ = child.wait(init.io) catch {};
}

fn notify(init: std.process.Init, url: []const u8) void {
    const bin = sys.commandPath(init.gpa, init.io, init.environ_map, "omarchy-notification-send") orelse return;
    defer init.gpa.free(bin);
    const body = std.fmt.allocPrint(init.gpa, "On the TV browser: {s}\n{s} {s}", .{ url, same_wifi, browser_note }) catch return;
    defer init.gpa.free(body);
    _ = sys.runQuiet(init.gpa, init.io, &.{
        bin,
        "--app-name",
        "Screen Cast",
        "-g",
        "\u{f03d}",
        "-t",
        "12000",
        "Screen Cast is live",
        body,
    }, 3000);
}

fn closeCastWindows(io: std.Io, gpa: std.mem.Allocator) void {
    const ran = sys.run(gpa, io, &.{ "hyprctl", "clients", "-j" }, 3000, 2 * 1024 * 1024) catch return;
    defer gpa.free(ran.stdout);
    defer gpa.free(ran.stderr);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const value = jsonx.parse(arena_state.allocator(), ran.stdout) catch return;
    const list = switch (value) {
        .array => |items| items,
        else => return,
    };
    for (list.items) |client| {
        const title = stringField(client, "title");
        const klass = stringField(client, "class");
        const initial = stringField(client, "initialClass");
        if (!eql(title, "Screen Cast") and !eql(klass, "screenmirror") and !eql(initial, "screenmirror")) continue;
        const address = stringField(client, "address");
        if (address.len == 0) continue;
        const owned = !std.mem.startsWith(u8, address, "address:");
        const selector = if (owned) std.fmt.allocPrint(gpa, "address:{s}", .{address}) catch continue else address;
        defer if (owned) gpa.free(selector);
        const dispatch = std.fmt.allocPrint(gpa, "hl.dsp.window.close({{ window = \"{s}\" }})", .{selector}) catch continue;
        defer gpa.free(dispatch);
        _ = sys.runQuiet(gpa, io, &.{ "hyprctl", "dispatch", dispatch }, 2000);
    }
}

fn focusCastWindow(io: std.Io, gpa: std.mem.Allocator) void {
    const ran = sys.run(gpa, io, &.{ "hyprctl", "clients", "-j" }, 3000, 2 * 1024 * 1024) catch return;
    defer gpa.free(ran.stdout);
    defer gpa.free(ran.stderr);
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const value = jsonx.parse(arena_state.allocator(), ran.stdout) catch return;
    const list = switch (value) {
        .array => |items| items,
        else => return,
    };
    for (list.items) |client| {
        const title = stringField(client, "title");
        const klass = stringField(client, "class");
        const address = stringField(client, "address");
        if (address.len == 0) continue;
        const match = eql(klass, "screenmirror") or (eql(klass, "foot") and (eql(title, "Screen Cast") or eql(title, "ScreenMirror")));
        if (!match) continue;
        const owned = !std.mem.startsWith(u8, address, "address:");
        const selector = if (owned) std.fmt.allocPrint(gpa, "address:{s}", .{address}) catch return else address;
        defer if (owned) gpa.free(selector);
        const dispatch = std.fmt.allocPrint(gpa, "hl.dsp.focus({{ window = \"{s}\" }})", .{selector}) catch return;
        defer gpa.free(dispatch);
        _ = sys.runQuiet(gpa, io, &.{ "hyprctl", "dispatch", dispatch }, 2000);
        return;
    }
}

fn stringField(value: jsonx.Value, key: []const u8) []const u8 {
    const item = value.get(key) orelse return "";
    return item.asString() orelse "";
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn writeStdout(io: std.Io, text: []const u8) !void {
    var buf: [1024]u8 = undefined;
    var w: std.Io.File.Writer = .init(.stdout(), io, &buf);
    try w.interface.writeAll(text);
    try w.interface.flush();
}

fn writeStderr(io: std.Io, text: []const u8) !void {
    var buf: [1024]u8 = undefined;
    var w: std.Io.File.Writer = .init(.stderr(), io, &buf);
    try w.interface.writeAll(text);
    try w.interface.flush();
}

fn printStdout(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [1024]u8 = undefined;
    var w: std.Io.File.Writer = .init(.stdout(), io, &buf);
    try w.interface.print(fmt, args);
    try w.interface.flush();
}

fn printStderr(io: std.Io, comptime fmt: []const u8, args: anytype) !void {
    var buf: [512]u8 = undefined;
    var w: std.Io.File.Writer = .init(.stderr(), io, &buf);
    try w.interface.print(fmt, args);
    try w.interface.flush();
}
