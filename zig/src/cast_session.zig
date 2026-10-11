//! One thread owns the Cast TLS socket. A quiet second is not a dead receiver.
const std = @import("std");
const cast = @import("cast.zig");
const jsonx = @import("jsonx.zig");
const sys = @import("sys.zig");

const linux = std.os.linux;

const connect_payload = "{\"type\":\"CONNECT\",\"origin\":{},\"userAgent\":\"omarchy-screencast\",\"senderInfo\":{\"sdkType\":2,\"version\":\"15.0\",\"platform\":4,\"connectionType\":1}}";

pub const Session = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    stream: std.Io.net.Stream,
    net_read_buf: []u8,
    net_write_buf: []u8,
    tls_read_buf: []u8,
    tls_write_buf: []u8,
    net_reader: std.Io.net.Stream.Reader,
    net_writer: std.Io.net.Stream.Writer,
    tls: std.crypto.tls.Client,
    inbox: std.ArrayList(u8),
    outbox: std.ArrayList([]u8),
    request: u32 = 0,
    last_rx: i64 = 0,
    last_ping: i64 = 0,
    status_gen: u64 = 0,
    seen_status: u64 = 0,
    transport: [96]u8 = undefined,
    transport_len: usize = 0,
    session_id: [96]u8 = undefined,
    session_len: usize = 0,
    player: [32]u8 = undefined,
    player_len: usize = 0,
    media_bad: [300]u8 = undefined,
    media_bad_len: usize = 0,
    failure: [300]u8 = undefined,
    failure_len: usize = 0,
    closed: bool = false,

    pub fn open(gpa: std.mem.Allocator, io: std.Io, host: []const u8, port: u16) !*Session {
        const addr = std.Io.net.IpAddress.parse(host, port) catch return error.CastConnect;
        const stream = sys.connectStream(addr, 5000) orelse return error.CastConnect;
        errdefer stream.close(io);
        const min = std.crypto.tls.Client.min_buffer_len;
        const net_read = try gpa.alloc(u8, min);
        errdefer gpa.free(net_read);
        const net_write = try gpa.alloc(u8, min);
        errdefer gpa.free(net_write);
        const tls_read = try gpa.alloc(u8, min);
        errdefer gpa.free(tls_read);
        const tls_write = try gpa.alloc(u8, min);
        errdefer gpa.free(tls_write);
        const session = try gpa.create(Session);
        session.* = .{
            .io = io,
            .gpa = gpa,
            .stream = stream,
            .net_read_buf = net_read,
            .net_write_buf = net_write,
            .tls_read_buf = tls_read,
            .tls_write_buf = tls_write,
            .net_reader = stream.reader(io, net_read),
            .net_writer = stream.writer(io, net_write),
            .tls = undefined,
            .inbox = .empty,
            .outbox = .empty,
        };
        var entropy: [std.crypto.tls.Client.Options.entropy_len]u8 = undefined;
        try io.randomSecure(&entropy);
        session.tls = std.crypto.tls.Client.init(&session.net_reader.interface, &session.net_writer.interface, .{
            .host = .no_verification,
            .ca = .no_verification,
            .read_buffer = tls_read,
            .write_buffer = tls_write,
            .entropy = &entropy,
            .realtime_now = .now(io, .real),
        }) catch return error.CastTls;
        const tv = linux.timeval{ .sec = 1, .usec = 0 };
        _ = linux.setsockopt(stream.socket.handle, linux.SOL.SOCKET, linux.SO.RCVTIMEO, @ptrCast(&tv), @intCast(@sizeOf(linux.timeval)));
        session.last_rx = sys.monoMs(io);
        session.last_ping = session.last_rx;
        try session.queue(cast.connection, connect_payload, cast.receiver_id);
        try session.pump();
        return session;
    }

    pub fn close(self: *Session) void {
        if (self.closed) return;
        self.closed = true;
        self.stream.close(self.io);
        for (self.outbox.items) |item| self.gpa.free(item);
        self.outbox.deinit(self.gpa);
        self.inbox.deinit(self.gpa);
        self.gpa.free(self.net_read_buf);
        self.gpa.free(self.net_write_buf);
        self.gpa.free(self.tls_read_buf);
        self.gpa.free(self.tls_write_buf);
    }

    fn nextRequest(self: *Session) u32 {
        self.request += 1;
        return self.request;
    }

    fn setError(self: *Session, text: []const u8) void {
        const n = @min(text.len, self.failure.len);
        @memcpy(self.failure[0..n], text[0..n]);
        self.failure_len = n;
    }

    fn queue(self: *Session, namespace: []const u8, payload: []const u8, dest: []const u8) !void {
        const packet = try cast.encode(self.gpa, cast.source_id, dest, namespace, payload);
        try self.outbox.append(self.gpa, packet);
    }

    fn flush(self: *Session) !void {
        var i: usize = 0;
        while (i < self.outbox.items.len) : (i += 1) {
            self.tls.writer.writeAll(self.outbox.items[i]) catch return error.CastWrite;
        }
        // tls.writer.flush only encrypts into the socket buffer. The Cast
        // messages are a few hundred bytes, so they never fill that buffer
        // and the display never sees them unless the socket itself is flushed.
        self.tls.writer.flush() catch return error.CastWrite;
        self.net_writer.interface.flush() catch return error.CastWrite;
        for (self.outbox.items) |item| self.gpa.free(item);
        self.outbox.clearRetainingCapacity();
    }

    pub fn pump(self: *Session) !void {
        if (self.closed) return error.CastClosed;
        const now = sys.monoMs(self.io);
        if (now - self.last_ping >= 5000) {
            try self.queue(cast.heartbeat, "{\"type\":\"PING\"}", cast.receiver_id);
            self.last_ping = now;
        }
        try self.flush();
        // One stream() call often returns 0 after it has done real work: it
        // eats a TLS session ticket, or it decrypts the Cast frame into the
        // TLS buffer without copying it out. The bytes are then already out
        // of the kernel, so a later poll never wakes up and the display sits
        // on Connecting. Keep reading while either buffer gained bytes.
        var spins: u8 = 0;
        while (spins < 8) : (spins += 1) {
            const tls_before = self.tls.reader.bufferedLen();
            const net_before = self.net_reader.interface.bufferedLen();
            if (tls_before == 0 and net_before == 0 and !readable(self.stream.socket.handle, 200)) {
                if (sys.monoMs(self.io) - self.last_rx > 15000) {
                    self.setError("Cast receiver stopped answering");
                    return error.CastClosed;
                }
                return;
            }
            var buf: [8192]u8 = undefined;
            var writer: std.Io.Writer = .fixed(&buf);
            const n = self.tls.reader.stream(&writer, .limited(buf.len)) catch {
                if (self.tls.read_err) |err| self.setError(@errorName(err));
                if (self.failure_len == 0) self.setError("Cast receiver stopped answering");
                return error.CastRead;
            };
            if (n == 0) {
                if (self.tls.reader.bufferedLen() == tls_before and self.net_reader.interface.bufferedLen() == net_before) return;
                continue;
            }
            self.last_rx = sys.monoMs(self.io);
            try self.inbox.appendSlice(self.gpa, buf[0..n]);
            try self.drain();
        }
    }

    fn drain(self: *Session) !void {
        while (self.inbox.items.len >= 4) {
            const size = std.mem.readInt(u32, self.inbox.items[0..4], .big);
            if (size == 0 or size > 1_000_000) {
                self.setError("unexpected Cast frame");
                return error.CastClosed;
            }
            if (self.inbox.items.len < 4 + size) return;
            const body = self.inbox.items[4 .. 4 + size];
            const message = cast.decode(body);
            self.handle(message.namespace, message.payload);
            const rest = self.inbox.items.len - (4 + size);
            std.mem.copyForwards(u8, self.inbox.items[0..rest], self.inbox.items[4 + size ..]);
            self.inbox.shrinkRetainingCapacity(rest);
        }
    }

    fn handle(self: *Session, namespace: []const u8, payload: []const u8) void {
        var arena_state = std.heap.ArenaAllocator.init(self.gpa);
        defer arena_state.deinit();
        const root = jsonx.parse(arena_state.allocator(), payload) catch return;
        const kind = (root.get("type") orelse return).asString() orelse return;
        if (std.mem.eql(u8, namespace, cast.heartbeat) and std.mem.eql(u8, kind, "PING")) {
            self.queue(cast.heartbeat, "{\"type\":\"PONG\"}", cast.receiver_id) catch {};
            return;
        }
        if (std.mem.eql(u8, kind, "RECEIVER_STATUS")) {
            self.scanStatus(root);
            self.status_gen += 1;
            return;
        }
        if (std.mem.eql(u8, kind, "LOAD_FAILED") or std.mem.eql(u8, kind, "LOAD_CANCELLED") or std.mem.eql(u8, kind, "INVALID_REQUEST") or std.mem.eql(u8, kind, "ERROR")) {
            const n = @min(payload.len, self.media_bad.len);
            @memcpy(self.media_bad[0..n], payload[0..n]);
            self.media_bad_len = n;
            return;
        }
        if (!std.mem.eql(u8, kind, "MEDIA_STATUS")) return;
        const status = root.get("status") orelse return;
        const list = switch (status) {
            .array => |items| items,
            else => return,
        };
        for (list.items) |item| {
            const state_name = (item.get("playerState") orelse continue).asString() orelse continue;
            if (!std.mem.eql(u8, self.player[0..self.player_len], state_name)) {
                const n = @min(state_name.len, self.player.len);
                @memcpy(self.player[0..n], state_name[0..n]);
                self.player_len = n;
                var log_buf: [96]u8 = undefined;
                var log_w: std.Io.File.Writer = .init(.stderr(), self.io, &log_buf);
                log_w.interface.print("cast player {s}\n", .{self.player[0..self.player_len]}) catch {};
                log_w.interface.flush() catch {};
            }
            const idle = (item.get("idleReason") orelse continue).asString() orelse continue;
            if (std.mem.eql(u8, state_name, "IDLE") and (std.mem.eql(u8, idle, "ERROR") or std.mem.eql(u8, idle, "CANCELLED"))) {
                const bad = @min(payload.len, self.media_bad.len);
                @memcpy(self.media_bad[0..bad], payload[0..bad]);
                self.media_bad_len = bad;
            }
        }
    }

    fn scanStatus(self: *Session, root: jsonx.Value) void {
        const status = root.get("status") orelse return;
        const apps_v = status.get("applications") orelse return;
        const apps = switch (apps_v) {
            .array => |items| items,
            else => return,
        };
        for (apps.items) |app| {
            const id = (app.get("appId") orelse continue).asString() orelse continue;
            if (!std.mem.eql(u8, id, cast.default_receiver)) continue;
            const transport = (app.get("transportId") orelse continue).asString() orelse continue;
            const sid = (app.get("sessionId") orelse continue).asString() orelse continue;
            if (transport.len == 0 or sid.len == 0 or transport.len > self.transport.len or sid.len > self.session_id.len) continue;
            @memcpy(self.transport[0..transport.len], transport);
            self.transport_len = transport.len;
            @memcpy(self.session_id[0..sid.len], sid);
            self.session_len = sid.len;
        }
    }

    fn until(self: *Session, ms: i64, comptime ready: fn (*Session) bool) !void {
        const deadline = sys.monoMs(self.io) + ms;
        while (sys.monoMs(self.io) < deadline) {
            if (self.failure_len != 0) return error.CastClosed;
            if (ready(self)) return;
            try self.pump();
        }
        self.setError("the Cast device did not answer");
        return error.CastTimeout;
    }

    pub fn getStatus(self: *Session) !void {
        self.seen_status = self.status_gen;
        var payload: [64]u8 = undefined;
        const text = try std.fmt.bufPrint(&payload, "{{\"type\":\"GET_STATUS\",\"requestId\":{d}}}", .{self.nextRequest()});
        try self.queue(cast.receiver, text, cast.receiver_id);
        try self.until(5000, statusReady);
    }

    pub fn launch(self: *Session) !void {
        if (self.transport_len == 0) {
            var payload: [96]u8 = undefined;
            const text = try std.fmt.bufPrint(&payload, "{{\"type\":\"LAUNCH\",\"requestId\":{d},\"appId\":\"{s}\"}}", .{ self.nextRequest(), cast.default_receiver });
            try self.queue(cast.receiver, text, cast.receiver_id);
            try self.until(8000, transportReady);
        }
        try self.queue(cast.connection, connect_payload, self.transport[0..self.transport_len]);
        try self.pump();
    }

    pub fn load(self: *Session, url: []const u8) !void {
        if (self.transport_len == 0 or self.session_len == 0) return error.CastClosed;
        if (std.mem.indexOfAny(u8, url, "\"\\") != null) return error.CastClosed;
        self.media_bad_len = 0;
        self.player_len = 0;
        // currentTime 0 seeks the live list back to a segment that has already
        // been deleted, so the hub stays on BUFFERING. The segment format is
        // what makes this player treat the MPEG-TS as playable.
        const payload = try std.fmt.allocPrint(self.gpa,
            \\{{"type":"LOAD","requestId":{d},"sessionId":"{s}","media":{{"contentId":"{s}","streamType":"LIVE","contentType":"application/vnd.apple.mpegurl","hlsSegmentFormat":"ts","hlsVideoSegmentFormat":"mpeg2_ts"}},"autoplay":true}}
        , .{ self.nextRequest(), self.session_id[0..self.session_len], url });
        defer self.gpa.free(payload);
        try self.queue(cast.media, payload, self.transport[0..self.transport_len]);
        const deadline = sys.monoMs(self.io) + 20000;
        var asked = false;
        while (sys.monoMs(self.io) < deadline) {
            if (self.failure_len != 0) return error.CastClosed;
            if (self.media_bad_len != 0) {
                self.setError(self.media_bad[0..self.media_bad_len]);
                return error.CastClosed;
            }
            if (self.playerReady()) return;
            if (!asked and deadline - sys.monoMs(self.io) < 8000) {
                asked = true;
                var extra: [64]u8 = undefined;
                const text = try std.fmt.bufPrint(&extra, "{{\"type\":\"GET_STATUS\",\"requestId\":{d}}}", .{self.nextRequest()});
                try self.queue(cast.media, text, self.transport[0..self.transport_len]);
            }
            try self.pump();
        }
        self.setError("the Cast device did not start the picture");
        return error.CastTimeout;
    }

    fn playerReady(self: *Session) bool {
        return std.mem.eql(u8, self.player[0..self.player_len], "PLAYING");
    }

    pub fn playbackFailure(self: *Session) ?[]const u8 {
        if (self.media_bad_len == 0) return null;
        const text = self.media_bad[0..self.media_bad_len];
        self.media_bad_len = 0;
        return text;
    }

    pub fn stopApp(self: *Session) void {
        if (self.session_len == 0) return;
        var payload: [160]u8 = undefined;
        const text = std.fmt.bufPrint(&payload, "{{\"type\":\"STOP\",\"requestId\":{d},\"sessionId\":\"{s}\"}}", .{ self.nextRequest(), self.session_id[0..self.session_len] }) catch return;
        self.queue(cast.receiver, text, cast.receiver_id) catch return;
        self.pump() catch {};
        sys.sleepMs(self.io, 300);
    }
};

fn statusReady(self: *Session) bool {
    return self.status_gen != self.seen_status;
}

fn transportReady(self: *Session) bool {
    return self.transport_len != 0;
}

fn readable(fd: std.posix.fd_t, ms: i32) bool {
    var pfd = linux.pollfd{ .fd = fd, .events = linux.POLL.IN, .revents = 0 };
    const rc = linux.poll(@ptrCast(&pfd), 1, ms);
    if (linux.errno(rc) != .SUCCESS or rc == 0) return false;
    return (pfd.revents & (linux.POLL.IN | linux.POLL.ERR | linux.POLL.HUP)) != 0;
}
