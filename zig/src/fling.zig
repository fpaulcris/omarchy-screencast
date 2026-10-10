//! WhisperPlay player on a Fire TV. A refusal string is the stick's own reply.
const std = @import("std");
const report = @import("report.zig");
const sys = @import("sys.zig");
const wire = @import("wire.zig");

const linux = std.os.linux;

const meta = "{\"type\":\"video\",\"title\":\"Desktop\"}";

pub fn run(io: std.Io, gpa: std.mem.Allocator, host: []const u8, port: u16, uuid: []const u8, stream: []const u8, playlist: []const u8) error{ NoPlayer, Reported, OutOfMemory }!void {
    if (!uuidOk(uuid)) return error.NoPlayer;
    const probed = call(io, gpa, host, port, uuid, "getStatus", 1, "", 3000) orelse return error.NoPlayer;
    defer gpa.free(probed);
    if (!speaksPlayer(probed)) return error.NoPlayer;
    if (report.stopped()) {
        report.publish("stopped", "Stopped.", 0);
        return;
    }
    const fields = try sourceFields(gpa, stream);
    defer gpa.free(fields);
    const posted = call(io, gpa, host, port, uuid, "setMediaSource", 2, fields, 8000) orelse {
        stopPlayer(io, gpa, host, port, uuid);
        return report.fail(io, "This Fire TV's player did not answer.");
    };
    defer gpa.free(posted);
    if (wire.statusCode(posted) != 200 or messageFields(wire.bodyOf(posted)) == null) {
        stopPlayer(io, gpa, host, port, uuid);
        return report.fail(io, "This Fire TV's player did not answer.");
    }
    // The integer beside a refusal is an error code, not MediaState.
    if (playerText(wire.bodyOf(posted))) |text| {
        stopPlayer(io, gpa, host, port, uuid);
        return refuse(io, text);
    }
    var mark = sys.monoMs(io);
    const deadline = sys.monoMs(io) + 20000;
    var polled = sys.monoMs(io) - 1000;
    var live = false;
    var seq: i32 = 10;
    while (!report.stopped() and sys.monoMs(io) < deadline) {
        if (report.stalled(io, playlist, &mark)) {
            stopPlayer(io, gpa, host, port, uuid);
            return report.fail(io, "The desktop stream stopped.");
        }
        if (sys.monoMs(io) - polled >= 1000) {
            polled = sys.monoMs(io);
            seq += 1;
            if (statusOf(io, gpa, host, port, uuid, seq)) |state| {
                if (state == 3) {
                    live = true;
                    break;
                }
                if (state == 7) {
                    stopPlayer(io, gpa, host, port, uuid);
                    return report.fail(io, "The Fire TV player stopped the video.");
                }
            }
        }
        sys.sleepMs(io, 200);
    }
    if (report.stopped()) {
        stopPlayer(io, gpa, host, port, uuid);
        report.publish("stopped", "Stopped.", 0);
        return;
    }
    if (!live) {
        stopPlayer(io, gpa, host, port, uuid);
        return report.fail(io, "The Fire TV player did not start the picture.");
    }
    report.log(io, "fling playing");
    report.publish("live", "Mirroring.", @intCast(linux.getpid()));
    var status_at = sys.monoMs(io);
    while (!report.stopped()) {
        if (report.stalled(io, playlist, &mark)) {
            stopPlayer(io, gpa, host, port, uuid);
            return report.fail(io, "The desktop stream stopped.");
        }
        if (sys.monoMs(io) - status_at >= 1000) {
            status_at = sys.monoMs(io);
            seq += 1;
            if (statusOf(io, gpa, host, port, uuid, seq)) |state| if (state == 7) {
                stopPlayer(io, gpa, host, port, uuid);
                return report.fail(io, "The Fire TV player stopped the video.");
            };
        }
        sys.sleepMs(io, 200);
    }
    stopPlayer(io, gpa, host, port, uuid);
    report.publish("stopped", "Stopped.", 0);
}

