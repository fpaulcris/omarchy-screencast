const std = @import("std");
const state = @import("state.zig");
const sys = @import("sys.zig");

const linux = std.os.linux;

const APkt = struct {
    pts: u64,
    data: []u8,
};

const Seg = struct {
    index: u32,
    dur: f64,
};

pub const Writer = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    dir: []u8,
    mu: std.Io.Mutex = .init,
    vcc: u4 = 0,
    acc: u4 = 0,
    pat_cc: u4 = 0,
    pmt_cc: u4 = 0,
    next_index: u32 = 0,
    seg_pts: u64 = 0,
    have_seg: bool = false,
    cur: std.ArrayList(u8) = .empty,
    aq: [128]APkt = undefined,
    aq_len: usize = 0,
    // The hub spends several seconds buffering before it plays. Keep about
    // 20 seconds so the segment it chose is still here. The browser reads
    // the live packet ring, not these files.
    segs: [40]Seg = undefined,
    seg_n: usize = 0,
    files: bool = true,
    live: bool = true,

    pub fn init(io: std.Io, gpa: std.mem.Allocator, dir: []const u8) !*Writer {
        const self = try gpa.create(Writer);
        self.* = .{
            .io = io,
            .gpa = gpa,
            .dir = try gpa.dupe(u8, dir),
        };
        return self;
    }

    pub fn deinit(self: *Writer) void {
        for (self.aq[0..self.aq_len]) |pkt| self.gpa.free(pkt.data);
        self.cur.deinit(self.gpa);
        self.gpa.free(self.dir);
        self.gpa.destroy(self);
    }

    pub fn pushVideo(self: *Writer, annexb: []const u8, pts90: u64, key: bool) void {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        if (!self.have_seg) {
            if (!key) return;
            self.openSeg(pts90) catch return;
        } else if (key and pts90 - self.seg_pts >= seg_ticks) {
            self.drainAudio(pts90);
            self.closeSeg(pts90) catch return;
            self.openSeg(pts90) catch return;
        }
        self.drainAudio(pts90);
        self.writePes(0x101, &self.vcc, 0xE0, pts90, annexb, true, false) catch return;
        state.noteVideo();
    }

    pub fn pushAudio(self: *Writer, adts: []const u8, pts90: u64) bool {
        self.mu.lockUncancelable(self.io);
        defer self.mu.unlock(self.io);
        // A full queue means the video clock has not caught up. The caller waits
        // and retries this same timestamp. Dropping the frame and moving on
        // leaves a hole that later segments never fill.
        if (self.aq_len == self.aq.len) return false;
        const copy = self.gpa.dupe(u8, adts) catch return false;
        self.aq[self.aq_len] = .{ .pts = pts90, .data = copy };
        self.aq_len += 1;
        return true;
    }

    fn drainAudio(self: *Writer, pts: u64) void {
        var i: usize = 0;
        while (i < self.aq_len and self.aq[i].pts <= pts) : (i += 1) {
            self.writePes(0x102, &self.acc, 0xC0, self.aq[i].pts, self.aq[i].data, false, true) catch {};
            self.gpa.free(self.aq[i].data);
        }
        if (i == 0) return;
        std.mem.copyForwards(APkt, self.aq[0 .. self.aq_len - i], self.aq[i..self.aq_len]);
        self.aq_len -= i;
    }

    fn openSeg(self: *Writer, pts: u64) !void {
        self.cur.clearRetainingCapacity();
        self.have_seg = true;
        self.seg_pts = pts;
        const pat = patSection();
        const pmt = pmtSection();
        try self.writePsi(0, &self.pat_cc, &pat);
        try self.writePsi(0x100, &self.pmt_cc, &pmt);
    }

    fn closeSeg(self: *Writer, pts: u64) !void {
        if (!self.files) {
            self.have_seg = false;
            self.cur.clearRetainingCapacity();
            return;
        }
        const index = self.next_index;
        self.next_index += 1;
        const path = try std.fmt.allocPrint(self.gpa, "{s}/seg_{d:0>5}.ts", .{ self.dir, index });
        defer self.gpa.free(path);
        try sys.writeAll(self.io, path, self.cur.items);
        var dur = @as(f64, @floatFromInt(pts - self.seg_pts)) / 90000.0;
        if (dur < 0.001) dur = 0.001;
        if (self.seg_n == self.segs.len) {
            const old = try std.fmt.allocPrint(self.gpa, "{s}/seg_{d:0>5}.ts", .{ self.dir, self.segs[0].index });
            defer self.gpa.free(old);
            sys.removeFile(self.io, old);
            std.mem.copyForwards(Seg, self.segs[0 .. self.seg_n - 1], self.segs[1..self.seg_n]);
            self.seg_n -= 1;
        }
        self.segs[self.seg_n] = .{ .index = index, .dur = dur };
        self.seg_n += 1;
        self.have_seg = false;
        self.cur.clearRetainingCapacity();
        try self.writePlaylist();
    }

    fn writePlaylist(self: *Writer) !void {
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(self.gpa);
        var max_d: u32 = 1;
        for (self.segs[0..self.seg_n]) |seg| {
            const ceil: u32 = @intFromFloat(@ceil(seg.dur));
            if (ceil > max_d) max_d = ceil;
        }
        // Start behind the live edge. A Nest Hub stays on BUFFERING if it is
        // told to begin half a second from the end of a short live list.
        try body.print(self.gpa, "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:{d}\n#EXT-X-MEDIA-SEQUENCE:{d}\n#EXT-X-INDEPENDENT-SEGMENTS\n#EXT-X-START:TIME-OFFSET=-3.0,PRECISE=NO\n", .{
            max_d, self.segs[0].index,
        });
        for (self.segs[0..self.seg_n]) |seg| {
            const ms: u64 = @intFromFloat(@round(seg.dur * 1000.0));
            try body.print(self.gpa, "#EXTINF:{d}.{d:0>3},\nseg_{d:0>5}.ts\n", .{ ms / 1000, ms % 1000, seg.index });
        }
        const tmp = try std.fmt.allocPrint(self.gpa, "{s}/live.m3u8.new", .{self.dir});
        defer self.gpa.free(tmp);
        const dest = try std.fmt.allocPrint(self.gpa, "{s}/live.m3u8", .{self.dir});
        defer self.gpa.free(dest);
        try sys.writeAll(self.io, tmp, body.items);
        if (!rename(tmp, dest)) return error.Rename;
    }

    fn writePsi(self: *Writer, pid: u16, cc: *u4, section: []const u8) !void {
        var payload: [184]u8 = undefined;
        @memset(&payload, 0xFF);
        payload[0] = 0;
        @memcpy(payload[1..][0..section.len], section);
        try self.emitPacket(pid, cc, true, null, payload[0 .. 1 + section.len]);
    }

    fn writePes(
        self: *Writer,
        pid: u16,
        cc: *u4,
        stream_id: u8,
        pts: u64,
        payload: []const u8,
        with_pcr: bool,
        set_length: bool,
    ) !void {
        var hdr: [14]u8 = undefined;
        hdr[0] = 0;
        hdr[1] = 0;
        hdr[2] = 1;
        hdr[3] = stream_id;
        const after = 8 + payload.len;
        const len_field: u16 = if (!set_length or after > 65535) 0 else @intCast(after);
        hdr[4] = @intCast(len_field >> 8);
        hdr[5] = @intCast(len_field & 0xFF);
        hdr[6] = 0x80;
        hdr[7] = 0x80;
        hdr[8] = 5;
        writePts(hdr[9..14], pts);
        const total = hdr.len + payload.len;
        var off: usize = 0;
        var first = true;
        while (off < total) {
            var room: usize = 184;
            var pcr: ?u64 = null;
            if (first and with_pcr) {
                room = 176;
                pcr = pts;
            }
            const left = total - off;
            const take = @min(left, room);
            var chunk: [184]u8 = undefined;
            for (0..take) |i| {
                const at = off + i;
                chunk[i] = if (at < hdr.len) hdr[at] else payload[at - hdr.len];
            }
            try self.emitPacket(pid, cc, first, if (first) pcr else null, chunk[0..take]);
            off += take;
            first = false;
        }
    }

    fn emitPacket(self: *Writer, pid: u16, cc: *u4, pusi: bool, pcr: ?u64, payload: []const u8) !void {
        if (payload.len > 184) return error.Packet;
        var pkt: [188]u8 = undefined;
        @memset(&pkt, 0xFF);
        pkt[0] = 0x47;
        pkt[1] = @intCast((pid >> 8) & 0x1F);
        if (pusi) pkt[1] |= 0x40;
        pkt[2] = @intCast(pid & 0xFF);
        const gap = 184 - payload.len;
        var adapt: usize = 0;
        var afc: u8 = 1;
        if (pcr != null or gap > 0) {
            afc = 3;
            if (pcr != null) {
                adapt = 183 - payload.len;
                if (adapt < 7) return error.Packet;
            } else if (gap == 1) {
                adapt = 0;
            } else {
                adapt = gap - 1;
            }
        }
        pkt[3] = (afc << 4) | @as(u8, cc.*);
        var i: usize = 4;
        if (afc == 3) {
            pkt[i] = @intCast(adapt);
            i += 1;
            if (adapt > 0) {
                pkt[i] = if (pcr != null) 0x10 else 0;
                i += 1;
                if (pcr) |val| {
                    writePcr(pkt[i..][0..6], val);
                    i += 6;
                }
                i = 5 + adapt;
            }
        }
        if (i + payload.len != 188) return error.Packet;
        @memcpy(pkt[i..][0..payload.len], payload);
        cc.* +%= 1;
        if (self.files) try self.cur.appendSlice(self.gpa, &pkt);
        if (self.live) state.publishLive(self.io, &pkt);
    }
};

