const std = @import("std");
const sys = @import("sys.zig");

const luma_q = [_]u8{
    16, 11, 10, 16, 24, 40, 51, 61,
    12, 12, 14, 19, 26, 58, 60, 55,
    14, 13, 16, 24, 40, 57, 69, 56,
    14, 17, 22, 29, 51, 87, 80, 62,
    18, 22, 37, 56, 68, 109, 103, 77,
    24, 35, 55, 64, 81, 104, 113, 92,
    49, 64, 78, 87, 103, 121, 120, 101,
    72, 92, 95, 98, 112, 100, 103, 99,
};

const chroma_q = [_]u8{
    17, 18, 24, 47, 99, 99, 99, 99,
    18, 21, 26, 66, 99, 99, 99, 99,
    24, 26, 56, 99, 99, 99, 99, 99,
    47, 66, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
};

const zigzag = [_]u8{
    0,  1,  8,  16, 9,  2,  3,  10,
    17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
};

const luma_dc_bits = [_]u8{ 0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0 };
const luma_dc_vals = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
const chroma_dc_bits = [_]u8{ 0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0 };
const chroma_dc_vals = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
const luma_ac_bits = [_]u8{ 0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7d };
const luma_ac_vals = [_]u8{
    0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
    0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08, 0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0,
    0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0a, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28,
    0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
    0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
    0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
    0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7,
    0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5,
    0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2,
    0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
    0xf9, 0xfa,
};
const chroma_ac_bits = [_]u8{ 0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77 };
const chroma_ac_vals = [_]u8{
    0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71,
    0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91, 0xa1, 0xb1, 0xc1, 0x09, 0x23, 0x33, 0x52, 0xf0,
    0x15, 0x62, 0x72, 0xd1, 0x0a, 0x16, 0x24, 0x34, 0xe1, 0x25, 0xf1, 0x17, 0x18, 0x19, 0x1a, 0x26,
    0x27, 0x28, 0x29, 0x2a, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
    0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68,
    0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
    0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5,
    0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3,
    0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda,
    0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
    0xf9, 0xfa,
};

const Code = struct { bits: u16 = 0, len: u8 = 0 };

const Scan = struct {
    data: []u8,
    len: usize = 0,
    acc: u32 = 0,
    nbits: u8 = 0,
    overflow: bool = false,

    fn push(self: *Scan, byte: u8) void {
        if (self.len >= self.data.len) {
            self.overflow = true;
            return;
        }
        self.data[self.len] = byte;
        self.len += 1;
    }

    fn put(self: *Scan, value: u32, n: u32) void {
        if (n == 0 or self.overflow) return;
        var left = n;
        while (left > 0) {
            left -= 1;
            self.acc = (self.acc << 1) | ((value >> @intCast(left)) & 1);
            self.nbits += 1;
            if (self.nbits == 8) {
                const byte: u8 = @intCast(self.acc & 0xFF);
                self.acc = 0;
                self.nbits = 0;
                self.push(byte);
                if (byte == 0xFF) self.push(0);
            }
        }
    }

    fn pad(self: *Scan) void {
        if (self.nbits == 0 or self.overflow) return;
        const left: u8 = 8 - self.nbits;
        self.acc = (self.acc << @intCast(left)) | ((@as(u32, 1) << @intCast(left)) - 1);
        const byte: u8 = @intCast(self.acc & 0xFF);
        self.acc = 0;
        self.nbits = 0;
        self.push(byte);
        if (byte == 0xFF) self.push(0);
    }
};

pub fn encodeBgra(gpa: std.mem.Allocator, pixels: []const u8, width: u32, height: u32, stride: usize) ![]u8 {
    if (width == 0 or height == 0 or width > 8192 or height > 8192) return error.BadSize;
    const cap = @as(usize, width) * @as(usize, height) + 65536;
    const buf = try gpa.alloc(u8, cap);
    errdefer gpa.free(buf);
    const n = writeJpeg(buf, pixels, width, height, stride) orelse {
        gpa.free(buf);
        return error.Overflow;
    };
    const out = try gpa.alloc(u8, n);
    @memcpy(out, buf[0..n]);
    gpa.free(buf);
    return out;
}

