const std = @import("std");
const tab = @import("h264tab.zig");
const sys = @import("sys.zig");

const qp: i32 = 26;
const qp_per: u6 = 4;
const qp_rem: usize = 2;
const zigzag = [_]usize{ 0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15 };
// H.264 luma 4x4 index order. Raster order makes the decoder read coeff_token with the wrong nC.
const blk_x = [_]usize{ 0, 1, 0, 1, 2, 3, 2, 3, 0, 1, 0, 1, 2, 3, 2, 3 };
const blk_y = [_]usize{ 0, 0, 1, 1, 0, 0, 1, 1, 2, 2, 3, 3, 2, 2, 3, 3 };

fn blkAt(sx: usize, sy: usize) usize {
    const map = [_]usize{
        0, 1,  4,  5,
        2, 3,  6,  7,
        8, 9,  12, 13,
        10, 11, 14, 15,
    };
    return map[sy * 4 + sx];
}

const quant_mf = [_][3]i64{
    .{ 13107, 5243, 8066 },
    .{ 11916, 4660, 7490 },
    .{ 10082, 4194, 6554 },
    .{ 9362, 3647, 5825 },
    .{ 8192, 3355, 5243 },
    .{ 7282, 2893, 4559 },
};
const dequant_mf = [_][3]i32{
    .{ 10, 16, 13 },
    .{ 11, 18, 14 },
    .{ 13, 20, 16 },
    .{ 14, 23, 18 },
    .{ 16, 25, 20 },
    .{ 18, 29, 23 },
};

pub const Au = struct {
    len: usize,
    key: bool,
};

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

    fn ue(self: *Bits, v: u32) void {
        const x = v +% 1;
        if (x == 0) {
            self.overflow = true;
            return;
        }
        const width: u32 = 32 - @clz(x);
        self.put(0, width - 1);
        self.put(x, width);
    }

    fn se(self: *Bits, v: i32) void {
        const mag: u32 = if (v < 0) @intCast(-v) else @intCast(v);
        const code: u32 = if (v > 0) (mag << 1) - 1 else mag << 1;
        self.ue(code);
    }

    fn trailing(self: *Bits) void {
        self.put(1, 1);
        while ((self.bit & 7) != 0) self.put(0, 1);
    }

    fn len(self: *const Bits) usize {
        return self.bit >> 3;
    }
};

