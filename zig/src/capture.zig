//! One process captures the screen. gpu-screen-recorder's H.264 is remuxed into
//! HLS. If it produces no video, Hyprland screencopy frames are encoded here.
//! Desktop audio is PCM from pw-record or parecord, encoded as AAC-LC.
const std = @import("std");
const aac = @import("aac.zig");
const flv = @import("flv.zig");
const h264enc = @import("h264enc.zig");
const hls = @import("hls.zig");
const jpeg = @import("jpeg.zig");
const screencopy = @import("screencopy.zig");
const state = @import("state.zig");
const sys = @import("sys.zig");

const linux = std.os.linux;

pub const Mode = enum { gsr, screen };

pub const Pipeline = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    world: *state.World,
    mode: Mode,
    fps: u32,
    width: u32,
    height: u32,
    output: []u8,
    xdg: []const u8,
    display: []const u8,
    gsr: ?std.process.Child = null,
    audio: ?std.process.Child = null,
    // Nest Hub's player rejects the 1920x1080 capture. This second recorder
    // is the 1280x720 picture Cast loads. The browser keeps the full stream.
    cast: ?*hls.Writer = null,
    cast_gsr: ?std.process.Child = null,
    cast_thread: ?std.Thread = null,
    video: ?std.Thread = null,
    audio_thread: ?std.Thread = null,
    preview: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    failed: std.atomic.Value(bool) = .init(false),
    hls: *hls.Writer,

    pub fn start(
        io: std.Io,
        gpa: std.mem.Allocator,
        world: *state.World,
        environ: *const std.process.Environ.Map,
        output: []const u8,
        width: u32,
        height: u32,
        mode: Mode,
    ) !*Pipeline {
        if (!sys.safeName(output)) return error.BadOutput;
        const even_w = width & ~@as(u32, 1);
        const even_h = height & ~@as(u32, 1);
        if (even_w < 2 or even_h < 2) return error.BadOutput;
        if (mode == .gsr and !sys.exists(io, "/usr/bin/gpu-screen-recorder")) return error.NoCapture;
        const hls_dir = try sys.join(gpa, world.runtime, "hls");
        defer gpa.free(hls_dir);
        sys.ensureDir(io, hls_dir);
        sys.clearDir(io, hls_dir);
        _ = hls.ensureToken(io, gpa, world.runtime) catch {};
        const writer = try hls.Writer.init(io, gpa, hls_dir);
        const self = try gpa.create(Pipeline);
        self.* = .{
            .io = io,
            .gpa = gpa,
            .world = world,
            .mode = mode,
            .fps = streamFps(even_w, even_h),
            .width = even_w,
            .height = even_h,
            .output = try gpa.dupe(u8, output),
            .xdg = sys.envGet(environ, "XDG_RUNTIME_DIR") orelse "",
            .display = sys.envGet(environ, "WAYLAND_DISPLAY") orelse "",
            .hls = writer,
        };
        errdefer {
            self.halt();
            gpa.destroy(self);
        }
        const log_path = try sys.join(gpa, world.runtime, "capture.log");
        defer gpa.free(log_path);
        const log_file = try std.Io.Dir.cwd().createFile(io, log_path, .{ .truncate = true });
        defer log_file.close(io);
        var env = try environ.clone(gpa);
        defer env.deinit();
        _ = env.swapRemove("LIBVA_DRIVER_NAME");
        const sink = try defaultSink(gpa, io);
        defer gpa.free(sink);
        self.audio = spawnAudio(io, gpa, &env, sink, log_file);
        if (mode == .gsr) {
            var size_buf: [32]u8 = undefined;
            const size = try std.fmt.bufPrint(&size_buf, "{d}x{d}", .{ even_w, even_h });
            var rate_buf: [16]u8 = undefined;
            const rate = try std.fmt.bufPrint(&rate_buf, "{d}", .{bitrate(even_w, even_h)});
            var gsr_argv = [_][]const u8{
                "/usr/bin/gpu-screen-recorder",
                "-w",
                output,
                "-c",
                "flv",
                "-k",
                "h264",
                "-s",
                size,
                "-f",
                "30",
                "-fm",
                "vfr",
                "-bm",
                "cbr",
                "-q",
                rate,
                "-keyint",
                "0.5",
                "-encoder",
                "gpu",
                "-tune",
                "performance",
                "-cursor",
                "yes",
                "-ffmpeg-video-opts",
                "rc-lookahead=0;zerolatency=1;tune=ll",
                "-o",
                "/dev/stdout",
            };
            self.gsr = try std.process.spawn(io, .{
                .argv = &gsr_argv,
                .stdin = .ignore,
                .stdout = .pipe,
                .stderr = .{ .file = log_file },
                .environ_map = &env,
            });
            if (self.gsr.?.stdout) |out| widen(out.handle);
            if (self.gsr.?.id) |pid| state.gsr_pid.store(@intCast(pid), .release);
            self.video = try std.Thread.spawn(.{}, videoGsr, .{self});
            self.preview = try std.Thread.spawn(.{}, previewMain, .{self});
            startCastCapture(self, &env, log_file, even_w, even_h);
        } else {
            self.video = try std.Thread.spawn(.{}, screenMain, .{self});
        }
        if (self.audio) |proc| {
            if (proc.stdout) |out| widen(out.handle);
            if (proc.id) |pid| state.audio_pid.store(@intCast(pid), .release);
        }
        self.audio_thread = try std.Thread.spawn(.{}, audioMain, .{self});
        return self;
    }

    pub fn captureExited(self: *Pipeline) bool {
        if (self.mode == .screen) return self.failed.load(.acquire);
        return pollExit(&self.gsr);
    }

    pub fn halt(self: *Pipeline) void {
        if (self.done.swap(true, .acq_rel)) return;
        const capture_pid = if (self.gsr) |proc| proc.id else null;
        const audio_pid = if (self.audio) |proc| proc.id else null;
        const cast_pid = if (self.cast_gsr) |proc| proc.id else null;
        state.gsr_pid.store(-1, .release);
        state.audio_pid.store(-1, .release);
        if (capture_pid) |pid| _ = linux.kill(pid, .KILL);
        if (audio_pid) |pid| _ = linux.kill(pid, .KILL);
        if (cast_pid) |pid| _ = linux.kill(pid, .KILL);
        if (self.video) |thread| thread.join();
        if (self.cast_thread) |thread| thread.join();
        if (self.preview) |thread| thread.join();
        if (self.audio_thread) |thread| thread.join();
        self.video = null;
        self.cast_thread = null;
        self.preview = null;
        self.audio_thread = null;
        finishChild(self.io, &self.gsr);
        finishChild(self.io, &self.cast_gsr);
        finishChild(self.io, &self.audio);
        if (self.cast) |cast| cast.deinit();
        self.cast = null;
        self.hls.deinit();
        self.gpa.free(self.output);
    }
};

