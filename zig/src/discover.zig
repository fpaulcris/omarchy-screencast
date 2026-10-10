//! LAN receiver list. The avahi line format and the speaker filter match share/discover.py.
const std = @import("std");
const dial = @import("dial.zig");
const jsonx = @import("jsonx.zig");
const sys = @import("sys.zig");

const speakers = [_][]const u8{
    "nest mini",
    "nest audio",
    "chromecast audio",
    "home mini",
    "homepod",
    "audioaccessory",
    "google home",
    "google nest mini",
};

const Protocol = struct {
    name: []u8,
    port: u16,
    video: bool,
    can_mirror: bool,
};

const Device = struct {
    address: []u8,
    name: []u8,
    model: []u8,
    uuid: []const u8,
    name_rank: i32,
    model_rank: i32,
    protocols: std.ArrayList(Protocol),
};

pub const Receiver = struct {
    id: []u8,
    name: []u8,
    protocol: []u8,
    protocols: []Protocol,
    address: []u8,
    port: u16,
    uuid: []const u8,
    model: []u8,
    video: bool,
    can_mirror: bool,
    note: []u8,
};

pub const Probe = *const fn (io: std.Io, address: []const u8) bool;

pub fn unescape(arena: std.mem.Allocator, text: []const u8) ![]u8 {
    var raw: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '\\' and i + 1 < text.len) {
            const next = text[i + 1];
            if (next == '\\' or next == '.') {
                try raw.append(arena, next);
                i += 2;
                continue;
            }
            if (i + 4 <= text.len and std.ascii.isDigit(text[i + 1]) and std.ascii.isDigit(text[i + 2]) and std.ascii.isDigit(text[i + 3])) {
                const value = std.fmt.parseInt(u16, text[i + 1 .. i + 4], 10) catch 256;
                if (value <= 255) {
                    try raw.append(arena, @intCast(value));
                    i += 4;
                    continue;
                }
            }
        }
        try raw.append(arena, text[i]);
        i += 1;
    }
    return raw.toOwnedSlice(arena);
}

fn looksLikeSpeaker(model: []const u8, name: []const u8) bool {
    var folded: [256]u8 = undefined;
    const n = @min(folded.len, model.len + 1 + name.len);
    const joined = if (model.len + 1 + name.len <= folded.len) blk: {
        @memcpy(folded[0..model.len], model);
        folded[model.len] = ' ';
        @memcpy(folded[model.len + 1 ..][0..name.len], name);
        break :blk folded[0 .. model.len + 1 + name.len];
    } else folded[0..n];
    for (joined) |*byte| byte.* = std.ascii.toLower(byte.*);
    if (std.mem.indexOf(u8, joined, "hub") != null) return false;
    if (std.mem.indexOf(u8, joined, "group") != null) return true;
    for (speakers) |word| {
        if (std.mem.indexOf(u8, joined, word) != null) return true;
    }
    return false;
}

fn serviceName(raw: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, raw, "_airplay._tcp")) return "AirPlay";
    if (std.mem.eql(u8, raw, "_googlecast._tcp")) return "Chromecast";
    if (std.mem.eql(u8, raw, "_display._tcp")) return "Miracast";
    if (std.mem.eql(u8, raw, "_androidtvremote2._tcp")) return "Android TV Remote";
    if (std.mem.eql(u8, raw, "_amzn-wplay._tcp")) return "Fire TV";
    if (std.mem.eql(u8, raw, "Amazon Fire TV")) return "Fire TV";
    return null;
}

fn idPrefix(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "Chromecast")) return "Chromecast";
    if (std.mem.eql(u8, name, "AirPlay")) return "AirPlay";
    if (std.mem.eql(u8, name, "Miracast")) return "Miracast";
    if (std.mem.eql(u8, name, "Android TV Remote")) return "AndroidTV";
    if (std.mem.eql(u8, name, "Fire TV")) return "FireTV";
    if (std.mem.eql(u8, name, "DIAL")) return "DIAL";
    return name;
}

fn txtMap(arena: std.mem.Allocator, raw: []const u8) !std.StringHashMap([]u8) {
    var map = std.StringHashMap([]u8).init(arena);
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] != '"') {
            i += 1;
            continue;
        }
        i += 1;
        const start = i;
        while (i < raw.len and raw[i] != '"') i += 1;
        const part = raw[start..i];
        if (i < raw.len) i += 1;
        if (std.mem.indexOfScalar(u8, part, '=')) |eq| {
            const key = part[0..eq];
            const value = try unescape(arena, part[eq + 1 ..]);
            try map.put(key, value);
        }
    }
    return map;
}