// A keyframe closer than this stays in the open segment. The encoder GOP and
// gpu-screen-recorder -keyint are half a second, so the next key still closes it.
const seg_ticks: u64 = 90000 * 2 / 5;

fn writePts(dst: []u8, pts: u64) void {
    const p = pts & 0x1FFFFFFFF;
    dst[0] = @intCast(0x20 | (((p >> 30) & 7) << 1) | 1);
    dst[1] = @intCast((p >> 22) & 0xFF);
    dst[2] = @intCast((((p >> 15) & 0x7F) << 1) | 1);
    dst[3] = @intCast((p >> 7) & 0xFF);
    dst[4] = @intCast(((p & 0x7F) << 1) | 1);
}

fn writePcr(dst: []u8, pts: u64) void {
    const p = pts & 0x1FFFFFFFF;
    dst[0] = @intCast((p >> 25) & 0xFF);
    dst[1] = @intCast((p >> 17) & 0xFF);
    dst[2] = @intCast((p >> 9) & 0xFF);
    dst[3] = @intCast((p >> 1) & 0xFF);
    dst[4] = @intCast(((p & 1) << 7) | 0x7E);
    dst[5] = 0;
}

fn patSection() [16]u8 {
    var s: [16]u8 = .{
        0x00, 0xB0, 0x0D, 0x00, 0x01, 0xC1, 0x00, 0x00,
        0x00, 0x01, 0xE1, 0x00, 0,    0,    0,    0,
    };
    const c = crc32(s[0..12]);
    std.mem.writeInt(u32, s[12..16], c, .big);
    return s;
}

