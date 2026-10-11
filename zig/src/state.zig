const std = @import("std");

pub const frame_cap: usize = 8 * 1024 * 1024;

// One MPEG-TS packet never wraps. The browser starts at the live edge of this
// ring, so it does not wait for the next HLS segment to close.
const live_cap: usize = 188 * 8192;
var live_mu: std.Io.Mutex = .init;
var live_buf: [live_cap]u8 = undefined;
var live_n: u64 = 0;

pub var gsr_pid = std.atomic.Value(i32).init(-1);
pub var audio_pid = std.atomic.Value(i32).init(-1);
pub var shutdown = std.atomic.Value(bool).init(false);
pub var video_id = std.atomic.Value(u64).init(0);

pub fn publishLive(io: std.Io, pkt: *const [188]u8) void {
    live_mu.lockUncancelable(io);
    defer live_mu.unlock(io);
    const at: usize = @intCast(live_n % live_cap);
    @memcpy(live_buf[at..][0..188], pkt);
    live_n += 188;
}

pub fn liveEdge(io: std.Io) u64 {
    live_mu.lockUncancelable(io);
    defer live_mu.unlock(io);
    return live_n;
}

pub fn copyLive(io: std.Io, dest: []u8, cursor: *u64) usize {
    live_mu.lockUncancelable(io);
    defer live_mu.unlock(io);
    if (cursor.* > live_n or live_n - cursor.* > live_cap) {
        cursor.* = live_n;
        return 0;
    }
    var have = live_n - cursor.*;
    have -= have % 188;
    if (dest.len < 188 or have == 0) return 0;
    const room = dest.len - (dest.len % 188);
    const take = @min(room, @as(usize, @intCast(have)));
    var left = take;
    var off: usize = 0;
    var pos: usize = @intCast(cursor.* % live_cap);
    while (left > 0) {
        const chunk = @min(left, live_cap - pos);
        @memcpy(dest[off..][0..chunk], live_buf[pos..][0..chunk]);
        off += chunk;
        left -= chunk;
        pos = 0;
    }
    cursor.* += take;
    return take;
}

pub fn noteVideo() void {
    _ = video_id.fetchAdd(1, .release);
}

pub fn videoCount() u64 {
    return video_id.load(.acquire);
}

pub const World = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    runtime: []const u8,
    frame_mu: std.Io.Mutex = .init,
    frame: []u8,
    frame_len: usize = 0,
    frame_id: u64 = 0,
    stop: std.atomic.Value(bool) = .init(false),
    output: []u8,
    width: u32 = 1920,
    height: u32 = 1080,
    follow: bool = true,
    virtual_out: bool = false,
    workspace: i32 = 0,
    listening: bool = false,
    ports: []u16,
    ip: []u8,

    pub fn publish(self: *World, jpeg: []const u8) void {
        if (jpeg.len < 4 or jpeg.len > self.frame.len) return;
        self.frame_mu.lockUncancelable(self.io);
        defer self.frame_mu.unlock(self.io);
        @memcpy(self.frame[0..jpeg.len], jpeg);
        self.frame_len = jpeg.len;
        self.frame_id += 1;
    }

    pub fn copyFrame(self: *World, dest: []u8) ?struct { len: usize, id: u64 } {
        self.frame_mu.lockUncancelable(self.io);
        defer self.frame_mu.unlock(self.io);
        if (self.frame_len == 0 or self.frame_len > dest.len) return null;
        @memcpy(dest[0..self.frame_len], self.frame[0..self.frame_len]);
        return .{ .len = self.frame_len, .id = self.frame_id };
    }

    pub fn snapshot(self: *World) Snapshot {
        self.frame_mu.lockUncancelable(self.io);
        defer self.frame_mu.unlock(self.io);
        return .{
            .ready = self.frame_id > 0 or video_id.load(.acquire) > 0,
            .output = self.output,
            .width = self.width,
            .height = self.height,
            .follow = self.follow,
            .virtual_out = self.virtual_out,
            .workspace = self.workspace,
            .listening = self.listening,
            .ports = self.ports,
            .ip = self.ip,
        };
    }
};

pub const Snapshot = struct {
    ready: bool,
    output: []u8,
    width: u32,
    height: u32,
    follow: bool,
    virtual_out: bool,
    workspace: i32,
    listening: bool,
    ports: []u16,
    ip: []u8,
};

pub fn stopped() bool {
    return false;
}