fn writeJpeg(buf: []u8, pixels: []const u8, width: u32, height: u32, stride: usize) ?usize {
    var yq: [64]u8 = undefined;
    var cq: [64]u8 = undefined;
    const s: u32 = 40;
    for (0..64) |i| {
        yq[i] = scaleQ(luma_q[i], s);
        cq[i] = scaleQ(chroma_q[i], s);
    }
    var ldc: [12]Code = undefined;
    var cdc: [12]Code = undefined;
    var lac: [256]Code = undefined;
    var cac: [256]Code = undefined;
    @memset(&lac, .{});
    @memset(&cac, .{});
    build(&ldc, &luma_dc_bits, &luma_dc_vals);
    build(&cdc, &chroma_dc_bits, &chroma_dc_vals);
    build(&lac, &luma_ac_bits, &luma_ac_vals);
    build(&cac, &chroma_ac_bits, &chroma_ac_vals);

    var n: usize = 0;
    const head = [_]u8{
        0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 'J', 'F', 'I', 'F', 0, 1, 1, 0, 0, 1, 0, 1, 0, 0,
    };
    if (!copy(buf, &n, &head)) return null;
    if (!writeDqt(buf, &n, &yq, &cq)) return null;
    if (!writeSof(buf, &n, width, height)) return null;
    if (!writeDht(buf, &n)) return null;
    if (!writeSos(buf, &n)) return null;

    var scan = Scan{ .data = buf[n..] };
    var ydc: i32 = 0;
    var cdc_v: i32 = 0;
    var crdc: i32 = 0;
    var my: u32 = 0;
    while (my < height) : (my += 16) {
        var mx: u32 = 0;
        while (mx < width) : (mx += 16) {
            inline for ([_]u32{ 0, 1, 0, 1 }, [_]u32{ 0, 0, 1, 1 }) |ox, oy| {
                var block: [64]f32 = undefined;
                var k: usize = 0;
                while (k < 64) : (k += 1) {
                    const x = mx + ox * 8 + @as(u32, @intCast(k & 7));
                    const y = my + oy * 8 + @as(u32, @intCast(k >> 3));
                    block[k] = @floatFromInt(@as(i32, sampleY(pixels, width, height, stride, x, y)) - 128);
                }
                ydc = encodeBlock(&scan, &block, &yq, &ldc, &lac, ydc);
            }
            var cb: [64]f32 = undefined;
            var cr: [64]f32 = undefined;
            fillChroma(pixels, width, height, stride, mx, my, &cb, &cr);
            cdc_v = encodeBlock(&scan, &cb, &cq, &cdc, &cac, cdc_v);
            crdc = encodeBlock(&scan, &cr, &cq, &cdc, &cac, crdc);
            if (scan.overflow) return null;
        }
    }
    scan.pad();
    if (scan.overflow) return null;
    n += scan.len;
    if (!copy(buf, &n, &[_]u8{ 0xFF, 0xD9 })) return null;
    return n;
}

fn sampleY(pixels: []const u8, width: u32, height: u32, stride: usize, x: u32, y: u32) u8 {
    const xx = @min(x, width - 1);
    const yy = @min(y, height - 1);
    const p = pixels[yy * stride + xx * 4 ..][0..4];
    return yOf(p[2], p[1], p[0]);
}

fn fillChroma(pixels: []const u8, width: u32, height: u32, stride: usize, mx: u32, my: u32, cb: *[64]f32, cr: *[64]f32) void {
    var k: usize = 0;
    while (k < 64) : (k += 1) {
        const cx: u32 = @intCast(k & 7);
        const cy: u32 = @intCast(k >> 3);
        var rs: i32 = 0;
        var gs: i32 = 0;
        var bs: i32 = 0;
        var dy: u32 = 0;
        while (dy < 2) : (dy += 1) {
            var dx: u32 = 0;
            while (dx < 2) : (dx += 1) {
                const x = @min(mx + cx * 2 + dx, width - 1);
                const y = @min(my + cy * 2 + dy, height - 1);
                const p = pixels[y * stride + x * 4 ..][0..4];
                rs += p[2];
                gs += p[1];
                bs += p[0];
            }
        }
        const r: u8 = @intCast(@divTrunc(rs, 4));
        const g: u8 = @intCast(@divTrunc(gs, 4));
        const b: u8 = @intCast(@divTrunc(bs, 4));
        cb[k] = @floatFromInt(@as(i32, cbOf(r, g, b)) - 128);
        cr[k] = @floatFromInt(@as(i32, crOf(r, g, b)) - 128);
    }
}

