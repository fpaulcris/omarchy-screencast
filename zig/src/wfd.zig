//! Miracast over the local network. Wi-Fi Direct sinks do not appear in discovery.
//! The picture is the desktop MPEG-TS, in RTP payload type 33.
const std = @import("std");
const report = @import("report.zig");
const sys = @import("sys.zig");
const wire = @import("wire.zig");

const linux = std.os.linux;

const source_id = [16]u8{ 'o', 'm', 'a', 'r', 'c', 'h', 'y', '-', 's', 'c', 'r', 'e', 'e', 'n', '0', '1' };

pub const Choice = struct {
    profile: u8,
    level: u8,
    cea: u32,
    width: u16,
    height: u16,
};

pub const Pick = union(enum) {
    ok: Choice,
    baseline,
    no_mode,
};

pub fn chooseFormat(text: []const u8) Pick {
    const line = param(text, "wfd_video_formats") orelse text;
    const trimmed = std.mem.trim(u8, line, " \r\n\t");
    if (trimmed.len == 0) {
        return .{ .ok = .{ .profile = 0x02, .level = 0x01, .cea = 1 << 5, .width = 1280, .height = 720 } };
    }
    var it = std.mem.tokenizeScalar(u8, trimmed, ' ');
    _ = it.next();
    _ = it.next();
    const profile = parseHex(u8, it.next() orelse return .no_mode) orelse return .no_mode;
    const level = parseHex(u8, it.next() orelse return .no_mode) orelse return .no_mode;
    const cea = parseHex(u32, it.next() orelse return .no_mode) orelse return .no_mode;
    // The desktop stream is H.264 High. Constrained Baseline sinks cannot decode it.
    if ((profile & 0x02) == 0) return .baseline;
    // The cast files are 1280x720. Offering 1080p would send a smaller picture than the sink expects.
    if ((cea & (1 << 5)) != 0 and levelOk(level, 0)) {
        return .{ .ok = .{ .profile = 0x02, .level = chosenLevel(level, 0), .cea = 1 << 5, .width = 1280, .height = 720 } };
    }
    return .no_mode;
}

pub fn aacOk(text: []const u8) bool {
    const line = param(text, "wfd_audio_codecs") orelse text;
    const trimmed = std.mem.trim(u8, line, " \r\n\t");
    if (trimmed.len == 0) return true;
    const at = std.mem.indexOf(u8, trimmed, "AAC") orelse return false;
    const rest = std.mem.trim(u8, trimmed[at + 3 ..], " ");
    if (rest.len == 0) return true;
    const end = std.mem.indexOfAny(u8, rest, " ,\r") orelse rest.len;
    if (end == 0) return true;
    const mode = std.fmt.parseInt(u32, rest[0..end], 16) catch return true;
    return (mode & 1) != 0;
}

fn levelOk(level: u8, min_bit: u3) bool {
    if (level == 0) return true;
    var bit: u4 = min_bit;
    while (bit < 5) : (bit += 1) {
        if ((level & (@as(u8, 1) << @intCast(bit))) != 0) return true;
    }
    return false;
}

fn chosenLevel(level: u8, min_bit: u3) u8 {
    if (level == 0) return @as(u8, 1) << min_bit;
    var bit: u4 = min_bit;
    while (bit < 5) : (bit += 1) {
        const mask: u8 = @as(u8, 1) << @intCast(bit);
        if ((level & mask) != 0) return mask;
    }
    return @as(u8, 1) << min_bit;
}

fn parseHex(comptime T: type, text: []const u8) ?T {
    return std.fmt.parseInt(T, text, 16) catch null;
}

pub fn param(text: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r\t");
        if (line.len < name.len + 1) continue;
        if (!std.mem.eql(u8, line[0..name.len], name)) continue;
        if (line[name.len] != ':') continue;
        return std.mem.trim(u8, line[name.len + 1 ..], " \t");
    }
    return null;
}

/// UTF-16LE for the friendly name. Windows and TV stacks read the name that way.
/// Size, TLV length, and the RTSP port stay big-endian, as MS-MICE specifies.
pub fn sourceReady(out: []u8, name: []const u8, port: u16) usize {
    return mice(out, 0x01, name, port, true);
}

pub fn stopProjection(out: []u8) usize {
    return mice(out, 0x02, "", 0, false);
}

fn mice(out: []u8, command: u8, name: []const u8, port: u16, with_name: bool) usize {
    var n: usize = 4;
    if (with_name) {
        const chars = @min(name.len, 40);
        if (n + 3 + chars * 2 + 5 + 19 > out.len) return 0;
        out[n] = 0x00;
        std.mem.writeInt(u16, out[n + 1 ..][0..2], @intCast(chars * 2), .big);
        n += 3;
        for (name[0..chars]) |byte| {
            out[n] = if (byte < 128) byte else '?';
            out[n + 1] = 0;
            n += 2;
        }
    }
    if (n + 5 + 19 > out.len) return 0;
    out[n] = 0x02;
    std.mem.writeInt(u16, out[n + 1 ..][0..2], 2, .big);
    std.mem.writeInt(u16, out[n + 3 ..][0..2], port, .big);
    n += 5;
    out[n] = 0x03;
    std.mem.writeInt(u16, out[n + 1 ..][0..2], 16, .big);
    @memcpy(out[n + 3 ..][0..16], &source_id);
    n += 19;
    std.mem.writeInt(u16, out[0..2], @intCast(n), .big);
    out[2] = 0x01;
    out[3] = command;
    return n;
}