fn spawnAudio(
    io: std.Io,
    gpa: std.mem.Allocator,
    env: *std.process.Environ.Map,
    sink: []const u8,
    log_file: std.Io.File,
) ?std.process.Child {
    if (sink.len == 0) return null;
    var dev_buf: [240]u8 = undefined;
    if (sys.exists(io, "/usr/bin/pw-record")) {
        // A plain --target of the sink name is not a capture source, so
        // WirePlumber records the default microphone instead. capture.sink
        // makes it take that sink's monitor, which is the speaker mix.
        const argv = [_][]const u8{
            "/usr/bin/pw-record",
            "-a",
            "--rate",
            "48000",
            "--channels",
            "2",
            "--format",
            "s16",
            "--target",
            sink,
            "-P",
            "{ stream.capture.sink = true }",
            "-",
        };
        return std.process.spawn(io, .{
            .argv = &argv,
            .stdin = .ignore,
            .stdout = .pipe,
            .stderr = .{ .file = log_file },
            .environ_map = env,
        }) catch null;
    }
    if (!sys.exists(io, "/usr/bin/parecord")) return null;
    const dev = std.fmt.bufPrint(&dev_buf, "--device={s}.monitor", .{sink}) catch return null;
    const argv = [_][]const u8{
        "/usr/bin/parecord",
        dev,
        "--rate=48000",
        "--channels=2",
        "--format=s16le",
        "--raw",
    };
    _ = gpa;
    return std.process.spawn(io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .{ .file = log_file },
        .environ_map = env,
    }) catch null;
}

