const std = @import("std");
const tab = @import("aactab.zig");
const sys = @import("sys.zig");

// ISO/IEC 14496-3 MDCT. N = 2048, n0 = 512.5, sine window.
// X[k] = 2 * sum_n w[n] * x[n] * cos(2π/N * (n + n0) * (k + 1/2)).

const swb = [_]u16{
    0,   4,   8,   12,  16,  20,  24,  28,  32,  36,  40,  48,  56,  64,  72,  80,  88,
    96,  108, 120, 132, 144, 160, 176, 196, 216, 240, 264, 292, 320, 352, 384, 416, 448,
    480, 512, 544, 576, 608, 640, 672, 704, 736, 768, 800, 832, 864, 896, 928, 1024,
};

const bands: u32 = 49;

comptime {
    if (tab.book11_len.len != 289 or tab.book11_code.len != 289) @compileError("book 11");
    if (tab.sf_len.len != 121 or tab.sf_code.len != 121) @compileError("scale factor book");
    if (swb.len != bands + 1) @compileError("scale factor bands");
}

const Bits = struct {
    data: []u8,
    bit: usize = 0,
    overflow: bool = false,

    fn put(self: *Bits, value: u32, n: u32) void {
        if (n == 0 or self.overflow) return;
        if (self.bit + n > self.data.len * 8) {
            self.overflow = true;
            return;
        }
        var left = n;
        while (left > 0) {
            left -= 1;
            const one: u8 = @intCast((value >> @intCast(left)) & 1);
            const pos = self.bit;
            self.data[pos >> 3] |= one << @intCast(7 - (pos & 7));
            self.bit += 1;
        }
    }

    fn bytes(self: *const Bits) usize {
        return (self.bit + 7) / 8;
    }
};

pub const Encoder = struct {
    prev_l: [1024]f32,
    prev_r: [1024]f32,
    win: [2048]f32,

    pub fn init() Encoder {
        var enc: Encoder = undefined;
        @memset(&enc.prev_l, 0);
        @memset(&enc.prev_r, 0);
        for (0..2048) |n| {
            enc.win[n] = @sin(std.math.pi / 2048.0 * (@as(f32, @floatFromInt(n)) + 0.5));
        }
        return enc;
    }

    pub fn encode(self: *Encoder, pcm: []const i16, out: []u8) usize {
        if (pcm.len < 2048 or out.len < 16) return 0;
        var xl: [2048]f32 = undefined;
        var xr: [2048]f32 = undefined;
        for (0..1024) |i| {
            xl[i] = self.prev_l[i];
            xr[i] = self.prev_r[i];
            const l: f32 = @floatFromInt(pcm[i * 2]);
            const r: f32 = @floatFromInt(pcm[i * 2 + 1]);
            xl[1024 + i] = l;
            xr[1024 + i] = r;
            self.prev_l[i] = l;
            self.prev_r[i] = r;
        }
        var raw: [3072]u8 = undefined;
        @memset(&raw, 0);
        var bits = Bits{ .data = &raw };
        const silent = quiet(&xl) and quiet(&xr);
        var spec_l: [1024]f32 = undefined;
        var spec_r: [1024]f32 = undefined;
        var sf_l: i32 = 0;
        var sf_r: i32 = 0;
        const max_sfb: u32 = if (silent) 0 else bands;
        if (!silent) {
            mdct(&self.win, &xl, &spec_l);
            mdct(&self.win, &xr, &spec_r);
            sf_l = chooseSf(peak(&spec_l));
            sf_r = chooseSf(peak(&spec_r));
        }
        writeCpe(&bits, &spec_l, &spec_r, max_sfb, sf_l, sf_r);
        if (bits.overflow) return 0;
        const raw_len = bits.bytes();
        const frame_len = raw_len + 7;
        if (frame_len > out.len) return 0;
        writeAdts(out, frame_len);
        @memcpy(out[7..frame_len], raw[0..raw_len]);
        return frame_len;
    }
};

