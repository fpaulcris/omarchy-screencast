//! DIAL client. Discovery is SSDP, then the Application-URL header.
//! A launch POST body is the app's extra data. YouTube and Netflix do not take a desktop address.
const std = @import("std");
const discover = @import("discover.zig");
const fling = @import("fling.zig");
const report = @import("report.zig");
const sys = @import("sys.zig");
const wire = @import("wire.zig");

const linux = std.os.linux;

const search =
    "M-SEARCH * HTTP/1.1\r\n" ++
    "HOST: 239.255.255.250:1900\r\n" ++
    "MAN: \"ssdp:discover\"\r\n" ++
    "MX: 1\r\n" ++
    "ST: urn:dial-multiscreen-org:service:dial:1\r\n" ++
    "\r\n";

const Catalog = struct {
    name: []const u8,
    opens_url: bool,
    page: bool,
};

const catalog = [_]Catalog{
    .{ .name = "Silk", .opens_url = true, .page = true },
    .{ .name = "com.amazon.cloud9", .opens_url = true, .page = true },
    .{ .name = "Browser", .opens_url = true, .page = true },
    .{ .name = "VLC", .opens_url = true, .page = false },
    .{ .name = "WebVideoCast", .opens_url = true, .page = false },
    .{ .name = "YouTube", .opens_url = false, .page = false },
    .{ .name = "Netflix", .opens_url = false, .page = false },
    .{ .name = "AmazonInstantVideo", .opens_url = false, .page = false },
    .{ .name = "Hulu", .opens_url = false, .page = false },
    .{ .name = "Spotify", .opens_url = false, .page = false },
};

pub fn responds(io: std.Io, address: []const u8) bool {
    if (std.mem.indexOfScalar(u8, address, ':') != null) return false;
    return restOk(io, address, 8009) or restOk(io, address, 8008);
}

fn restOk(io: std.Io, address: []const u8, port: u16) bool {
    var req_buf: [192]u8 = undefined;
    const req = std.fmt.bufPrint(&req_buf, "GET /apps/YouTube HTTP/1.1\r\nHost: {s}:{d}\r\nConnection: close\r\n\r\n", .{ address, port }) catch return false;
    const gpa = std.heap.page_allocator;
    const resp = wire.exchange(io, gpa, address, port, req, 700, 2048) orelse return false;
    defer gpa.free(resp);
    return wire.statusCode(resp) != null;
}

pub fn locationOf(message: []const u8) ?[]const u8 {
    return wire.headerValue(message, "LOCATION") orelse wire.headerValue(message, "Location");
}

pub fn applicationUrl(message: []const u8) ?[]const u8 {
    return wire.headerValue(message, "Application-URL") orelse wire.headerValue(message, "Application-Url");
}

pub fn hostOfUrl(url: []const u8) ?[]const u8 {
    const mark = "://";
    const at = std.mem.indexOf(u8, url, mark) orelse return null;
    const rest = url[at + mark.len ..];
    const end = std.mem.indexOfAny(u8, rest, ":/") orelse rest.len;
    if (end == 0) return null;
    return rest[0..end];
}

pub fn joinApp(gpa: std.mem.Allocator, base: []const u8, name: []const u8) ![]u8 {
    if (std.mem.endsWith(u8, base, "/")) return std.fmt.allocPrint(gpa, "{s}{s}", .{ base, name });
    return std.fmt.allocPrint(gpa, "{s}/{s}", .{ base, name });
}

fn xmlText(body: []const u8, tag: []const u8) ?[]const u8 {
    var open_buf: [64]u8 = undefined;
    const open = std.fmt.bufPrint(&open_buf, "<{s}>", .{tag}) catch return null;
    const at = std.mem.indexOf(u8, body, open) orelse return null;
    const rest = body[at + open.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '<') orelse return null;
    const text = std.mem.trim(u8, rest[0..end], " \t\r\n");
    if (text.len == 0) return null;
    return text;
}

fn appAllowed(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    for (name) |byte| {
        const ok = std.ascii.isAlphanumeric(byte) or byte == '.' or byte == '_' or byte == '-';
        if (!ok) return false;
    }
    return true;
}

fn hostOfArg(arg: []const u8) []const u8 {
    if (wire.parse4(arg) != null) return arg;
    if (std.mem.lastIndexOfScalar(u8, arg, ':')) |at| {
        const tail = arg[at + 1 ..];
        if (wire.parse4(tail) != null) return tail;
    }
    return arg;
}