fn statusOf(io: std.Io, gpa: std.mem.Allocator, host: []const u8, port: u16, uuid: []const u8, seq: i32) ?i32 {
    const resp = call(io, gpa, host, port, uuid, "getStatus", seq, "", 2500) orelse return null;
    defer gpa.free(resp);
    return mediaState(wire.bodyOf(resp));
}

fn stopPlayer(io: std.Io, gpa: std.mem.Allocator, host: []const u8, port: u16, uuid: []const u8) void {
    const resp = call(io, gpa, host, port, uuid, "stop", 3, "", 2000) orelse return;
    gpa.free(resp);
}

fn refuse(io: std.Io, text: []const u8) error{Reported} {
    const prefix = "This Fire TV's player refused the video.";
    if (!readable(text)) return report.fail(io, prefix);
    var buf: [320]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    w.writeAll(prefix) catch return report.fail(io, prefix);
    w.writeAll(" ") catch return report.fail(io, prefix);
    w.writeAll(text) catch {};
    return report.fail(io, w.buffered());
}

fn readable(text: []const u8) bool {
    if (text.len == 0 or text.len > 180) return false;
    for (text) |byte| if (byte < 32 or byte > 126) return false;
    return true;
}

fn uuidOk(text: []const u8) bool {
    if (text.len != 32) return false;
    for (text) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
}

fn speaksPlayer(response: []const u8) bool {
    if (wire.statusCode(response) != 200) return false;
    const body = wire.bodyOf(response);
    if (std.mem.indexOf(u8, body, "Invalid method name") != null) return false;
    if (messageFields(body) == null) return false;
    return (std.mem.readInt(u32, body[0..4], .big) & 0xff) == 2;
}

fn messageFields(body: []const u8) ?[]const u8 {
    if (body.len < 12) return null;
    const head = std.mem.readInt(u32, body[0..4], .big);
    if ((head >> 16) != 0x8001) return null;
    const kind = head & 0xff;
    if (kind != 2 and kind != 3) return null;
    const name_raw = std.mem.readInt(i32, body[4..8], .big);
    if (name_raw < 0 or name_raw > 128) return null;
    const name_len: usize = @intCast(name_raw);
    const at = 12 + name_len;
    if (at > body.len) return null;
    return body[at..];
}

fn playerText(body: []const u8) ?[]const u8 {
    const fields = messageFields(body) orelse return null;
    return firstString(fields);
}

fn mediaState(body: []const u8) ?i32 {
    const fields = messageFields(body) orelse return null;
    var i: usize = 0;
    while (i < fields.len) {
        const kind = fields[i];
        if (kind == 0) {
            i += 1;
            continue;
        }
        if (i + 3 > fields.len) return null;
        const id = std.mem.readInt(u16, fields[i + 1 ..][0..2], .big);
        i += 3;
        switch (kind) {
            0x02 => {
                if (i >= fields.len) return null;
                i += 1;
            },
            0x08 => {
                if (i + 4 > fields.len) return null;
                const value = std.mem.readInt(i32, fields[i..][0..4], .big);
                if (id == 1) return value;
                i += 4;
            },
            0x0b => {
                if (i + 4 > fields.len) return null;
                const raw = std.mem.readInt(i32, fields[i..][0..4], .big);
                if (raw < 0) return null;
                const n: usize = @intCast(raw);
                i += 4;
                if (i + n > fields.len) return null;
                i += n;
            },
            0x0c => {},
            else => return null,
        }
    }
    return null;
}

fn firstString(fields: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < fields.len) {
        const kind = fields[i];
        if (kind == 0) {
            i += 1;
            continue;
        }
        if (i + 3 > fields.len) return null;
        i += 3;
        switch (kind) {
            0x02 => {
                if (i >= fields.len) return null;
                i += 1;
            },
            0x08 => {
                if (i + 4 > fields.len) return null;
                i += 4;
            },
            0x0b => {
                if (i + 4 > fields.len) return null;
                const raw = std.mem.readInt(i32, fields[i..][0..4], .big);
                if (raw < 0) return null;
                const n: usize = @intCast(raw);
                i += 4;
                if (i + n > fields.len) return null;
                return fields[i .. i + n];
            },
            0x0c => {},
            else => return null,
        }
    }
    return null;
}