fn pmtSection() [26]u8 {
    var s: [26]u8 = .{
        0x02, 0xB0, 0x17, 0x00, 0x01, 0xC1, 0x00, 0x00,
        0xE1, 0x01, 0xF0, 0x00, 0x1B, 0xE1, 0x01, 0xF0,
        0x00, 0x0F, 0xE1, 0x02, 0xF0, 0x00, 0,    0,
        0,    0,
    };
    const c = crc32(s[0..22]);
    std.mem.writeInt(u32, s[22..26], c, .big);
    return s;
}

fn crc32(data: []const u8) u32 {
    var crc: u32 = 0xFFFFFFFF;
    for (data) |byte| {
        crc ^= @as(u32, byte) << 24;
        var bit: u8 = 0;
        while (bit < 8) : (bit += 1) {
            if (crc & 0x80000000 != 0) crc = (crc << 1) ^ 0x04C11DB7 else crc <<= 1;
        }
    }
    return crc;
}

fn rename(from: []const u8, to: []const u8) bool {
    var a: [1024]u8 = undefined;
    var b: [1024]u8 = undefined;
    if (from.len + 1 > a.len or to.len + 1 > b.len) return false;
    @memcpy(a[0..from.len], from);
    a[from.len] = 0;
    @memcpy(b[0..to.len], to);
    b[to.len] = 0;
    const rc = linux.rename(@ptrCast(&a), @ptrCast(&b));
    return linux.errno(rc) == .SUCCESS;
}