pub const Encoder = struct {
    gpa: std.mem.Allocator,
    width: u32,
    height: u32,
    coded_w: u32,
    coded_h: u32,
    fps: u32,
    gop: u32,
    frame_num: u32 = 0,
    idr_id: u32 = 0,
    count: u32 = 0,
    has_ref: bool = false,
    mb_w: u32,
    mb_h: u32,
    slab: []u8,
    src_y: []u8,
    src_u: []u8,
    src_v: []u8,
    rec_y: []u8,
    rec_u: []u8,
    rec_v: []u8,
    ref_y: []u8,
    ref_u: []u8,
    ref_v: []u8,
    nnz_y: []u8,
    nnz_dc: []u8,
    nnz_u: []u8,
    nnz_v: []u8,
    scratch: []u8,

    pub fn init(gpa: std.mem.Allocator, width: u32, height: u32, fps: u32) !*Encoder {
        if (width == 0 or height == 0 or width > 4096 or height > 4096) return error.BadSize;
        if ((width & 1) != 0 or (height & 1) != 0) return error.BadSize;
        const cw = (width + 15) & ~@as(u32, 15);
        const ch = (height + 15) & ~@as(u32, 15);
        const y_n: usize = @as(usize, cw) * ch;
        const c_n: usize = @as(usize, cw / 2) * (ch / 2);
        const mb_n: usize = @as(usize, cw / 16) * (ch / 16);
        const slab_n = y_n * 3 + c_n * 6 + mb_n * 25;
        const self = try gpa.create(Encoder);
        errdefer gpa.destroy(self);
        const slab = try gpa.alloc(u8, slab_n);
        errdefer gpa.free(slab);
        @memset(slab, 0);
        const scratch_n = @min(@as(usize, 4 * 1024 * 1024), @max(@as(usize, 256 * 1024), y_n));
        const scratch = try gpa.alloc(u8, scratch_n);
        errdefer gpa.free(scratch);
        var at: usize = 0;
        const src_y = slab[at..][0..y_n];
        at += y_n;
        const rec_y = slab[at..][0..y_n];
        at += y_n;
        const ref_y = slab[at..][0..y_n];
        at += y_n;
        const src_u = slab[at..][0..c_n];
        at += c_n;
        const src_v = slab[at..][0..c_n];
        at += c_n;
        const rec_u = slab[at..][0..c_n];
        at += c_n;
        const rec_v = slab[at..][0..c_n];
        at += c_n;
        const ref_u = slab[at..][0..c_n];
        at += c_n;
        const ref_v = slab[at..][0..c_n];
        at += c_n;
        const nnz_y = slab[at..][0..mb_n * 16];
        at += mb_n * 16;
        const nnz_dc = slab[at..][0..mb_n];
        at += mb_n;
        const nnz_u = slab[at..][0..mb_n * 4];
        at += mb_n * 4;
        const nnz_v = slab[at..][0..mb_n * 4];
        const rate: u32 = if (fps == 0) 30 else fps;
        self.* = .{
            .gpa = gpa,
            .width = width,
            .height = height,
            .coded_w = cw,
            .coded_h = ch,
            .fps = rate,
            .gop = @max(rate / 2, 2),
            .mb_w = cw / 16,
            .mb_h = ch / 16,
            .slab = slab,
            .src_y = src_y,
            .src_u = src_u,
            .src_v = src_v,
            .rec_y = rec_y,
            .rec_u = rec_u,
            .rec_v = rec_v,
            .ref_y = ref_y,
            .ref_u = ref_u,
            .ref_v = ref_v,
            .nnz_y = nnz_y,
            .nnz_dc = nnz_dc,
            .nnz_u = nnz_u,
            .nnz_v = nnz_v,
            .scratch = scratch,
        };
        return self;
    }

    pub fn deinit(self: *Encoder) void {
        self.gpa.free(self.scratch);
        self.gpa.free(self.slab);
        self.gpa.destroy(self);
    }

    pub fn encodePlanes(
        self: *Encoder,
        y: []const u8,
        ys: usize,
        u: []const u8,
        us: usize,
        v: []const u8,
        vs: usize,
        out: []u8,
    ) !Au {
        loadPlane(self.src_y, self.coded_w, self.coded_h, y, self.width, self.height, ys);
        loadPlane(self.src_u, self.coded_w / 2, self.coded_h / 2, u, self.width / 2, self.height / 2, us);
        loadPlane(self.src_v, self.coded_w / 2, self.coded_h / 2, v, self.width / 2, self.height / 2, vs);
        return self.encodeLoaded(out);
    }

    pub fn encodeBgra(self: *Encoder, pixels: []const u8, stride: usize, out: []u8) !Au {
        const w = self.width;
        const h = self.height;
        const cw = self.coded_w;
        const ch = self.coded_h;
        var row: usize = 0;
        while (row < h) : (row += 1) {
            var col: usize = 0;
            while (col < w) : (col += 1) {
                const p = pixels[row * stride + col * 4 ..][0..4];
                self.src_y[row * cw + col] = yOf(p[2], p[1], p[0]);
            }
            var colp = w;
            while (colp < cw) : (colp += 1) self.src_y[row * cw + colp] = self.src_y[row * cw + w - 1];
        }
        var ypad = h;
        while (ypad < ch) : (ypad += 1) {
            @memcpy(self.src_y[ypad * cw ..][0..cw], self.src_y[(h - 1) * cw ..][0..cw]);
        }
        const cw2 = cw / 2;
        const ch2 = ch / 2;
        var cy: usize = 0;
        while (cy < h / 2) : (cy += 1) {
            var cx: usize = 0;
            while (cx < w / 2) : (cx += 1) {
                var cb: i32 = 0;
                var cr: i32 = 0;
                for (0..2) |dy| {
                    for (0..2) |dx| {
                        const p = pixels[(cy * 2 + dy) * stride + (cx * 2 + dx) * 4 ..][0..4];
                        cb += cbOf(p[2], p[1], p[0]);
                        cr += crOf(p[2], p[1], p[0]);
                    }
                }
                self.src_u[cy * cw2 + cx] = @intCast(@divTrunc(cb + 2, 4));
                self.src_v[cy * cw2 + cx] = @intCast(@divTrunc(cr + 2, 4));
            }
            var cxp = w / 2;
            while (cxp < cw2) : (cxp += 1) {
                self.src_u[cy * cw2 + cxp] = self.src_u[cy * cw2 + w / 2 - 1];
                self.src_v[cy * cw2 + cxp] = self.src_v[cy * cw2 + w / 2 - 1];
            }
        }
        var cpad = h / 2;
        while (cpad < ch2) : (cpad += 1) {
            @memcpy(self.src_u[cpad * cw2 ..][0..cw2], self.src_u[(h / 2 - 1) * cw2 ..][0..cw2]);
            @memcpy(self.src_v[cpad * cw2 ..][0..cw2], self.src_v[(h / 2 - 1) * cw2 ..][0..cw2]);
        }
        return self.encodeLoaded(out);
    }

    fn encodeLoaded(self: *Encoder, out: []u8) !Au {
        const key = self.count % self.gop == 0;
        var n: usize = 0;
        if (key) {
            var raw: [128]u8 = undefined;
            @memset(&raw, 0);
            var bits = Bits{ .data = &raw };
            writeSps(self, &bits);
            if (bits.overflow) return error.Overflow;
            bits.trailing();
            if (!putNal(out, &n, 7, raw[0..bits.len()])) return error.Overflow;
            @memset(raw[0..], 0);
            bits = .{ .data = &raw };
            writePps(&bits);
            if (bits.overflow) return error.Overflow;
            bits.trailing();
            if (!putNal(out, &n, 8, raw[0..bits.len()])) return error.Overflow;
        }
        @memset(self.scratch, 0);
        var slice = Bits{ .data = self.scratch };
        try self.writeSlice(&slice, key);
        if (slice.overflow) return error.Overflow;
        slice.trailing();
        if (slice.overflow) return error.Overflow;
        const nal: u8 = if (key) 5 else 1;
        if (!putNal(out, &n, nal, self.scratch[0..slice.len()])) return error.Overflow;
        if (key) {
            self.frame_num = 1;
            self.idr_id +%= 1;
        } else {
            self.frame_num = (self.frame_num + 1) & 255;
        }
        std.mem.swap([]u8, &self.rec_y, &self.ref_y);
        std.mem.swap([]u8, &self.rec_u, &self.ref_u);
        std.mem.swap([]u8, &self.rec_v, &self.ref_v);
        self.has_ref = true;
        self.count += 1;
        return .{ .len = n, .key = key };
    }

    fn writeSlice(self: *Encoder, bits: *Bits, key: bool) !void {
        bits.ue(0);
        bits.ue(if (key) 7 else 5);
        bits.ue(0);
        bits.put(if (key) 0 else self.frame_num, 8);
        if (key) {
            bits.ue(self.idr_id & 15);
            bits.put(0, 1);
            bits.put(0, 1);
        } else {
            bits.put(0, 1);
            bits.put(0, 1);
            bits.put(0, 1);
        }
        bits.se(0);
        bits.ue(1);
        var run: u32 = 0;
        var mby: u32 = 0;
        while (mby < self.mb_h) : (mby += 1) {
            var mbx: u32 = 0;
            while (mbx < self.mb_w) : (mbx += 1) {
                const skip = !key and self.has_ref and self.quiet(mbx, mby);
                if (skip) {
                    self.copyMb(mbx, mby);
                    run += 1;
                    continue;
                }
                if (!key) {
                    bits.ue(run);
                    run = 0;
                }
                self.codeMb(bits, mbx, mby, key);
                if (bits.overflow) return error.Overflow;
            }
        }
        if (!key and run > 0) bits.ue(run);
    }

    fn quiet(self: *const Encoder, mbx: u32, mby: u32) bool {
        return sad16(self.src_y, self.ref_y, self.coded_w, mbx * 16, mby * 16) <= 192;
    }

    fn copyMb(self: *Encoder, mbx: u32, mby: u32) void {
        const mb = @as(usize, mby) * self.mb_w + mbx;
        @memset(self.nnz_y[mb * 16 ..][0..16], 0);
        self.nnz_dc[mb] = 0;
        @memset(self.nnz_u[mb * 4 ..][0..4], 0);
        @memset(self.nnz_v[mb * 4 ..][0..4], 0);
        const x = @as(usize, mbx) * 16;
        const y = @as(usize, mby) * 16;
        const stride = @as(usize, self.coded_w);
        for (0..16) |row| {
            const at = (y + row) * stride + x;
            @memcpy(self.rec_y[at..][0..16], self.ref_y[at..][0..16]);
        }
        const cx = @as(usize, mbx) * 8;
        const cy = @as(usize, mby) * 8;
        const cs = @as(usize, self.coded_w / 2);
        for (0..8) |row| {
            const at = (cy + row) * cs + cx;
            @memcpy(self.rec_u[at..][0..8], self.ref_u[at..][0..8]);
            @memcpy(self.rec_v[at..][0..8], self.ref_v[at..][0..8]);
        }
    }

    fn codeMb(self: *Encoder, bits: *Bits, mbx: u32, mby: u32, key: bool) void {
        const mb = @as(usize, mby) * self.mb_w + mbx;
        const pred = predDc(self.rec_y, self.coded_w, mbx, mby, 16);
        var dc_in: [16]i32 = undefined;
        var ac: [16][16]i32 = undefined;
        const stride = @as(usize, self.coded_w);
        const x0 = @as(usize, mbx) * 16;
        const y0 = @as(usize, mby) * 16;
        for (0..16) |blk| {
            const bx = blk_x[blk] * 4;
            const by = blk_y[blk] * 4;
            var pix: [16]i32 = undefined;
            for (0..4) |row| {
                for (0..4) |col| {
                    const sample = self.src_y[(y0 + by + row) * stride + x0 + bx + col];
                    pix[row * 4 + col] = @as(i32, sample) - pred;
                }
            }
            var coeff: [16]i32 = undefined;
            fwd4(&pix, &coeff);
            dc_in[blk_y[blk] * 4 + blk_x[blk]] = coeff[0];
            for (1..16) |i| ac[blk][i] = quantAc(coeff[i], qcls(i));
            ac[blk][0] = 0;
        }
        var had: [16]i32 = undefined;
        hadamard4(&dc_in, &had);
        var dc_level: [16]i32 = undefined;
        for (0..16) |i| dc_level[i] = quantDc((had[i] + 1) >> 1);
        var dc_spread: [16]i32 = undefined;
        hadamard4(&dc_level, &dc_spread);
        for (&dc_spread) |*v| v.* = scaleLumaDc(v.*);

        var cbp_luma: u32 = 0;
        for (0..16) |blk| {
            var nnz: u8 = 0;
            var recon: [16]i32 = undefined;
            var freq: [16]i32 = undefined;
            for (1..16) |i| {
                if (ac[blk][i] != 0) {
                    cbp_luma = 1;
                    nnz += 1;
                }
                freq[i] = dequantAc(ac[blk][i], qcls(i));
            }
            freq[0] = dc_spread[blk_y[blk] * 4 + blk_x[blk]];
            inv4(&freq, &recon);
            const bx = blk_x[blk] * 4;
            const by = blk_y[blk] * 4;
            for (0..4) |row| {
                for (0..4) |col| {
                    self.rec_y[(y0 + by + row) * stride + x0 + bx + col] = clip8(pred + recon[row * 4 + col]);
                }
            }
            self.nnz_y[mb * 16 + blk] = nnz;
        }
        var dc_nnz: u8 = 0;
        for (dc_level) |v| {
            if (v != 0) dc_nnz += 1;
        }
        self.nnz_dc[mb] = dc_nnz;

        const cu = self.codeChroma(mb, mbx, mby, self.src_u, self.rec_u, self.nnz_u);
        const cv = self.codeChroma(mb, mbx, mby, self.src_v, self.rec_v, self.nnz_v);
        var cbp_c: u32 = 0;
        if (cu.dc or cv.dc) cbp_c = 1;
        if (cu.ac or cv.ac) cbp_c = 2;

        const mode: u32 = 2;
        const mb_type: u32 = (if (key) @as(u32, 1) else 6) + mode + cbp_c * 4 + cbp_luma * 12;
        bits.ue(mb_type);
        bits.ue(0);
        bits.se(0);

        var scan_dc: [16]i32 = undefined;
        for (0..16) |i| scan_dc[i] = dc_level[zigzag[i]];
        writeResidual(bits, &scan_dc, self.dcNc(mb, mbx, mby), false);
        if (cbp_luma != 0) {
            for (0..16) |blk| {
                var scan: [15]i32 = undefined;
                for (1..16) |i| scan[i - 1] = ac[blk][zigzag[i]];
                writeResidual(bits, &scan, self.acNc(mb, blk, mbx, mby), false);
            }
        }
        if (cbp_c != 0) {
            writeResidual(bits, &cu.dc_scan, -1, true);
            writeResidual(bits, &cv.dc_scan, -1, true);
            if (cbp_c == 2) {
                for (0..4) |blk| writeResidual(bits, &cu.ac_scan[blk], self.chromaNc(self.nnz_u, mb, blk, mbx, mby), false);
                for (0..4) |blk| writeResidual(bits, &cv.ac_scan[blk], self.chromaNc(self.nnz_v, mb, blk, mbx, mby), false);
            }
        }
    }

    const ChromaCode = struct {
        dc: bool,
        ac: bool,
        dc_scan: [4]i32,
        ac_scan: [4][15]i32,
    };

    fn codeChroma(self: *Encoder, mb: usize, mbx: u32, mby: u32, src: []u8, rec: []u8, nnz: []u8) ChromaCode {
        const pred: i32 = predDc(rec, self.coded_w / 2, mbx, mby, 8);
        const cs = @as(usize, self.coded_w / 2);
        const x0 = @as(usize, mbx) * 8;
        const y0 = @as(usize, mby) * 8;
        var dc_in: [4]i32 = undefined;
        var ac: [4][16]i32 = undefined;
        for (0..4) |blk| {
            const bx = (blk % 2) * 4;
            const by = (blk / 2) * 4;
            var pix: [16]i32 = undefined;
            for (0..4) |row| {
                for (0..4) |col| {
                    const sample = src[(y0 + by + row) * cs + x0 + bx + col];
                    pix[row * 4 + col] = @as(i32, sample) - pred;
                }
            }
            var coeff: [16]i32 = undefined;
            fwd4(&pix, &coeff);
            dc_in[blk] = coeff[0];
            for (1..16) |i| ac[blk][i] = quantAc(coeff[i], qcls(i));
            ac[blk][0] = 0;
        }
        const h = hadamard2(dc_in[0], dc_in[1], dc_in[2], dc_in[3]);
        var dc_level: [4]i32 = undefined;
        var dc_scaled: [4]i32 = undefined;
        for (0..4) |i| {
            dc_level[i] = quantChromaDc(h[i]);
            dc_scaled[i] = dequantChromaDc(dc_level[i]);
        }
        const back = hadamard2(dc_scaled[0], dc_scaled[1], dc_scaled[2], dc_scaled[3]);
        var out = ChromaCode{
            .dc = false,
            .ac = false,
            .dc_scan = dc_level,
            .ac_scan = undefined,
        };
        for (dc_level) |v| if (v != 0) {
            out.dc = true;
        };
        for (0..4) |blk| {
            var freq: [16]i32 = undefined;
            var recon: [16]i32 = undefined;
            var nnz_n: u8 = 0;
            for (1..16) |i| {
                if (ac[blk][i] != 0) {
                    out.ac = true;
                    nnz_n += 1;
                }
                freq[i] = dequantAc(ac[blk][i], qcls(i));
                if (i < 16) {}
            }
            for (1..16) |i| out.ac_scan[blk][i - 1] = ac[blk][zigzag[i]];
            freq[0] = back[blk];
            inv4(&freq, &recon);
            const bx = (blk % 2) * 4;
            const by = (blk / 2) * 4;
            for (0..4) |row| {
                for (0..4) |col| {
                    rec[(y0 + by + row) * cs + x0 + bx + col] = clip8(pred + recon[row * 4 + col]);
                }
            }
            nnz[mb * 4 + blk] = nnz_n;
        }
        return out;
    }

    fn dcNc(self: *const Encoder, mb: usize, mbx: u32, mby: u32) i32 {
        // Intra16x16 luma DC takes nA and nB from the upper-left 4x4, not from the neighbouring DC blocks.
        return self.acNc(mb, 0, mbx, mby);
    }

    fn acNc(self: *const Encoder, mb: usize, blk: usize, mbx: u32, mby: u32) i32 {
        const sx = blk_x[blk];
        const sy = blk_y[blk];
        const left: ?u8 = if (sx > 0)
            self.nnz_y[mb * 16 + blkAt(sx - 1, sy)]
        else if (mbx > 0)
            self.nnz_y[(mb - 1) * 16 + blkAt(3, sy)]
        else
            null;
        const up: ?u8 = if (sy > 0)
            self.nnz_y[mb * 16 + blkAt(sx, sy - 1)]
        else if (mby > 0)
            self.nnz_y[(@as(usize, mby - 1) * self.mb_w + mbx) * 16 + blkAt(sx, 3)]
        else
            null;
        return neighborNc(left, up);
    }

    fn chromaNc(self: *const Encoder, nnz: []const u8, mb: usize, blk: usize, mbx: u32, mby: u32) i32 {
        const bx = blk % 2;
        const by = blk / 2;
        const left: ?u8 = if (bx > 0)
            nnz[mb * 4 + blk - 1]
        else if (mbx > 0)
            nnz[(mb - 1) * 4 + by * 2 + 1]
        else
            null;
        const up: ?u8 = if (by > 0)
            nnz[mb * 4 + blk - 2]
        else if (mby > 0)
            nnz[(@as(usize, mby - 1) * self.mb_w + mbx) * 4 + 2 + bx]
        else
            null;
        return neighborNc(left, up);
    }
};