fn yOf(r: u8, g: u8, b: u8) u8 {
    const v = (19595 * @as(i32, r) + 38470 * @as(i32, g) + 7471 * @as(i32, b)) >> 16;
    return sat(v);
}

fn cbOf(r: u8, g: u8, b: u8) u8 {
    const v = ((-11059 * @as(i32, r) - 21709 * @as(i32, g) + 32768 * @as(i32, b)) >> 16) + 128;
    return sat(v);
}

fn crOf(r: u8, g: u8, b: u8) u8 {
    const v = ((32768 * @as(i32, r) - 27439 * @as(i32, g) - 5329 * @as(i32, b)) >> 16) + 128;
    return sat(v);
}

fn sat(v: i32) u8 {
    if (v < 0) return 0;
    if (v > 255) return 255;
    return @intCast(v);
}

fn encodeBlock(scan: *Scan, pix: *const [64]f32, q: *const [64]u8, dc_tab: []const Code, ac_tab: []const Code, prev_dc: i32) i32 {
    var coef: [64]f32 = undefined;
    dct(pix, &coef);
    var level: [64]i32 = undefined;
    for (0..64) |i| {
        const d = coef[i] / @as(f32, @floatFromInt(q[i]));
        level[i] = @intFromFloat(@round(d));
    }
    const diff = level[0] - prev_dc;
    writeDc(scan, diff, dc_tab);
    var run: u32 = 0;
    var k: usize = 1;
    while (k < 64) : (k += 1) {
        const v = level[zigzag[k]];
        if (v == 0) {
            run += 1;
            continue;
        }
        while (run >= 16) : (run -= 16) writeAc(scan, 0xF0, 0, ac_tab);
        const c = category(v);
        writeAc(scan, (run << 4) | c, v, ac_tab);
        run = 0;
    }
    if (run > 0) writeAc(scan, 0, 0, ac_tab);
    return level[0];
}

fn writeDc(scan: *Scan, diff: i32, tab: []const Code) void {
    const c = category(diff);
    if (c >= tab.len or tab[c].len == 0) {
        scan.overflow = true;
        return;
    }
    scan.put(tab[c].bits, tab[c].len);
    if (c > 0) scan.put(magBits(diff, c), c);
}

fn writeAc(scan: *Scan, symbol: u32, value: i32, tab: []const Code) void {
    if (symbol >= tab.len or tab[symbol].len == 0) {
        scan.overflow = true;
        return;
    }
    scan.put(tab[symbol].bits, tab[symbol].len);
    const c = symbol & 0x0F;
    if (c > 0) scan.put(magBits(value, c), c);
}

fn category(v: i32) u32 {
    var m: u32 = if (v < 0) @intCast(-v) else @intCast(v);
    var c: u32 = 0;
    while (m > 0) : (m >>= 1) c += 1;
    return c;
}

fn magBits(v: i32, cat: u32) u32 {
    if (cat == 0) return 0;
    if (v >= 0) return @intCast(v);
    const mask = (@as(i32, 1) << @intCast(cat)) - 1;
    return @intCast((v - 1) & mask);
}

fn dct(pix: *const [64]f32, coef: *[64]f32) void {
    var tmp: [64]f32 = undefined;
    for (0..8) |y| {
        for (0..8) |u| {
            var sum: f32 = 0;
            for (0..8) |x| {
                const ang = (2.0 * @as(f32, @floatFromInt(x)) + 1.0) * @as(f32, @floatFromInt(u)) * std.math.pi / 16.0;
                sum += pix[y * 8 + x] * @cos(ang);
            }
            const c: f32 = if (u == 0) 0.3535533905932738 else 0.5;
            tmp[y * 8 + u] = sum * c;
        }
    }
    for (0..8) |u| {
        for (0..8) |v| {
            var sum: f32 = 0;
            for (0..8) |y| {
                const ang = (2.0 * @as(f32, @floatFromInt(y)) + 1.0) * @as(f32, @floatFromInt(v)) * std.math.pi / 16.0;
                sum += tmp[y * 8 + u] * @cos(ang);
            }
            const c: f32 = if (v == 0) 0.3535533905932738 else 0.5;
            coef[v * 8 + u] = sum * c;
        }
    }
}