fn uuidHex(text: []const u8) bool {
    for (text) |byte| if (!std.ascii.isHex(byte)) return false;
    return true;
}

fn prefer(device: *Device, field: enum { name, model }, value: []u8, rank: i32) !void {
    if (value.len == 0) return;
    switch (field) {
        .name => if (rank >= device.name_rank) {
            device.name = value;
            device.name_rank = rank;
        },
        .model => if (rank >= device.model_rank) {
            device.model = value;
            device.model_rank = rank;
        },
    }
}

fn addProtocol(arena: std.mem.Allocator, device: *Device, name: []const u8, port: u16, video: bool, can_mirror: bool) !void {
    for (device.protocols.items) |*item| {
        if (std.mem.eql(u8, item.name, name) and item.port == port) {
            item.video = item.video or video;
            item.can_mirror = item.can_mirror or can_mirror;
            return;
        }
    }
    try device.protocols.append(arena, .{
        .name = try arena.dupe(u8, name),
        .port = port,
        .video = video,
        .can_mirror = can_mirror,
    });
}

fn noteFor(arena: std.mem.Allocator, primary: []const u8, names: []const []const u8, video: bool, can_mirror: bool) ![]u8 {
    if (can_mirror) {
        if (std.mem.eql(u8, primary, "AirPlay")) return arena.dupe(u8, "The switch asks AirPlay to play this desktop.");
        if (std.mem.eql(u8, primary, "Miracast")) return arena.dupe(u8, "The switch sends this desktop with Miracast.");
        if (std.mem.eql(u8, primary, "Fire TV")) return arena.dupe(u8, "The switch sends this desktop to the Fire TV player. screencast dial launches other apps.");
        return arena.dupe(u8, "");
    }
    if (contains(names, "Fire TV")) {
        if (contains(names, "DIAL")) {
            return arena.dupe(u8, "Fire TV uses Amazon messaging and DIAL. DIAL can open Netflix. It cannot show this desktop.");
        }
        return arena.dupe(u8, "Fire TV uses Amazon messaging. It cannot show this desktop.");
    }
    if (contains(names, "Android TV Remote")) {
        return arena.dupe(u8, "Android TV Remote sends keys after pairing. It cannot show this desktop.");
    }
    if (contains(names, "AirPlay")) {
        if (!video) return arena.dupe(u8, "This is a speaker, so it cannot show the screen.");
        return arena.dupe(u8, "AirPlay is visible. This computer has no AirPlay sender.");
    }
    if (contains(names, "Miracast")) return arena.dupe(u8, "Miracast needs Wi-Fi Direct. This computer does not send it.");
    if (contains(names, "Chromecast") and !video) return arena.dupe(u8, "This is a speaker, so it cannot show the screen.");
    return arena.dupe(u8, "");
}

fn contains(names: []const []const u8, want: []const u8) bool {
    for (names) |name| if (std.mem.eql(u8, name, want)) return true;
    return false;
}

pub fn parseBrowse(arena: std.mem.Allocator, text: []const u8) ![]Device {
    var devices: std.ArrayList(Device) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] != '=') continue;
        var parts = std.mem.splitScalar(u8, line, ';');
        var fields: [10][]const u8 = undefined;
        var n: usize = 0;
        while (n < fields.len) : (n += 1) {
            fields[n] = parts.next() orelse break;
        }
        if (n < 9) continue;
        const protocol_name = serviceName(fields[4]) orelse continue;
        if (!std.mem.eql(u8, fields[2], "IPv4")) continue;
        const address = fields[7];
        if (address.len == 0 or std.mem.indexOfScalar(u8, address, ':') != null) continue;
        const port = std.fmt.parseInt(u16, fields[8], 10) catch continue;
        const rest_at = blk: {
            var used: usize = 0;
            var i: usize = 0;
            while (i < 9) : (i += 1) used += fields[i].len + 1;
            break :blk @min(used, line.len);
        };
        var txt = try txtMap(arena, if (rest_at < line.len) line[rest_at..] else "");
        const model = txt.get("md") orelse txt.get("model") orelse txt.get("am") orelse "";
        const friendly = txt.get("fn") orelse txt.get("n") orelse txt.get("name") orelse "";
        const instance = try unescape(arena, fields[3]);
        const device = try findDevice(arena, &devices, address);
        if (std.mem.eql(u8, protocol_name, "Fire TV") and device.uuid.len == 0) {
            if (txt.get("u")) |raw| if (raw.len == 32 and uuidHex(raw)) {
                device.uuid = raw;
            };
        }
        const rank: i32 = if (std.mem.eql(u8, protocol_name, "Chromecast") and friendly.len > 0) 3 else if (friendly.len > 0) 2 else 1;
        const shown = if (friendly.len > 0) friendly else instance;
        try prefer(device, .name, try arena.dupe(u8, shown), rank);
        const model_rank: i32 = if (std.mem.eql(u8, protocol_name, "Chromecast")) 2 else 1;
        try prefer(device, .model, try arena.dupe(u8, model), model_rank);
        var video = false;
        var can_mirror = false;
        if (std.mem.eql(u8, protocol_name, "Chromecast")) {
            const speaker = looksLikeSpeaker(model, shown);
            if (txt.get("ca")) |ca_raw| {
                const ca = std.fmt.parseInt(u32, ca_raw, 10) catch 0;
                video = (ca & 1) != 0 and !speaker;
            } else video = !speaker;
            can_mirror = video;
        } else if (std.mem.eql(u8, protocol_name, "Miracast")) {
            video = true;
            can_mirror = true;
        } else if (std.mem.eql(u8, protocol_name, "Fire TV")) {
            video = true;
            can_mirror = true;
        } else if (std.mem.eql(u8, protocol_name, "Android TV Remote")) {
            video = true;
        } else if (std.mem.eql(u8, protocol_name, "AirPlay")) {
            video = !looksLikeSpeaker(model, shown);
            can_mirror = video;
        }
        try addProtocol(arena, device, protocol_name, port, video, can_mirror);
    }
    return devices.toOwnedSlice(arena);
}