fn quiet(x: *const [2048]f32) bool {
    for (x) |v| if (@abs(v) >= 8) return false;
    return true;
}

fn peak(spec: *const [1024]f32) f32 {
    var m: f32 = 0;
    for (spec) |v| m = @max(m, @abs(v));
    return m;
}

fn chooseSf(max_abs: f32) i32 {
    if (max_abs < 1) return 0;
    var sf: i32 = @intFromFloat(@round(100.0 + 4.0 * std.math.log2(max_abs / 27.5)));
    if (sf < 0) sf = 0;
    if (sf > 255) sf = 255;
    var guard: u8 = 0;
    while (guard < 8 and qabs(max_abs, sf) > 8191 and sf < 252) : (guard += 1) sf += 4;
    return sf;
}

fn qabs(mag: f32, sf: i32) i32 {
    const gain = std.math.pow(f32, 2.0, @as(f32, @floatFromInt(sf - 100)) / 4.0);
    const scaled = mag / gain;
    const q = std.math.pow(f32, @max(scaled, 0), 0.75);
    return @intFromFloat(@round(q));
}

fn quant(spec: f32, sf: i32) i32 {
    var level = qabs(@abs(spec), sf);
    if (level > 8191) level = 8191;
    return if (spec < 0) -level else level;
}

fn mdct(win: *const [2048]f32, x: *const [2048]f32, out: *[1024]f32) void {
    @setRuntimeSafety(false);
    const n0: f32 = 512.5;
    const scale: f32 = 2.0 * std.math.pi / 2048.0;
    for (0..1024) |k| {
        const step = scale * (@as(f32, @floatFromInt(k)) + 0.5);
        const cd = @cos(step);
        const sd = @sin(step);
        var sum: f32 = 0;
        var n: usize = 0;
        while (n < 2048) {
            const ang = step * (n0 + @as(f32, @floatFromInt(n)));
            var c = @cos(ang);
            var s = @sin(ang);
            const end = @min(n + 64, 2048);
            while (n < end) : (n += 1) {
                sum += win[n] * x[n] * c;
                const nc = c * cd - s * sd;
                s = s * cd + c * sd;
                c = nc;
            }
        }
        out[k] = 2 * sum;
    }
}

fn writeCpe(bits: *Bits, left: *const [1024]f32, right: *const [1024]f32, max_sfb: u32, sf_l: i32, sf_r: i32) void {
    bits.put(1, 3);
    bits.put(0, 4);
    bits.put(1, 1);
    writeIcsInfo(bits, max_sfb);
    bits.put(0, 2);
    writeChannel(bits, left, max_sfb, sf_l);
    writeChannel(bits, right, max_sfb, sf_r);
    bits.put(7, 3);
}

fn writeIcsInfo(bits: *Bits, max_sfb: u32) void {
    bits.put(0, 1);
    bits.put(0, 2);
    bits.put(0, 1);
    bits.put(max_sfb, 6);
    bits.put(0, 1);
}

fn writeChannel(bits: *Bits, spec: *const [1024]f32, max_sfb: u32, sf: i32) void {
    const gain: u32 = @intCast(sf);
    bits.put(gain, 8);
    writeSection(bits, max_sfb);
    // Every band, including the first, is a delta from global_gain.
    var i: u32 = 0;
    while (i < max_sfb) : (i += 1) bits.put(tab.sf_code[60], tab.sf_len[60]);
    bits.put(0, 1);
    bits.put(0, 1);
    // Decoders read this bit on long windows too (ffmpeg, faad). 1 means SSR.
    bits.put(0, 1);
    if (max_sfb == 0) return;
    var sfb: usize = 0;
    while (sfb < max_sfb) : (sfb += 1) {
        var n: usize = swb[sfb];
        const end = swb[sfb + 1];
        while (n + 1 < end) : (n += 2) writePair(bits, quant(spec[n], sf), quant(spec[n + 1], sf));
    }
}