fn startCastCapture(self: *Pipeline, env: *std.process.Environ.Map, log_file: std.Io.File, width: u32, height: u32) void {
    const size = fitCast(width, height);
    if (size.w == width and size.h == height) return;
    const cast_writer = hls.Writer.init(self.io, self.gpa, self.hls.dir) catch return;
    cast_writer.live = false;
    self.cast = cast_writer;
    self.hls.files = false;
    var size_buf: [32]u8 = undefined;
    const size_text = std.fmt.bufPrint(&size_buf, "{d}x{d}", .{ size.w, size.h }) catch {
        dropCast(self);
        return;
    };
    var rate_buf: [16]u8 = undefined;
    const rate = std.fmt.bufPrint(&rate_buf, "{d}", .{bitrate(size.w, size.h)}) catch {
        dropCast(self);
        return;
    };
    const argv = [_][]const u8{
        "/usr/bin/gpu-screen-recorder",
        "-w",
        self.output,
        "-c",
        "flv",
        "-k",
        "h264",
        "-s",
        size_text,
        "-f",
        "30",
        "-fm",
        "vfr",
        "-bm",
        "cbr",
        "-q",
        rate,
        "-keyint",
        "0.5",
        "-encoder",
        "gpu",
        "-tune",
        "performance",
        "-cursor",
        "yes",
        "-ffmpeg-video-opts",
        "rc-lookahead=0;zerolatency=1;tune=ll",
        "-o",
        "/dev/stdout",
    };
    self.cast_gsr = std.process.spawn(self.io, .{
        .argv = &argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .{ .file = log_file },
        .environ_map = env,
    }) catch null;
    if (self.cast_gsr == null) {
        note(self, "cast recorder failed to start\n");
        dropCast(self);
        return;
    }
    if (self.cast_gsr.?.stdout) |out| widen(out.handle);
    self.cast_thread = std.Thread.spawn(.{}, videoCast, .{self}) catch {
        note(self, "cast recorder thread failed\n");
        const pid = if (self.cast_gsr) |proc| proc.id else null;
        if (pid) |id| _ = linux.kill(id, .KILL);
        finishChild(self.io, &self.cast_gsr);
        dropCast(self);
        return;
    };
}

fn dropCast(self: *Pipeline) void {
    self.hls.files = true;
    if (self.cast) |cast| cast.deinit();
    self.cast = null;
}

fn videoCast(self: *Pipeline) void {
    const cast_out = (self.cast_gsr orelse return).stdout orelse return;
    const cast = self.cast orelse return;
    const storage = self.gpa.alloc(u8, 4 * 1024 * 1024) catch return;
    defer self.gpa.free(storage);
    const au = self.gpa.alloc(u8, flv.au_max) catch return;
    defer self.gpa.free(au);
    var parser = flv.Parser{ .buf = storage };
    var chunk: [65536]u8 = undefined;
    while (!self.done.load(.acquire) and !self.world.stop.load(.acquire)) {
        const n = cast_out.readStreaming(self.io, &.{&chunk}) catch break;
        if (n == 0) break;
        var outcome = parser.push(chunk[0..n], au);
        while (true) {
            switch (outcome) {
                .none => break,
                .broken => {
                    parser.reset();
                    break;
                },
                .frame => |frame| {
                    cast.pushVideo(au[0..frame.len], @as(u64, frame.ts) * 90, frame.key);
                    outcome = parser.next(au);
                },
            }
        }
    }
}

fn videoGsr(self: *Pipeline) void {
    const gsr_out = self.gsr.?.stdout orelse return;
    const storage = self.gpa.alloc(u8, 4 * 1024 * 1024) catch return;
    defer self.gpa.free(storage);
    const au = self.gpa.alloc(u8, flv.au_max) catch return;
    defer self.gpa.free(au);
    var parser = flv.Parser{ .buf = storage };
    var chunk: [65536]u8 = undefined;
    while (!self.done.load(.acquire) and !self.world.stop.load(.acquire)) {
        const n = gsr_out.readStreaming(self.io, &.{&chunk}) catch break;
        if (n == 0) continue;
        var outcome = parser.push(chunk[0..n], au);
        while (true) {
            switch (outcome) {
                .none => break,
                .broken => {
                    parser.reset();
                    break;
                },
                .frame => |frame| {
                    self.hls.pushVideo(au[0..frame.len], @as(u64, frame.ts) * 90, frame.key);
                    outcome = parser.next(au);
                },
            }
        }
    }
}

fn note(self: *Pipeline, msg: []const u8) void {
    var buf: [320]u8 = undefined;
    var w: std.Io.File.Writer = .initStreaming(.stderr(), self.io, &buf);
    w.interface.writeAll(msg) catch {};
    w.interface.flush() catch {};
}

