//! Browser picture. wf-recorder writes hardware MJPEG, and the newest JPEG is published.
//! The CPU path is the same recorder with qscale 4 when VAAPI JPEG is unavailable.
const std = @import("std");
const state = @import("state.zig");
const sys = @import("sys.zig");

const linux = std.os.linux;

const vaapi_device = "/dev/dri/renderD128";

var vaapi_known = std.atomic.Value(u8).init(0);

pub const Pump = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    world: *state.World,
    width: u32,
    height: u32,
    output: []u8,
    proc: ?std.process.Child = null,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),

    pub fn start(
        io: std.Io,
        gpa: std.mem.Allocator,
        world: *state.World,
        environ: *const std.process.Environ.Map,
        output: []const u8,
        width: u32,
        height: u32,
    ) !*Pump {
        if (!sys.safeName(output)) return error.BadOutput;
        const even_w = width & ~@as(u32, 1);
        const even_h = height & ~@as(u32, 1);
        if (even_w < 2 or even_h < 2) return error.BadOutput;
        const owned_bin = sys.commandPath(gpa, io, environ, "wf-recorder");
        defer if (owned_bin) |path| gpa.free(path);
        const bin: []const u8 = owned_bin orelse blk: {
            if (!sys.exists(io, "/usr/bin/wf-recorder")) return error.NoCapture;
            break :blk "/usr/bin/wf-recorder";
        };
        const self = try gpa.create(Pump);
        errdefer gpa.destroy(self);
        self.* = .{
            .io = io,
            .gpa = gpa,
            .world = world,
            .width = even_w,
            .height = even_h,
            .output = try gpa.dupe(u8, output),
        };
        errdefer gpa.free(self.output);
        const gpu = vaapiOk(io, gpa);
        var fps_buf: [8]u8 = undefined;
        const fps = try std.fmt.bufPrint(&fps_buf, "{d}", .{streamFps(even_w, even_h)});
        var quality_buf: [24]u8 = undefined;
        const quality = try std.fmt.bufPrint(&quality_buf, "global_quality={s}", .{vaapiQuality(even_w, even_h)});
        const log_path = try sys.join(gpa, world.runtime, "jpeg.log");
        defer gpa.free(log_path);
        const log_file = try std.Io.Dir.cwd().createFile(io, log_path, .{ .truncate = true });
        defer log_file.close(io);
        var env = try environ.clone(gpa);
        defer env.deinit();
        const argv_gpu = [_][]const u8{
            bin,
            "-o",
            self.output,
            "-d",
            vaapi_device,
            "-c",
            "mjpeg_vaapi",
            "-r",
            fps,
            "-p",
            quality,
            "-p",
            "async_depth=1",
            "-m",
            "mjpeg",
            "-f",
            "/dev/stdout",
            "-D",
        };
        const argv_cpu = [_][]const u8{
            bin,
            "-o",
            self.output,
            "-c",
            "mjpeg",
            "-r",
            fps,
            "-x",
            "yuvj420p",
            "-p",
            "qscale=4",
            "-p",
            "qmin=2",
            "-p",
            "qmax=6",
            "-m",
            "mjpeg",
            "-f",
            "/dev/stdout",
            "-D",
        };
        self.proc = try std.process.spawn(io, .{
            .argv = if (gpu) &argv_gpu else &argv_cpu,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .{ .file = log_file },
            .environ_map = &env,
        });
        errdefer {
            if (self.proc) |proc| {
                if (proc.id) |pid| _ = linux.kill(pid, .KILL);
            }
            finishChild(io, &self.proc);
        }
        if (self.proc.?.stdout) |out| widen(out.handle);
        if (self.proc.?.id) |pid| state.jpeg_pid.store(@intCast(pid), .release);
        self.thread = try std.Thread.spawn(.{}, readMain, .{self});
        note(io, if (gpu) "browser capture: GPU JPEG\n" else "browser capture: CPU JPEG\n");
        return self;
    }

    pub fn matches(self: *const Pump, output: []const u8, width: u32, height: u32) bool {
        const even_w = width & ~@as(u32, 1);
        const even_h = height & ~@as(u32, 1);
        return self.width == even_w and self.height == even_h and std.mem.eql(u8, self.output, output);
    }

    pub fn exited(self: *Pump) bool {
        if (self.failed.load(.acquire)) return true;
        return pollExit(&self.proc);
    }

    pub fn halt(self: *Pump) void {
        if (self.done.swap(true, .acq_rel)) return;
        const pid = if (self.proc) |proc| proc.id else null;
        state.jpeg_pid.store(-1, .release);
        if (pid) |id| _ = linux.kill(id, .KILL);
        if (self.thread) |thread| thread.join();
        self.thread = null;
        finishChild(self.io, &self.proc);
        self.gpa.free(self.output);
    }
};

