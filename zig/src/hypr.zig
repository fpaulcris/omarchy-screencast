//! Numbered desktops use the embedded Hyprland script.
const std = @import("std");
const jsonx = @import("jsonx.zig");
const sys = @import("sys.zig");

const layout_lua = @embedFile("layout.lua");

pub const Monitor = struct {
    name: []u8,
    focused: bool,
    x: i64,
    y: i64,
    width: i64,
    height: i64,
    scale: f64,
    workspace: i64,
    disabled: bool,
};

pub const Cast = struct {
    follow: bool = true,
    auto: bool = true,
    workspace: i32 = 0,
    width: u32 = 1920,
    height: u32 = 1080,
};

pub const Plan = struct {
    output: []u8,
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

fn isVirtual(name: []const u8) bool {
    for (candidates) |item| if (std.mem.eql(u8, name, item)) return true;
    return std.mem.startsWith(u8, name, "HEADLESS");
}

pub fn laptop(items: []const Monitor) ?Monitor {
    for (items) |item| if (std.mem.startsWith(u8, item.name, "eDP")) return item;
    for (items) |item| if (!isVirtual(item.name) and !item.disabled and item.width > 0) return item;
    if (items.len > 0) return items[0];
    return null;
}

pub fn focused(items: []const Monitor) ?Monitor {
    for (items) |item| if (item.focused and !isVirtual(item.name)) return item;
    return laptop(items);
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

fn runLayout(arena: std.mem.Allocator, io: std.Io, gpa: std.mem.Allocator, runtime: []const u8, mode: []const u8, wanted: i32, output: []const u8) ![]u8 {
    const result_path = try sys.join(gpa, runtime, "layout.txt");
    defer gpa.free(result_path);
    sys.removeFile(io, result_path);
    var body = try replaceAll(arena, layout_lua, "__OUTPUT__", output);
    body = try replaceAll(arena, body, "__MODE__", mode);
    const wanted_text = try std.fmt.allocPrint(arena, "{d}", .{wanted});
    body = try replaceAll(arena, body, "__WANTED__", wanted_text);
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

fn configure(arena: std.mem.Allocator, io: std.Io, gpa: std.mem.Allocator, host: Monitor, output: []const u8, width: u32, height: u32) !void {
    const scale: f64 = if (host.scale == 0) 1 else host.scale;
    const pos_x = host.x + host.width;
    const code = try std.fmt.allocPrint(arena,
        "hl.monitor({{ output = \"{s}\", position = \"{d}x{d}\", scale = {d} }}); hl.monitor({{ output = \"{s}\", mode = \"{d}x{d}@60\", position = \"{d}x{d}\", scale = 1 }})",
        .{ host.name, host.x, host.y, scale, output, width, height, pos_x, host.y },
    );
    hypr(io, gpa, &.{ "hyprctl", "eval", code });
}

pub fn release(arena: std.mem.Allocator, io: std.Io, gpa: std.mem.Allocator, runtime: []const u8) void {
    const seen = monitors(arena, io, gpa) catch return;
    const virt = virtualMonitor(seen) orelse return;
    _ = runLayout(arena, io, gpa, runtime, "release", 0, virt.name) catch {};
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
    if (cast.follow) {
        if (virtualMonitor(seen) != null) release(arena, io, gpa, runtime);
        const fresh = monitors(arena, io, gpa) catch seen;
        const screen = focused(fresh) orelse host;
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
    if (host.workspace == wanted) {
        const size = fit(cast, host.width, host.height, false);
        return .{
            .output = host.name,
            .width = size.w,
            .height = size.h,
            .follow = false,
            .virtual_out = false,
            .workspace = wanted,
        };
    }
    const size = fit(cast, 0, 0, true);
    const output = try ensureVirtual(arena, io, gpa);
    const again = monitors(arena, io, gpa) catch seen;
    const desk = laptop(again) orelse host;
    try configure(arena, io, gpa, desk, output, size.w, size.h);
    sys.sleepMs(io, 150);
    const line = try runLayout(arena, io, gpa, runtime, "show", wanted, output);
    if (!std.mem.startsWith(u8, line, "ok")) return error.Hyprland;
    _ = runLayout(arena, io, gpa, runtime, "focus", 0, output) catch {};
    return .{
        .output = try arena.dupe(u8, output),
        .width = size.w,
        .height = size.h,
        .follow = false,
        .virtual_out = true,
        .workspace = wanted,
    };
}

test "layout script keeps the placeholders" {
    try std.testing.expect(std.mem.indexOf(u8, layout_lua, "__OUTPUT__") != null);
    try std.testing.expect(std.mem.indexOf(u8, layout_lua, "__MODE__") != null);
    try std.testing.expect(std.mem.indexOf(u8, layout_lua, "__WANTED__") != null);
}