fn neighborNc(left: ?u8, up: ?u8) i32 {
    if (left) |a| {
        if (up) |b| return @intCast((@as(u32, a) + b + 1) >> 1);
        return a;
    }
    if (up) |b| return b;
    return 0;
}

fn writeSps(self: *const Encoder, bits: *Bits) void {
    bits.put(66, 8);
    bits.put(1, 1);
    bits.put(1, 1);
    bits.put(0, 1);
    bits.put(0, 1);
    bits.put(0, 1);
    bits.put(0, 1);
    bits.put(0, 2);
    bits.put(levelIdc(self.width, self.height), 8);
    bits.ue(0);
    bits.ue(4);
    bits.ue(2);
    bits.ue(1);
    bits.put(0, 1);
    bits.ue(self.mb_w - 1);
    bits.ue(self.mb_h - 1);
    bits.put(1, 1);
    bits.put(1, 1);
    const crop_r = (self.coded_w - self.width) / 2;
    const crop_b = (self.coded_h - self.height) / 2;
    if (crop_r == 0 and crop_b == 0) {
        bits.put(0, 1);
    } else {
        bits.put(1, 1);
        bits.ue(0);
        bits.ue(crop_r);
        bits.ue(0);
        bits.ue(crop_b);
    }
    bits.put(0, 1);
}