fn findDevice(arena: std.mem.Allocator, devices: *std.ArrayList(Device), address: []const u8) !*Device {
    for (devices.items) |*device| {
        if (std.mem.eql(u8, device.address, address)) return device;
    }
    try devices.append(arena, .{
        .address = try arena.dupe(u8, address),
        .name = try arena.dupe(u8, ""),
        .model = try arena.dupe(u8, ""),
        .name_rank = -1,
        .model_rank = -1,
        .uuid = "",
        .protocols = .empty,
    });
    return &devices.items[devices.items.len - 1];
}

fn protocolRank(name: []const u8) u8 {
    if (std.mem.eql(u8, name, "Chromecast")) return 0;
    if (std.mem.eql(u8, name, "Miracast")) return 1;
    if (std.mem.eql(u8, name, "AirPlay")) return 2;
    if (std.mem.eql(u8, name, "Fire TV")) return 3;
    return 9;
}

fn finish(arena: std.mem.Allocator, device: Device) !?Receiver {
    if (device.protocols.items.len == 0) return null;
    var mirror: ?Protocol = null;
    var video = false;
    for (device.protocols.items) |item| {
        video = video or item.video;
        if (!item.can_mirror) continue;
        if (mirror == null or protocolRank(item.name) < protocolRank(mirror.?.name)) mirror = item;
    }
    const primary = mirror orelse device.protocols.items[0];
    var names: std.ArrayList([]const u8) = .empty;
    for (device.protocols.items) |item| try names.append(arena, item.name);
    const can_mirror = mirror != null;
    const prefix = idPrefix(primary.name);
    return .{
        .id = try std.fmt.allocPrint(arena, "{s}:{s}", .{ prefix, device.address }),
        .name = if (device.name.len > 0) device.name else device.address,
        .protocol = primary.name,
        .protocols = device.protocols.items,
        .address = device.address,
        .port = primary.port,
        .uuid = device.uuid,
        .model = device.model,
        .video = video,
        .can_mirror = can_mirror,
        .note = try noteFor(arena, primary.name, names.items, video, can_mirror),
    };
}

fn nameLess(a: []const u8, b: []const u8) bool {
    const n = @min(a.len, b.len);
    for (a[0..n], b[0..n]) |left, right| {
        const dl = std.ascii.toLower(left);
        const dr = std.ascii.toLower(right);
        if (dl < dr) return true;
        if (dl > dr) return false;
    }
    return a.len < b.len;
}

pub fn build(arena: std.mem.Allocator, text: []const u8, io: std.Io, probe: ?Probe) ![]Receiver {
    const devices = try parseBrowse(arena, text);
    if (probe) |ask| {
        for (devices) |*device| {
            var fire = false;
            for (device.protocols.items) |item| {
                if (std.mem.eql(u8, item.name, "Fire TV")) fire = true;
            }
            if (fire and ask(io, device.address)) {
                try addProtocol(arena, device, "DIAL", 8009, true, false);
            }
        }
    }
    var out: std.ArrayList(Receiver) = .empty;
    for (devices) |device| {
        if (try finish(arena, device)) |item| try out.append(arena, item);
    }
    std.mem.sort(Receiver, out.items, {}, struct {
        fn less(_: void, a: Receiver, b: Receiver) bool {
            if (a.can_mirror != b.can_mirror) return a.can_mirror;
            return nameLess(a.name, b.name);
        }
    }.less);
    return out.toOwnedSlice(arena);
}