const Found = struct {
    address: []u8,
    name: []u8,
    apps: []u8,
};

fn discoverAll(io: std.Io, gpa: std.mem.Allocator) ![]Found {
    const blob = wire.udpExchange(io, gpa, search, 1200, 32 * 1024) orelse return try gpa.alloc(Found, 0);
    defer gpa.free(blob);
    var out: std.ArrayList(Found) = .empty;
    errdefer {
        for (out.items) |item| {
            gpa.free(item.address);
            gpa.free(item.name);
            gpa.free(item.apps);
        }
        out.deinit(gpa);
    }
    var messages = std.mem.splitScalar(u8, blob, '\n');
    while (messages.next()) |raw| {
        if (raw.len < 12) continue;
        const loc = locationOf(raw) orelse continue;
        const host = hostOfUrl(loc) orelse continue;
        var seen = false;
        for (out.items) |item| if (std.mem.eql(u8, item.address, host)) {
            seen = true;
        };
        if (seen) continue;
        if (out.items.len == 16) break;
        const desc = getUrl(io, gpa, loc, 1500) orelse continue;
        defer gpa.free(desc);
        const app_url = applicationUrl(desc) orelse continue;
        const friendly = xmlText(wire.bodyOf(desc), "friendlyName") orelse host;
        try out.append(gpa, .{
            .address = try gpa.dupe(u8, host),
            .name = try gpa.dupe(u8, friendly),
            .apps = try gpa.dupe(u8, app_url),
        });
    }
    return try out.toOwnedSlice(gpa);
}

fn freeFound(gpa: std.mem.Allocator, items: []Found) void {
    for (items) |item| {
        gpa.free(item.address);
        gpa.free(item.name);
        gpa.free(item.apps);
    }
    gpa.free(items);
}

fn getUrl(io: std.Io, gpa: std.mem.Allocator, url: []const u8, timeout_ms: i32) ?[]u8 {
    const host = hostOfUrl(url) orelse return null;
    const port = portOfUrl(url) orelse return null;
    const path = pathOfUrl(url) orelse return null;
    var req_buf: [512]u8 = undefined;
    const req = std.fmt.bufPrint(&req_buf, "GET {s} HTTP/1.1\r\nHost: {s}:{d}\r\nConnection: close\r\n\r\n", .{ path, host, port }) catch return null;
    return wire.exchange(io, gpa, host, port, req, timeout_ms, 64 * 1024);
}

fn portOfUrl(url: []const u8) ?u16 {
    const mark = "://";
    const at = std.mem.indexOf(u8, url, mark) orelse return null;
    const rest = url[at + mark.len ..];
    const colon = std.mem.indexOfScalar(u8, rest, ':') orelse return 80;
    const after = rest[colon + 1 ..];
    const end = std.mem.indexOfAny(u8, after, "/") orelse after.len;
    return std.fmt.parseInt(u16, after[0..end], 10) catch null;
}

