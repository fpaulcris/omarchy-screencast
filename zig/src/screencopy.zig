const std = @import("std");

const linux = std.os.linux;
const endian = @import("builtin").cpu.arch.endian();

pub const Shot = struct {
    pixels: []u8,
    width: u32,
    height: u32,
    stride: u32,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *Shot) void {
        self.gpa.free(self.pixels);
        self.* = undefined;
    }
};

const Out = struct {
    id: u32,
    name: [64]u8 = undefined,
    name_len: u8 = 0,
};

const Global = struct {
    name: u32,
    version: u32,
    kind: u8,
};

const Msg = struct {
    id: u32,
    op: u16,
    body: [1024]u8 = undefined,
    len: usize = 0,
};

pub const Client = struct {
    gpa: std.mem.Allocator,
    fd: i32,
    shm: u32 = 0,
    manager: u32 = 0,
    copy_version: u32 = 1,
    outputs: [8]Out = undefined,
    output_n: u8 = 0,
    next_id: u32 = 2,
    stop: *std.atomic.Value(bool),
    inbuf: [8192]u8 = undefined,
    inlen: usize = 0,

    pub fn connect(gpa: std.mem.Allocator, xdg: []const u8, display: []const u8, stop: *std.atomic.Value(bool)) ?*Client {
        if (xdg.len == 0 or display.len == 0) return null;
        var path_buf: [160]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ xdg, display }) catch return null;
        const fd = openSocket(path) orelse return null;
        const self = gpa.create(Client) catch {
            _ = linux.close(fd);
            return null;
        };
        self.* = .{
            .gpa = gpa,
            .fd = fd,
            .stop = stop,
        };
        if (!self.handshake()) {
            self.deinit();
            return null;
        }
        return self;
    }

    pub fn deinit(self: *Client) void {
        _ = linux.close(self.fd);
        self.gpa.destroy(self);
    }

    pub fn grab(self: *Client, name: []const u8, max_w: u32, max_h: u32) ?Shot {
        if (self.stop.load(.acquire)) return null;
        if (name.len > 0) {
            const output = self.findOutput(name) orelse return null;
            return self.grabOutput(output, max_w, max_h);
        }
        // A disabled connector accepts the request and then never sends ready.
        if (self.output_n == 0) return null;
        for (self.outputs[0..self.output_n]) |out| {
            if (self.grabOutput(out.id, max_w, max_h)) |shot| return shot;
            if (self.stop.load(.acquire)) return null;
        }
        return null;
    }

    fn grabOutput(self: *Client, output: u32, max_w: u32, max_h: u32) ?Shot {
        if (self.stop.load(.acquire)) return null;
        const frame = self.allocId();
        var msg_buf: [32]u8 = undefined;
        var n: usize = 0;
        putHeader(&msg_buf, &n, self.manager, 0, 20);
        putU32(&msg_buf, &n, frame);
        putU32(&msg_buf, &n, 1);
        putU32(&msg_buf, &n, output);
        if (!writeAll(self.fd, msg_buf[0..n])) return null;

        var format: u32 = 0;
        var width: u32 = 0;
        var height: u32 = 0;
        var stride: u32 = 0;
        var flags: u32 = 0;
        var got = false;
        while (!self.stop.load(.acquire)) {
            const msg = self.readMsg(if (got and self.copy_version < 3) 40 else 1500) orelse break;
            if (msg.id == 1 and msg.op == 0) return null;
            if (msg.id != frame) continue;
            if (msg.op == 0 and msg.len >= 16) {
                format = rdU32(msg.body[0..4]);
                width = rdU32(msg.body[4..8]);
                height = rdU32(msg.body[8..12]);
                stride = rdU32(msg.body[12..16]);
                got = true;
                if (self.copy_version < 3) continue;
            } else if (msg.op == 1 and msg.len >= 4) {
                flags = rdU32(msg.body[0..4]);
            } else if (msg.op == 3) {
                self.destroy(frame, 1);
                return null;
            } else if (msg.op == 6) break;
        }
        if (!got or width < 2 or height < 2 or stride < width * 4) {
            self.destroy(frame, 1);
            return null;
        }
        if (format != 0 and format != 1) {
            self.destroy(frame, 1);
            return null;
        }
        const bytes: u64 = @as(u64, stride) * height;
        if (bytes == 0 or bytes > 64 * 1024 * 1024) {
            self.destroy(frame, 1);
            return null;
        }
        const size: usize = @intCast(bytes);
        const memfd = linux.memfd_create("screencast", 1);
        if (linux.errno(memfd) != .SUCCESS) {
            self.destroy(frame, 1);
            return null;
        }
        const mfd: i32 = @intCast(memfd);
        defer _ = linux.close(mfd);
        if (linux.errno(linux.ftruncate(mfd, @intCast(size))) != .SUCCESS) {
            self.destroy(frame, 1);
            return null;
        }
        const mapped = linux.mmap(null, size, .{ .READ = true, .WRITE = true }, .{ .TYPE = .SHARED }, mfd, 0);
        if (linux.errno(mapped) != .SUCCESS) {
            self.destroy(frame, 1);
            return null;
        }
        const ptr: [*]u8 = @ptrFromInt(mapped);
        defer _ = linux.munmap(ptr, size);

        const pool = self.allocId();
        var pool_msg: [16]u8 = undefined;
        var pn: usize = 0;
        putHeader(&pool_msg, &pn, self.shm, 0, 16);
        putU32(&pool_msg, &pn, pool);
        putU32(&pool_msg, &pn, @intCast(size));
        if (!sendFd(self.fd, pool_msg[0..pn], mfd)) {
            self.destroy(frame, 1);
            return null;
        }
        const buffer = self.allocId();
        var bmsg: [32]u8 = undefined;
        var bn: usize = 0;
        putHeader(&bmsg, &bn, pool, 0, 32);
        putU32(&bmsg, &bn, buffer);
        putU32(&bmsg, &bn, 0);
        putI32(&bmsg, &bn, @intCast(width));
        putI32(&bmsg, &bn, @intCast(height));
        putI32(&bmsg, &bn, @intCast(stride));
        putU32(&bmsg, &bn, format);
        if (!writeAll(self.fd, bmsg[0..bn])) {
            self.destroy(frame, 1);
            self.destroy(pool, 1);
            return null;
        }
        var copy_msg: [12]u8 = undefined;
        var cn: usize = 0;
        putHeader(&copy_msg, &cn, frame, 0, 12);
        putU32(&copy_msg, &cn, buffer);
        if (!writeAll(self.fd, copy_msg[0..cn])) {
            self.destroy(buffer, 0);
            self.destroy(pool, 1);
            self.destroy(frame, 1);
            return null;
        }
        var ready = false;
        while (!self.stop.load(.acquire)) {
            const msg = self.readMsg(1500) orelse break;
            if (msg.id == 1 and msg.op == 0) break;
            if (msg.id != frame) continue;
            if (msg.op == 2) {
                ready = true;
                break;
            }
            if (msg.op == 3) break;
            if (msg.op == 1 and msg.len >= 4) flags = rdU32(msg.body[0..4]);
        }
        self.destroy(buffer, 0);
        self.destroy(pool, 1);
        self.destroy(frame, 1);
        if (!ready) return null;
        const shot = scale(self.gpa, ptr[0..size], width, height, stride, (flags & 1) != 0, max_w, max_h) orelse return null;
        return shot;
    }

    fn findOutput(self: *Client, name: []const u8) ?u32 {
        if (name.len > 0) {
            for (self.outputs[0..self.output_n]) |out| {
                if (std.mem.eql(u8, out.name[0..out.name_len], name)) return out.id;
            }
        }
        if (self.output_n == 0) return null;
        return self.outputs[0].id;
    }

    fn handshake(self: *Client) bool {
        var buf: [64]u8 = undefined;
        var n: usize = 0;
        const registry = self.allocId();
        putHeader(&buf, &n, 1, 1, 12);
        putU32(&buf, &n, registry);
        const sync1 = self.allocId();
        putHeader(&buf, &n, 1, 0, 12);
        putU32(&buf, &n, sync1);
        if (!writeAll(self.fd, buf[0..n])) return false;

        var globals: [16]Global = undefined;
        var gn: usize = 0;
        while (!self.stop.load(.acquire)) {
            const msg = self.readMsg(1500) orelse return false;
            if (msg.id == 1 and msg.op == 0) return false;
            if (msg.id == registry and msg.op == 0) {
                if (gn >= globals.len) continue;
                var at: usize = 0;
                const gname = takeU32(msg.body[0..msg.len], &at) orelse continue;
                const iname = takeString(msg.body[0..msg.len], &at) orelse continue;
                const ver = takeU32(msg.body[0..msg.len], &at) orelse continue;
                const kind: ?u8 = if (std.mem.eql(u8, iname, "wl_shm"))
                    1
                else if (std.mem.eql(u8, iname, "wl_output"))
                    2
                else if (std.mem.eql(u8, iname, "zwlr_screencopy_manager_v1"))
                    3
                else
                    null;
                if (kind) |k| {
                    globals[gn] = .{ .name = gname, .version = ver, .kind = k };
                    gn += 1;
                }
            } else if (msg.id == sync1 and msg.op == 0) break;
        }

        for (globals[0..gn]) |g| {
            if (g.kind == 1 and self.shm == 0) {
                self.shm = self.allocId();
                if (!self.bind(registry, g.name, "wl_shm", 1, self.shm)) return false;
            } else if (g.kind == 3 and self.manager == 0) {
                const ver = @min(g.version, 3);
                self.manager = self.allocId();
                self.copy_version = ver;
                if (!self.bind(registry, g.name, "zwlr_screencopy_manager_v1", ver, self.manager)) return false;
            } else if (g.kind == 2 and self.output_n < self.outputs.len) {
                const id = self.allocId();
                const ver = @min(g.version, 4);
                if (!self.bind(registry, g.name, "wl_output", ver, id)) return false;
                self.outputs[self.output_n] = .{ .id = id };
                self.output_n += 1;
            }
        }
        if (self.shm == 0 or self.manager == 0 or self.output_n == 0) return false;

        var sb: [16]u8 = undefined;
        var sn: usize = 0;
        const sync2 = self.allocId();
        putHeader(&sb, &sn, 1, 0, 12);
        putU32(&sb, &sn, sync2);
        if (!writeAll(self.fd, sb[0..sn])) return false;
        while (!self.stop.load(.acquire)) {
            const msg = self.readMsg(1500) orelse return false;
            if (msg.id == 1 and msg.op == 0) return false;
            if (msg.op == 4) {
                for (self.outputs[0..self.output_n]) |*out| {
                    if (out.id != msg.id) continue;
                    var at: usize = 0;
                    const oname = takeString(msg.body[0..msg.len], &at) orelse break;
                    const copy_n = @min(oname.len, out.name.len);
                    @memcpy(out.name[0..copy_n], oname[0..copy_n]);
                    out.name_len = @intCast(copy_n);
                }
            } else if (msg.id == sync2 and msg.op == 0) return true;
        }
        return false;
    }

    fn bind(self: *Client, registry: u32, name: u32, iface: []const u8, version: u32, id: u32) bool {
        var buf: [128]u8 = undefined;
        var n: usize = 0;
        const str_len = 4 + std.mem.alignForward(usize, iface.len + 1, 4);
        const size: u32 = @intCast(8 + 4 + 4 + str_len + 4);
        putHeader(&buf, &n, registry, 0, size);
        putU32(&buf, &n, name);
        putString(&buf, &n, iface);
        putU32(&buf, &n, version);
        putU32(&buf, &n, id);
        return writeAll(self.fd, buf[0..n]);
    }

    fn allocId(self: *Client) u32 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }

    fn destroy(self: *Client, id: u32, opcode: u16) void {
        var buf: [8]u8 = undefined;
        var n: usize = 0;
        putHeader(&buf, &n, id, opcode, 8);
        _ = writeAll(self.fd, buf[0..n]);
    }

    fn readMsg(self: *Client, timeout_ms: i32) ?Msg {
        while (self.inlen < 8) {
            if (self.stop.load(.acquire)) return null;
            if (!self.fill(timeout_ms)) return null;
        }
        const size = rdU32(self.inbuf[4..8]) >> 16;
        if (size < 8 or size > 8192) return null;
        while (self.inlen < size) {
            if (self.stop.load(.acquire)) return null;
            if (!self.fill(timeout_ms)) return null;
        }
        var msg = Msg{
            .id = rdU32(self.inbuf[0..4]),
            .op = @intCast(rdU32(self.inbuf[4..8]) & 0xFFFF),
        };
        const body_len = size - 8;
        const copy_n = @min(body_len, msg.body.len);
        @memcpy(msg.body[0..copy_n], self.inbuf[8..][0..copy_n]);
        msg.len = copy_n;
        std.mem.copyForwards(u8, self.inbuf[0 .. self.inlen - size], self.inbuf[size..self.inlen]);
        self.inlen -= size;
        return msg;
    }

    fn fill(self: *Client, timeout_ms: i32) bool {
        var pfd = linux.pollfd{ .fd = self.fd, .events = linux.POLL.IN };
        const waited = linux.poll(@ptrCast(&pfd), 1, timeout_ms);
        const err = linux.errno(waited);
        if (err == .INTR) return self.fill(timeout_ms);
        if (err != .SUCCESS or waited == 0) return false;
        if (self.inlen >= self.inbuf.len) return false;
        const n = linux.read(self.fd, self.inbuf[self.inlen..].ptr, self.inbuf.len - self.inlen);
        const rerr = linux.errno(n);
        if (rerr == .INTR) return self.fill(timeout_ms);
        if (rerr != .SUCCESS or n == 0) return false;
        self.inlen += n;
        return true;
    }
};

