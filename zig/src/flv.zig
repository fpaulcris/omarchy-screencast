// Ported from naquad-desk src/flv_au.zig.
// Copyright (c) 2026 Naquad. MIT License.
//! Turn a gpu-screen-recorder FLV byte stream into Annex-B access units.
//! Each video tag is one picture and is emitted as soon as its body arrives.
//! The AVC sequence header is not a picture. A keyframe repeats it so the
//! access unit can be decoded on its own.

const std = @import("std");

pub const au_max: usize = 1048576;

pub const Frame = struct {
    len: usize,
    ts: u32,
    key: bool,
};

pub const Out = union(enum) {
    none,
    frame: Frame,
    broken,
};

const Stage = enum { magic, skip, tag, body, prev };

pub const Parser = struct {
    buf: []u8,
    start: usize = 0,
    end: usize = 0,
    stage: Stage = .magic,
    skip_left: usize = 0,
    body_need: usize = 0,
    tag_type: u8 = 0,
    tag_ts: u32 = 0,
    nal_size: usize = 4,
    sps: [256]u8 = undefined,
    pps: [128]u8 = undefined,
    sps_len: usize = 0,
    pps_len: usize = 0,

    pub fn reset(self: *Parser) void {
        self.start = 0;
        self.end = 0;
        self.stage = .magic;
        self.skip_left = 0;
        self.body_need = 0;
        self.tag_type = 0;
        self.tag_ts = 0;
        self.nal_size = 4;
        self.sps_len = 0;
        self.pps_len = 0;
    }

    pub fn push(self: *Parser, data: []const u8, out: []u8) Out {
        if (data.len != 0 and !self.append(data)) {
            self.reset();
            if (data.len > self.buf.len or !self.append(data)) return .broken;
        }
        return self.next(out);
    }

    pub fn next(self: *Parser, out: []u8) Out {
        while (true) {
            const avail = self.end - self.start;
            switch (self.stage) {
                .magic => {
                    if (avail < 9) return .none;
                    const rel = std.mem.indexOf(u8, self.buf[self.start..self.end], "FLV") orelse {
                        if (avail > 2) self.start = self.end - 2;
                        return .none;
                    };
                    self.start += rel;
                    if (self.end - self.start < 9) return .none;
                    const hdr = self.buf[self.start..self.end];
                    if (hdr[3] != 1) {
                        self.start += 1;
                        continue;
                    }
                    const data_off = readBe(hdr[5..9]);
                    if (data_off < 9 or data_off > 1024) {
                        self.start += 1;
                        continue;
                    }
                    self.stage = .skip;
                    self.skip_left = data_off + 4;
                },
                .skip => {
                    if (avail == 0) return .none;
                    const n = @min(avail, self.skip_left);
                    self.start += n;
                    self.skip_left -= n;
                    if (self.skip_left != 0) return .none;
                    self.stage = .tag;
                },
                .tag => {
                    if (avail < 11) return .none;
                    const h = self.buf[self.start..self.end];
                    const size = readBe(h[1..4]);
                    if (size > self.buf.len - 32) {
                        self.reset();
                        return .broken;
                    }
                    self.tag_type = h[0];
                    self.tag_ts = @intCast(readBe(h[4..7]) | (@as(usize, h[7]) << 24));
                    self.start += 11;
                    self.body_need = size;
                    self.stage = .body;
                },
                .body => {
                    if (avail < self.body_need) return .none;
                    const body = self.buf[self.start..][0..self.body_need];
                    const frame = if (self.tag_type == 9) self.video(body, out) else null;
                    self.start += self.body_need;
                    self.stage = .prev;
                    if (frame) |got| return .{ .frame = got };
                },
                .prev => {
                    if (avail < 4) return .none;
                    self.start += 4;
                    self.stage = .tag;
                },
            }
        }
    }

    fn append(self: *Parser, data: []const u8) bool {
        self.compact();
        if (self.end + data.len > self.buf.len) return false;
        @memcpy(self.buf[self.end..][0..data.len], data);
        self.end += data.len;
        return true;
    }

    fn compact(self: *Parser) void {
        if (self.start == 0) return;
        const n = self.end - self.start;
        if (n != 0) std.mem.copyForwards(u8, self.buf[0..n], self.buf[self.start..self.end]);
        self.start = 0;
        self.end = n;
    }

    fn video(self: *Parser, body: []const u8, out: []u8) ?Frame {
        if (body.len < 5) return null;
        if ((body[0] & 0x0f) != 7) return null;
        const key = (body[0] >> 4) == 1;
        const kind = body[1];
        const payload = body[5..];
        if (kind == 0) {
            self.storeConfig(payload);
            return null;
        }
        if (kind != 1) return null;
        var n: usize = 0;
        if (key and self.sps_len != 0 and self.pps_len != 0) {
            if (!writeNal(out, &n, self.sps[0..self.sps_len])) return null;
            if (!writeNal(out, &n, self.pps[0..self.pps_len])) return null;
        }
        var i: usize = 0;
        while (i + self.nal_size <= payload.len) {
            const ln = readBe(payload[i..][0..self.nal_size]);
            i += self.nal_size;
            if (ln == 0 or i + ln > payload.len) break;
            if (!writeNal(out, &n, payload[i..][0..ln])) return null;
            i += ln;
        }
        if (n == 0) return null;
        return .{ .len = n, .ts = self.tag_ts, .key = key };
    }

    fn storeConfig(self: *Parser, payload: []const u8) void {
        if (payload.len < 7) return;
        const nal_size = (payload[4] & 3) + 1;
        if (nal_size < 1 or nal_size > 4) return;
        var i: usize = 6;
        const n_sps: usize = payload[5] & 0x1f;
        if (n_sps == 0) return;
        if (i + 2 > payload.len) return;
        const sps_n = readBe(payload[i..][0..2]);
        i += 2;
        if (sps_n == 0 or sps_n > self.sps.len or i + sps_n > payload.len) return;
        const sps = payload[i..][0..sps_n];
        i += sps_n;
        if (i >= payload.len) return;
        const n_pps = payload[i];
        i += 1;
        if (n_pps == 0 or i + 2 > payload.len) return;
        const pps_n = readBe(payload[i..][0..2]);
        i += 2;
        if (pps_n == 0 or pps_n > self.pps.len or i + pps_n > payload.len) return;
        @memcpy(self.sps[0..sps_n], sps);
        self.sps_len = sps_n;
        @memcpy(self.pps[0..pps_n], payload[i..][0..pps_n]);
        self.pps_len = pps_n;
        self.nal_size = nal_size;
    }
};