fn pathOfUrl(url: []const u8) ?[]const u8 {
    const mark = "://";
    const at = std.mem.indexOf(u8, url, mark) orelse return null;
    const rest = url[at + mark.len ..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return "/";
    return rest[slash..];
}

fn findBase(io: std.Io, gpa: std.mem.Allocator, address: []const u8) ?[]u8 {
    const found = discoverAll(io, gpa) catch null;
    if (found) |items| {
        defer freeFound(gpa, items);
        for (items) |item| {
            if (std.mem.eql(u8, item.address, address)) return gpa.dupe(u8, item.apps) catch null;
        }
    }
    return httpBase(io, gpa, address);
}

fn httpBase(io: std.Io, gpa: std.mem.Allocator, address: []const u8) ?[]u8 {
    if (std.mem.indexOfScalar(u8, address, ':') != null) return null;
    if (restOk(io, address, 8009)) return std.fmt.allocPrint(gpa, "http://{s}:8009/apps/", .{address}) catch null;
    if (restOk(io, address, 8008)) return std.fmt.allocPrint(gpa, "http://{s}:8008/apps/", .{address}) catch null;
    var desc_buf: [128]u8 = undefined;
    const desc_url = std.fmt.bufPrint(&desc_buf, "http://{s}:8008/ssdp/device-desc.xml", .{address}) catch return null;
    const desc = getUrl(io, gpa, desc_url, 1200) orelse return null;
    defer gpa.free(desc);
    const app_url = applicationUrl(desc) orelse return null;
    return gpa.dupe(u8, app_url) catch null;
}

const Probe = struct {
    name: []const u8,
    installed: bool,
    state: []const u8,
    opens_url: bool,
    page: bool,
};

fn probeAll(io: std.Io, gpa: std.mem.Allocator, base: []const u8) ![]Probe {
    var out: std.ArrayList(Probe) = .empty;
    for (catalog) |item| {
        const url = try joinApp(gpa, base, item.name);
        defer gpa.free(url);
        const resp = getUrl(io, gpa, url, 1200);
        var installed = false;
        var state: []const u8 = "not installed";
        if (resp) |body| {
            defer gpa.free(body);
            if ((wire.statusCode(body) orelse 0) == 200) {
                if (xmlText(wire.bodyOf(body), "state")) |got| {
                    installed = true;
                    state = try gpa.dupe(u8, got);
                } else if (std.mem.indexOf(u8, wire.bodyOf(body), "<service") != null) {
                    installed = true;
                    state = try gpa.dupe(u8, "installed");
                }
            }
        }
        try out.append(gpa, .{
            .name = item.name,
            .installed = installed,
            .state = if (installed) state else "not installed",
            .opens_url = item.opens_url,
            .page = item.page,
        });
    }
    return out.toOwnedSlice(gpa);
}

fn postApp(io: std.Io, gpa: std.mem.Allocator, base: []const u8, name: []const u8, payload: []const u8) ?u16 {
    const url = joinApp(gpa, base, name) catch return null;
    defer gpa.free(url);
    const host = hostOfUrl(url) orelse return null;
    const port = portOfUrl(url) orelse return null;
    const path = pathOfUrl(url) orelse return null;
    const req = std.fmt.allocPrint(gpa,
        "POST {s} HTTP/1.1\r\nHost: {s}:{d}\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}",
        .{ path, host, port, payload.len, payload },
    ) catch return null;
    defer gpa.free(req);
    const resp = wire.exchange(io, gpa, host, port, req, 8000, 64 * 1024) orelse return null;
    defer gpa.free(resp);
    return wire.statusCode(resp);
}

fn deleteApp(io: std.Io, gpa: std.mem.Allocator, base: []const u8, name: []const u8) void {
    const url = joinApp(gpa, base, name) catch return;
    defer gpa.free(url);
    const host = hostOfUrl(url) orelse return;
    const port = portOfUrl(url) orelse return;
    const path = pathOfUrl(url) orelse return;
    const req = std.fmt.allocPrint(gpa, "DELETE {s} HTTP/1.1\r\nHost: {s}:{d}\r\nConnection: close\r\n\r\n", .{ path, host, port }) catch return;
    defer gpa.free(req);
    if (wire.exchange(io, gpa, host, port, req, 2000, 8192)) |resp| gpa.free(resp);
}

fn appState(io: std.Io, gpa: std.mem.Allocator, base: []const u8, name: []const u8) ?[]u8 {
    const url = joinApp(gpa, base, name) catch return null;
    defer gpa.free(url);
    const resp = getUrl(io, gpa, url, 1500) orelse return null;
    errdefer gpa.free(resp);
    const state = xmlText(wire.bodyOf(resp), "state") orelse {
        gpa.free(resp);
        return null;
    };
    const copy = gpa.dupe(u8, state) catch {
        gpa.free(resp);
        return null;
    };
    gpa.free(resp);
    return copy;
}

pub fn runDesktop(io: std.Io, gpa: std.mem.Allocator, address: []const u8, port: u16, uuid: []const u8, page: []const u8, stream: []const u8, playlist: []const u8) !void {
    if (port != 0 and port != 8008 and port != 8009) {
        if (fling.run(io, gpa, address, port, uuid, stream, playlist)) {
            return;
        } else |err| {
            if (err != error.NoPlayer) return err;
        }
    }
    const base = findBase(io, gpa, address) orelse return report.fail(io, "This Fire TV did not answer DIAL.");
    defer gpa.free(base);
    const probed = probeAll(io, gpa, base) catch return report.fail(io, "This Fire TV did not answer DIAL.");
    defer {
        for (probed) |item| if (item.installed) gpa.free(item.state);
        gpa.free(probed);
    }
    var chosen: ?Probe = null;
    for (probed) |item| {
        if (item.installed and item.opens_url) {
            chosen = item;
            break;
        }
    }
    const app = chosen orelse {
        var msg: [320]u8 = undefined;
        var w: std.Io.Writer = .fixed(&msg);
        var any = false;
        w.writeAll("DIAL answered. Installed:") catch {};
        for (probed) |item| if (item.installed) {
            any = true;
            w.print(" {s}", .{item.name}) catch {};
        };
        if (!any) w.writeAll(" none of the usual apps") catch {};
        w.writeAll(". None of them can open this desktop. screencast dial launch starts one.") catch {};
        return report.fail(io, w.buffered());
    };
    const payload = if (app.page) page else stream;
    const posted = postApp(io, gpa, base, app.name, payload) orelse return report.fail(io, "The DIAL app did not accept the connection.");
    if (posted != 200 and posted != 201) return report.fail(io, "The DIAL app refused the desktop address.");
    report.log(io, "dial launched");
    var opened = false;
    var mark = sys.monoMs(io);
    var check = sys.monoMs(io);
    const started = sys.monoMs(io);
    while (!report.stopped()) {
        if (report.stalled(io, playlist, &mark)) {
            deleteApp(io, gpa, base, app.name);
            return report.fail(io, "The desktop stream stopped.");
        }
        if (sys.monoMs(io) - check > 2000) {
            check = sys.monoMs(io);
            if (appState(io, gpa, base, app.name)) |state| {
                defer gpa.free(state);
                if (std.mem.eql(u8, state, "running") or std.mem.eql(u8, state, "hidden")) {
                    if (!opened) report.publish("live", "Mirroring.", @intCast(linux.getpid()));
                    opened = true;
                } else if (opened and std.mem.eql(u8, state, "stopped")) {
                    deleteApp(io, gpa, base, app.name);
                    return report.fail(io, "The DIAL app closed.");
                }
            }
        }
        // cloud9 rests at "stopped" until it actually opens. Deleting that state kills the launch.
        if (!opened and sys.monoMs(io) - started > 8000) {
            return report.fail(io, "The Fire TV accepted the launch, but the app stayed stopped.");
        }
        sys.sleepMs(io, 200);
    }
    deleteApp(io, gpa, base, app.name);
    report.publish("stopped", "Stopped.", 0);
}

pub fn command(init: std.process.Init, args: []const []const u8) !void {
    const io = init.io;
    const gpa = init.gpa;
    if (args.len == 0 or eql(args[0], "list")) return list(io, gpa);
    if (eql(args[0], "apps") and args.len >= 2) return apps(io, gpa, hostOfArg(args[1]));
    if (eql(args[0], "launch") and args.len >= 3) return launch(io, gpa, hostOfArg(args[1]), args[2], args[3..]);
    if (eql(args[0], "stop") and args.len >= 3) return stopApp(io, gpa, hostOfArg(args[1]), args[2]);
    try say(io, "usage: screencast dial [list]\n       screencast dial apps <id-or-ip>\n       screencast dial launch <id-or-ip> <App> [payload]\n       screencast dial stop <id-or-ip> <App>\n");
    std.process.exit(2);
}

fn list(io: std.Io, gpa: std.mem.Allocator) !void {
    const found = try discoverAll(io, gpa);
    defer freeFound(gpa, found);
    if (found.len > 0) {
        for (found) |item| {
            const line = try std.fmt.allocPrint(gpa, "{s}  {s}  {s}\n", .{ item.address, item.name, item.apps });
            defer gpa.free(line);
            try say(io, line);
        }
        return;
    }
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const browsed = discover.browse(arena_state.allocator(), gpa, io) catch {
        try say(io, "No DIAL receiver answered.\n");
        return;
    };
    var any = false;
    for (browsed.receivers) |item| {
        const base = httpBase(io, gpa, item.address) orelse continue;
        defer gpa.free(base);
        any = true;
        const line = try std.fmt.allocPrint(gpa, "{s}  {s}  {s}\n", .{ item.address, item.name, base });
        defer gpa.free(line);
        try say(io, line);
    }
    if (!any) try say(io, "No DIAL receiver answered.\n");
}

fn apps(io: std.Io, gpa: std.mem.Allocator, address: []const u8) !void {
    const base = findBase(io, gpa, address) orelse {
        try say(io, "No DIAL receiver at that address.\n");
        std.process.exit(1);
    };
    defer gpa.free(base);
    const line = try std.fmt.allocPrint(gpa, "{s}\n", .{base});
    defer gpa.free(line);
    try say(io, line);
    const probed = try probeAll(io, gpa, base);
    defer {
        for (probed) |item| if (item.installed) gpa.free(item.state);
        gpa.free(probed);
    }
    for (probed) |item| {
        const row = try std.fmt.allocPrint(gpa, "{s}  {s}\n", .{ item.name, item.state });
        defer gpa.free(row);
        try say(io, row);
    }
}

fn launch(io: std.Io, gpa: std.mem.Allocator, address: []const u8, name: []const u8, parts: []const []const u8) !void {
    if (!appAllowed(name)) {
        try say(io, "The app name has to be letters, digits, dots, or dashes.\n");
        std.process.exit(2);
    }
    var payload: std.ArrayList(u8) = .empty;
    defer payload.deinit(gpa);
    for (parts, 0..) |part, index| {
        if (std.mem.indexOfAny(u8, part, "\r\n") != null) {
            try say(io, "The launch text cannot contain a new line.\n");
            std.process.exit(2);
        }
        if (index != 0) try payload.append(gpa, ' ');
        try payload.appendSlice(gpa, part);
        if (payload.items.len > 2048) {
            try say(io, "The launch text is too long.\n");
            std.process.exit(2);
        }
    }
    const base = findBase(io, gpa, address) orelse {
        try say(io, "No DIAL receiver at that address.\n");
        std.process.exit(1);
    };
    defer gpa.free(base);
    const posted = postApp(io, gpa, base, name, payload.items) orelse {
        try say(io, "The DIAL receiver did not accept the connection.\n");
        std.process.exit(1);
    };
    if (posted == 200 or posted == 201) {
        const line = try std.fmt.allocPrint(gpa, "Launched {s}.\n", .{name});
        defer gpa.free(line);
        try say(io, line);
        return;
    }
    const line = try std.fmt.allocPrint(gpa, "{s} did not launch ({d}).\n", .{ name, posted });
    defer gpa.free(line);
    try say(io, line);
    std.process.exit(1);
}

fn stopApp(io: std.Io, gpa: std.mem.Allocator, address: []const u8, name: []const u8) !void {
    if (!appAllowed(name)) {
        try say(io, "The app name has to be letters, digits, dots, or dashes.\n");
        std.process.exit(2);
    }
    const base = findBase(io, gpa, address) orelse {
        try say(io, "No DIAL receiver at that address.\n");
        std.process.exit(1);
    };
    defer gpa.free(base);
    deleteApp(io, gpa, base, name);
    const line = try std.fmt.allocPrint(gpa, "Stopped {s}.\n", .{name});
    defer gpa.free(line);
    try say(io, line);
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn say(io: std.Io, text: []const u8) !void {
    var buf: [1024]u8 = undefined;
    var w: std.Io.File.Writer = .init(.stdout(), io, &buf);
    var off: usize = 0;
    while (off < text.len) {
        const n = @min(buf.len, text.len - off);
        try w.interface.writeAll(text[off .. off + n]);
        try w.interface.flush();
        off += n;
    }
}

test "dial headers and app url" {
    const gpa = std.testing.allocator;
    const ssdp = "HTTP/1.1 200 OK\r\nLOCATION: http://192.168.0.144:60000/dd.xml\r\nST: urn:dial-multiscreen-org:service:dial:1\r\n\r\n";
    try std.testing.expectEqualStrings("http://192.168.0.144:60000/dd.xml", locationOf(ssdp).?);
    try std.testing.expectEqualStrings("192.168.0.144", hostOfUrl(locationOf(ssdp).?).?);
    const desc = "HTTP/1.1 200 OK\r\nApplication-URL: http://192.168.0.144:8009/apps/\r\n\r\n<friendlyName>Fire TV</friendlyName>";
    try std.testing.expectEqualStrings("http://192.168.0.144:8009/apps/", applicationUrl(desc).?);
    try std.testing.expectEqualStrings("Fire TV", xmlText(wire.bodyOf(desc), "friendlyName").?);
    const joined = try joinApp(gpa, applicationUrl(desc).?, "YouTube");
    defer gpa.free(joined);
    try std.testing.expectEqualStrings("http://192.168.0.144:8009/apps/YouTube", joined);
    const bare = try joinApp(gpa, "http://192.168.0.10:8008/apps", "Netflix");
    defer gpa.free(bare);
    try std.testing.expectEqualStrings("http://192.168.0.10:8008/apps/Netflix", bare);
}