fn openSocket(path: []const u8) ?i32 {
    if (path.len + 1 > 108) return null;
    var addr = linux.sockaddr.un{ .path = undefined };
    @memset(&addr.path, 0);
    @memcpy(addr.path[0..path.len], path);
    const opened = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(opened) != .SUCCESS) return null;
    const fd: i32 = @intCast(opened);
    const len: linux.socklen_t = @intCast(@offsetOf(linux.sockaddr.un, "path") + path.len + 1);
    const rc = linux.connect(fd, &addr, len);
    if (linux.errno(rc) != .SUCCESS) {
        _ = linux.close(fd);
        return null;
    }
    return fd;
}

fn writeAll(fd: i32, data: []const u8) bool {
    var off: usize = 0;
    while (off < data.len) {
        const n = linux.write(fd, data[off..].ptr, data.len - off);
        const err = linux.errno(n);
        if (err == .INTR) continue;
        if (err != .SUCCESS or n == 0) return false;
        off += n;
    }
    return true;
}

fn sendFd(fd: i32, payload: []const u8, memfd: i32) bool {
    var iov = std.posix.iovec_const{ .base = payload.ptr, .len = payload.len };
    var cbuf: [64]u8 align(8) = undefined;
    @memset(&cbuf, 0);
    const cmsg_len = @sizeOf(linux.cmsghdr) + @sizeOf(i32);
    const hdr: *linux.cmsghdr = @ptrCast(@alignCast(&cbuf));
    hdr.len = cmsg_len;
    hdr.level = linux.SOL.SOCKET;
    hdr.type = 1;
    @memcpy(cbuf[@sizeOf(linux.cmsghdr)..][0..4], std.mem.asBytes(&memfd));
    const msg = linux.msghdr_const{
        .name = null,
        .namelen = 0,
        .iov = @ptrCast(&iov),
        .iovlen = 1,
        .control = &cbuf,
        .controllen = cmsg_len,
        .flags = 0,
    };
    const rc = linux.sendmsg(fd, &msg, 0);
    return linux.errno(rc) == .SUCCESS and rc == payload.len;
}