pub fn writeJson(out: *std.Io.Writer, receivers: []const Receiver, err_text: []const u8) std.Io.Writer.Error!void {
    try out.writeAll("{\"receivers\":[");
    for (receivers, 0..) |item, index| {
        if (index != 0) try out.writeByte(',');
        try out.writeAll("{\"id\":");
        try jsonx.escape(out, item.id);
        try out.writeAll(",\"name\":");
        try jsonx.escape(out, item.name);
        try out.writeAll(",\"protocol\":");
        try jsonx.escape(out, item.protocol);
        try out.writeAll(",\"protocols\":[");
        for (item.protocols, 0..) |protocol, p| {
            if (p != 0) try out.writeByte(',');
            try out.print("{{\"name\":", .{});
            try jsonx.escape(out, protocol.name);
            try out.print(",\"port\":{d},\"video\":{s},\"canMirror\":{s}}}", .{
                protocol.port,
                if (protocol.video) "true" else "false",
                if (protocol.can_mirror) "true" else "false",
            });
        }
        try out.writeAll("],\"address\":");
        try jsonx.escape(out, item.address);
        try out.print(",\"port\":{d},\"model\":", .{item.port});
        try jsonx.escape(out, item.model);
        try out.print(",\"video\":{s},\"canMirror\":{s},\"note\":", .{
            if (item.video) "true" else "false",
            if (item.can_mirror) "true" else "false",
        });
        try jsonx.escape(out, item.note);
        try out.writeByte('}');
    }
    try out.writeByte(']');
    if (err_text.len > 0) {
        try out.writeAll(",\"error\":");
        try jsonx.escape(out, err_text);
    }
    try out.writeAll("}\n");
}

pub fn dialProbe(io: std.Io, address: []const u8) bool {
    return dial.responds(io, address);
}

pub const Browse = struct {
    receivers: []Receiver,
    failure: []const u8,
};

pub fn browse(arena: std.mem.Allocator, gpa: std.mem.Allocator, io: std.Io) !Browse {
    const result = sys.run(gpa, io, &.{ "avahi-browse", "-arpkt" }, 6000, 1024 * 1024) catch |err| switch (err) {
        error.FileNotFound => return .{ .receivers = &.{}, .failure = "Install avahi to look for receivers." },
        else => return .{ .receivers = &.{}, .failure = "" },
    };
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    const receivers = try build(arena, result.stdout, io, dialProbe);
    return .{ .receivers = receivers, .failure = "" };
}

const sample =
    \\=;enp42s0;IPv4;TPM191E;_googlecast._tcp;local;host.local;192.168.0.152;8009;"md=TPM191E" "fn=TV" "ca=264709" "rs=TV"
    \\=;enp42s0;IPv4;TV;_androidtvremote2._tcp;local;Android.local;192.168.0.152;6466;"bt=34:F1:50:1E:CD:F5"
    \\=;enp42s0;IPv4;Google-Nest-Hub;_googlecast._tcp;local;fuchsia.local;192.168.0.237;8009;"md=Google Nest Hub" "fn=Kitchen 2 Display" "ca=231941"
    \\=;enp42s0;IPv4;Google-Nest-Mini;_googlecast._tcp;local;mini.local;192.168.0.50;8009;"md=Google Nest Mini" "fn=Speaker" "ca=4"
    \\=;enp42s0;IPv4;amzn;_amzn-wplay._tcp;local;fire.local;192.168.0.144;38083;"n=Floricica's Fire TV" "u=0123456789ABCDEF0123456789ABCDEF"
    \\=;enp42s0;IPv6;TPM191E;_googlecast._tcp;local;host.local;fe80::1;8009;"fn=TV"
;

fn testProbe(_: std.Io, address: []const u8) bool {
    return std.mem.eql(u8, address, "192.168.0.144");
}

