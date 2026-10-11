//! A numbered desktop is recorded from the real monitor that is already showing
//! it. When no real monitor shows it, the desktop moves to a headless screen
//! placed past the other monitors, and the recording follows it. Focusing that
//! desktop brings it back onto the screen you are looking at.
const std = @import("std");
const jsonx = @import("jsonx.zig");
const state = @import("state.zig");
const sys = @import("sys.zig");

const linux = std.os.linux;

const layout_lua = @embedFile("layout.lua");

pub const Monitor = struct {
    name: []const u8,
    focused: bool,
    x: i64,
    y: i64,
    width: i64,
    height: i64,
    scale: f64,
    workspace: i64,
    disabled: bool,
    transform: i32,
};

pub const Cast = struct {
    follow: bool = true,
    auto: bool = true,
    workspace: i32 = 0,
    width: u32 = 1920,
    height: u32 = 1080,
};

pub const Plan = struct {
    output: []const u8,
    width: u32,
    height: u32,
    follow: bool,
    virtual_out: bool,
    workspace: i32,
};

const candidates = [_][]const u8{ "screenmirror", "castscreen" };

pub fn readCast(arena: std.mem.Allocator, io: std.Io, gpa: std.mem.Allocator, path: []const u8) Cast {
    var cast = Cast{};
    const text = sys.readAll(io, gpa, path, 8192) orelse return cast;
    defer gpa.free(text);
    const value = jsonx.parse(arena, text) catch return cast;
    if (value.get("follow")) |item| if (item.asBool()) |bit| {
        cast.follow = bit;
    };
    if (value.get("auto")) |item| if (item.asBool()) |bit| {
        cast.auto = bit;
    };
    if (value.get("workspace")) |item| if (item.asInt()) |id| {
        cast.workspace = @intCast(id);
    };
    if (value.get("width")) |item| if (item.asInt()) |n| if (n > 0) {
        cast.width = @intCast(n);
    };
    if (value.get("height")) |item| if (item.asInt()) |n| if (n > 0) {
        cast.height = @intCast(n);
    };
    if (cast.follow or cast.workspace <= 0) cast.follow = true;
    return cast;
}

pub fn monitors(arena: std.mem.Allocator, io: std.Io, gpa: std.mem.Allocator) ![]Monitor {
    const result = try sys.run(gpa, io, &.{ "hyprctl", "monitors", "-j" }, 3000, 1024 * 1024);
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    if (!result.term_ok and result.stdout.len == 0) return error.Hyprland;
    const value = jsonx.parse(arena, result.stdout) catch return error.Hyprland;
    const list = switch (value) {
        .array => |items| items,
        else => return error.Hyprland,
    };
    var out: std.ArrayList(Monitor) = .empty;
    for (list.items) |item| {
        const name = (item.get("name") orelse continue).asString() orelse continue;
        if (!sys.safeName(name)) continue;
        try out.append(arena, .{
            .name = try arena.dupe(u8, name),
            .focused = if (item.get("focused")) |bit| bit.asBool() orelse false else false,
            .x = if (item.get("x")) |n| n.asInt() orelse 0 else 0,
            .y = if (item.get("y")) |n| n.asInt() orelse 0 else 0,
            .width = if (item.get("width")) |n| n.asInt() orelse 0 else 0,
            .height = if (item.get("height")) |n| n.asInt() orelse 0 else 0,
            .scale = if (item.get("scale")) |n| n.asFloat() orelse 1 else 1,
            .workspace = workspaceId(item),
            .disabled = if (item.get("disabled")) |bit| bit.asBool() orelse false else false,
            .transform = if (item.get("transform")) |n| @intCast(n.asInt() orelse 0) else 0,
        });
    }
    return out.toOwnedSlice(arena);
}

fn workspaceId(item: jsonx.Value) i64 {
    const ws = item.get("activeWorkspace") orelse return 0;
    const id = ws.get("id") orelse return 0;
    return id.asInt() orelse 0;
}