fn screenMain(self: *Pipeline) void {
    const client = screencopy.Client.connect(self.gpa, self.xdg, self.display, &self.done) orelse {
        var buf: [320]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "screencopy connect failed {s}/{s}\n", .{ self.xdg, self.display }) catch "screencopy connect failed\n";
        note(self, msg);
        self.failed.store(true, .release);
        return;
    };
    defer client.deinit();
    var enc: ?*h264enc.Encoder = null;
    defer if (enc) |item| item.deinit();
    const au = self.gpa.alloc(u8, 2 * 1024 * 1024) catch {
        self.failed.store(true, .release);
        return;
    };
    defer self.gpa.free(au);
    var index: u64 = 0;
    const period: i64 = @intCast(@divTrunc(@as(u64, 1000), self.fps));
    while (!self.done.load(.acquire) and !self.world.stop.load(.acquire)) {
        const started = sys.monoMs(self.io);
        var shot = client.grab(self.output, self.width, self.height) orelse {
            if (self.done.load(.acquire) or self.world.stop.load(.acquire)) break;
            var buf: [160]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "screencopy grab failed {s} {d}x{d}\n", .{ self.output, self.width, self.height }) catch "screencopy grab failed\n";
            note(self, msg);
            self.failed.store(true, .release);
            break;
        };
        defer shot.deinit();
        publishJpeg(self, shot.pixels, shot.width, shot.height, shot.stride);
        if (enc == null or enc.?.width != shot.width or enc.?.height != shot.height) {
            if (enc) |item| item.deinit();
            enc = h264enc.Encoder.init(self.gpa, shot.width, shot.height, self.fps) catch {
                note(self, "screencopy encoder init failed\n");
                self.failed.store(true, .release);
                break;
            };
        }
        const frame = enc.?.encodeBgra(shot.pixels, shot.stride, au) catch continue;
        const pts = index * 90000 / self.fps;
        self.hls.pushVideo(au[0..frame.len], pts, frame.key);
        index += 1;
        const spent = sys.monoMs(self.io) - started;
        if (spent < period) sys.sleepMs(self.io, period - spent);
    }
}

fn previewMain(self: *Pipeline) void {
    const client = screencopy.Client.connect(self.gpa, self.xdg, self.display, &self.done) orelse return;
    defer client.deinit();
    while (!self.done.load(.acquire) and !self.world.stop.load(.acquire)) {
        const started = sys.monoMs(self.io);
        var shot = client.grab(self.output, self.width, self.height) orelse {
            if (self.done.load(.acquire) or self.world.stop.load(.acquire)) break;
            break;
        };
        defer shot.deinit();
        publishJpeg(self, shot.pixels, shot.width, shot.height, shot.stride);
        const spent = sys.monoMs(self.io) - started;
        if (spent < 200) sys.sleepMs(self.io, 200 - spent);
    }
}

fn publishJpeg(self: *Pipeline, pixels: []const u8, width: u32, height: u32, stride: u32) void {
    const jpg = jpeg.encodeBgra(self.gpa, pixels, width, height, stride) catch return;
    defer self.gpa.free(jpg);
    self.world.publish(jpg);
}

fn audioMain(self: *Pipeline) void {
    var enc = aac.Encoder.init();
    var pcm: [2048]i16 = undefined;
    var adts: [4096]u8 = undefined;
    var raw: [4096]u8 = undefined;
    var pts: u64 = 0;
    var record = if (self.audio) |proc| proc.stdout else null;
    while (!self.done.load(.acquire) and !self.world.stop.load(.acquire)) {
        var got = false;
        if (record) |file| {
            if (readable(file, 400)) got = readExact(self.io, file, &raw);
            if (!got) {
                if (self.audio) |proc| if (proc.id) |pid| {
                    _ = linux.kill(pid, .KILL);
                };
                record = null;
            }
        }
        if (got) {
            var i: usize = 0;
            while (i < 1024) : (i += 1) {
                pcm[i * 2] = std.mem.readInt(i16, raw[i * 4 ..][0..2], .little);
                pcm[i * 2 + 1] = std.mem.readInt(i16, raw[i * 4 + 2 ..][0..2], .little);
            }
        } else {
            @memset(&pcm, 0);
        }
        const n = enc.encode(&pcm, &adts);
        if (n > 0) {
            while (!self.hls.pushAudio(adts[0..n], pts)) {
                if (self.done.load(.acquire) or self.world.stop.load(.acquire)) return;
                pauseMs(5);
            }
            // A full Cast queue must not stall the browser stream.
            if (self.cast) |cast| _ = cast.pushAudio(adts[0..n], pts);
            pts += 1920;
        }
        // Pace silence. A recording read already blocks on the pipe.
        if (!got) pauseMs(21);
    }
}