fn readMain(self: *Pump) void {
    const file = (self.proc orelse return).stdout orelse return;
    const storage = self.gpa.alloc(u8, 8_000_000 + 65536) catch {
        self.failed.store(true, .release);
        return;
    };
    defer self.gpa.free(storage);
    var n: usize = 0;
    var chunk: [65536]u8 = undefined;
    while (!self.done.load(.acquire) and !self.world.stop.load(.acquire)) {
        const got = file.readStreaming(self.io, &.{&chunk}) catch break;
        if (got == 0) break;
        if (n + got > storage.len) {
            const keep = @min(n, 2_000_000);
            std.mem.copyForwards(u8, storage[0..keep], storage[n - keep .. n]);
            n = keep;
        }
        @memcpy(storage[n..][0..got], chunk[0..got]);
        n += got;
        while (nextJpeg(storage[0..n])) |jpg| {
            self.world.publish(storage[jpg.at .. jpg.at + jpg.len]);
            const used = jpg.at + jpg.len;
            std.mem.copyForwards(u8, storage[0 .. n - used], storage[used..n]);
            n -= used;
        }
        if (std.mem.lastIndexOf(u8, storage[0..n], &soi)) |start| {
            if (start > 0) {
                std.mem.copyForwards(u8, storage[0 .. n - start], storage[start..n]);
                n -= start;
            }
        } else if (n > 1) {
            storage[0] = storage[n - 1];
            n = 1;
        }
        if (n > 8_000_000) {
            std.mem.copyForwards(u8, storage[0..2_000_000], storage[n - 2_000_000 .. n]);
            n = 2_000_000;
        }
    }
    if (!self.done.load(.acquire)) self.failed.store(true, .release);
}

const soi = [_]u8{ 0xFF, 0xD8 };
const eoi = [_]u8{ 0xFF, 0xD9 };

const JpegSpan = struct { at: usize, len: usize };

fn nextJpeg(buf: []const u8) ?JpegSpan {
    const start = std.mem.indexOf(u8, buf, &soi) orelse return null;
    if (start + 4 > buf.len) return null;
    const rel = std.mem.indexOf(u8, buf[start + 2 ..], &eoi) orelse return null;
    return .{ .at = start, .len = rel + 4 };
}

pub fn streamFps(width: u32, height: u32) u32 {
    const pixels = width * height;
    if (pixels >= 3840 * 2160 * 9 / 10) return 8;
    if (pixels >= 2560 * 1440 * 9 / 10) return 12;
    return 20;
}

pub fn vaapiQuality(width: u32, height: u32) []const u8 {
    if (width * height > 1920 * 1080) return "80";
    return "90";
}

fn vaapiOk(io: std.Io, gpa: std.mem.Allocator) bool {
    const known = vaapi_known.load(.acquire);
    if (known == 1) return true;
    if (known == 2) return false;
    const ok = probeVaapi(io, gpa);
    vaapi_known.store(if (ok) 1 else 2, .release);
    return ok;
}

fn probeVaapi(io: std.Io, gpa: std.mem.Allocator) bool {
    if (!sys.exists(io, vaapi_device) or !sys.exists(io, "/usr/bin/ffmpeg")) return false;
    const argv = [_][]const u8{
        "ffmpeg",
        "-hide_banner",
        "-loglevel",
        "error",
        "-vaapi_device",
        vaapi_device,
        "-f",
        "lavfi",
        "-i",
        "nullsrc=size=64x64:rate=1",
        "-vf",
        "format=nv12,hwupload",
        "-c:v",
        "mjpeg_vaapi",
        "-frames:v",
        "1",
        "-f",
        "null",
        "-",
    };
    const ran = sys.run(gpa, io, &argv, 4000, 1024) catch return false;
    defer gpa.free(ran.stdout);
    defer gpa.free(ran.stderr);
    return ran.term_ok;
}

fn note(io: std.Io, msg: []const u8) void {
    var buf: [120]u8 = undefined;
    var w: std.Io.File.Writer = .initStreaming(.stderr(), io, &buf);
    w.interface.writeAll(msg) catch {};
    w.interface.flush() catch {};
}

fn widen(fd: std.posix.fd_t) void {
    _ = linux.fcntl(fd, linux.F.SETPIPE_SZ, 1 << 20);
}

fn pollExit(slot: *?std.process.Child) bool {
    var proc = slot.* orelse return false;
    const pid = proc.id orelse return false;
    var st: i32 = 0;
    const rc = linux.waitpid(pid, &st, linux.W.NOHANG);
    const err = linux.errno(rc);
    if (err == .INTR) return false;
    if (err == .SUCCESS and rc == 0) return false;
    proc.id = null;
    slot.* = proc;
    return true;
}

fn finishChild(io: std.Io, slot: *?std.process.Child) void {
    const proc = slot.* orelse return;
    slot.* = null;
    if (proc.id) |pid| {
        var st: i32 = 0;
        while (true) {
            const rc = linux.waitpid(pid, &st, 0);
            if (linux.errno(rc) != .INTR) break;
        }
    }
    if (proc.stdin) |file| file.close(io);
    if (proc.stdout) |file| file.close(io);
    if (proc.stderr) |file| file.close(io);
}

test "jpeg markers split a concatenated stream" {
    const raw = [_]u8{ 0x00, 0xFF, 0xD8, 0x11, 0xFF, 0xD9, 0xFF, 0xD8, 0x22 };
    const first = nextJpeg(&raw) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), first.at);
    try std.testing.expectEqual(@as(usize, 5), first.len);
    const rest = raw[first.at + first.len ..];
    try std.testing.expect(nextJpeg(rest) == null);
}

test "browser jpeg rate and quality follow the picture size" {
    try std.testing.expectEqual(@as(u32, 20), streamFps(1920, 1080));
    try std.testing.expectEqual(@as(u32, 12), streamFps(2560, 1440));
    try std.testing.expectEqual(@as(u32, 8), streamFps(3840, 2160));
    try std.testing.expectEqualStrings("90", vaapiQuality(1920, 1080));
    try std.testing.expectEqualStrings("80", vaapiQuality(2560, 1440));
}