pub fn workspaces(arena: std.mem.Allocator, io: std.Io, gpa: std.mem.Allocator) ![]i64 {
    const result = sys.run(gpa, io, &.{ "hyprctl", "workspaces", "-j" }, 3000, 256 * 1024) catch return &.{};
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    const value = jsonx.parse(arena, result.stdout) catch return &.{};
    const list = switch (value) {
        .array => |items| items,
        else => return &.{},
    };
    var out: std.ArrayList(i64) = .empty;
    for (list.items) |item| {
        const id = (item.get("id") orelse continue).asInt() orelse continue;
        if (id >= 1 and id <= 10) try out.append(arena, id);
    }
    return out.toOwnedSlice(arena);
}

pub fn isVirtual(name: []const u8) bool {
    for (candidates) |item| if (std.mem.eql(u8, name, item)) return true;
    return std.mem.startsWith(u8, name, "HEADLESS");
}

pub const Target = enum { laptop, virtual };

/// `opening` is the desktop the user just selected on the virtual screen.
/// Hyprland then bounces focus back to the laptop, so the laptop workspace
/// alone misses that selection.
pub fn captureTarget(follow: bool, wanted: i32, showing: bool, opening: i32) Target {
    if (follow or wanted < 1) return .laptop;
    if (showing or opening == wanted) return .laptop;
    return .virtual;
}

pub const Focus = struct {
    open: i32 = 0,
    at: i64 = 0,
    seen: i64 = 0,
};

pub const FocusKind = enum { stay, bounce, open, laptop };

pub fn noteFocus(focus: *Focus, virtual_output: bool, workspace: i64, now: i64) FocusKind {
    if (workspace < 1 or workspace > 10) return .stay;
    if (now < ignore_open_until.load(.acquire)) {
        if (!virtual_output) focus.seen = workspace;
        return .stay;
    }
    if (virtual_output) {
        focus.open = @intCast(workspace);
        focus.at = now;
        return .open;
    }
    if (focus.open != 0 and now - focus.at < 500 and workspace == focus.seen) return .bounce;
    focus.open = 0;
    focus.seen = workspace;
    return .laptop;
}

pub fn laptop(items: []const Monitor) ?Monitor {
    for (items) |item| {
        if (item.disabled or item.width <= 0 or isVirtual(item.name)) continue;
        if (std.mem.startsWith(u8, item.name, "eDP")) return item;
    }
    for (items) |item| {
        if (item.disabled or item.width <= 0 or isVirtual(item.name)) continue;
        return item;
    }
    return null;
}

pub fn focused(items: []const Monitor) ?Monitor {
    for (items) |item| {
        if (item.focused and !item.disabled and item.width > 0 and !isVirtual(item.name)) return item;
    }
    return laptop(items);
}

fn axisSwaps(transform: i32) bool {
    return transform == 1 or transform == 3 or transform == 5 or transform == 7;
}

/// Right edge past every real monitor. A rotated panel reports its unrotated
/// mode size, so the span uses the longer side and the headless screen cannot
/// land on top of that panel.
fn logicalWidth(item: Monitor) i64 {
    if (axisSwaps(item.transform)) return @max(item.width, item.height);
    return item.width;
}

pub fn freeOrigin(items: []const Monitor) struct { x: i64, y: i64 } {
    var right: i64 = 0;
    var top: i64 = 0;
    var any = false;
    for (items) |item| {
        if (item.disabled or item.width <= 0 or isVirtual(item.name)) continue;
        if (!any or item.y < top) top = item.y;
        any = true;
        const edge = item.x + logicalWidth(item);
        if (edge > right) right = edge;
    }
    return .{ .x = right, .y = if (any) top else 0 };
}

fn overlapsReal(items: []const Monitor, virt: Monitor) bool {
    const vw: i64 = virt.width;
    const vh: i64 = virt.height;
    if (vw <= 0 or vh <= 0) return false;
    for (items) |item| {
        if (item.disabled or item.width <= 0 or isVirtual(item.name)) continue;
        const iw = logicalWidth(item);
        const ih: i64 = if (axisSwaps(item.transform)) @max(item.width, item.height) else item.height;
        const separated = virt.x >= item.x + iw or virt.x + vw <= item.x or virt.y >= item.y + ih or virt.y + vh <= item.y;
        if (!separated) return true;
    }
    return false;
}

fn monitorShowing(items: []const Monitor, workspace: i32) ?Monitor {
    var found: ?Monitor = null;
    for (items) |item| {
        if (item.disabled or item.width <= 0 or isVirtual(item.name)) continue;
        if (item.workspace != workspace) continue;
        if (item.focused) return item;
        if (found == null) found = item;
    }
    return found;
}