fn scaleQ(base: u8, s: u32) u8 {
    var v = (@as(u32, base) * s + 50) / 100;
    if (v < 1) v = 1;
    if (v > 255) v = 255;
    return @intCast(v);
}

fn build(out: []Code, bits: *const [16]u8, vals: []const u8) void {
    var code: u32 = 0;
    var vi: usize = 0;
    for (bits, 0..) |count, li| {
        const len: u8 = @intCast(li + 1);
        var c: u8 = 0;
        while (c < count) : (c += 1) {
            out[vals[vi]] = .{ .bits = @intCast(code), .len = len };
            code += 1;
            vi += 1;
        }
        code <<= 1;
    }
}

fn copy(buf: []u8, n: *usize, bytes: []const u8) bool {
    if (n.* + bytes.len > buf.len) return false;
    @memcpy(buf[n.*..][0..bytes.len], bytes);
    n.* += bytes.len;
    return true;
}

fn put16(buf: []u8, n: *usize, v: u16) bool {
    const b = [_]u8{ @intCast(v >> 8), @intCast(v & 0xFF) };
    return copy(buf, n, &b);
}

fn writeDqt(buf: []u8, n: *usize, yq: *const [64]u8, cq: *const [64]u8) bool {
    if (!copy(buf, n, &[_]u8{ 0xFF, 0xDB })) return false;
    if (!put16(buf, n, 132)) return false;
    if (!copy(buf, n, &[_]u8{0})) return false;
    for (zigzag) |pos| if (!copy(buf, n, yq[pos .. pos + 1])) return false;
    if (!copy(buf, n, &[_]u8{1})) return false;
    for (zigzag) |pos| if (!copy(buf, n, cq[pos .. pos + 1])) return false;
    return true;
}

fn writeSof(buf: []u8, n: *usize, width: u32, height: u32) bool {
    if (!copy(buf, n, &[_]u8{ 0xFF, 0xC0 })) return false;
    if (!put16(buf, n, 17)) return false;
    if (!copy(buf, n, &[_]u8{8})) return false;
    if (!put16(buf, n, @intCast(height))) return false;
    if (!put16(buf, n, @intCast(width))) return false;
    return copy(buf, n, &[_]u8{ 3, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1 });
}

fn writeDht(buf: []u8, n: *usize) bool {
    var body: [420]u8 = undefined;
    var bn: usize = 0;
    if (!dhtTable(&body, &bn, 0x00, &luma_dc_bits, &luma_dc_vals)) return false;
    if (!dhtTable(&body, &bn, 0x10, &luma_ac_bits, &luma_ac_vals)) return false;
    if (!dhtTable(&body, &bn, 0x01, &chroma_dc_bits, &chroma_dc_vals)) return false;
    if (!dhtTable(&body, &bn, 0x11, &chroma_ac_bits, &chroma_ac_vals)) return false;
    if (!copy(buf, n, &[_]u8{ 0xFF, 0xC4 })) return false;
    if (!put16(buf, n, @intCast(bn + 2))) return false;
    return copy(buf, n, body[0..bn]);
}

fn dhtTable(buf: []u8, n: *usize, class: u8, bits: *const [16]u8, vals: []const u8) bool {
    if (n.* >= buf.len) return false;
    buf[n.*] = class;
    n.* += 1;
    if (!copy(buf, n, bits)) return false;
    return copy(buf, n, vals);
}

fn writeSos(buf: []u8, n: *usize) bool {
    if (!copy(buf, n, &[_]u8{ 0xFF, 0xDA })) return false;
    if (!put16(buf, n, 12)) return false;
    return copy(buf, n, &[_]u8{ 3, 1, 0x00, 2, 0x11, 3, 0x11, 0, 63, 0 });
}