const Continuity = struct {
    pid: [8]u16 = @splat(0xFFFF),
    next: [8]u4 = @splat(0),
    last: [8]u4 = @splat(0),
    seen: [8]bool = @splat(false),

    fn apply(self: *Continuity, pkt: *[188]u8) void {
        if (pkt[0] != 0x47) return;
        const pid: u16 = (@as(u16, pkt[1] & 0x1f) << 8) | pkt[2];
        const payload = ((pkt[3] >> 4) & 0x1) != 0;
        var slot: usize = 0;
        while (slot < 8) : (slot += 1) {
            if (!self.seen[slot] or self.pid[slot] == pid) break;
        }
        if (slot == 8) slot = 0;
        if (!self.seen[slot] or self.pid[slot] != pid) {
            self.seen[slot] = true;
            self.pid[slot] = pid;
            self.next[slot] = 0;
            self.last[slot] = 0;
        }
        if (payload) {
            pkt[3] = (pkt[3] & 0xF0) | self.next[slot];
            self.last[slot] = self.next[slot];
            self.next[slot] +%= 1;
        } else pkt[3] = (pkt[3] & 0xF0) | self.last[slot];
    }
};

pub fn writeRtp(out: []u8, seq: u16, timestamp: u32, ssrc: u32, marker: bool, parts: []const []const u8) usize {
    if (out.len < 12) return 0;
    out[0] = 0x80;
    out[1] = 33;
    if (marker) out[1] |= 0x80;
    std.mem.writeInt(u16, out[2..4], seq, .big);
    std.mem.writeInt(u32, out[4..8], timestamp, .big);
    std.mem.writeInt(u32, out[8..12], ssrc, .big);
    var n: usize = 12;
    for (parts) |part| {
        if (n + part.len > out.len) return 0;
        @memcpy(out[n..][0..part.len], part);
        n += part.len;
    }
    return n;
}

fn videoStart(pkt: []const u8) bool {
    if (pkt.len < 3 or pkt[0] != 0x47) return false;
    const pid: u16 = (@as(u16, pkt[1] & 0x1f) << 8) | pkt[2];
    return pid == 0x101 and (pkt[1] & 0x40) != 0;
}

const Message = struct {
    head: []u8,
    body: []u8,

    fn deinit(self: Message, gpa: std.mem.Allocator) void {
        gpa.free(self.head);
        gpa.free(self.body);
    }
};

const Take = union(enum) {
    msg: Message,
    closed,
    timeout,
};

const Sock = struct {
    fd: i32,
    gpa: std.mem.Allocator,
    inbox: std.ArrayList(u8) = .empty,
    pos: usize = 0,
    dead: bool = false,
    pending: ?Message = null,

    fn deinit(self: *Sock) void {
        if (self.pending) |msg| msg.deinit(self.gpa);
        self.inbox.deinit(self.gpa);
        wire.close(self.fd);
        self.fd = -1;
    }

    fn rest(self: *Sock) []u8 {
        return self.inbox.items[self.pos..];
    }

    fn consume(self: *Sock, n: usize) void {
        self.pos += n;
        if (self.pos >= self.inbox.items.len) {
            self.inbox.clearRetainingCapacity();
            self.pos = 0;
        }
    }

    fn send(self: *Sock, data: []const u8) bool {
        if (self.fd < 0) return false;
        return wire.writeAll(self.fd, data);
    }

    fn pull(self: *Sock, timeout_ms: i32) bool {
        if (self.dead or self.fd < 0) return false;
        if (!wire.pollIn(self.fd, timeout_ms)) return false;
        var tmp: [4096]u8 = undefined;
        const got = wire.readSome(self.fd, &tmp) orelse {
            self.dead = true;
            return false;
        };
        self.inbox.appendSlice(self.gpa, got) catch {
            self.dead = true;
            return false;
        };
        return true;
    }

    fn take(self: *Sock, io: std.Io, deadline: i64) Take {
        if (self.pending) |msg| {
            self.pending = null;
            return .{ .msg = msg };
        }
        while (std.mem.indexOf(u8, self.rest(), "\r\n\r\n") == null) {
            if (self.dead) return .closed;
            if (sys.monoMs(io) >= deadline) return .timeout;
            const left: i32 = @intCast(@max(deadline - sys.monoMs(io), 1));
            if (!self.pull(@min(left, 400))) {
                if (self.dead) return .closed;
                if (sys.monoMs(io) >= deadline) return .timeout;
            }
        }
        const split = std.mem.indexOf(u8, self.rest(), "\r\n\r\n").?;
        const need = contentLen(self.rest()[0..split]);
        if (need > 64 * 1024) return .closed;
        const total = split + 4 + need;
        while (self.rest().len < total) {
            if (self.dead) return .closed;
            if (sys.monoMs(io) >= deadline) return .timeout;
            const left: i32 = @intCast(@max(deadline - sys.monoMs(io), 1));
            if (!self.pull(@min(left, 400))) {
                if (self.dead) return .closed;
                if (sys.monoMs(io) >= deadline) return .timeout;
            }
        }
        const raw = self.rest()[0..total];
        const head = self.gpa.dupe(u8, raw[0..split]) catch return .closed;
        const body = self.gpa.dupe(u8, raw[split + 4 ..]) catch {
            self.gpa.free(head);
            return .closed;
        };
        self.consume(total);
        return .{ .msg = .{ .head = head, .body = body } };
    }
};

