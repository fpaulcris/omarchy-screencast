const std = @import("std");
const hls = @import("hls.zig");
const state = @import("state.zig");
const sys = @import("sys.zig");

const watch_html = @embedFile("watch.html");

const html =
    \\<html>
    \\<head>
    \\<title>Screen Cast</title>
    \\<style type="text/css">
    \\html, body { margin: 0; padding: 0; width: 100%; height: 100%; background: #000; overflow: hidden; }
    \\img { position: absolute; left: 0; top: 0; width: 100%; height: 100%; border: 0; object-fit: contain; }
    \\</style>
    \\</head>
    \\<body bgcolor="#000000">
    \\<img src="stream.mjpg" alt="">
    \\</body>
    \\</html>
;

const poll_html =
    \\<html>
    \\<head>
    \\<title>Screen Cast</title>
    \\<style type="text/css">
    \\html, body { margin: 0; padding: 0; width: 100%; height: 100%; background: #000; overflow: hidden; }
    \\img { position: absolute; left: 0; top: 0; width: 100%; height: 100%; border: 0; object-fit: contain; }
    \\</style>
    \\</head>
    \\<body bgcolor="#000000">
    \\<img id="a" alt="">
    \\<script type="text/javascript">
    \\var shown = document.getElementById('a');
    \\function tick() {
    \\  var next = new Image();
    \\  next.onload = function() { shown.src = next.src; tick(); };
    \\  next.onerror = function() { setTimeout(tick, 400); };
    \\  next.src = 'frame.jpg?n=' + (new Date()).getTime();
    \\}
    \\tick();
    \\</script>
    \\</body>
    \\</html>
;

const old_markers = [_][]const u8{
    "viera", "panasonic", "netfront", "hbbtv", "netcast", "aquos",
};

pub fn serve(world: *state.World, port: u16) void {
    const addr = std.Io.net.IpAddress.parseIp4("0.0.0.0", port) catch return;
    var server = addr.listen(world.io, .{ .reuse_address = true }) catch return;
    while (!world.stop.load(.acquire)) {
        const stream = server.accept(world.io) catch continue;
        const thread = std.Thread.spawn(.{}, handle, .{ world, stream }) catch {
            stream.close(world.io);
            continue;
        };
        thread.detach();
    }
    server.socket.close(world.io);
}

fn handle(world: *state.World, stream: std.Io.net.Stream) void {
    defer stream.close(world.io);
    var req_buf: [8192]u8 = undefined;
    var req_w: std.Io.Writer = .fixed(&req_buf);
    var read_buf: [1024]u8 = undefined;
    var reader = stream.reader(world.io, &read_buf);
    const n = reader.interface.stream(&req_w, .limited(req_buf.len)) catch return;
    if (n == 0) return;
    const req = req_buf[0..n];
    const line_end = std.mem.indexOf(u8, req, "\r\n") orelse return;
    const line = req[0..line_end];
    if (!std.mem.startsWith(u8, line, "GET ")) return;
    const path_start: usize = 4;
    const path_end = std.mem.indexOfScalar(u8, line[path_start..], ' ') orelse return;
    var path = line[path_start .. path_start + path_end];
    if (std.mem.indexOfScalar(u8, path, '?')) |q| path = path[0..q];
    var wbuf: [8192]u8 = undefined;
    var writer = stream.writer(world.io, &wbuf);
    const out = &writer.interface;
    if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html")) {
        if (oldTv(req)) {
            send(out, 200, "text/html", poll_html, false) catch {};
            return;
        }
        if (hls.readToken(world.io, world.gpa, world.runtime)) |token| {
            sendWatch(out, token) catch send(out, 200, "text/html", html, false) catch {};
            return;
        }
        send(out, 200, "text/html", html, false) catch {};
        return;
    }
    if (std.mem.eql(u8, path, "/poll")) {
        send(out, 200, "text/html", poll_html, false) catch {};
        return;
    }
    if (std.mem.eql(u8, path, "/preview") or std.mem.startsWith(u8, path, "/preview/")) {
        if (std.mem.eql(u8, path, "/preview/on")) setPreview(world, true) else if (std.mem.eql(u8, path, "/preview/off")) setPreview(world, false) else if (std.mem.eql(u8, path, "/preview/toggle")) setPreview(world, !previewEnabled(world)) else if (!std.mem.eql(u8, path, "/preview")) {
            send(out, 404, "text/plain", "not found\n", false) catch {};
            return;
        }
        sendPreview(world, out) catch {};
        return;
    }
    if (std.mem.eql(u8, path, "/health") or std.mem.eql(u8, path, "/ok")) {
        const snap = world.snapshot();
        if (snap.ready) send(out, 200, "text/plain", "ok\n", false) catch {} else send(out, 503, "text/plain", "starting\n", false) catch {};
        return;
    }
    if (std.mem.eql(u8, path, "/frame.jpg") or std.mem.eql(u8, path, "/frame.jpeg") or std.mem.eql(u8, path, "/desktop.jpg")) {
        const jpeg = world.gpa.alloc(u8, state.frame_cap) catch return;
        defer world.gpa.free(jpeg);
        if (world.copyFrame(jpeg)) |got| {
            send(out, 200, "image/jpeg", jpeg[0..got.len], false) catch {};
        } else send(out, 503, "text/plain", "starting\n", false) catch {};
        return;
    }
    if (std.mem.eql(u8, path, "/stream.mjpg") or std.mem.eql(u8, path, "/live.mjpg")) {
        streamMjpeg(world, out) catch {};
        return;
    }
    if (std.mem.startsWith(u8, path, "/hls/")) {
        sendHls(world, out, path[5..]) catch {};
        return;
    }
    send(out, 404, "text/plain", "not found\n", false) catch {};
}

fn oldTv(req: []const u8) bool {
    var lower: [8192]u8 = undefined;
    const n = @min(req.len, lower.len);
    for (req[0..n], 0..) |byte, i| lower[i] = std.ascii.toLower(byte);
    for (old_markers) |marker| if (std.mem.indexOf(u8, lower[0..n], marker) != null) return true;
    return false;
}

fn sendWatch(out: *std.Io.Writer, token: [32]u8) !void {
    const mark = "__TOKEN__";
    const at = std.mem.indexOf(u8, watch_html, mark) orelse return error.NoToken;
    const prefix = watch_html[0..at];
    const suffix = watch_html[at + mark.len ..];
    if (std.mem.indexOf(u8, suffix, mark) != null) return error.NoToken;
    const len = prefix.len + token.len + suffix.len;
    try out.print("HTTP/1.0 200 OK\r\nContent-Type: text/html\r\nContent-Length: {d}\r\n", .{len});
    try out.writeAll("Cache-Control: no-store, no-cache, must-revalidate\r\nPragma: no-cache\r\nConnection: close\r\n\r\n");
    try out.writeAll(prefix);
    try out.writeAll(&token);
    try out.writeAll(suffix);
    try out.flush();
}

fn previewPath(world: *state.World) ![]u8 {
    return sys.join(world.gpa, world.runtime, "preview.on");
}

fn previewEnabled(world: *state.World) bool {
    const path = previewPath(world) catch return false;
    defer world.gpa.free(path);
    return sys.flagOn(world.io, world.gpa, path);
}

fn setPreview(world: *state.World, on: bool) void {
    const path = previewPath(world) catch return;
    defer world.gpa.free(path);
    sys.ensureDir(world.io, world.runtime);
    sys.setFlag(world.io, path, on) catch {};
}

fn sendPreview(world: *state.World, out: *std.Io.Writer) !void {
    const body = if (previewEnabled(world)) "{\"preview\":true}\n" else "{\"preview\":false}\n";
    try send(out, 200, "application/json", body, false);
}

fn send(out: *std.Io.Writer, code: u16, ctype: []const u8, body: []const u8, cors: bool) !void {
    const reason: []const u8 = switch (code) {
        200 => "OK",
        503 => "Unavailable",
        else => "Not Found",
    };
    try out.print("HTTP/1.0 {d} {s}\r\nContent-Type: {s}\r\nContent-Length: {d}\r\n", .{ code, reason, ctype, body.len });
    if (cors) try out.writeAll("Access-Control-Allow-Origin: *\r\n");
    try out.writeAll("Cache-Control: no-store, no-cache, must-revalidate\r\nPragma: no-cache\r\nConnection: close\r\n\r\n");
    try out.writeAll(body);
    try out.flush();
}

fn writeChunk(out: *std.Io.Writer, data: []const u8) !void {
    try out.print("{x}\r\n", .{data.len});
    try out.writeAll(data);
    try out.writeAll("\r\n");
    try out.flush();
}

fn streamLive(world: *state.World, out: *std.Io.Writer) !void {
    try out.writeAll("HTTP/1.1 200 OK\r\nContent-Type: video/mp2t\r\nCache-Control: no-store\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n");
    try out.flush();
    var cursor = state.liveEdge(world.io);
    var buf: [188 * 32]u8 = undefined;
    while (!world.stop.load(.acquire)) {
        const n = state.copyLive(world.io, &buf, &cursor);
        if (n == 0) {
            sys.sleepMs(world.io, 5);
            continue;
        }
        writeChunk(out, buf[0..n]) catch return;
    }
    out.writeAll("0\r\n\r\n") catch {};
    out.flush() catch {};
}

fn streamMjpeg(world: *state.World, out: *std.Io.Writer) !void {
    try out.writeAll("HTTP/1.0 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=frame\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n");
    try out.flush();
    const jpeg = try world.gpa.alloc(u8, state.frame_cap);
    defer world.gpa.free(jpeg);
    var last: u64 = 0;
    while (!world.stop.load(.acquire)) {
        const got = world.copyFrame(jpeg) orelse {
            sys.sleepMs(world.io, 40);
            continue;
        };
        if (got.id == last) {
            sys.sleepMs(world.io, 30);
            continue;
        }
        last = got.id;
        try out.print("--frame\r\nContent-Type: image/jpeg\r\nContent-Length: {d}\r\n\r\n", .{got.len});
        try out.writeAll(jpeg[0..got.len]);
        try out.writeAll("\r\n");
        try out.flush();
    }
}

fn hlsName(token: []const u8, rest: []const u8) ?[]const u8 {
    if (token.len != 32) return null;
    for (token) |byte| if (!std.ascii.isHex(byte)) return null;
    if (rest.len < token.len + 2 or !std.mem.startsWith(u8, rest, token) or rest[token.len] != '/') return null;
    const name = rest[token.len + 1 ..];
    if (name.len == 0 or name.len > 81) return null;
    if (!std.ascii.isAlphanumeric(name[0])) return null;
    for (name) |byte| {
        const ok = std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '_' or byte == '-';
        if (!ok) return null;
    }
    return name;
}

fn sendHls(world: *state.World, out: *std.Io.Writer, rest: []const u8) !void {
    const token_path = try sys.join(world.gpa, world.runtime, "hls.token");
    defer world.gpa.free(token_path);
    const raw = sys.readAll(world.io, world.gpa, token_path, 64) orelse {
        try send(out, 404, "text/plain", "not found\n", false);
        return;
    };
    defer world.gpa.free(raw);
    const token = std.mem.trim(u8, raw, " \t\r\n");
    const name = hlsName(token, rest) orelse {
        try send(out, 404, "text/plain", "not found\n", false);
        return;
    };
    if (std.mem.eql(u8, name, "live.ts")) {
        streamLive(world, out) catch {};
        return;
    }
    const path = try std.fmt.allocPrint(world.gpa, "{s}/hls/{s}", .{ world.runtime, name });
    defer world.gpa.free(path);
    const body = sys.readAll(world.io, world.gpa, path, 8 * 1024 * 1024) orelse {
        try send(out, 404, "text/plain", "not found\n", false);
        return;
    };
    defer world.gpa.free(body);
    const ctype: []const u8 = if (std.mem.endsWith(u8, name, ".m3u8"))
        "application/vnd.apple.mpegurl"
    else if (std.mem.endsWith(u8, name, ".ts"))
        "video/mp2t"
    else
        "application/octet-stream";
    try send(out, 200, ctype, body, true);
}

pub fn bind(world: *state.World, ports: []const u16) ![]u16 {
    var bound: std.ArrayList(u16) = .empty;
    errdefer bound.deinit(world.gpa);
    for (ports) |port| {
        const addr = std.Io.net.IpAddress.parseIp4("0.0.0.0", port) catch continue;
        const server = addr.listen(world.io, .{ .reuse_address = true }) catch |err| switch (err) {
            error.AddressInUse => {
                log(world, "port {d} is already open\n", .{port});
                continue;
            },
            else => continue,
        };
        try bound.append(world.gpa, port);
        const thread = try std.Thread.spawn(.{}, acceptLoop, .{ world, server });
        thread.detach();
        log(world, "Listening on http://{s}:{d}/\n", .{ world.ip, port });
    }
    return bound.toOwnedSlice(world.gpa);
}

fn acceptLoop(world: *state.World, server: std.Io.net.Server) void {
    var alive = server;
    while (!world.stop.load(.acquire)) {
        const stream = alive.accept(world.io) catch continue;
        const thread = std.Thread.spawn(.{}, handle, .{ world, stream }) catch {
            stream.close(world.io);
            continue;
        };
        thread.detach();
    }
}

fn log(world: *state.World, comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    var err_w: std.Io.File.Writer = .init(.stderr(), world.io, &buf);
    err_w.interface.print(fmt, args) catch {};
    err_w.interface.flush() catch {};
}

test "living room browsers get the picture with sound" {
    const tizen = "GET / HTTP/1.1\r\nUser-Agent: Mozilla/5.0 (SMART-TV; LINUX; Tizen 6.5) AppleWebKit/537.36\r\n\r\n";
    const webos = "GET / HTTP/1.1\r\nUser-Agent: Mozilla/5.0 (Web0S; Linux/SmartTV) AppleWebKit/537.36 Chrome/87.0.4280.88\r\n\r\n";
    const bravia = "GET / HTTP/1.1\r\nUser-Agent: Mozilla/5.0 (Linux; Android 12; BRAVIA 4K VH2) AppleWebKit/537.36 Chrome/108.0\r\n\r\n";
    const desktop = "GET / HTTP/1.1\r\nUser-Agent: Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 Chrome/154.0.0.0\r\n\r\n";
    try std.testing.expect(!oldTv(tizen));
    try std.testing.expect(!oldTv(webos));
    try std.testing.expect(!oldTv(bravia));
    try std.testing.expect(!oldTv(desktop));
    try std.testing.expect(oldTv("GET / HTTP/1.1\r\nUser-Agent: Mozilla/5.0 (Linux; U; Viera)\r\n\r\n"));
    try std.testing.expect(oldTv("GET / HTTP/1.1\r\nUser-Agent: HbbTV/1.5.1\r\n\r\n"));
    try std.testing.expect(oldTv("GET / HTTP/1.1\r\nUser-Agent: NetCast\r\n\r\n"));
    try std.testing.expect(oldTv("GET / HTTP/1.1\r\nUser-Agent: AQUOS\r\n\r\n"));
}