fn writePps(bits: *Bits) void {
    bits.ue(0);
    bits.ue(0);
    bits.put(0, 1);
    bits.put(0, 1);
    bits.ue(0);
    bits.ue(0);
    bits.ue(0);
    bits.put(0, 1);
    bits.put(0, 2);
    bits.se(0);
    bits.se(0);
    bits.se(0);
    bits.put(1, 1);
    bits.put(0, 1);
    bits.put(0, 1);
}

fn levelIdc(width: u32, height: u32) u32 {
    const blocks = ((width + 15) / 16) * ((height + 15) / 16);
    if (width <= 1280 and height <= 720 and blocks <= 3600) return 31;
    if (width <= 1920 and height <= 1088 and blocks <= 8192) return 40;
    if (blocks <= 22080) return 50;
    return 51;
}

fn putNal(out: []u8, n: *usize, kind: u8, rbsp: []const u8) bool {
    if (n.* + 5 > out.len) return false;
    out[n.*] = 0;
    out[n.* + 1] = 0;
    out[n.* + 2] = 0;
    out[n.* + 3] = 1;
    out[n.* + 4] = 0x60 | kind;
    n.* += 5;
    var zeros: u8 = 0;
    for (rbsp) |byte| {
        if (zeros == 2 and byte <= 3) {
            if (n.* >= out.len) return false;
            out[n.*] = 3;
            n.* += 1;
            zeros = 0;
        }
        if (n.* >= out.len) return false;
        out[n.*] = byte;
        n.* += 1;
        zeros = if (byte == 0) zeros + 1 else 0;
    }
    return true;
}