test "browse merges cast and marks what can mirror" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const receivers = try build(arena, sample, std.testing.io, testProbe);
    var tv: ?Receiver = null;
    var hub: ?Receiver = null;
    var speaker: ?Receiver = null;
    var fire: ?Receiver = null;
    for (receivers) |item| {
        if (std.mem.eql(u8, item.id, "Chromecast:192.168.0.152")) tv = item;
        if (std.mem.eql(u8, item.id, "Chromecast:192.168.0.237")) hub = item;
        if (std.mem.eql(u8, item.id, "Chromecast:192.168.0.50")) speaker = item;
        if (std.mem.eql(u8, item.id, "FireTV:192.168.0.144")) fire = item;
        try std.testing.expect(!std.mem.eql(u8, item.id, "Chromecast:fe80::1"));
    }
    const got_tv = tv orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("TV", got_tv.name);
    try std.testing.expectEqualStrings("TPM191E", got_tv.model);
    try std.testing.expect(got_tv.can_mirror);
    try std.testing.expectEqual(@as(usize, 2), got_tv.protocols.len);
    try std.testing.expect(hub.?.can_mirror);
    try std.testing.expectEqualStrings("Kitchen 2 Display", hub.?.name);
    try std.testing.expect(!speaker.?.can_mirror);
    try std.testing.expect(!speaker.?.video);
    try std.testing.expect(std.mem.indexOf(u8, speaker.?.note, "speaker") != null);
    try std.testing.expect(fire.?.can_mirror);
    try std.testing.expectEqualStrings("Floricica's Fire TV", fire.?.name);
    var dial_found = false;
    for (fire.?.protocols) |item| {
        if (std.mem.eql(u8, item.name, "DIAL")) dial_found = true;
    }
    try std.testing.expect(dial_found);
    try std.testing.expect(std.mem.indexOf(u8, fire.?.note, "player") != null);
    try std.testing.expectEqualStrings("0123456789ABCDEF0123456789ABCDEF", fire.?.uuid);
}

test "avahi decimal escapes are spaces" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqualStrings("Google Inc. Hub", try unescape(arena, "Google\\032Inc\\.\\032Hub"));
    try std.testing.expectEqualStrings("café", try unescape(arena, "caf\\195\\169"));
    const line = "=;enp42s0;IPv4;Samsung\\0327\\032Series\\032\\04043\\041;_airplay._tcp;local;TIZEN.local;192.168.0.174;40998;\"model=URU7100\"\n";
    const receivers = try build(arena, line, std.testing.io, null);
    try std.testing.expectEqual(@as(usize, 1), receivers.len);
    try std.testing.expectEqualStrings("Samsung 7 Series (43)", receivers[0].name);
    try std.testing.expectEqualStrings("URU7100", receivers[0].model);
    try std.testing.expect(receivers[0].can_mirror);
    try std.testing.expectEqualStrings("AirPlay", receivers[0].protocol);
    try std.testing.expect(std.mem.indexOf(u8, receivers[0].note, "AirPlay") != null);
}

test "miracast and airplay mirror, and cast outranks airplay" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text =
        \\=;enp42s0;IPv4;Living Room;_display._tcp;local;tv.local;192.168.0.180;7250;"fn=Living Room"
        \\=;enp42s0;IPv4;Speaker;_airplay._tcp;local;spk.local;192.168.0.60;7000;"model=AudioAccessory" "fn=Speaker"
        \\=;enp42s0;IPv4;Both;_airplay._tcp;local;both.local;192.168.0.70;7000;"model=Hub" "fn=Both"
        \\=;enp42s0;IPv4;Both;_googlecast._tcp;local;both.local;192.168.0.70;8009;"md=Hub" "fn=Both" "ca=1"
        \\
    ;
    const receivers = try build(arena, text, std.testing.io, null);
    var room: ?Receiver = null;
    var speaker: ?Receiver = null;
    var both: ?Receiver = null;
    for (receivers) |item| {
        if (std.mem.eql(u8, item.id, "Miracast:192.168.0.180")) room = item;
        if (std.mem.eql(u8, item.id, "AirPlay:192.168.0.60")) speaker = item;
        if (std.mem.eql(u8, item.address, "192.168.0.70")) both = item;
    }
    const got_room = room orelse return error.TestUnexpectedResult;
    try std.testing.expect(got_room.can_mirror);
    try std.testing.expectEqual(@as(u16, 7250), got_room.port);
    try std.testing.expectEqualStrings("Living Room", got_room.name);
    try std.testing.expect(std.mem.indexOf(u8, got_room.note, "Miracast") != null);
    try std.testing.expect(!speaker.?.can_mirror);
    try std.testing.expect(std.mem.indexOf(u8, speaker.?.note, "speaker") != null);
    try std.testing.expectEqualStrings("Chromecast:192.168.0.70", both.?.id);
    try std.testing.expectEqualStrings("Chromecast", both.?.protocol);
    try std.testing.expect(both.?.can_mirror);
    try std.testing.expectEqual(@as(u16, 8009), both.?.port);
}