fn contentLen(head: []const u8) usize {
    const raw = header(head, "Content-Length") orelse return 0;
    return std.fmt.parseInt(usize, raw, 10) catch 0;
}

fn header(head: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, head, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r");
        if (line.len < name.len + 1) continue;
        if (!std.ascii.eqlIgnoreCase(line[0..name.len], name)) continue;
        if (line[name.len] != ':') continue;
        return std.mem.trim(u8, line[name.len + 1 ..], " \t");
    }
    return null;
}

fn firstLine(head: []const u8) []const u8 {
    const n = std.mem.indexOf(u8, head, "\r\n") orelse head.len;
    return head[0..n];
}

fn methodOf(head: []const u8) []const u8 {
    const line = firstLine(head);
    const sp = std.mem.indexOfScalar(u8, line, ' ') orelse return line;
    return line[0..sp];
}

fn isResponse(head: []const u8) bool {
    return std.mem.startsWith(u8, head, "RTSP/");
}

fn ok200(head: []const u8) bool {
    const line = firstLine(head);
    return std.mem.indexOf(u8, line, " 200") != null;
}

fn cseqOf(head: []const u8) u32 {
    const raw = header(head, "CSeq") orelse return 0;
    return std.fmt.parseInt(u32, raw, 10) catch 0;
}

fn clientPort(head: []const u8) ?u16 {
    const transport = header(head, "Transport") orelse return null;
    const key = "client_port=";
    const at = std.mem.indexOf(u8, transport, key) orelse return null;
    const rest = transport[at + key.len ..];
    const end = std.mem.indexOfAny(u8, rest, "-;, \t") orelse rest.len;
    if (end == 0) return null;
    return std.fmt.parseInt(u16, rest[0..end], 10) catch null;
}

const Link = struct {
    sock: Sock,
    mice: i32 = -1,
    listen: i32 = -1,
    udp: i32 = -1,
    cseq: u32 = 1,
    client_port: u16 = 0,
    ssrc: u32 = 0x7363726e,
    seq: u16 = 1,
    cc: Continuity = .{},

    fn deinit(self: *Link) void {
        self.sock.deinit();
        wire.close(self.mice);
        wire.close(self.listen);
        wire.close(self.udp);
        self.mice = -1;
        self.listen = -1;
        self.udp = -1;
    }
};

fn fillRequest(buf: []u8, verb: []const u8, url: []const u8, cseq: u32, body: []const u8) ![]const u8 {
    if (body.len == 0) {
        return std.fmt.bufPrint(buf, "{s} {s} RTSP/1.0\r\nCSeq: {d}\r\nUser-Agent: omarchy-screencast\r\n\r\n", .{ verb, url, cseq });
    }
    return std.fmt.bufPrint(buf, "{s} {s} RTSP/1.0\r\nCSeq: {d}\r\nContent-Type: text/parameters\r\nContent-Length: {d}\r\nUser-Agent: omarchy-screencast\r\n\r\n{s}", .{ verb, url, cseq, body.len, body });
}

fn replyText(fd: i32, cseq: u32, extra: []const u8, body: []const u8) bool {
    var buf: [1024]u8 = undefined;
    const text = if (body.len == 0)
        std.fmt.bufPrint(&buf, "RTSP/1.0 200 OK\r\nCSeq: {d}\r\n{s}\r\n", .{ cseq, extra }) catch return false
    else
        std.fmt.bufPrint(&buf, "RTSP/1.0 200 OK\r\nCSeq: {d}\r\nContent-Type: text/parameters\r\nContent-Length: {d}\r\n{s}\r\n{s}", .{ cseq, body.len, extra, body }) catch return false;
    return wire.writeAll(fd, text);
}

fn replySimple(sock: *Sock, head: []const u8) bool {
    const verb = methodOf(head);
    if (std.mem.eql(u8, verb, "OPTIONS")) {
        return replyText(sock.fd, cseqOf(head), "Public: org.wfa.wfd1.0, SETUP, TEARDOWN, PLAY, PAUSE, GET_PARAMETER, SET_PARAMETER\r\n", "");
    }
    return replyText(sock.fd, cseqOf(head), "Content-Length: 0\r\n", "");
}