fn sourceFields(gpa: std.mem.Allocator, url: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try writeString(gpa, &out, 1, url);
    try writeString(gpa, &out, 2, meta);
    try writeBool(gpa, &out, 3, true);
    try writeBool(gpa, &out, 4, false);
    return out.toOwnedSlice(gpa);
}

fn writeString(gpa: std.mem.Allocator, list: *std.ArrayList(u8), id: u16, text: []const u8) !void {
    try list.append(gpa, 0x0b);
    try writeBe(u16, gpa, list, id);
    try writeBe(i32, gpa, list, @intCast(text.len));
    try list.appendSlice(gpa, text);
}

fn writeBool(gpa: std.mem.Allocator, list: *std.ArrayList(u8), id: u16, value: bool) !void {
    try list.append(gpa, 0x02);
    try writeBe(u16, gpa, list, id);
    try list.append(gpa, if (value) 1 else 0);
}

fn writeBe(comptime T: type, gpa: std.mem.Allocator, list: *std.ArrayList(u8), value: T) !void {
    var buf: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buf, value, .big);
    try list.appendSlice(gpa, &buf);
}

fn request(gpa: std.mem.Allocator, host: []const u8, port: u16, uuid: []const u8, method: []const u8, seq: i32, fields: []const u8) ![]u8 {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try writeBe(u32, gpa, &body, 0x80010001);
    try writeBe(i32, gpa, &body, @intCast(method.len));
    try body.appendSlice(gpa, method);
    try writeBe(i32, gpa, &body, seq);
    try body.appendSlice(gpa, fields);
    try body.append(gpa, 0);
    const head = try std.fmt.allocPrint(gpa,
        "POST /whisperlink HTTP/1.1\r\nHost: {s}:{d}\r\nContent-Length: {d}\r\nConnection: close\r\nx-amzn-svc-uuid: amzn.thin.pl\r\nx-amzn-dev-uuid: {s}\r\nx-amzn-svc-version: 0\r\nx-amzn-dev-name: Omarchy\r\nx-amzn-channel: inet\r\nx-amzn-connection-id: 1\r\nx-amzn-dev-type: 0\r\n\r\n",
        .{ host, port, body.items.len, uuid },
    );
    defer gpa.free(head);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, head);
    try out.appendSlice(gpa, body.items);
    return out.toOwnedSlice(gpa);
}

fn call(io: std.Io, gpa: std.mem.Allocator, host: []const u8, port: u16, uuid: []const u8, method: []const u8, seq: i32, fields: []const u8, timeout_ms: i32) ?[]u8 {
    const req = request(gpa, host, port, uuid, method, seq, fields) catch return null;
    defer gpa.free(req);
    return wire.exchange(io, gpa, host, port, req, timeout_ms, 64 * 1024);
}

test "fling reply carries the player refusal" {
    const gpa = std.testing.allocator;
    const sentence = "Requires ACCESS_HDMI_SERVICE_ADVANCED permission";
    const head = [_]u8{
        0x80, 0x01, 0x00, 0x02, 0x00, 0x00, 0x00, 14,
        's',  'e',  't',  'M',  'e',  'd',  'i',  'a',
        'S',  'o',  'u',  'r',  'c',  'e',  0x00, 0x00,
        0x00, 0x04, 0x0c, 0x00, 0x01, 0x08, 0x00, 0x01,
        0x00, 0x00, 0x00, 0x02, 0x0b, 0x00, 0x02, 0x00,
        0x00, 0x00, 0x30,
    };
    var raw: [93]u8 = undefined;
    @memcpy(raw[0..head.len], &head);
    @memcpy(raw[head.len .. head.len + sentence.len], sentence);
    raw[91] = 0;
    raw[92] = 0;
    try std.testing.expectEqual(@as(usize, 43), head.len);
    try std.testing.expectEqualStrings(sentence, playerText(&raw).?);
    try std.testing.expectEqual(@as(i32, 2), mediaState(&raw).?);
    const playing = [_]u8{
        0x80, 0x01, 0x00, 0x02, 0x00, 0x00, 0x00, 9,
        'g',  'e',  't',  'S',  't',  'a',  't',  'u',
        's',  0x00, 0x00, 0x00, 0x01, 0x0c, 0x00, 0x00,
        0x08, 0x00, 0x01, 0x00, 0x00, 0x00, 0x03, 0x08,
        0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };
    try std.testing.expectEqual(@as(i32, 3), mediaState(&playing).?);
    try std.testing.expect(playerText(&playing) == null);
    const fields = try sourceFields(gpa, "http://192.168.0.110:8080/hls/tok/live.m3u8");
    defer gpa.free(fields);
    const req = try request(gpa, "192.168.0.144", 38083, "0123456789ABCDEF0123456789ABCDEF", "setMediaSource", 4, fields);
    defer gpa.free(req);
    try std.testing.expect(std.mem.indexOf(u8, req, "POST /whisperlink ") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "x-amzn-svc-uuid: amzn.thin.pl\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "x-amzn-dev-uuid: 0123456789ABCDEF0123456789ABCDEF\r\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "http://192.168.0.110:8080/hls/tok/live.m3u8") != null);
    try std.testing.expect(std.mem.indexOf(u8, req, meta) != null);
    try std.testing.expect(std.mem.indexOf(u8, req, "setMediaSource") != null);
}