fn readable(file: std.Io.File, timeout_ms: i32) bool {
    var pfd = [1]linux.pollfd{.{
        .fd = file.handle,
        .events = linux.POLL.IN,
    }};
    while (true) {
        const rc = linux.poll(&pfd, 1, timeout_ms);
        const err = linux.errno(rc);
        if (err == .INTR) continue;
        if (err != .SUCCESS or rc == 0) return false;
        const rev: u16 = @bitCast(pfd[0].revents);
        return (rev & (linux.POLL.IN | linux.POLL.HUP | linux.POLL.ERR | linux.POLL.NVAL)) != 0;
    }
}

fn pauseMs(ms: i64) void {
    if (ms <= 0) return;
    var req = linux.timespec{
        .sec = @intCast(@divTrunc(ms, 1000)),
        .nsec = @intCast(@mod(ms, 1000) * 1_000_000),
    };
    while (true) {
        var rem: linux.timespec = undefined;
        const rc = linux.nanosleep(&req, &rem);
        if (linux.errno(rc) != .INTR) return;
        req = rem;
    }
}

fn readExact(io: std.Io, file: std.Io.File, dest: []u8) bool {
    var off: usize = 0;
    while (off < dest.len) {
        var buf: [4096]u8 = undefined;
        const want = @min(buf.len, dest.len - off);
        const n = file.readStreaming(io, &.{buf[0..want]}) catch return false;
        if (n == 0) return false;
        @memcpy(dest[off..][0..n], buf[0..n]);
        off += n;
    }
    return true;
}

fn widen(fd: std.posix.fd_t) void {
    _ = linux.fcntl(fd, linux.F.SETPIPE_SZ, 1 << 20);
}

fn streamFps(width: u32, height: u32) u32 {
    const pixels = width * height;
    if (pixels >= 3840 * 2160 * 9 / 10) return 8;
    if (pixels >= 2560 * 1440 * 9 / 10) return 12;
    return 20;
}

const CastSize = struct { w: u32, h: u32 };

fn fitCast(width: u32, height: u32) CastSize {
    const max_w: u32 = 1280;
    const max_h: u32 = 720;
    if (width <= max_w and height <= max_h) return .{ .w = width, .h = height };
    if (max_w * height <= max_h * width) {
        var fitted = max_w * height / width;
        fitted &= ~@as(u32, 1);
        if (fitted < 2) fitted = 2;
        return .{ .w = max_w, .h = fitted };
    }
    var fitted = max_h * width / height;
    fitted &= ~@as(u32, 1);
    if (fitted < 2) fitted = 2;
    return .{ .w = fitted, .h = max_h };
}

fn bitrate(width: u32, height: u32) u32 {
    const pixels = width * height;
    if (pixels <= 1280 * 720) return 4000;
    if (pixels <= 1920 * 1080) return 8000;
    if (pixels <= 2560 * 1440) return 12000;
    return 20000;
}

test "cast picture fits inside 1280x720" {
    const hd = fitCast(1920, 1080);
    try std.testing.expectEqual(@as(u32, 1280), hd.w);
    try std.testing.expectEqual(@as(u32, 720), hd.h);
    const same = fitCast(1280, 720);
    try std.testing.expectEqual(@as(u32, 1280), same.w);
    try std.testing.expectEqual(@as(u32, 720), same.h);
    const small = fitCast(800, 600);
    try std.testing.expectEqual(@as(u32, 800), small.w);
    try std.testing.expectEqual(@as(u32, 600), small.h);
    const wide = fitCast(1920, 1200);
    try std.testing.expectEqual(@as(u32, 1152), wide.w);
    try std.testing.expectEqual(@as(u32, 720), wide.h);
}

fn defaultSink(gpa: std.mem.Allocator, io: std.Io) ![]u8 {
    const ran = sys.run(gpa, io, &.{ "pactl", "get-default-sink" }, 2000, 1024) catch return gpa.dupe(u8, "");
    defer gpa.free(ran.stdout);
    defer gpa.free(ran.stderr);
    const sink = std.mem.trim(u8, ran.stdout, " \t\r\n");
    if (!ran.term_ok or sink.len == 0 or std.mem.indexOfAny(u8, sink, " \t") != null) return gpa.dupe(u8, "");
    return gpa.dupe(u8, sink);
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