fn readBe(bytes: []const u8) usize {
    var v: usize = 0;
    for (bytes) |b| v = (v << 8) | b;
    return v;
}

fn writeNal(out: []u8, n: *usize, nal: []const u8) bool {
    if (n.* + 4 + nal.len > out.len) return false;
    out[n.*] = 0;
    out[n.* + 1] = 0;
    out[n.* + 2] = 0;
    out[n.* + 3] = 1;
    @memcpy(out[n.* + 4 ..][0..nal.len], nal);
    n.* += 4 + nal.len;
    return true;
}

fn putBe(out: []u8, n: *usize, bytes: usize, value: usize) void {
    var i: usize = bytes;
    while (i > 0) {
        i -= 1;
        out[n.*] = @intCast((value >> @intCast(i * 8)) & 0xff);
        n.* += 1;
    }
}

fn putTag(out: []u8, n: *usize, kind: u8, ts: u32, body: []const u8) void {
    out[n.*] = kind;
    n.* += 1;
    putBe(out, n, 3, body.len);
    putBe(out, n, 3, ts & 0xffffff);
    out[n.*] = @intCast((ts >> 24) & 0xff);
    n.* += 1;
    out[n.*] = 0;
    out[n.* + 1] = 0;
    out[n.* + 2] = 0;
    n.* += 3;
    @memcpy(out[n.*..][0..body.len], body);
    n.* += body.len;
    putBe(out, n, 4, 11 + body.len);
}

