const std = @import("std");
const sys = @import("sys.zig");

var detail_buf: [320]u8 = undefined;
var detail_len: usize = 0;
var on_state: ?*const fn ([]const u8, []const u8, i32) void = null;
var on_stop: ?*const fn () bool = null;

pub fn bind(state_fn: *const fn ([]const u8, []const u8, i32) void, stop_fn: *const fn () bool) void {
    on_state = state_fn;
    on_stop = stop_fn;
}

pub fn unbind() void {
    on_state = null;
    on_stop = null;
}

pub fn clear() void {
    detail_len = 0;
}

pub fn get() []const u8 {
    return detail_buf[0..detail_len];
}

pub fn set(text: []const u8) void {
    const n = @min(text.len, detail_buf.len);
    @memcpy(detail_buf[0..n], text[0..n]);
    detail_len = n;
}

pub fn fail(io: std.Io, text: []const u8) error{Reported} {
    set(text);
    log(io, text);
    return error.Reported;
}

pub fn publish(state_name: []const u8, detail: []const u8, pid: i32) void {
    const f = on_state orelse return;
    f(state_name, detail, pid);
}

pub fn stopped() bool {
    const f = on_stop orelse return false;
    return f();
}

pub fn stalled(io: std.Io, path: []const u8, mark: *i64) bool {
    if (sys.fileMtimeMs(io, path)) |mtime| {
        if (sys.monoMs(io) - mtime <= 8000) mark.* = sys.monoMs(io);
    }
    return sys.monoMs(io) - mark.* > 12000;
}

pub fn log(io: std.Io, text: []const u8) void {
    var buf: [512]u8 = undefined;
    var w: std.Io.File.Writer = .init(.stderr(), io, &buf);
    var off: usize = 0;
    while (off < text.len) {
        const n = @min(buf.len / 2, text.len - off);
        w.interface.writeAll(text[off .. off + n]) catch return;
        w.interface.flush() catch return;
        off += n;
    }
    w.interface.writeAll("\n") catch return;
    w.interface.flush() catch {};
}