fn expectOk(link: *Link, io: std.Io, deadline: i64) ![]u8 {
    while (true) {
        switch (link.sock.take(io, deadline)) {
            .timeout => return error.Timeout,
            .closed => return error.Closed,
            .msg => |msg| {
                if (isResponse(msg.head)) {
                    defer link.sock.gpa.free(msg.head);
                    if (!ok200(msg.head)) {
                        link.sock.gpa.free(msg.body);
                        return error.Refused;
                    }
                    return msg.body;
                }
                if (std.mem.eql(u8, methodOf(msg.head), "SETUP")) {
                    link.sock.pending = msg;
                    return link.sock.gpa.dupe(u8, "") catch return error.Closed;
                }
                if (std.mem.eql(u8, methodOf(msg.head), "TEARDOWN")) {
                    _ = replySimple(&link.sock, msg.head);
                    msg.deinit(link.sock.gpa);
                    return error.Closed;
                }
                const wrote = replySimple(&link.sock, msg.head);
                msg.deinit(link.sock.gpa);
                if (!wrote) return error.Closed;
            },
        }
    }
}

fn drain(link: *Link, io: std.Io, ms: i64) !void {
    const deadline = sys.monoMs(io) + ms;
    while (sys.monoMs(io) < deadline) {
        switch (link.sock.take(io, deadline)) {
            .timeout => return,
            .closed => return error.Closed,
            .msg => |msg| {
                if (isResponse(msg.head)) {
                    msg.deinit(link.sock.gpa);
                    continue;
                }
                if (std.mem.eql(u8, methodOf(msg.head), "SETUP")) {
                    link.sock.pending = msg;
                    return;
                }
                const wrote = replySimple(&link.sock, msg.head);
                msg.deinit(link.sock.gpa);
                if (!wrote) return error.Closed;
            },
        }
    }
}

fn sendStep(link: *Link, io: std.Io, verb: []const u8, url: []const u8, body: []const u8) ![]u8 {
    var buf: [1200]u8 = undefined;
    const text = try fillRequest(&buf, verb, url, link.cseq, body);
    link.cseq += 1;
    if (!link.sock.send(text)) return error.Closed;
    const deadline = sys.monoMs(io) + 8000;
    return expectOk(link, io, deadline);
}

fn acceptSetup(link: *Link, io: std.Io, lan_ip: []const u8, listen_port: u16) !void {
    const deadline = sys.monoMs(io) + 8000;
    var extra: ?Sock = null;
    defer if (extra) |*sock| sock.deinit();
    var active = false;
    while (sys.monoMs(io) < deadline) {
        if (link.sock.pending != null or link.sock.rest().len > 0) {
            if (try takeSetup(link, &link.sock, io, deadline, lan_ip, listen_port)) return;
        }
        const left: i32 = @intCast(@max(deadline - sys.monoMs(io), 1));
        if (link.listen >= 0 and wire.pollIn(link.listen, @min(left, 200))) {
            var sa = linux.sockaddr.in{ .port = 0, .addr = 0 };
            var slen: linux.socklen_t = @sizeOf(linux.sockaddr.in);
            const accepted = linux.accept4(link.listen, @ptrCast(&sa), &slen, linux.SOCK.CLOEXEC);
            if (linux.errno(accepted) == .SUCCESS) {
                if (extra) |*old| old.deinit();
                extra = .{ .fd = @intCast(accepted), .gpa = link.sock.gpa };
                active = true;
            }
        }
        if (active) {
            if (extra) |*sock| {
                if (try takeSetup(link, sock, io, deadline, lan_ip, listen_port)) {
                    link.sock.deinit();
                    link.sock = sock.*;
                    extra = null;
                    return;
                }
            }
        } else if (link.sock.fd >= 0 and wire.pollIn(link.sock.fd, @min(left, 200))) {
            _ = link.sock.pull(0);
        }
    }
    return error.Timeout;
}

fn takeSetup(link: *Link, sock: *Sock, io: std.Io, deadline: i64, lan_ip: []const u8, listen_port: u16) !bool {
    _ = lan_ip;
    _ = listen_port;
    switch (sock.take(io, @min(deadline, sys.monoMs(io) + 300))) {
        .timeout, .closed => return false,
        .msg => |msg| {
            defer msg.deinit(sock.gpa);
            if (!std.mem.eql(u8, methodOf(msg.head), "SETUP")) {
                if (!isResponse(msg.head)) _ = replySimple(sock, msg.head);
                return false;
            }
            const port = clientPort(msg.head) orelse return error.Refused;
            link.client_port = port;
            if (link.udp < 0) return error.Closed;
            const local = wire.udpPort(link.udp) orelse return error.Closed;
            var extra_buf: [160]u8 = undefined;
            const extra = std.fmt.bufPrint(&extra_buf, "Session: 1;timeout=30\r\nTransport: RTP/AVP/UDP;unicast;client_port={d}-{d};server_port={d}-{d}\r\n", .{
                port, port + 1, local, local + 1,
            }) catch return error.Closed;
            if (!replyText(sock.fd, cseqOf(msg.head), extra, "")) return error.Closed;
            return true;
        },
    }
}

fn connectSock(gpa: std.mem.Allocator, host: []const u8, port: u16) ?Sock {
    const fd = wire.openTcp(host, port, 3000) orelse return null;
    return .{ .fd = fd, .gpa = gpa };
}