pub fn ensureToken(io: std.Io, gpa: std.mem.Allocator, runtime: []const u8) ![32]u8 {
    const path = try sys.join(gpa, runtime, "hls.token");
    defer gpa.free(path);
    if (readToken(io, gpa, runtime)) |token| return token;
    var created: [32]u8 = undefined;
    try sys.hexToken(io, &created);
    if (path.len + 1 > 512) return error.BadId;
    var z: [512]u8 = undefined;
    @memcpy(z[0..path.len], path);
    z[path.len] = 0;
    const opened = linux.open(@ptrCast(&z), .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, 0o600);
    if (linux.errno(opened) == .SUCCESS) {
        const fd: i32 = @intCast(opened);
        const n = linux.write(fd, &created, created.len);
        _ = linux.close(fd);
        if (linux.errno(n) == .SUCCESS and n == created.len) return created;
        sys.removeFile(io, path);
    }
    if (readToken(io, gpa, runtime)) |token| return token;
    try sys.writeAll(io, path, &created);
    return created;
}

pub fn readToken(io: std.Io, gpa: std.mem.Allocator, runtime: []const u8) ?[32]u8 {
    const path = sys.join(gpa, runtime, "hls.token") catch return null;
    defer gpa.free(path);
    const text = sys.readAll(io, gpa, path, 64) orelse return null;
    defer gpa.free(text);
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (trimmed.len != 32) return null;
    for (trimmed) |byte| if (!std.ascii.isHex(byte)) return null;
    var out: [32]u8 = undefined;
    @memcpy(&out, trimmed);
    return out;
}