fn putHeader(buf: []u8, n: *usize, id: u32, opcode: u16, size: u32) void {
    putU32(buf, n, id);
    putU32(buf, n, (size << 16) | opcode);
}

fn putU32(buf: []u8, n: *usize, v: u32) void {
    std.mem.writeInt(u32, buf[n.*..][0..4], v, endian);
    n.* += 4;
}

fn putI32(buf: []u8, n: *usize, v: i32) void {
    std.mem.writeInt(i32, buf[n.*..][0..4], v, endian);
    n.* += 4;
}

fn putString(buf: []u8, n: *usize, s: []const u8) void {
    const raw = s.len + 1;
    const padded = std.mem.alignForward(usize, raw, 4);
    putU32(buf, n, @intCast(raw));
    @memcpy(buf[n.*..][0..s.len], s);
    @memset(buf[n.* + s.len ..][0 .. padded - s.len], 0);
    n.* += padded;
}

fn rdU32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], endian);
}

fn takeU32(body: []const u8, at: *usize) ?u32 {
    if (at.* + 4 > body.len) return null;
    const v = rdU32(body[at.*..][0..4]);
    at.* += 4;
    return v;
}

fn takeString(body: []const u8, at: *usize) ?[]const u8 {
    const len = takeU32(body, at) orelse return null;
    if (len == 0 or at.* + len > body.len) return null;
    const s = body[at.* .. at.* + len - 1];
    at.* += std.mem.alignForward(usize, len, 4);
    return s;
}