fn handshake(io: std.Io, gpa: std.mem.Allocator, address: []const u8, port: u16, lan_ip: []const u8) !Link {
    const listener = wire.listenTcp(0) orelse return error.Connect;
    var link = Link{ .sock = .{ .fd = -1, .gpa = gpa }, .listen = listener.fd };
    errdefer link.deinit();
    const bytes = wire.parse4(address) orelse return error.Connect;
    if (port == 7250) {
        if (wire.openTcp(address, 7250, 3000)) |mice_fd| {
            link.mice = mice_fd;
            var ready_buf: [256]u8 = undefined;
            const n = sourceReady(&ready_buf, "Omarchy", listener.port);
            if (n == 0 or !wire.writeAll(mice_fd, ready_buf[0..n])) return error.Closed;
            const deadline = sys.monoMs(io) + 8000;
            while (sys.monoMs(io) < deadline) {
                const left: i32 = @intCast(@max(deadline - sys.monoMs(io), 1));
                if (!wire.pollIn(listener.fd, @min(left, 500))) continue;
                var sa = linux.sockaddr.in{ .port = 0, .addr = 0 };
                var slen: linux.socklen_t = @sizeOf(linux.sockaddr.in);
                const accepted = linux.accept4(listener.fd, @ptrCast(&sa), &slen, linux.SOCK.CLOEXEC);
                if (linux.errno(accepted) != .SUCCESS) continue;
                link.sock = .{ .fd = @intCast(accepted), .gpa = gpa };
                break;
            }
            if (link.sock.fd < 0) return error.Timeout;
        } else {
            link.sock = connectSock(gpa, address, 7236) orelse return error.Connect;
        }
    } else {
        link.sock = connectSock(gpa, address, port) orelse return error.Connect;
    }
    var req: [1200]u8 = undefined;
    const m1 = try fillRequest(&req, "OPTIONS", "*", link.cseq, "");
    link.cseq += 1;
    if (!link.sock.send(m1)) return error.Closed;
    const m1_body = try expectOk(&link, io, sys.monoMs(io) + 8000);
    gpa.free(m1_body);
    try drain(&link, io, 400);

    const m3_body = "wfd_video_formats\r\nwfd_audio_codecs\r\nwfd_client_rtp_ports\r\n";
    const caps = try sendStep(&link, io, "GET_PARAMETER", "rtsp://localhost/wfd1.0", m3_body);
    defer gpa.free(caps);
    const pick = chooseFormat(caps);
    const choice = switch (pick) {
        .ok => |item| item,
        .baseline => return error.Baseline,
        .no_mode => return error.NoMode,
    };
    if (!aacOk(caps)) return error.NoAac;
    const rtp_line = param(caps, "wfd_client_rtp_ports") orelse "RTP/AVP/UDP;unicast 19000 0 mode=play";
    var m4_buf: [640]u8 = undefined;
    const m4 = std.fmt.bufPrint(&m4_buf, "wfd_video_formats: 00 00 {x:0>2} {x:0>2} {x:0>8} 00000000 00000000 00 0000 0000 00 none none\r\nwfd_audio_codecs: AAC 00000001 00\r\nwfd_presentation_URL: rtsp://{s}:{d}/wfd1.0/streamid=0 none\r\nwfd_client_rtp_ports: {s}\r\n", .{
        choice.profile, choice.level, choice.cea, lan_ip, listener.port, rtp_line,
    }) catch return error.Closed;
    const m4_reply = try sendStep(&link, io, "SET_PARAMETER", "rtsp://localhost/wfd1.0", m4);
    gpa.free(m4_reply);
    const m5 = try sendStep(&link, io, "SET_PARAMETER", "rtsp://localhost/wfd1.0", "wfd_trigger_method: SETUP\r\n");
    gpa.free(m5);
    // Bind UDP to an ephemeral port. The destination is set after SETUP.
    const opened = linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(opened) != .SUCCESS) return error.Connect;
    link.udp = @intCast(opened);
    var local = wire.sock4(.{ 0, 0, 0, 0 }, 0);
    if (linux.errno(linux.bind(link.udp, @ptrCast(&local), @sizeOf(linux.sockaddr.in))) != .SUCCESS) return error.Connect;
    try acceptSetup(&link, io, lan_ip, listener.port);
    var remote = wire.sock4(bytes, link.client_port);
    if (linux.errno(linux.connect(link.udp, &remote, @sizeOf(linux.sockaddr.in))) != .SUCCESS) return error.Connect;
    var play_url: [128]u8 = undefined;
    const url = std.fmt.bufPrint(&play_url, "rtsp://{s}:{d}/wfd1.0/streamid=0", .{ lan_ip, listener.port }) catch return error.Closed;
    var play_buf: [256]u8 = undefined;
    const play = std.fmt.bufPrint(&play_buf, "PLAY {s} RTSP/1.0\r\nCSeq: {d}\r\nSession: 1\r\nUser-Agent: omarchy-screencast\r\nRange: npt=now-\r\n\r\n", .{ url, link.cseq }) catch return error.Closed;
    link.cseq += 1;
    if (!link.sock.send(play)) return error.Closed;
    const played = try expectOk(&link, io, sys.monoMs(io) + 8000);
    gpa.free(played);
    wire.close(link.listen);
    link.listen = -1;
    return link;
}