test "live segment closes near half a second" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const dir = ".zig-cache/hls-short";
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    sys.clearDir(io, dir);
    const w = try Writer.init(io, gpa, dir);
    defer w.deinit();
    const edge = state.liveEdge(io);
    const nal = [_]u8{ 0, 0, 0, 1, 0x65, 0x88 };
    w.pushVideo(&nal, 0, true);
    w.pushVideo(&nal, 45000, true);
    const list = sys.readAll(io, gpa, ".zig-cache/hls-short/live.m3u8", 4096) orelse return error.TestUnexpectedResult;
    defer gpa.free(list);
    try std.testing.expect(std.mem.indexOf(u8, list, "#EXTINF:0.500,") != null);
    try std.testing.expect(std.mem.indexOf(u8, list, "#EXT-X-TARGETDURATION:1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, list, "#EXT-X-INDEPENDENT-SEGMENTS\n") != null);
    var cursor = edge;
    var buf: [8192]u8 = undefined;
    const n = state.copyLive(io, &buf, &cursor);
    try std.testing.expect(n >= 188 and buf[0] == 0x47);
    try std.testing.expect(cursor > edge);
}

test "mpegts playlist has two segments" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const h264enc = @import("h264enc.zig");
    const aac = @import("aac.zig");
    const dir = ".zig-cache/hls-test";
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    sys.clearDir(io, dir);
    const w = try Writer.init(io, gpa, dir);
    defer w.deinit();
    var venc = try h264enc.Encoder.init(gpa, 64, 64, 1);
    defer venc.deinit();
    var aenc = aac.Encoder.init();
    var y: [64 * 64]u8 = undefined;
    var c: [32 * 32]u8 = undefined;
    @memset(&y, 128);
    @memset(&c, 128);
    var au: [64 * 1024]u8 = undefined;
    var pcm: [2048]i16 = undefined;
    @memset(&pcm, 0);
    var adts: [512]u8 = undefined;
    for (0..5) |i| {
        const n = aenc.encode(&pcm, &adts);
        try std.testing.expect(n > 7);
        try std.testing.expect(w.pushAudio(adts[0..n], @as(u64, i) * 90000));
        const frame = try venc.encodePlanes(&y, 64, &c, 32, &c, 32, &au);
        w.pushVideo(au[0..frame.len], @as(u64, i) * 90000, frame.key);
    }
    const list = sys.readAll(io, gpa, ".zig-cache/hls-test/live.m3u8", 4096) orelse return error.TestUnexpectedResult;
    defer gpa.free(list);
    var extinf: usize = 0;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, list, from, "#EXTINF:")) |at| {
        extinf += 1;
        from = at + 8;
    }
    try std.testing.expect(extinf >= 2);
    const ts = sys.readAll(io, gpa, ".zig-cache/hls-test/seg_00000.ts", 2 * 1024 * 1024) orelse return error.TestUnexpectedResult;
    defer gpa.free(ts);
    try std.testing.expect(ts.len > 188 and ts[0] == 0x47);
    if (!sys.exists(io, "/usr/bin/ffmpeg")) return;
    const ran = try sys.run(gpa, io, &.{
        "/usr/bin/ffmpeg", "-y",           "-hide_banner", "-loglevel", "error",
        "-f",              "mpegts",       "-i",           ".zig-cache/hls-test/seg_00000.ts",
        "-map",            "0:v:0",        "-fps_mode",    "vfr",        "-frames:v", "2",
        "-f",              "rawvideo",     "-pix_fmt",     "yuv420p",
        ".zig-cache/hls-test/out.yuv",
    }, 20000, 8192);
    defer gpa.free(ran.stdout);
    defer gpa.free(ran.stderr);
    if (!ran.term_ok) {
        std.debug.print("ts stderr {s}\n", .{ran.stderr});
        return error.TestUnexpectedResult;
    }
    const yuv = sys.readAll(io, gpa, ".zig-cache/hls-test/out.yuv", 256 * 1024) orelse return error.TestUnexpectedResult;
    defer gpa.free(yuv);
    try std.testing.expect(yuv.len >= 64 * 64);
    const audio = try sys.run(gpa, io, &.{
        "/usr/bin/ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
        "-f",              "mpegts", "-i", ".zig-cache/hls-test/seg_00000.ts",
        "-map",            "0:a:0", "-f", "s16le", ".zig-cache/hls-test/out.pcm",
    }, 20000, 8192);
    defer gpa.free(audio.stdout);
    defer gpa.free(audio.stderr);
    if (!audio.term_ok) {
        std.debug.print("ts audio stderr {s}\n", .{audio.stderr});
        return error.TestUnexpectedResult;
    }
}

test "mpegts keeps audio that arrives before the picture" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const h264enc = @import("h264enc.zig");
    const aac = @import("aac.zig");
    const dir = ".zig-cache/hls-ahead";
    std.Io.Dir.cwd().createDirPath(io, dir) catch {};
    sys.clearDir(io, dir);
    const w = try Writer.init(io, gpa, dir);
    defer w.deinit();
    var venc = try h264enc.Encoder.init(gpa, 64, 64, 1);
    defer venc.deinit();
    var aenc = aac.Encoder.init();
    var y: [64 * 64]u8 = undefined;
    var c: [32 * 32]u8 = undefined;
    @memset(&y, 128);
    @memset(&c, 128);
    var au: [64 * 1024]u8 = undefined;
    var pcm: [2048]i16 = undefined;
    @memset(&pcm, 0);
    var adts: [512]u8 = undefined;
    const frame = try venc.encodePlanes(&y, 64, &c, 32, &c, 32, &au);
    for (0..200) |i| {
        const n = aenc.encode(&pcm, &adts);
        try std.testing.expect(n > 7);
        _ = w.pushAudio(adts[0..n], @as(u64, i) * 1920);
    }
    w.pushVideo(au[0..frame.len], 0, true);
    w.pushVideo(au[0..frame.len], 2 * 90000, true);
    const ts = sys.readAll(io, gpa, ".zig-cache/hls-ahead/seg_00000.ts", 2 * 1024 * 1024) orelse return error.TestUnexpectedResult;
    defer gpa.free(ts);
    var audio_pkts: usize = 0;
    var at: usize = 0;
    while (at + 188 <= ts.len) : (at += 188) {
        const pid = (@as(u16, ts[at + 1] & 0x1f) << 8) | ts[at + 2];
        if (pid == 0x102) audio_pkts += 1;
    }
    try std.testing.expect(audio_pkts > 0);
}