fn writeResidual(bits: *Bits, scan: []const i32, nc: i32, chroma_dc: bool) void {
    var levels: [16]i32 = undefined;
    var runs: [16]u32 = undefined;
    var total: usize = 0;
    var total_zeros: u32 = 0;
    var last: isize = @as(isize, @intCast(scan.len)) - 1;
    while (last >= 0 and scan[@intCast(last)] == 0) last -= 1;
    while (last >= 0) {
        levels[total] = scan[@intCast(last)];
        last -= 1;
        var z: u32 = 0;
        while (last >= 0 and scan[@intCast(last)] == 0) {
            z += 1;
            last -= 1;
        }
        runs[total] = z;
        total_zeros += z;
        total += 1;
    }
    var trailing: usize = 0;
    while (trailing < total and trailing < 3 and (levels[trailing] == 1 or levels[trailing] == -1)) trailing += 1;
    writeToken(bits, nc, total, trailing);
    if (total == 0) return;
    for (0..trailing) |i| bits.put(if (levels[i] < 0) 1 else 0, 1);
    writeLevels(bits, levels[0..total], trailing);
    if (total < scan.len) {
        const value: u8, const nbits: u8 = if (chroma_dc) blk: {
            const at = (total * 4 + total_zeros) * 2;
            break :blk .{ tab.total_zeros_chroma_dc[at], tab.total_zeros_chroma_dc[at + 1] };
        } else blk: {
            const at = (total * 16 + total_zeros) * 2;
            break :blk .{ tab.total_zeros[at], tab.total_zeros[at + 1] };
        };
        bits.put(value, nbits);
    }
    var left = total_zeros;
    var k: usize = 0;
    while (k + 1 < total and left > 0) : (k += 1) {
        const idx: usize = if (left > 6) 7 else left;
        const at = (idx * 15 + runs[k]) * 2;
        bits.put(tab.run_before[at], tab.run_before[at + 1]);
        left -= runs[k];
    }
}

fn writeToken(bits: *Bits, nc: i32, total: usize, trailing: usize) void {
    const row: usize = if (nc < 0) 4 else if (nc < 2) 0 else if (nc < 4) 1 else if (nc < 8) 2 else 3;
    const at = ((row * 17 + total) * 4 + trailing) * 2;
    bits.put(tab.coeff_token[at], tab.coeff_token[at + 1]);
}

fn writeLevels(bits: *Bits, levels: []const i32, trailing: usize) void {
    var suffix: u32 = if (levels.len > 10 and trailing < 3) 1 else 0;
    for (levels[trailing..], 0..) |val, j| {
        const first = j == 0 and trailing < 3;
        var code: i32 = (val - 1) * 2;
        if (code < 0) code = ~code - 2;
        if (first) code -= 2;
        writeLevelCode(bits, code, suffix);
        if (suffix == 0) suffix = 1;
        const thr: i32 = @as(i32, 3) << @intCast(suffix - 1);
        if ((val > thr or val < -thr) and suffix < 6) suffix += 1;
    }
}

fn writeLevelCode(bits: *Bits, code: i32, suffix: u32) void {
    var prefix: u32 = @intCast(code >> @intCast(suffix));
    var ssize: u32 = suffix;
    var sbits: i32 = code - (@as(i32, @intCast(prefix)) << @intCast(suffix));
    if (prefix >= 14 and prefix < 30 and suffix == 0) {
        prefix = 14;
        sbits = code - 14;
        ssize = 4;
    } else if (prefix >= 15) {
        prefix = 15;
        sbits = code - (@as(i32, 15) << @intCast(suffix));
        if (suffix == 0) sbits -= 15;
        ssize = 12;
    }
    const n = prefix + 1 + ssize;
    const word: u32 = if (ssize == 0) 1 else (@as(u32, 1) << @intCast(ssize)) | @as(u32, @intCast(sbits));
    bits.put(word, n);
}

fn qcls(i: usize) usize {
    const r = i >> 2;
    const c = i & 3;
    const re = (r & 1) == 0;
    const ce = (c & 1) == 0;
    if (re and ce) return 0;
    if (!re and !ce) return 1;
    return 2;
}

fn quantAc(v: i32, cls: usize) i32 {
    return quantShift(v, quant_mf[qp_rem][cls], 15 + qp_per);
}