fn sendTs(link: *Link, data: []const u8, dur_ms: i64, io: std.Io, t0: i64, media_ms: *i64) !void {
    var off: usize = 0;
    if (data.len >= 188 and data[0] != 0x47) {
        while (off + 188 <= data.len and data[off] != 0x47) off += 1;
    }
    var count: usize = 0;
    var scan = off;
    while (scan + 188 <= data.len) : (scan += 188) count += 1;
    if (count == 0) return;
    const groups = (count + 6) / 7;
    const slice: i64 = @max(@divTrunc(dur_ms, @as(i64, @intCast(groups))), 1);
    while (off + 188 <= data.len) {
        if (report.stopped()) return error.Stopped;
        var parts: [7][]const u8 = undefined;
        var raw: [7][188]u8 = undefined;
        var k: usize = 0;
        var marker = false;
        while (k < 7 and off + 188 <= data.len) : (k += 1) {
            @memcpy(&raw[k], data[off..][0..188]);
            off += 188;
            if (videoStart(&raw[k])) marker = true;
            link.cc.apply(&raw[k]);
            parts[k] = &raw[k];
        }
        var pkt: [12 + 188 * 7]u8 = undefined;
        const ts: u32 = @intCast(@as(u64, @intCast(@max(media_ms.*, 0))) * 90);
        const n = writeRtp(&pkt, link.seq, ts, link.ssrc, marker, parts[0..k]);
        link.seq +%= 1;
        if (n == 0 or !wire.writeAll(link.udp, pkt[0..n])) return error.Closed;
        media_ms.* += slice;
        const ahead = media_ms.* - (sys.monoMs(io) - t0);
        if (ahead > 2) sys.sleepMs(io, ahead);
        if (link.sock.fd >= 0 and (wire.pollIn(link.sock.fd, 0) or link.sock.rest().len > 0)) {
            switch (link.sock.take(io, sys.monoMs(io) + 50)) {
                .timeout, .closed => if (link.sock.dead) return error.Closed,
                .msg => |msg| {
                    defer msg.deinit(link.sock.gpa);
                    if (std.mem.eql(u8, methodOf(msg.head), "TEARDOWN")) {
                        _ = replySimple(&link.sock, msg.head);
                        return error.Stopped;
                    }
                    if (!isResponse(msg.head)) _ = replySimple(&link.sock, msg.head);
                },
            }
        }
    }
}

fn segList(text: []const u8, out: *[40]u32, durs: *[40]i64) usize {
    var n: usize = 0;
    var pending: i64 = 400;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r");
        if (std.mem.startsWith(u8, line, "#EXTINF:")) {
            const rest = line["#EXTINF:".len..];
            const end = std.mem.indexOfScalar(u8, rest, ',') orelse rest.len;
            const sec = std.fmt.parseFloat(f64, rest[0..end]) catch 0.4;
            pending = @intFromFloat(@max(sec * 1000.0, 1));
        } else if (std.mem.startsWith(u8, line, "seg_") and std.mem.endsWith(u8, line, ".ts")) {
            const num = line[4 .. line.len - 3];
            const index = std.fmt.parseInt(u32, num, 10) catch continue;
            if (n < out.len) {
                out[n] = index;
                durs[n] = pending;
                n += 1;
            }
        }
    }
    return n;
}

fn failKind(io: std.Io, err: anyerror) error{Reported} {
    return switch (err) {
        error.Baseline => report.fail(io, "This Miracast receiver only accepts H.264 Baseline, and this desktop is H.264 High."),
        error.NoMode => report.fail(io, "This Miracast receiver has no 1280x720 mode for this desktop."),
        error.NoAac => report.fail(io, "This Miracast receiver has no AAC sound mode for this desktop."),
        error.Refused => report.fail(io, "This Miracast receiver refused the picture format."),
        error.Connect => report.fail(io, "This Miracast receiver did not accept the connection."),
        error.Timeout => report.fail(io, "This Miracast receiver did not finish the connection."),
        error.Closed => report.fail(io, "This Miracast receiver closed the connection."),
        error.Reported => error.Reported,
        else => report.fail(io, "This Miracast receiver closed the connection."),
    };
}