test "fling reports the player refusal and ignores another service" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const sentence = "Requires ACCESS_HDMI_SERVICE_ADVANCED permission";
    const head = [_]u8{
        0x80, 0x01, 0x00, 0x02, 0x00, 0x00, 0x00, 14,
        's',  'e',  't',  'M',  'e',  'd',  'i',  'a',
        'S',  'o',  'u',  'r',  'c',  'e',  0x00, 0x00,
        0x00, 0x04, 0x0c, 0x00, 0x01, 0x08, 0x00, 0x01,
        0x00, 0x00, 0x00, 0x02, 0x0b, 0x00, 0x02, 0x00,
        0x00, 0x00, 0x30,
    };
    var refusal: [93]u8 = undefined;
    @memcpy(refusal[0..head.len], &head);
    @memcpy(refusal[head.len .. head.len + sentence.len], sentence);
    refusal[91] = 0;
    refusal[92] = 0;

    report.clear();
    var absent_port: u16 = 0;
    var absent_ready = std.atomic.Value(bool).init(false);
    const absent = try std.Thread.spawn(.{}, struct {
        fn serve(out_port: *u16, flag: *std.atomic.Value(bool)) void {
            const listener = wire.listenTcp(0) orelse return;
            defer wire.close(listener.fd);
            out_port.* = listener.port;
            flag.store(true, .release);
            if (!wire.pollIn(listener.fd, 2000)) return;
            var sa = linux.sockaddr.in{ .port = 0, .addr = 0 };
            var slen: linux.socklen_t = @sizeOf(linux.sockaddr.in);
            const accepted = linux.accept4(listener.fd, @ptrCast(&sa), &slen, linux.SOCK.CLOEXEC);
            if (linux.errno(accepted) != .SUCCESS) return;
            const fd: i32 = @intCast(accepted);
            defer wire.close(fd);
            var buf: [2048]u8 = undefined;
            var got: usize = 0;
            while (got < buf.len) {
                if (std.mem.indexOf(u8, buf[0..got], "\r\n\r\n") != null) break;
                if (!wire.pollIn(fd, 1000)) break;
                const chunk = wire.readSome(fd, buf[got..]) orelse break;
                got += chunk.len;
            }
            const msg = "Invalid method name: 'getStatus'";
            var hdr: [96]u8 = undefined;
            const top = std.fmt.bufPrint(&hdr, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{msg.len}) catch return;
            if (!wire.writeAll(fd, top)) return;
            _ = wire.writeAll(fd, msg);
        }
    }.serve, .{ &absent_port, &absent_ready });
    defer absent.join();
    var spins: usize = 0;
    while (!absent_ready.load(.acquire) and spins < 50) : (spins += 1) sys.sleepMs(io, 20);
    try std.testing.expect(absent_port != 0);
    try std.testing.expectError(error.NoPlayer, run(io, gpa, "127.0.0.1", absent_port, "0123456789ABCDEF0123456789ABCDEF", "http://127.0.0.1/desktop.m3u8", "missing-playlist"));
    try std.testing.expectEqual(@as(usize, 0), report.get().len);

    report.clear();
    var port: u16 = 0;
    var ready = std.atomic.Value(bool).init(false);
    var saw_url = std.atomic.Value(bool).init(false);
    var saw_stop = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, struct {
        fn serve(out_port: *u16, flag: *std.atomic.Value(bool), payload: *const [93]u8, url_flag: *std.atomic.Value(bool), stop_flag: *std.atomic.Value(bool)) void {
            const listener = wire.listenTcp(0) orelse return;
            defer wire.close(listener.fd);
            out_port.* = listener.port;
            flag.store(true, .release);
            var n: usize = 0;
            while (n < 4) : (n += 1) {
                if (!wire.pollIn(listener.fd, 3000)) return;
                var sa = linux.sockaddr.in{ .port = 0, .addr = 0 };
                var slen: linux.socklen_t = @sizeOf(linux.sockaddr.in);
                const accepted = linux.accept4(listener.fd, @ptrCast(&sa), &slen, linux.SOCK.CLOEXEC);
                if (linux.errno(accepted) != .SUCCESS) return;
                const fd: i32 = @intCast(accepted);
                defer wire.close(fd);
                var buf: [2048]u8 = undefined;
                var got: usize = 0;
                while (got < buf.len) {
                    if (std.mem.indexOf(u8, buf[0..got], "\r\n\r\n")) |at| {
                        const raw = wire.headerValue(buf[0 .. at + 4], "Content-Length") orelse break;
                        const need = std.fmt.parseInt(usize, raw, 10) catch break;
                        if (got >= at + 4 + need) break;
                    }
                    if (!wire.pollIn(fd, 1000)) break;
                    const chunk = wire.readSome(fd, buf[got..]) orelse break;
                    got += chunk.len;
                }
                const req = buf[0..got];
                if (std.mem.indexOf(u8, req, "desktop.m3u8") != null) url_flag.store(true, .release);
                const idle = [_]u8{
                    0x80, 0x01, 0x00, 0x02, 0x00, 0x00, 0x00, 9,
                    'g',  'e',  't',  'S',  't',  'a',  't',  'u',
                    's',  0x00, 0x00, 0x00, 0x01, 0x0c, 0x00, 0x00,
                    0x08, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x08,
                    0x00, 0x02, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                };
                const stopped_body = [_]u8{
                    0x80, 0x01, 0x00, 0x02, 0x00, 0x00, 0x00, 4,
                    's',  't',  'o',  'p',  0x00, 0x00, 0x00, 3,
                    0x00,
                };
                const is_source = std.mem.indexOf(u8, req, "setMediaSource") != null;
                const is_stop = std.mem.indexOf(u8, req, "\x00\x00\x00\x04stop") != null;
                if (is_stop) stop_flag.store(true, .release);
                const body: []const u8 = if (is_source) payload else if (is_stop) &stopped_body else &idle;
                var hdr: [96]u8 = undefined;
                const top = std.fmt.bufPrint(&hdr, "HTTP/1.1 200 OK\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n", .{body.len}) catch return;
                if (!wire.writeAll(fd, top)) return;
                _ = wire.writeAll(fd, body);
            }
        }
    }.serve, .{ &port, &ready, &refusal, &saw_url, &saw_stop });
    defer thread.join();
    spins = 0;
    while (!ready.load(.acquire) and spins < 50) : (spins += 1) sys.sleepMs(io, 20);
    try std.testing.expect(port != 0);
    try std.testing.expectError(error.Reported, run(io, gpa, "127.0.0.1", port, "0123456789ABCDEF0123456789ABCDEF", "http://127.0.0.1/desktop.m3u8", "missing-playlist"));
    try std.testing.expect(saw_url.load(.acquire));
    try std.testing.expect(saw_stop.load(.acquire));
    try std.testing.expect(std.mem.indexOf(u8, report.get(), "This Fire TV's player refused the video.") != null);
    try std.testing.expect(std.mem.indexOf(u8, report.get(), sentence) != null);
    report.clear();
}