fn quantDc(v: i32) i32 {
    return quantShift(v, quant_mf[qp_rem][0], 16 + qp_per);
}

fn quantChromaDc(v: i32) i32 {
    return quantShift(v, quant_mf[qp_rem][0], 15 + qp_per);
}

fn quantShift(v: i32, mf: i64, qbits: u6) i32 {
    const bias: i64 = @divTrunc(@as(i64, 1) << qbits, 3);
    const mag: i64 = if (v < 0) -@as(i64, v) else v;
    var level: i32 = @intCast((mag * mf + bias) >> qbits);
    if (level > 2063) level = 2063;
    return if (v < 0) -level else level;
}

fn dequantAc(level: i32, cls: usize) i32 {
    const scale: i64 = dequant_mf[qp_rem][cls];
    const mag: i64 = if (level < 0) -@as(i64, level) else level;
    // Zig binds + tighter than <<, so the rounding bias has to sit outside the shift.
    const d = (((mag * scale * 16) << (qp_per + 2)) + 32) >> 6;
    const out: i32 = @intCast(d);
    return if (level < 0) -out else out;
}

fn scaleLumaDc(f: i32) i32 {
    const qmul: i64 = @as(i64, dequant_mf[qp_rem][0]) * 16 << (qp_per + 2);
    const mag: i64 = if (f < 0) -@as(i64, f) else f;
    const d = (mag * qmul + 128) >> 8;
    const out: i32 = @intCast(d);
    return if (f < 0) -out else out;
}

fn dequantChromaDc(level: i32) i32 {
    const scale = dequant_mf[qp_rem][0];
    const mag = if (level < 0) -level else level;
    const d = mag * scale << (qp_per - 1);
    return if (level < 0) -d else d;
}

fn fwd4(pix: *const [16]i32, outc: *[16]i32) void {
    var m: [16]i32 = undefined;
    for (0..4) |i| {
        const o = i * 4;
        const p0 = pix[o] + pix[o + 3];
        const p1 = pix[o + 1] + pix[o + 2];
        const p2 = pix[o + 1] - pix[o + 2];
        const p3 = pix[o] - pix[o + 3];
        m[o] = p0 + p1;
        m[o + 1] = p2 + (p3 << 1);
        m[o + 2] = p0 - p1;
        m[o + 3] = p3 - (p2 << 1);
    }
    for (0..4) |j| {
        const p0 = m[j] + m[12 + j];
        const p1 = m[4 + j] + m[8 + j];
        const p2 = m[4 + j] - m[8 + j];
        const p3 = m[j] - m[12 + j];
        outc[j] = p0 + p1;
        outc[4 + j] = p2 + (p3 << 1);
        outc[8 + j] = p0 - p1;
        outc[12 + j] = p3 - (p2 << 1);
    }
}

fn inv4(d: *const [16]i32, r: *[16]i32) void {
    var m: [16]i32 = undefined;
    for (0..4) |i| {
        const o = i * 4;
        const e0 = d[o] + d[o + 2];
        const e1 = d[o] - d[o + 2];
        const e2 = (d[o + 1] >> 1) - d[o + 3];
        const e3 = d[o + 1] + (d[o + 3] >> 1);
        m[o] = e0 + e3;
        m[o + 1] = e1 + e2;
        m[o + 2] = e1 - e2;
        m[o + 3] = e0 - e3;
    }
    for (0..4) |j| {
        const e0 = m[j] + m[8 + j];
        const e1 = m[j] - m[8 + j];
        const e2 = (m[4 + j] >> 1) - m[12 + j];
        const e3 = m[4 + j] + (m[12 + j] >> 1);
        r[j] = (e0 + e3 + 32) >> 6;
        r[4 + j] = (e1 + e2 + 32) >> 6;
        r[8 + j] = (e1 - e2 + 32) >> 6;
        r[12 + j] = (e0 - e3 + 32) >> 6;
    }
}

fn hadamard4(d: *const [16]i32, o: *[16]i32) void {
    var m: [16]i32 = undefined;
    for (0..4) |i| {
        const b = i * 4;
        const s01 = d[b] + d[b + 1];
        const d01 = d[b] - d[b + 1];
        const s23 = d[b + 2] + d[b + 3];
        const d23 = d[b + 2] - d[b + 3];
        m[b] = s01 + s23;
        m[b + 1] = s01 - s23;
        m[b + 2] = d01 - d23;
        m[b + 3] = d01 + d23;
    }
    for (0..4) |j| {
        const s01 = m[j] + m[4 + j];
        const d01 = m[j] - m[4 + j];
        const s23 = m[8 + j] + m[12 + j];
        const d23 = m[8 + j] - m[12 + j];
        o[j] = s01 + s23;
        o[4 + j] = s01 - s23;
        o[8 + j] = d01 - d23;
        o[12 + j] = d01 + d23;
    }
}

fn hadamard2(a: i32, b: i32, c: i32, d: i32) [4]i32 {
    return .{
        a + b + c + d,
        a - b + c - d,
        a + b - c - d,
        a - b - c + d,
    };
}

fn predDc(rec: []const u8, stride: u32, mbx: u32, mby: u32, n: usize) i32 {
    const x = @as(usize, mbx) * n;
    const y = @as(usize, mby) * n;
    const step = @as(usize, stride);
    var sum: u32 = 0;
    var count: u32 = 0;
    if (mbx > 0) {
        for (0..n) |i| sum += rec[(y + i) * step + x - 1];
        count += @intCast(n);
    }
    if (mby > 0) {
        for (0..n) |i| sum += rec[(y - 1) * step + x + i];
        count += @intCast(n);
    }
    if (count == n * 2) return @intCast((sum + @as(u32, @intCast(n))) >> @intCast(std.math.log2_int(usize, n) + 1));
    if (count == n) return @intCast((sum + @as(u32, @intCast(n / 2))) >> @intCast(std.math.log2_int(usize, n)));
    return 128;
}