pub fn run(io: std.Io, gpa: std.mem.Allocator, address: []const u8, port: u16, lan_ip: []const u8, hls_dir: []const u8, playlist: []const u8) !void {
    var link = handshake(io, gpa, address, port, lan_ip) catch |err| return failKind(io, err);
    defer {
        var bye: [256]u8 = undefined;
        if (link.sock.fd >= 0) {
            if (fillRequest(&bye, "TEARDOWN", "rtsp://localhost/wfd1.0/streamid=0", link.cseq, "")) |text| {
                _ = link.sock.send(text);
            } else |_| {}
        }
        if (link.mice >= 0) {
            var stop_buf: [64]u8 = undefined;
            const n = stopProjection(&stop_buf);
            if (n > 0) _ = wire.writeAll(link.mice, stop_buf[0..n]);
        }
        link.deinit();
    }
    report.log(io, "miracast playing");
    report.publish("live", "Mirroring.", @intCast(linux.getpid()));
    var next: i64 = -1;
    var mark = sys.monoMs(io);
    const t0 = sys.monoMs(io);
    var media_ms: i64 = 0;
    while (!report.stopped()) {
        if (report.stalled(io, playlist, &mark)) return report.fail(io, "The desktop stream stopped.");
        const text = sys.readAll(io, gpa, playlist, 64 * 1024) orelse {
            sys.sleepMs(io, 40);
            continue;
        };
        defer gpa.free(text);
        var ids: [40]u32 = undefined;
        var durs: [40]i64 = undefined;
        const n = segList(text, &ids, &durs);
        if (n == 0) {
            sys.sleepMs(io, 40);
            continue;
        }
        if (next < 0) next = if (n >= 3) ids[n - 3] else ids[0];
        if (next < ids[0]) next = ids[0];
        var sent = false;
        for (ids[0..n], durs[0..n]) |index, dur| {
            if (index < next) continue;
            const path = std.fmt.allocPrint(gpa, "{s}/seg_{d:0>5}.ts", .{ hls_dir, index }) catch continue;
            defer gpa.free(path);
            const file = sys.readAll(io, gpa, path, 8 * 1024 * 1024) orelse {
                next = index + 1;
                continue;
            };
            defer gpa.free(file);
            sendTs(&link, file, dur, io, t0, &media_ms) catch |err| switch (err) {
                error.Stopped => {
                    report.publish("stopped", "Stopped.", 0);
                    return;
                },
                else => return failKind(io, err),
            };
            next = index + 1;
            sent = true;
            if (report.stopped()) break;
        }
        if (!sent) sys.sleepMs(io, 30);
    }
    report.publish("stopped", "Stopped.", 0);
}

test "miracast format, rtp, and source ready" {
    const sample = "wfd_video_formats: 40 00 03 07 000000a0 00000000 00000000 00 0000 0000 00 none none\r\nwfd_audio_codecs: LPCM 00000003 00, AAC 00000001 00\r\n";
    const pick = chooseFormat(sample);
    try std.testing.expect(pick == .ok);
    try std.testing.expectEqual(@as(u16, 1280), pick.ok.width);
    try std.testing.expectEqual(@as(u8, 0x02), pick.ok.profile);
    try std.testing.expectEqual(@as(u8, 0x01), pick.ok.level);
    try std.testing.expectEqual(@as(u32, 1 << 5), pick.ok.cea);
    try std.testing.expect(aacOk(sample));
    try std.testing.expectEqual(Pick.baseline, chooseFormat("00 00 01 01 00000020 00000000 00000000 00 0000 0000 00 none none"));
    try std.testing.expectEqual(Pick.no_mode, chooseFormat("00 00 02 01 00000001 00000000 00000000 00 0000 0000 00 none none"));
    try std.testing.expectEqual(Pick.no_mode, chooseFormat("00 00 02 1f 00000080 00000000 00000000 00 0000 0000 00 none none"));
    var cc = Continuity{};
    var first: [188]u8 = @splat(0x47);
    first[1] = 0x41;
    first[2] = 0x01;
    first[3] = 0x10;
    var second = first;
    second[3] = 0x10;
    cc.apply(&first);
    cc.apply(&second);
    try std.testing.expectEqual(@as(u8, 0), first[3] & 0xf);
    try std.testing.expectEqual(@as(u8, 1), second[3] & 0xf);
    var reset = first;
    reset[3] = 0x10;
    cc.apply(&reset);
    try std.testing.expectEqual(@as(u8, 2), reset[3] & 0xf);
    var rtp: [12 + 188]u8 = undefined;
    const pn = writeRtp(&rtp, 7, 90000, 1, true, &.{&first});
    try std.testing.expectEqual(@as(usize, 12 + 188), pn);
    try std.testing.expectEqual(@as(u8, 0x80), rtp[0]);
    try std.testing.expectEqual(@as(u8, 33 | 0x80), rtp[1]);
    var mice_buf: [128]u8 = undefined;
    const mn = sourceReady(&mice_buf, "Omarchy", 7236);
    try std.testing.expect(mn > 8);
    try std.testing.expectEqual(@as(u16, @intCast(mn)), std.mem.readInt(u16, mice_buf[0..2], .big));
    try std.testing.expectEqual(@as(u8, 0x01), mice_buf[3]);
    try std.testing.expect(std.mem.indexOf(u8, mice_buf[0..mn], &[_]u8{ 0x1c, 0x44 }) != null);
}

test "miracast handshake delivers one rtp packet" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var sink_port: u16 = 0;
    var ready = std.atomic.Value(bool).init(false);
    var rtp_ok = std.atomic.Value(bool).init(false);
    const thread = try std.Thread.spawn(.{}, fakeSink, .{ &sink_port, &ready, &rtp_ok });
    var spins: usize = 0;
    while (!ready.load(.acquire) and spins < 50) : (spins += 1) sys.sleepMs(io, 20);
    try std.testing.expect(sink_port != 0);
    var link = handshake(io, gpa, "127.0.0.1", sink_port, "127.0.0.1") catch |err| {
        thread.join();
        return err;
    };
    defer link.deinit();
    var ts: [188]u8 = @splat(0x47);
    ts[1] = 0x40;
    ts[2] = 0x00;
    var media: i64 = 0;
    try sendTs(&link, &ts, 20, io, sys.monoMs(io), &media);
    thread.join();
    try std.testing.expect(rtp_ok.load(.acquire));
}