fn average(rgb: []const u8) struct { r: i32, g: i32, b: i32 } {
    var r: i32 = 0;
    var g: i32 = 0;
    var b: i32 = 0;
    var n: i32 = 0;
    var i: usize = 0;
    while (i + 2 < rgb.len) : (i += 3) {
        r += rgb[i];
        g += rgb[i + 1];
        b += rgb[i + 2];
        n += 1;
    }
    return .{ .r = @divTrunc(r, n), .g = @divTrunc(g, n), .b = @divTrunc(b, n) };
}

test "jpeg gray decodes" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var pixels: [32 * 32 * 4]u8 = undefined;
    var i: usize = 0;
    while (i < pixels.len) : (i += 4) {
        pixels[i] = 128;
        pixels[i + 1] = 128;
        pixels[i + 2] = 128;
        pixels[i + 3] = 255;
    }
    const jpg = try encodeBgra(gpa, &pixels, 32, 32, 32 * 4);
    defer gpa.free(jpg);
    try std.testing.expect(jpg.len > 4 and jpg[0] == 0xFF and jpg[1] == 0xD8);
    if (!sys.exists(io, "/usr/bin/ffmpeg")) return;
    std.Io.Dir.cwd().createDirPath(io, ".zig-cache") catch {};
    try sys.writeAll(io, ".zig-cache/jpeg-gray.jpg", jpg);
    const ran = try sys.run(gpa, io, &.{
        "/usr/bin/ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
        "-i",              ".zig-cache/jpeg-gray.jpg",
        "-f",              "rawvideo", "-pix_fmt", "rgb24", ".zig-cache/jpeg-gray.rgb",
    }, 20000, 4096);
    defer gpa.free(ran.stdout);
    defer gpa.free(ran.stderr);
    try std.testing.expect(ran.term_ok);
    const rgb = sys.readAll(io, gpa, ".zig-cache/jpeg-gray.rgb", 64 * 1024) orelse return error.TestUnexpectedResult;
    defer gpa.free(rgb);
    const avg = average(rgb);
    try std.testing.expect(avg.r > 120 and avg.r < 136);
    try std.testing.expect(avg.g > 120 and avg.g < 136);
    try std.testing.expect(avg.b > 120 and avg.b < 136);
}

test "jpeg red and blue stay apart" {
    const io = std.testing.io;
    if (!sys.exists(io, "/usr/bin/ffmpeg")) return;
    const gpa = std.testing.allocator;
    var pixels: [32 * 32 * 4]u8 = undefined;
    for (0..32) |y| {
        for (0..32) |x| {
            const p = pixels[y * 128 + x * 4 ..][0..4];
            if (x < 16) {
                p[0] = 0;
                p[1] = 0;
                p[2] = 255;
            } else {
                p[0] = 255;
                p[1] = 0;
                p[2] = 0;
            }
            p[3] = 255;
        }
    }
    const jpg = try encodeBgra(gpa, &pixels, 32, 32, 128);
    defer gpa.free(jpg);
    std.Io.Dir.cwd().createDirPath(io, ".zig-cache") catch {};
    try sys.writeAll(io, ".zig-cache/jpeg-color.jpg", jpg);
    const ran = try sys.run(gpa, io, &.{
        "/usr/bin/ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
        "-i",              ".zig-cache/jpeg-color.jpg",
        "-f",              "rawvideo", "-pix_fmt", "rgb24", ".zig-cache/jpeg-color.rgb",
    }, 20000, 4096);
    defer gpa.free(ran.stdout);
    defer gpa.free(ran.stderr);
    try std.testing.expect(ran.term_ok);
    const rgb = sys.readAll(io, gpa, ".zig-cache/jpeg-color.rgb", 64 * 1024) orelse return error.TestUnexpectedResult;
    defer gpa.free(rgb);
    var lr: i32 = 0;
    var lb: i32 = 0;
    var rr: i32 = 0;
    var rb: i32 = 0;
    for (0..32) |y| {
        for (0..8) |x| {
            const p = rgb[(y * 32 + x) * 3 ..][0..3];
            lr += p[0];
            lb += p[2];
        }
        for (24..32) |x| {
            const p = rgb[(y * 32 + x) * 3 ..][0..3];
            rr += p[0];
            rb += p[2];
        }
    }
    try std.testing.expect(lr > lb + 4000);
    try std.testing.expect(rb > rr + 4000);
}