fn writeSection(bits: *Bits, max_sfb: u32) void {
    if (max_sfb == 0) return;
    bits.put(11, 4);
    var left = max_sfb;
    while (true) {
        const n: u32 = if (left >= 31) 31 else left;
        bits.put(n, 5);
        if (n < 31) break;
        left -= 31;
    }
}

fn writePair(bits: *Bits, y: i32, z: i32) void {
    const ay = absInt(y);
    const az = absInt(z);
    const iy: usize = @intCast(@min(ay, 16));
    const iz: usize = @intCast(@min(az, 16));
    const index = iy * 17 + iz;
    bits.put(tab.book11_code[index], tab.book11_len[index]);
    if (y != 0) bits.put(if (y < 0) 1 else 0, 1);
    if (z != 0) bits.put(if (z < 0) 1 else 0, 1);
    if (ay >= 16) writeEscape(bits, ay);
    if (az >= 16) writeEscape(bits, az);
}

fn writeEscape(bits: *Bits, mag: i32) void {
    const value: u32 = @intCast(mag);
    const n: u32 = (31 - @clz(value)) - 4;
    if (n > 0) bits.put((@as(u32, 1) << @intCast(n)) - 1, n);
    bits.put(0, 1);
    const base = @as(u32, 1) << @intCast(n + 4);
    bits.put(value - base, n + 4);
}

fn absInt(v: i32) i32 {
    return if (v < 0) -v else v;
}

fn writeAdts(out: []u8, frame_len: usize) void {
    const fl: u32 = @intCast(frame_len);
    out[0] = 0xFF;
    out[1] = 0xF1;
    out[2] = 0x4C;
    out[3] = 0x80 | @as(u8, @intCast((fl >> 11) & 0x3));
    out[4] = @intCast((fl >> 3) & 0xFF);
    out[5] = @as(u8, @intCast((fl & 0x7) << 5)) | 0x1F;
    out[6] = 0xFC;
}

fn directBin(win: *const [2048]f32, x: *const [2048]f32, k: usize) f32 {
    const n0: f32 = 512.5;
    const step = (2.0 * std.math.pi / 2048.0) * (@as(f32, @floatFromInt(k)) + 0.5);
    var sum: f32 = 0;
    for (0..2048) |n| {
        const ang = step * (n0 + @as(f32, @floatFromInt(n)));
        sum += win[n] * x[n] * @cos(ang);
    }
    return 2 * sum;
}

test "mdct recurrence matches the direct sum" {
    var enc = Encoder.init();
    var x: [2048]f32 = undefined;
    @memset(&x, 0);
    x[10] = 0.5;
    x[100] = 1;
    x[500] = -0.25;
    x[1500] = 0.75;
    var got: [1024]f32 = undefined;
    mdct(&enc.win, &x, &got);
    for ([_]usize{ 0, 1, 100 }) |k| {
        const want = directBin(&enc.win, &x, k);
        const err = @abs(got[k] - want);
        const tol = @max(@abs(want) * 0.001, 0.05);
        try std.testing.expect(err < tol);
    }
}