fn realHost(items: []const Monitor) []const u8 {
    if (focused(items)) |item| return item.name;
    return "";
}

fn virtualMonitor(items: []const Monitor) ?Monitor {
    for (items) |item| if (isVirtual(item.name) and !item.disabled and item.width > 0) return item;
    return null;
}

fn replaceAll(arena: std.mem.Allocator, text: []const u8, needle: []const u8, repl: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (std.mem.startsWith(u8, text[i..], needle)) {
            try out.appendSlice(arena, repl);
            i += needle.len;
        } else {
            try out.append(arena, text[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(arena);
}

fn runLayout(arena: std.mem.Allocator, io: std.Io, gpa: std.mem.Allocator, runtime: []const u8, mode: []const u8, wanted: i32, output: []const u8, host: []const u8) ![]u8 {
    const result_path = try sys.join(gpa, runtime, "layout.txt");
    defer gpa.free(result_path);
    sys.removeFile(io, result_path);
    var body = try replaceAll(arena, layout_lua, "__OUTPUT__", output);
    body = try replaceAll(arena, body, "__MODE__", mode);
    const wanted_text = try std.fmt.allocPrint(arena, "{d}", .{wanted});
    body = try replaceAll(arena, body, "__WANTED__", wanted_text);
    const host_name = if (sys.safeName(host)) host else "";
    body = try replaceAll(arena, body, "__HOST__", host_name);
    const wrapper = try std.fmt.allocPrint(arena,
        \\local __line = 'ok'
        \\local __ok, __err = pcall(function()
        \\{s}
        \\end)
        \\local __f = io.open('{s}', 'w')
        \\if __f then
        \\  if __ok then __f:write(__line or 'ok') else __f:write('err ' .. tostring(__err)) end
        \\  __f:write('\n')
        \\  __f:close()
        \\end
    , .{ body, result_path });
    const ran = try sys.run(gpa, io, &.{ "hyprctl", "eval", wrapper }, 4000, 64 * 1024);
    defer gpa.free(ran.stdout);
    defer gpa.free(ran.stderr);
    return sys.readAll(io, arena, result_path, 4096) orelse try arena.dupe(u8, "");
}

fn hypr(io: std.Io, gpa: std.mem.Allocator, argv: []const []const u8) void {
    const ran = sys.run(gpa, io, argv, 3000, 64 * 1024) catch return;
    gpa.free(ran.stdout);
    gpa.free(ran.stderr);
}

// grim and wf-recorder wait forever when Hyprland reports dpmsStatus false.
// gpu-screen-recorder reads the CRTC itself, so it does not notice.
pub fn wake(io: std.Io, gpa: std.mem.Allocator) void {
    hypr(io, gpa, &.{ "hyprctl", "dispatch", "hl.dsp.dpms({ action = \"enable\" })" });
}

fn ensureVirtual(arena: std.mem.Allocator, io: std.Io, gpa: std.mem.Allocator) ![]const u8 {
    var seen = monitors(arena, io, gpa) catch return error.Hyprland;
    if (virtualMonitor(seen)) |item| return item.name;
    for (candidates) |name| {
        hypr(io, gpa, &.{ "hyprctl", "output", "create", "headless", name });
        var i: usize = 0;
        while (i < 25) : (i += 1) {
            sys.sleepMs(io, 40);
            seen = monitors(arena, io, gpa) catch continue;
            for (seen) |item| {
                if (std.mem.eql(u8, item.name, name) and item.width > 0 and !item.disabled) return name;
            }
        }
    }
    return error.Hyprland;
}

fn configure(arena: std.mem.Allocator, io: std.Io, gpa: std.mem.Allocator, items: []const Monitor, output: []const u8, width: u32, height: u32) !void {
    const place = freeOrigin(items);
    const code = try std.fmt.allocPrint(arena,
        "hl.monitor({{ output = \"{s}\", mode = \"{d}x{d}@60\", position = \"{d}x{d}\", scale = 1 }})",
        .{ output, width, height, place.x, place.y },
    );
    hypr(io, gpa, &.{ "hyprctl", "eval", code });
}

pub fn release(arena: std.mem.Allocator, io: std.Io, gpa: std.mem.Allocator, runtime: []const u8) void {
    const seen = monitors(arena, io, gpa) catch return;
    const virt = virtualMonitor(seen) orelse return;
    _ = runLayout(arena, io, gpa, runtime, "release", 0, virt.name, "") catch {};
    hypr(io, gpa, &.{ "hyprctl", "output", "remove", virt.name });
}

fn even(value: u32) u32 {
    return value - (value % 2);
}

fn fit(cast: Cast, native_w: i64, native_h: i64, virtual_out: bool) struct { w: u32, h: u32 } {
    var width = cast.width;
    var height = cast.height;
    if (cast.auto) {
        width = 1920;
        height = 1080;
    }
    if (!virtual_out and native_w > 0 and native_h > 0) {
        if (width > native_w or height > native_h) {
            width = @intCast(native_w);
            height = @intCast(native_h);
        }
    }
    if (width < 2) width = 2;
    if (height < 2) height = 2;
    return .{ .w = even(width), .h = even(height) };
}

pub fn previewTarget(arena: std.mem.Allocator, io: std.Io, gpa: std.mem.Allocator, cast: Cast) !Target {
    if (cast.follow or cast.workspace < 1) return .laptop;
    const seen = try monitors(arena, io, gpa);
    const showing = monitorShowing(seen, cast.workspace) != null;
    return captureTarget(false, cast.workspace, showing, currentOpen());
}

pub fn plan(arena: std.mem.Allocator, io: std.Io, gpa: std.mem.Allocator, runtime: []const u8, cast: Cast) !Plan {
    const seen = monitors(arena, io, gpa) catch {
        const size = fit(cast, 1920, 1080, false);
        return .{
            .output = try arena.dupe(u8, "HDMI-A-1"),
            .width = size.w,
            .height = size.h,
            .follow = true,
            .virtual_out = false,
            .workspace = 1,
        };
    };
    const host = laptop(seen) orelse return error.Hyprland;
    rememberLaptop(host.workspace);
    if (cast.follow) {
        if (virtualMonitor(seen) != null) release(arena, io, gpa, runtime);
        const fresh = monitors(arena, io, gpa) catch seen;
        const screen = focused(fresh) orelse host;
        rememberLaptop(screen.workspace);
        const size = fit(cast, screen.width, screen.height, false);
        return .{
            .output = screen.name,
            .width = size.w,
            .height = size.h,
            .follow = true,
            .virtual_out = false,
            .workspace = @intCast(screen.workspace),
        };
    }
    const wanted = cast.workspace;
    if (wanted < 1 or wanted > 10) return error.Hyprland;
    const opening = currentOpen();
    if (opening == wanted) {
        const dest = focused(seen) orelse host;
        const virt_name = if (virtualMonitor(seen)) |item| item.name else candidates[0];
        const line = try runLayout(arena, io, gpa, runtime, "borrow", wanted, virt_name, dest.name);
        if (!std.mem.startsWith(u8, line, "ok")) return error.Hyprland;
        if (virtualMonitor(seen) != null) release(arena, io, gpa, runtime);
        clearOpening();
        const fresh = monitors(arena, io, gpa) catch seen;
        const shown = monitorShowing(fresh, wanted) orelse focused(fresh) orelse dest;
        rememberLaptop(shown.workspace);
        const size = fit(cast, shown.width, shown.height, false);
        return .{
            .output = shown.name,
            .width = size.w,
            .height = size.h,
            .follow = false,
            .virtual_out = false,
            .workspace = wanted,
        };
    }
    if (monitorShowing(seen, wanted)) |screen| {
        if (virtualMonitor(seen) != null) release(arena, io, gpa, runtime);
        clearOpening();
        const fresh = monitors(arena, io, gpa) catch seen;
        const shown = monitorShowing(fresh, wanted) orelse screen;
        rememberLaptop(shown.workspace);
        const size = fit(cast, shown.width, shown.height, false);
        return .{
            .output = shown.name,
            .width = size.w,
            .height = size.h,
            .follow = false,
            .virtual_out = false,
            .workspace = wanted,
        };
    }
    clearOpening();
    const size = fit(cast, 0, 0, true);
    if (virtualMonitor(seen)) |virt| {
        const settled = virt.workspace == wanted and virt.width == size.w and virt.height == size.h and @abs(virt.scale - 1.0) < 0.01 and !overlapsReal(seen, virt);
        if (settled) {
            return .{
                .output = virt.name,
                .width = size.w,
                .height = size.h,
                .follow = false,
                .virtual_out = true,
                .workspace = wanted,
            };
        }
    }
    const output = try ensureVirtual(arena, io, gpa);
    const again = monitors(arena, io, gpa) catch seen;
    const desk = realHost(again);
    try configure(arena, io, gpa, again, output, size.w, size.h);
    sys.sleepMs(io, 150);
    const line = try runLayout(arena, io, gpa, runtime, "show", wanted, output, desk);
    if (!std.mem.startsWith(u8, line, "ok")) return error.Hyprland;
    suppressOpen(1500);
    _ = runLayout(arena, io, gpa, runtime, "focus", 0, output, desk) catch {};
    const parked = monitors(arena, io, gpa) catch again;
    if (laptop(parked)) |item| rememberLaptop(item.workspace);
    return .{
        .output = try arena.dupe(u8, output),
        .width = size.w,
        .height = size.h,
        .follow = false,
        .virtual_out = true,
        .workspace = wanted,
    };
}

var focus_lock = std.atomic.Value(bool).init(false);
var focus_state = Focus{};
var quiet = std.atomic.Value(bool).init(false);
var dirty = std.atomic.Value(bool).init(false);
var depart = std.atomic.Value(bool).init(false);
var cast_ws = std.atomic.Value(i32).init(0);
var on_laptop = std.atomic.Value(bool).init(false);
var ignore_open_until = std.atomic.Value(i64).init(0);
var watch_buf: [80]u8 = undefined;
var watch_len: usize = 0;
var desk_gate = std.atomic.Value(u32).init(0);
var watch_stop = std.atomic.Value(bool).init(false);
var watch_thread: ?std.Thread = null;
var sock_buf: [108]u8 = undefined;
var sock_len: usize = 0;

fn lockFocus() void {
    while (focus_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
        std.atomic.spinLoopHint();
    }
}

fn unlockFocus() void {
    focus_lock.store(false, .release);
}

fn currentOpen() i32 {
    lockFocus();
    defer unlockFocus();
    return focus_state.open;
}

fn clearOpening() void {
    lockFocus();
    defer unlockFocus();
    focus_state.open = 0;
}

fn suppressOpen(ms: i64) void {
    lockFocus();
    defer unlockFocus();
    ignore_open_until.store(nowMs() + ms, .release);
    focus_state.open = 0;
}

fn rememberLaptop(workspace: i64) void {
    if (workspace < 1 or workspace > 10) return;
    lockFocus();
    defer unlockFocus();
    focus_state.seen = workspace;
}

pub fn setQuiet(on: bool) void {
    quiet.store(on, .release);
}

pub fn setWatch(workspace: i32, laptop_capture: bool, output: []const u8) void {
    cast_ws.store(workspace, .release);
    on_laptop.store(laptop_capture, .release);
    lockFocus();
    defer unlockFocus();
    const n = @min(output.len, watch_buf.len);
    @memcpy(watch_buf[0..n], output[0..n]);
    watch_len = n;
}

pub fn takeDirty() bool {
    return dirty.swap(false, .acq_rel);
}

pub fn takeDepart() bool {
    return depart.swap(false, .acq_rel);
}

pub fn deskToken() u32 {
    return desk_gate.load(.acquire);
}

pub fn waitDesk(seen: u32, timeout_ms: i32) u32 {
    const now = desk_gate.load(.acquire);
    if (now != seen or timeout_ms <= 0) return now;
    var ts = linux.timespec{
        .sec = @intCast(@divTrunc(timeout_ms, 1000)),
        .nsec = @intCast(@mod(timeout_ms, 1000) * 1_000_000),
    };
    const op = linux.FUTEX_OP{ .cmd = .WAIT, .private = true };
    _ = linux.futex_4arg(&desk_gate.raw, op, seen, &ts);
    return desk_gate.load(.acquire);
}

fn pokeDesk() void {
    _ = desk_gate.fetchAdd(1, .release);
    const op = linux.FUTEX_OP{ .cmd = .WAKE, .private = true };
    _ = linux.futex_3arg(&desk_gate.raw, op, std.math.maxInt(u32));
}

fn freezePicture() void {
    depart.store(true, .release);
    const jpeg = state.jpeg_pid.load(.acquire);
    if (jpeg > 0) _ = linux.kill(jpeg, .KILL);
    const gsr = state.gsr_pid.load(.acquire);
    if (gsr > 0) _ = linux.kill(gsr, .KILL);
}

fn noteDesktop(line: []const u8, now_ms: i64) void {
    if (quiet.load(.acquire)) return;
    if (std.mem.startsWith(u8, line, "focusedmon>>") or std.mem.startsWith(u8, line, "focusedmonv2>>")) {
        const parsed = parseFocus(line) orelse return;
        var kind: FocusKind = .stay;
        var same = false;
        lockFocus();
        kind = noteFocus(&focus_state, parsed.virtual_output, parsed.workspace, now_ms);
        const open = focus_state.open;
        same = watch_len > 0 and std.mem.eql(u8, watch_buf[0..watch_len], parsed.name);
        unlockFocus();
        if (kind == .stay or kind == .bounce) return;
        dirty.store(true, .release);
        const wanted = cast_ws.load(.acquire);
        const laptop_capture = on_laptop.load(.acquire);
        if (kind == .open and !laptop_capture and open == wanted and wanted > 0) freezePicture();
        if (kind == .laptop and laptop_capture and same and parsed.workspace != wanted and wanted > 0) freezePicture();
        pokeDesk();
        return;
    }
    const watched = [_][]const u8{
        "workspace>>",         "workspacev2>>",
        "moveworkspace>>",     "moveworkspacev2>>",
        "createworkspace>>",   "createworkspacev2>>",
        "destroyworkspace>>",  "destroyworkspacev2>>",
        "monitoradded>>",      "monitorremoved>>",
        "configreloaded>>",
    };
    for (watched) |prefix| if (std.mem.startsWith(u8, line, prefix)) {
        dirty.store(true, .release);
        pokeDesk();
        return;
    };
}

const ParsedFocus = struct { name: []const u8, virtual_output: bool, workspace: i64 };

fn parseFocus(line: []const u8) ?ParsedFocus {
    const mark = std.mem.indexOf(u8, line, ">>") orelse return null;
    const payload = line[mark + 2 ..];
    const comma = std.mem.indexOfScalar(u8, payload, ',') orelse return null;
    const name = payload[0..comma];
    if (!sys.safeName(name)) return null;
    const workspace = std.fmt.parseInt(i64, payload[comma + 1 ..], 10) catch return null;
    return .{ .name = name, .virtual_output = isVirtual(name), .workspace = workspace };
}

pub fn startWatch(env: *const std.process.Environ.Map) void {
    if (watch_thread != null) return;
    const base = sys.envGet(env, "XDG_RUNTIME_DIR") orelse return;
    const sig = sys.envGet(env, "HYPRLAND_INSTANCE_SIGNATURE") orelse return;
    const path = std.fmt.bufPrint(&sock_buf, "{s}/hypr/{s}/.socket2.sock", .{ base, sig }) catch return;
    sock_len = path.len;
    watch_stop.store(false, .release);
    watch_thread = std.Thread.spawn(.{}, watchMain, .{}) catch null;
}

pub fn finishWatch() void {
    watch_stop.store(true, .release);
    if (watch_thread) |thread| {
        thread.join();
        watch_thread = null;
    }
}

fn watchMain() void {
    const path = sock_buf[0..sock_len];
    while (!watch_stop.load(.acquire) and !state.shutdown.load(.acquire)) {
        const fd = openEventSocket(path) orelse {
            pauseMs(500);
            continue;
        };
        var held: [512]u8 = undefined;
        var n: usize = 0;
        while (!watch_stop.load(.acquire) and !state.shutdown.load(.acquire)) {
            var pfd = linux.pollfd{ .fd = fd, .events = linux.POLL.IN };
            const waited = linux.poll(@ptrCast(&pfd), 1, 400);
            const err = linux.errno(waited);
            if (err == .INTR) continue;
            if (err != .SUCCESS) break;
            if (waited == 0) continue;
            if (n >= held.len) n = 0;
            const got = linux.read(fd, held[n..].ptr, held.len - n);
            const rerr = linux.errno(got);
            if (rerr == .INTR) continue;
            if (rerr != .SUCCESS or got == 0) break;
            n += got;
            while (std.mem.indexOfScalar(u8, held[0..n], '\n')) |end| {
                noteDesktop(held[0..end], nowMs());
                const rest = end + 1;
                std.mem.copyForwards(u8, held[0 .. n - rest], held[rest..n]);
                n -= rest;
            }
        }
        _ = linux.close(fd);
    }
}

fn nowMs() i64 {
    var ts: linux.timespec = undefined;
    const rc = linux.clock_gettime(.MONOTONIC, &ts);
    if (linux.errno(rc) != .SUCCESS) return 0;
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(ts.nsec, 1_000_000);
}

fn pauseMs(ms: i64) void {
    var ts = linux.timespec{
        .sec = @intCast(@divTrunc(ms, 1000)),
        .nsec = @intCast(@mod(ms, 1000) * 1_000_000),
    };
    _ = linux.nanosleep(&ts, null);
}

fn openEventSocket(path: []const u8) ?i32 {
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

test "layout script keeps the placeholders" {
    try std.testing.expect(std.mem.indexOf(u8, layout_lua, "__OUTPUT__") != null);
    try std.testing.expect(std.mem.indexOf(u8, layout_lua, "__MODE__") != null);
    try std.testing.expect(std.mem.indexOf(u8, layout_lua, "__WANTED__") != null);
    try std.testing.expect(std.mem.indexOf(u8, layout_lua, "__HOST__") != null);
    try std.testing.expect(std.mem.indexOf(u8, layout_lua, "borrow") != null);
}

test "a numbered desktop stays put when a real screen already shows it" {
    try std.testing.expectEqual(Target.laptop, captureTarget(true, 2, false, 0));
    try std.testing.expectEqual(Target.laptop, captureTarget(false, 2, true, 0));
    try std.testing.expectEqual(Target.laptop, captureTarget(false, 2, false, 2));
    try std.testing.expectEqual(Target.virtual, captureTarget(false, 2, false, 0));
    try std.testing.expectEqual(Target.virtual, captureTarget(false, 2, false, 1));
}

test "the virtual screen sits past a rotated second monitor" {
    const items = [_]Monitor{
        .{ .name = "HDMI-A-1", .focused = false, .x = 0, .y = 0, .width = 2560, .height = 1080, .scale = 1, .workspace = 1, .disabled = false, .transform = 0 },
        .{ .name = "DP-2", .focused = true, .x = 2560, .y = 0, .width = 1920, .height = 1080, .scale = 1, .workspace = 2, .disabled = false, .transform = 3 },
        .{ .name = "screenmirror", .focused = false, .x = 2560, .y = 0, .width = 1920, .height = 1080, .scale = 1, .workspace = 3, .disabled = false, .transform = 0 },
    };
    const place = freeOrigin(&items);
    try std.testing.expectEqual(@as(i64, 4480), place.x);
    try std.testing.expectEqual(@as(i64, 0), place.y);
    try std.testing.expect(overlapsReal(&items, items[2]));
    const clear = Monitor{
        .name = "screenmirror",
        .focused = false,
        .x = place.x,
        .y = place.y,
        .width = 1920,
        .height = 1080,
        .scale = 1,
        .workspace = 4,
        .disabled = false,
        .transform = 0,
    };
    try std.testing.expect(!overlapsReal(&items, clear));
    try std.testing.expect(monitorShowing(&items, 2) != null);
    try std.testing.expectEqualStrings("DP-2", monitorShowing(&items, 2).?.name);
    try std.testing.expect(monitorShowing(&items, 4) == null);
}

test "selecting the virtual desktop survives the focus bounce" {
    var focus = Focus{ .seen = 1 };
    try std.testing.expectEqual(FocusKind.open, noteFocus(&focus, true, 2, 1000));
    try std.testing.expectEqual(FocusKind.bounce, noteFocus(&focus, false, 1, 1200));
    try std.testing.expectEqual(@as(i32, 2), focus.open);
    try std.testing.expectEqual(FocusKind.laptop, noteFocus(&focus, false, 1, 2000));
    try std.testing.expectEqual(@as(i32, 0), focus.open);
}
