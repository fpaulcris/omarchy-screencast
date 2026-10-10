//! AirPlay video URL playback. This is the unauthenticated /play request.
//! AirPlay 2 screen mirroring needs pairing and FairPlay, which this sender does not do.
const std = @import("std");
const report = @import("report.zig");
const sys = @import("sys.zig");
const wire = @import("wire.zig");

const linux = std.os.linux;

pub const Answer = enum { ok, pairing, refused };

pub fn interpret(status: u16) Answer {
    if (status == 401 or status == 403 or status == 453) return .pairing;
    if (status >= 200 and status < 300) return .ok;
    return .refused;
}

pub fn playing(text: []const u8) bool {
    if (std.mem.indexOf(u8, text, "playing") != null) return true;
    if (std.mem.indexOf(u8, text, "Playing") != null) return true;
    if (std.mem.indexOf(u8, text, "<real>1") != null) return true;
    if (std.mem.indexOf(u8, text, "rate") != null and std.mem.indexOf(u8, text, "<integer>1</integer>") != null) return true;
    return false;
}

pub fn ended(text: []const u8) bool {
    if (playing(text)) return false;
    if (std.mem.indexOf(u8, text, "stopped") != null) return true;
    if (std.mem.indexOf(u8, text, "paused") != null) return true;
    return false;
}

pub fn playRequest(gpa: std.mem.Allocator, host: []const u8, port: u16, session: []const u8, url: []const u8) ![]u8 {
    const body = try std.fmt.allocPrint(gpa, "Content-Location: {s}\r\nStart-Position: 0\r\n", .{url});
    defer gpa.free(body);
    return std.fmt.allocPrint(gpa,
        "POST /play HTTP/1.1\r\nHost: {s}:{d}\r\nContent-Type: text/parameters\r\nContent-Length: {d}\r\nUser-Agent: MediaControl/1.0\r\nX-Apple-Session-ID: {s}\r\nConnection: close\r\n\r\n{s}",
        .{ host, port, body.len, session, body },
    );
}

fn shortRequest(gpa: std.mem.Allocator, method: []const u8, path: []const u8, host: []const u8, port: u16, session: []const u8) ![]u8 {
    return std.fmt.allocPrint(gpa,
        "{s} {s} HTTP/1.1\r\nHost: {s}:{d}\r\nContent-Length: 0\r\nUser-Agent: MediaControl/1.0\r\nX-Apple-Session-ID: {s}\r\nConnection: close\r\n\r\n",
        .{ method, path, host, port, session },
    );
}

fn sessionId(io: std.Io, out: []u8) void {
    var raw: [16]u8 = undefined;
    io.randomSecure(raw[0 .. out.len / 2]) catch {
        @memset(out, 'a');
        return;
    };
    const hex = "0123456789abcdef";
    for (raw[0 .. out.len / 2], 0..) |byte, i| {
        out[i * 2] = hex[byte >> 4];
        out[i * 2 + 1] = hex[byte & 0xf];
    }
}

pub fn run(io: std.Io, gpa: std.mem.Allocator, host: []const u8, port: u16, url: []const u8, playlist: []const u8) !void {
    var id_buf: [32]u8 = undefined;
    sessionId(io, &id_buf);
    const session = &id_buf;
    const play = try playRequest(gpa, host, port, session, url);
    defer gpa.free(play);
    const played = wire.exchange(io, gpa, host, port, play, 8000, 64 * 1024) orelse {
        return report.fail(io, "This AirPlay receiver did not accept the connection.");
    };
    defer gpa.free(played);
    const code = wire.statusCode(played) orelse 0;
    switch (interpret(code)) {
        .pairing => return report.fail(io, "This AirPlay receiver asked for pairing."),
        .refused => return report.fail(io, "This AirPlay receiver refused the desktop stream."),
        .ok => {},
    }
    const rate = try shortRequest(gpa, "POST", "/rate?value=1.000000", host, port, session);
    defer gpa.free(rate);
    if (wire.exchange(io, gpa, host, port, rate, 3000, 16 * 1024)) |reply| gpa.free(reply);
    const info_req = try shortRequest(gpa, "GET", "/playback-info", host, port, session);
    defer gpa.free(info_req);
    var mark = sys.monoMs(io);
    var saw_info = false;
    var live = false;
    const deadline = sys.monoMs(io) + 20000;
    while (!report.stopped() and sys.monoMs(io) < deadline) {
        if (report.stalled(io, playlist, &mark)) return report.fail(io, "The desktop stream stopped.");
        if (wire.exchange(io, gpa, host, port, info_req, 2500, 64 * 1024)) |reply| {
            defer gpa.free(reply);
            const info_code = wire.statusCode(reply) orelse 0;
            if (info_code == 404 or info_code == 501) {
                if (!saw_info) {
                    live = true;
                    break;
                }
            } else if (info_code >= 200 and info_code < 300) {
                const text = wire.bodyOf(reply);
                if (text.len == 0) {
                    if (!saw_info) {
                        live = true;
                        break;
                    }
                } else {
                    saw_info = true;
                    if (playing(text)) {
                        live = true;
                        break;
                    }
                }
            }
        } else if (!saw_info) {
            live = true;
            break;
        }
        sys.sleepMs(io, 300);
    }
    if (report.stopped()) {
        postStop(io, gpa, host, port, session);
        report.publish("stopped", "Stopped.", 0);
        return;
    }
    if (!live) return report.fail(io, "This AirPlay receiver did not start the picture.");
    report.log(io, "airplay playing");
    report.publish("live", "Mirroring.", @intCast(linux.getpid()));
    var info_at = sys.monoMs(io);
    while (!report.stopped()) {
        if (report.stalled(io, playlist, &mark)) {
            postStop(io, gpa, host, port, session);
            return report.fail(io, "The desktop stream stopped.");
        }
        if (sys.monoMs(io) - info_at > 2000) {
            info_at = sys.monoMs(io);
            if (wire.exchange(io, gpa, host, port, info_req, 2500, 64 * 1024)) |reply| {
                defer gpa.free(reply);
                if ((wire.statusCode(reply) orelse 0) == 200 and ended(wire.bodyOf(reply))) {
                    postStop(io, gpa, host, port, session);
                    return report.fail(io, "This AirPlay receiver stopped the picture.");
                }
            }
        }
        sys.sleepMs(io, 200);
    }
    postStop(io, gpa, host, port, session);
    report.publish("stopped", "Stopped.", 0);
}

fn postStop(io: std.Io, gpa: std.mem.Allocator, host: []const u8, port: u16, session: []const u8) void {
    const stop = shortRequest(gpa, "POST", "/stop", host, port, session) catch return;
    defer gpa.free(stop);
    if (wire.exchange(io, gpa, host, port, stop, 2000, 8192)) |reply| gpa.free(reply);
}

test "airplay play request carries the stream address" {
    const gpa = std.testing.allocator;
    const req = try playRequest(gpa, "192.168.0.174", 7000, "abcd", "http://192.168.0.110:8080/hls/tok/live.m3u8");
    defer gpa.free(req);
    try std.testing.expect(std.mem.indexOf(u8, req, "POST /play ") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "text/parameters") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "Content-Location: http://192.168.0.110:8080/hls/tok/live.m3u8\r\n") != null);
    try std.testing.expectEqual(Answer.pairing, interpret(403));
    try std.testing.expectEqual(Answer.ok, interpret(200));
    try std.testing.expect(playing("<key>rate</key><real>1.0</real>"));
    try std.testing.expect(ended("<string>stopped</string>"));
    try std.testing.expect(!ended("<string>playing</string>"));
}