fn sad16(a: []const u8, b: []const u8, stride: u32, x: usize, y: usize) u32 {
    var s: u32 = 0;
    const step = @as(usize, stride);
    for (0..16) |row| {
        const at = (y + row) * step + x;
        for (0..16) |col| {
            const d = @as(i32, a[at + col]) - b[at + col];
            s += @intCast(if (d < 0) -d else d);
        }
    }
    return s;
}

fn loadPlane(dst: []u8, dw: u32, dh: u32, src: []const u8, sw: u32, sh: u32, stride: usize) void {
    const dest_w: usize = dw;
    var row: usize = 0;
    while (row < sh) : (row += 1) {
        const from = src[row * stride ..][0..sw];
        @memcpy(dst[row * dest_w ..][0..sw], from);
        var col = sw;
        while (col < dw) : (col += 1) dst[row * dest_w + col] = from[sw - 1];
    }
    var y = sh;
    while (y < dh) : (y += 1) {
        @memcpy(dst[y * dest_w ..][0..dest_w], dst[(sh - 1) * dest_w ..][0..dest_w]);
    }
}

fn clip8(v: i32) u8 {
    if (v < 0) return 0;
    if (v > 255) return 255;
    return @intCast(v);
}

fn yOf(r: u8, g: u8, b: u8) u8 {
    const v = (66 * @as(i32, r) + 129 * @as(i32, g) + 25 * @as(i32, b) + 128) >> 8;
    return clip8(v + 16);
}

fn cbOf(r: u8, g: u8, b: u8) i32 {
    return @as(i32, clip8(((-38 * @as(i32, r) - 74 * @as(i32, g) + 112 * @as(i32, b) + 128) >> 8) + 128));
}

fn crOf(r: u8, g: u8, b: u8) i32 {
    return @as(i32, clip8(((112 * @as(i32, r) - 94 * @as(i32, g) - 18 * @as(i32, b) + 128) >> 8) + 128));
}

fn avg(bytes: []const u8) u32 {
    var s: u32 = 0;
    for (bytes) |v| s += v;
    return s / @as(u32, @intCast(bytes.len));
}

test "encoder emits an idr access unit" {
    const gpa = std.testing.allocator;
    const enc = try Encoder.init(gpa, 64, 64, 30);
    defer enc.deinit();
    const y = try gpa.alloc(u8, 64 * 64);
    defer gpa.free(y);
    const c = try gpa.alloc(u8, 32 * 32);
    defer gpa.free(c);
    @memset(y, 128);
    @memset(c, 128);
    var out: [65536]u8 = undefined;
    const au = try enc.encodePlanes(y, 64, c, 32, c, 32, &out);
    try std.testing.expect(au.key);
    try std.testing.expect(au.len > 8);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0, 0, 1 }, out[0..4]);
    try std.testing.expectEqual(@as(u8, 7), out[4] & 0x1f);
}

test "baseline frames decode" {
    const io = std.testing.io;
    if (!sys.exists(io, "/usr/bin/ffmpeg")) return;
    const gpa = std.testing.allocator;
    const enc = try Encoder.init(gpa, 64, 64, 30);
    defer enc.deinit();
    const y = try gpa.alloc(u8, 64 * 64);
    defer gpa.free(y);
    const c = try gpa.alloc(u8, 32 * 32);
    defer gpa.free(c);
    var stream: [256 * 1024]u8 = undefined;
    var n: usize = 0;
    @memset(y, 128);
    @memset(c, 128);
    const first = try enc.encodePlanes(y, 64, c, 32, c, 32, stream[n..]);
    try std.testing.expect(first.key);
    n += first.len;
    const second = try enc.encodePlanes(y, 64, c, 32, c, 32, stream[n..]);
    try std.testing.expect(!second.key);
    n += second.len;
    @memset(y, 235);
    const third = try enc.encodePlanes(y, 64, c, 32, c, 32, stream[n..]);
    n += third.len;
    std.Io.Dir.cwd().createDirPath(io, ".zig-cache") catch {};
    try sys.writeAll(io, ".zig-cache/h264-test.h264", stream[0..n]);
    const ran = try sys.run(gpa, io, &.{
        "/usr/bin/ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
        "-f",                "h264",
        "-i",                ".zig-cache/h264-test.h264",
        "-f",                "rawvideo",
        "-pix_fmt",          "yuv420p",
        ".zig-cache/h264-test.yuv",
    }, 20000, 1024);
    defer gpa.free(ran.stdout);
    defer gpa.free(ran.stderr);
    if (!ran.term_ok) {
        std.debug.print("ffmpeg h264: {s}\n", .{ran.stderr});
        return error.TestUnexpectedResult;
    }
    const yuv = sys.readAll(io, gpa, ".zig-cache/h264-test.yuv", 256 * 1024) orelse return error.TestUnexpectedResult;
    defer gpa.free(yuv);
    const frame: usize = 64 * 64 + 32 * 32 + 32 * 32;
    try std.testing.expectEqual(frame * 3, yuv.len);
    const y0 = avg(yuv[0..4096]);
    const y1 = avg(yuv[frame..][0..4096]);
    const y2 = avg(yuv[frame * 2 ..][0..4096]);
    std.debug.print("h264 y averages {d} {d} {d}\n", .{ y0, y1, y2 });
    try std.testing.expect(y0 > 120 and y0 < 136);
    try std.testing.expect(y1 > 120 and y1 < 136);
    try std.testing.expect(y2 > 220 and y2 < 250);
}