fn scale(
    gpa: std.mem.Allocator,
    src: []const u8,
    sw: u32,
    sh: u32,
    stride: u32,
    invert: bool,
    max_w: u32,
    max_h: u32,
) ?Shot {
    var dw: u32 = sw;
    var dh: u32 = sh;
    if (max_w >= 2 and max_h >= 2 and (sw > max_w or sh > max_h)) {
        const sx = @as(f64, @floatFromInt(max_w)) / @as(f64, @floatFromInt(sw));
        const sy = @as(f64, @floatFromInt(max_h)) / @as(f64, @floatFromInt(sh));
        const s = @min(sx, sy);
        dw = @intFromFloat(@floor(@as(f64, @floatFromInt(sw)) * s));
        dh = @intFromFloat(@floor(@as(f64, @floatFromInt(sh)) * s));
    }
    dw &= ~@as(u32, 1);
    dh &= ~@as(u32, 1);
    if (dw < 2 or dh < 2) return null;
    const out_stride = dw * 4;
    const pixels = gpa.alloc(u8, @as(usize, dh) * out_stride) catch return null;
    if (dw == sw and dh == sh) {
        var y: u32 = 0;
        while (y < dh) : (y += 1) {
            const sy: u32 = if (invert) sh - 1 - y else y;
            const row = src[@as(usize, sy) * stride ..][0 .. sw * 4];
            @memcpy(pixels[@as(usize, y) * out_stride ..][0 .. sw * 4], row);
        }
    } else {
        var y: u32 = 0;
        while (y < dh) : (y += 1) {
            const y0 = y * sh / dh;
            var y1 = (y + 1) * sh / dh;
            if (y1 <= y0) y1 = y0 + 1;
            var x: u32 = 0;
            while (x < dw) : (x += 1) {
                const x0 = x * sw / dw;
                var x1 = (x + 1) * sw / dw;
                if (x1 <= x0) x1 = x0 + 1;
                var acc: [4]u32 = .{ 0, 0, 0, 0 };
                var count: u32 = 0;
                var yy = y0;
                while (yy < y1 and yy < sh) : (yy += 1) {
                    const sy: u32 = if (invert) sh - 1 - yy else yy;
                    var xx = x0;
                    while (xx < x1 and xx < sw) : (xx += 1) {
                        const p = src[@as(usize, sy) * stride + @as(usize, xx) * 4 ..][0..4];
                        acc[0] += p[0];
                        acc[1] += p[1];
                        acc[2] += p[2];
                        acc[3] += p[3];
                        count += 1;
                    }
                }
                const dest = pixels[@as(usize, y) * out_stride + @as(usize, x) * 4 ..][0..4];
                if (count == 0) {
                    @memset(dest, 0);
                } else {
                    dest[0] = @intCast(acc[0] / count);
                    dest[1] = @intCast(acc[1] / count);
                    dest[2] = @intCast(acc[2] / count);
                    dest[3] = @intCast(acc[3] / count);
                }
            }
        }
    }
    return .{
        .pixels = pixels,
        .width = dw,
        .height = dh,
        .stride = out_stride,
        .gpa = gpa,
    };
}

test "screencopy grabs a frame when wayland is up" {
    const display = std.c.getenv("WAYLAND_DISPLAY") orelse return;
    const xdg = std.c.getenv("XDG_RUNTIME_DIR") orelse return;
    const gpa = std.testing.allocator;
    var stop = std.atomic.Value(bool).init(false);
    const client = Client.connect(gpa, std.mem.span(xdg), std.mem.span(display), &stop) orelse return error.TestUnexpectedResult;
    defer client.deinit();
    var shot = client.grab("", 320, 180) orelse return error.TestUnexpectedResult;
    defer shot.deinit();
    try std.testing.expect(shot.width >= 2 and shot.height >= 2);
    try std.testing.expect(shot.width % 2 == 0 and shot.height % 2 == 0);
    try std.testing.expect(shot.width <= 320 and shot.height <= 180);
    try std.testing.expect(shot.pixels.len == @as(usize, shot.width) * shot.height * 4);
}