fn fakeSink(out_port: *u16, flag: *std.atomic.Value(bool), rtp_ok: *std.atomic.Value(bool)) void {
    const listener = wire.listenTcp(0) orelse return;
    defer wire.close(listener.fd);
    const udp_fd = linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(udp_fd) != .SUCCESS) return;
    const udp: i32 = @intCast(udp_fd);
    defer wire.close(udp);
    var local = wire.sock4(.{ 0, 0, 0, 0 }, 0);
    if (linux.errno(linux.bind(udp, @ptrCast(&local), @sizeOf(linux.sockaddr.in))) != .SUCCESS) return;
    const udp_port = wire.udpPort(udp) orelse return;
    out_port.* = listener.port;
    flag.store(true, .release);
    if (!wire.pollIn(listener.fd, 3000)) return;
    var sa = linux.sockaddr.in{ .port = 0, .addr = 0 };
    var slen: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    const accepted = linux.accept4(listener.fd, @ptrCast(&sa), &slen, linux.SOCK.CLOEXEC);
    if (linux.errno(accepted) != .SUCCESS) return;
    const fd: i32 = @intCast(accepted);
    defer wire.close(fd);
    var box: [8192]u8 = undefined;
    var len: usize = 0;
    var sent_m2 = false;
    var caps_buf: [384]u8 = undefined;
    const caps = std.fmt.bufPrint(&caps_buf, "wfd_video_formats: 00 00 03 01 00000020 00000000 00000000 00 0000 0000 00 none none\r\nwfd_audio_codecs: AAC 00000001 00\r\nwfd_client_rtp_ports: RTP/AVP/UDP;unicast {d} 0 mode=play\r\n", .{udp_port}) catch return;
    while (len < box.len) {
        if (std.mem.indexOf(u8, box[0..len], "\r\n\r\n") == null) {
            if (!wire.pollIn(fd, 3000)) return;
            const n = linux.read(fd, box[len..].ptr, box.len - len);
            if (linux.errno(n) != .SUCCESS or n == 0) return;
            len += n;
            continue;
        }
        const split = std.mem.indexOf(u8, box[0..len], "\r\n\r\n").?;
        const head = box[0..split];
        const need = contentLen(head);
        if (len < split + 4 + need) {
            if (!wire.pollIn(fd, 1000)) return;
            const n = linux.read(fd, box[len..].ptr, box.len - len);
            if (linux.errno(n) != .SUCCESS or n == 0) return;
            len += n;
            continue;
        }
        const total = split + 4 + need;
        const body = box[split + 4 .. total];
        const seq = cseqOf(head);
        if (std.mem.startsWith(u8, head, "OPTIONS")) {
            _ = replyText(fd, seq, "Public: org.wfa.wfd1.0, SETUP, TEARDOWN, PLAY, PAUSE, GET_PARAMETER, SET_PARAMETER\r\n", "");
            if (!sent_m2) {
                sent_m2 = true;
                _ = wire.writeAll(fd, "OPTIONS * RTSP/1.0\r\nCSeq: 1\r\nRequire: org.wfa.wfd1.0\r\n\r\n");
            }
        } else if (std.mem.startsWith(u8, head, "GET_PARAMETER")) {
            _ = replyText(fd, seq, "", caps);
        } else if (std.mem.startsWith(u8, head, "SET_PARAMETER")) {
            _ = replyText(fd, seq, "Content-Length: 0\r\n", "");
            if (std.mem.indexOf(u8, body, "wfd_trigger_method") != null) {
                var setup: [192]u8 = undefined;
                const text = std.fmt.bufPrint(&setup, "SETUP rtsp://127.0.0.1/wfd1.0/streamid=0 RTSP/1.0\r\nCSeq: 9\r\nTransport: RTP/AVP/UDP;unicast;client_port={d}-{d}\r\n\r\n", .{ udp_port, udp_port + 1 }) catch return;
                _ = wire.writeAll(fd, text);
            }
        } else if (std.mem.startsWith(u8, head, "PLAY")) {
            _ = replyText(fd, seq, "Session: 1\r\n", "");
            std.mem.copyForwards(u8, box[0 .. len - total], box[total..len]);
            len -= total;
            break;
        }
        std.mem.copyForwards(u8, box[0 .. len - total], box[total..len]);
        len -= total;
    }
    if (!wire.pollIn(udp, 3000)) return;
    var pkt: [1600]u8 = undefined;
    const n = linux.read(udp, &pkt, pkt.len);
    if (linux.errno(n) != .SUCCESS or n < 12 + 188) return;
    if (pkt[0] == 0x80 and (pkt[1] & 0x7f) == 33 and pkt[12] == 0x47) rtp_ok.store(true, .release);
    while (wire.pollIn(fd, 1000)) {
        var junk: [256]u8 = undefined;
        const got = linux.read(fd, &junk, junk.len);
        if (linux.errno(got) != .SUCCESS or got == 0) break;
    }
}