test "aac silence decodes" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var enc = Encoder.init();
    var pcm: [2048]i16 = undefined;
    @memset(&pcm, 0);
    var frame: [512]u8 = undefined;
    var file: [1536]u8 = undefined;
    var at: usize = 0;
    for (0..3) |_| {
        const n = enc.encode(&pcm, &frame);
        try std.testing.expect(n > 7);
        try std.testing.expect(frame[0] == 0xFF and frame[1] == 0xF1);
        @memcpy(file[at..][0..n], frame[0..n]);
        at += n;
    }
    if (!sys.exists(io, "/usr/bin/ffmpeg")) return;
    std.Io.Dir.cwd().createDirPath(io, ".zig-cache") catch {};
    try sys.writeAll(io, ".zig-cache/aac-silence.aac", file[0..at]);
    const ran = try sys.run(gpa, io, &.{
        "/usr/bin/ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
        "-f",              "aac",  "-i", ".zig-cache/aac-silence.aac",
        "-f",              "s16le", "-ac", "2", "-ar", "48000", ".zig-cache/aac-silence.pcm",
    }, 20000, 4096);
    defer gpa.free(ran.stdout);
    defer gpa.free(ran.stderr);
    try std.testing.expect(ran.term_ok);
    const pcm_out = sys.readAll(io, gpa, ".zig-cache/aac-silence.pcm", 64 * 1024) orelse return error.TestUnexpectedResult;
    defer gpa.free(pcm_out);
    try std.testing.expect(pcm_out.len >= 4);
    var i: usize = 0;
    while (i + 1 < pcm_out.len) : (i += 2) {
        const s = std.mem.readInt(i16, pcm_out[i..][0..2], .little);
        try std.testing.expect(@abs(s) < 8);
    }
}

test "aac sine correlates" {
    const io = std.testing.io;
    if (!sys.exists(io, "/usr/bin/ffmpeg")) return;
    const gpa = std.testing.allocator;
    var enc = Encoder.init();
    var input: [8192]f32 = undefined;
    var file_buf: [64 * 1024]u8 = undefined;
    var at: usize = 0;
    var frame: [4096]u8 = undefined;
    var pcm: [2048]i16 = undefined;
    for (0..8) |frame_i| {
        for (0..1024) |i| {
            const n = frame_i * 1024 + i;
            const t = @as(f32, @floatFromInt(n)) / 48000.0;
            const s = @sin(2.0 * std.math.pi * 440.0 * t) * 8000.0;
            input[n] = s;
            const sample: i16 = @intFromFloat(s);
            pcm[i * 2] = sample;
            pcm[i * 2 + 1] = sample;
        }
        const n = enc.encode(&pcm, &frame);
        try std.testing.expect(n > 7);
        @memcpy(file_buf[at..][0..n], frame[0..n]);
        at += n;
    }
    std.Io.Dir.cwd().createDirPath(io, ".zig-cache") catch {};
    try sys.writeAll(io, ".zig-cache/aac-sine.aac", file_buf[0..at]);
    const ran = try sys.run(gpa, io, &.{
        "/usr/bin/ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
        "-f",              "aac",  "-i", ".zig-cache/aac-sine.aac",
        "-f",              "s16le", "-ac", "2", "-ar", "48000", ".zig-cache/aac-sine.pcm",
    }, 20000, 4096);
    defer gpa.free(ran.stdout);
    defer gpa.free(ran.stderr);
    if (!ran.term_ok) {
        std.debug.print("aac sine stderr {s}\n", .{ran.stderr});
        return error.TestUnexpectedResult;
    }
    const pcm_out = sys.readAll(io, gpa, ".zig-cache/aac-sine.pcm", 256 * 1024) orelse return error.TestUnexpectedResult;
    defer gpa.free(pcm_out);
    const samples = pcm_out.len / 4;
    var best: f32 = -2;
    for ([_]usize{ 0, 1024, 2048, 3072, 4096 }) |delay| {
        if (delay + 1024 > samples or delay + 1024 > input.len) continue;
        var dot: f32 = 0;
        var na: f32 = 0;
        var nb: f32 = 0;
        for (0..1024) |i| {
            const raw = std.mem.readInt(i16, pcm_out[(delay + i) * 4 ..][0..2], .little);
            const a: f32 = @floatFromInt(raw);
            const b = input[i];
            dot += a * b;
            na += a * a;
            nb += b * b;
        }
        const corr = dot / (@sqrt(na) * @sqrt(nb) + 1e-6);
        if (corr > best) best = corr;
        std.debug.print("aac sine delay {d} corr {d:.3}\n", .{ delay, corr });
    }
    try std.testing.expect(best > 0.5);
}