test "baseline edge survives ac coefficients" {
    const io = std.testing.io;
    if (!sys.exists(io, "/usr/bin/ffmpeg")) return;
    const gpa = std.testing.allocator;
    const enc = try Encoder.init(gpa, 64, 64, 30);
    defer enc.deinit();
    const y = try gpa.alloc(u8, 64 * 64);
    defer gpa.free(y);
    const c = try gpa.alloc(u8, 32 * 32);
    defer gpa.free(c);
    @memset(c, 128);
    for (0..64) |row| {
        for (0..64) |col| y[row * 64 + col] = if (col < 16) 80 else 180;
    }
    var stream: [256 * 1024]u8 = undefined;
    const au = try enc.encodePlanes(y, 64, c, 32, c, 32, &stream);
    std.Io.Dir.cwd().createDirPath(io, ".zig-cache") catch {};
    try sys.writeAll(io, ".zig-cache/h264-edge.h264", stream[0..au.len]);
    const ran = try sys.run(gpa, io, &.{
        "/usr/bin/ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
        "-f",                "h264",
        "-i",                ".zig-cache/h264-edge.h264",
        "-f",                "rawvideo",
        "-pix_fmt",          "yuv420p",
        ".zig-cache/h264-edge.yuv",
    }, 20000, 1024);
    defer gpa.free(ran.stdout);
    defer gpa.free(ran.stderr);
    if (!ran.term_ok) return error.TestUnexpectedResult;
    const yuv = sys.readAll(io, gpa, ".zig-cache/h264-edge.yuv", 64 * 1024) orelse return error.TestUnexpectedResult;
    defer gpa.free(yuv);
    var left: u32 = 0;
    var right: u32 = 0;
    for (0..64) |row| {
        for (0..16) |col| left += yuv[row * 64 + col];
        for (48..64) |col| right += yuv[row * 64 + col];
    }
    const l = left / (64 * 16);
    const r = right / (64 * 16);
    std.debug.print("h264 edge {d} {d}\n", .{ l, r });
    try std.testing.expect(l > 60 and l < 110);
    try std.testing.expect(r > 150 and r < 210);
}

test "one mb checker decodes" {
    const io = std.testing.io;
    if (!sys.exists(io, "/usr/bin/ffmpeg")) return;
    const gpa = std.testing.allocator;
    const enc = try Encoder.init(gpa, 16, 16, 30);
    defer enc.deinit();
    var y: [16 * 16]u8 = undefined;
    var c: [8 * 8]u8 = undefined;
    @memset(&c, 128);
    for (0..16) |row| {
        for (0..16) |col| y[row * 16 + col] = if (((col + row) & 1) == 0) 32 else 200;
    }
    var stream: [64 * 1024]u8 = undefined;
    const au = try enc.encodePlanes(&y, 16, &c, 8, &c, 8, &stream);
    std.Io.Dir.cwd().createDirPath(io, ".zig-cache") catch {};
    try sys.writeAll(io, ".zig-cache/h264-one.h264", stream[0..au.len]);
    const ran = try sys.run(gpa, io, &.{
        "/usr/bin/ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
        "-f",                "h264",
        "-i",                ".zig-cache/h264-one.h264",
        "-f",                "rawvideo",
        "-pix_fmt",          "yuv420p",
        ".zig-cache/h264-one.yuv",
    }, 20000, 4096);
    defer gpa.free(ran.stdout);
    defer gpa.free(ran.stderr);
    if (!ran.term_ok or ran.stderr.len != 0) {
        std.debug.print("ffmpeg one: {s}\n", .{ran.stderr});
        return error.TestUnexpectedResult;
    }
}

test "baseline detail decodes" {
    const io = std.testing.io;
    if (!sys.exists(io, "/usr/bin/ffmpeg")) return;
    const gpa = std.testing.allocator;
    const enc = try Encoder.init(gpa, 64, 64, 30);
    defer enc.deinit();
    const y = try gpa.alloc(u8, 64 * 64);
    defer gpa.free(y);
    const c = try gpa.alloc(u8, 32 * 32);
    defer gpa.free(c);
    @memset(c, 128);
    for (0..64) |row| {
        for (0..64) |col| {
            y[row * 64 + col] = if (((col + row) & 1) == 0) 32 else 200;
        }
    }
    var stream: [512 * 1024]u8 = undefined;
    var n: usize = 0;
    const first = try enc.encodePlanes(y, 64, c, 32, c, 32, stream[n..]);
    n += first.len;
    for (0..64) |row| {
        for (0..64) |col| y[row * 64 + col] = @intCast(16 + col * 3);
    }
    const second = try enc.encodePlanes(y, 64, c, 32, c, 32, stream[n..]);
    n += second.len;
    std.Io.Dir.cwd().createDirPath(io, ".zig-cache") catch {};
    try sys.writeAll(io, ".zig-cache/h264-detail.h264", stream[0..n]);
    const ran = try sys.run(gpa, io, &.{
        "/usr/bin/ffmpeg", "-y", "-hide_banner", "-loglevel", "error",
        "-f",                "h264",
        "-i",                ".zig-cache/h264-detail.h264",
        "-f",                "rawvideo",
        "-pix_fmt",          "yuv420p",
        ".zig-cache/h264-detail.yuv",
    }, 20000, 4096);
    defer gpa.free(ran.stdout);
    defer gpa.free(ran.stderr);
    if (!ran.term_ok or ran.stderr.len != 0) {
        std.debug.print("ffmpeg detail: {s}\n", .{ran.stderr});
        return error.TestUnexpectedResult;
    }
    const yuv = sys.readAll(io, gpa, ".zig-cache/h264-detail.yuv", 256 * 1024) orelse return error.TestUnexpectedResult;
    defer gpa.free(yuv);
    const frame: usize = 64 * 64 + 32 * 32 + 32 * 32;
    try std.testing.expectEqual(frame * 2, yuv.len);
    const grad = yuv[frame..][0..4096];
    var left: u32 = 0;
    var right: u32 = 0;
    for (0..64) |row| {
        for (0..8) |col| left += grad[row * 64 + col];
        for (56..64) |col| right += grad[row * 64 + col];
    }
    const l = left / (64 * 8);
    const r = right / (64 * 8);
    std.debug.print("h264 detail {d} {d}\n", .{ l, r });
    try std.testing.expect(l < 80);
    try std.testing.expect(r > 150);
}