fn sampleStream(out: []u8, inter_at: *usize) usize {
    var n: usize = 0;
    out[0] = 'F';
    out[1] = 'L';
    out[2] = 'V';
    out[3] = 1;
    out[4] = 1;
    n = 5;
    putBe(out, &n, 4, 9);
    putBe(out, &n, 4, 0);
    const script = [_]u8{ 0, 1, 2 };
    putTag(out, &n, 18, 0, &script);
    var seq: [64]u8 = undefined;
    seq[0] = 0x17;
    seq[1] = 0;
    seq[2] = 0;
    seq[3] = 0;
    seq[4] = 0;
    seq[5] = 1;
    seq[6] = 0x64;
    seq[7] = 0;
    seq[8] = 0x2a;
    seq[9] = 0xff;
    seq[10] = 0xe1;
    var s: usize = 11;
    putBe(seq[0..], &s, 2, 4);
    seq[s] = 0x67;
    seq[s + 1] = 'S';
    seq[s + 2] = 'P';
    seq[s + 3] = 'S';
    s += 4;
    seq[s] = 1;
    s += 1;
    putBe(seq[0..], &s, 2, 4);
    seq[s] = 0x68;
    seq[s + 1] = 'P';
    seq[s + 2] = 'P';
    seq[s + 3] = 'S';
    s += 4;
    putTag(out, &n, 9, 0, seq[0..s]);
    var key: [16]u8 = undefined;
    key[0] = 0x17;
    key[1] = 1;
    key[2] = 0;
    key[3] = 0;
    key[4] = 0;
    var k: usize = 5;
    putBe(key[0..], &k, 4, 4);
    key[k] = 0x65;
    key[k + 1] = 'I';
    key[k + 2] = 'D';
    key[k + 3] = 'R';
    k += 4;
    putTag(out, &n, 9, 0, key[0..k]);
    inter_at.* = n;
    var inter: [16]u8 = undefined;
    inter[0] = 0x27;
    inter[1] = 1;
    inter[2] = 0;
    inter[3] = 0;
    inter[4] = 0;
    var p: usize = 5;
    putBe(inter[0..], &p, 4, 4);
    inter[p] = 0x41;
    inter[p + 1] = 'P';
    inter[p + 2] = 'F';
    inter[p + 3] = 'R';
    p += 4;
    putTag(out, &n, 9, 17, inter[0..p]);
    return n;
}

test "a keyframe is complete before the next tag arrives" {
    var raw: [512]u8 = undefined;
    var inter_at: usize = 0;
    const n = sampleStream(&raw, &inter_at);
    var storage: [2048]u8 = undefined;
    var parser = Parser{ .buf = &storage };
    var out: [256]u8 = undefined;
    var got: ?Frame = null;
    var i: usize = 0;
    while (i < inter_at) : (i += 1) {
        switch (parser.push(raw[i .. i + 1], &out)) {
            .none => {},
            .broken => return error.TestUnexpectedResult,
            .frame => |frame| {
                if (got != null) return error.TestUnexpectedResult;
                got = frame;
            },
        }
    }
    const key = got orelse return error.TestUnexpectedResult;
    try std.testing.expect(key.key);
    try std.testing.expect(std.mem.indexOf(u8, out[0..key.len], "SPS") != null);
    try std.testing.expect(std.mem.indexOf(u8, out[0..key.len], "PPS") != null);
    try std.testing.expect(std.mem.indexOf(u8, out[0..key.len], "IDR") != null);
    try std.testing.expect(std.mem.indexOf(u8, out[0..key.len], "PFR") == null);
    const second = parser.push(raw[inter_at..n], &out);
    switch (second) {
        .frame => |frame| {
            try std.testing.expect(!frame.key);
            try std.testing.expectEqual(@as(u32, 17), frame.ts);
            try std.testing.expect(std.mem.indexOf(u8, out[0..frame.len], "PFR") != null);
            try std.testing.expect(std.mem.indexOf(u8, out[0..frame.len], "SPS") == null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "junk before the signature still frames" {
    var raw: [512]u8 = undefined;
    raw[0] = '/';
    raw[1] = 'x';
    raw[2] = '\n';
    var inter_at: usize = 0;
    const n = sampleStream(raw[3..], &inter_at);
    var storage: [2048]u8 = undefined;
    var parser = Parser{ .buf = &storage };
    var out: [256]u8 = undefined;
    const first = parser.push(raw[0 .. n + 3], &out);
    switch (first) {
        .frame => |frame| try std.testing.expect(frame.key),
        else => return error.TestUnexpectedResult,
    }
}
