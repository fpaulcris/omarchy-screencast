//! Cast v2 frames. The protobuf only uses varints and length-delimited strings.
const std = @import("std");

pub const source_id = "sender-0";
pub const receiver_id = "receiver-0";

pub const connection = "urn:x-cast:com.google.cast.tp.connection";
pub const heartbeat = "urn:x-cast:com.google.cast.tp.heartbeat";
pub const receiver = "urn:x-cast:com.google.cast.receiver";
pub const media = "urn:x-cast:com.google.cast.media";
pub const default_receiver = "CC1AD845";

pub const Message = struct {
    source: []const u8 = "",
    dest: []const u8 = "",
    namespace: []const u8 = "",
    payload: []const u8 = "",
};

fn appendVarint(out: *std.ArrayList(u8), gpa: std.mem.Allocator, value: u32) !void {
    var rest = value;
    while (true) {
        var byte: u8 = @intCast(rest & 0x7f);
        rest >>= 7;
        if (rest != 0) byte |= 0x80;
        try out.append(gpa, byte);
        if (rest == 0) break;
    }
}

fn appendString(out: *std.ArrayList(u8), gpa: std.mem.Allocator, field: u8, text: []const u8) !void {
    try out.append(gpa, (field << 3) | 2);
    try appendVarint(out, gpa, @intCast(text.len));
    try out.appendSlice(gpa, text);
}

fn appendVar(out: *std.ArrayList(u8), gpa: std.mem.Allocator, field: u8, value: u32) !void {
    try out.append(gpa, (field << 3) | 0);
    try appendVarint(out, gpa, value);
}

pub fn encode(gpa: std.mem.Allocator, source: []const u8, dest: []const u8, namespace: []const u8, payload: []const u8) ![]u8 {
    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(gpa);
    try appendVar(&body, gpa, 1, 0);
    try appendString(&body, gpa, 2, source);
    try appendString(&body, gpa, 3, dest);
    try appendString(&body, gpa, 4, namespace);
    try appendVar(&body, gpa, 5, 0);
    try appendString(&body, gpa, 6, payload);

    var frame: std.ArrayList(u8) = .empty;
    errdefer frame.deinit(gpa);
    const len: u32 = @intCast(body.items.len);
    try frame.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToBig(u32, len)));
    try frame.appendSlice(gpa, body.items);
    body.deinit(gpa);
    return frame.toOwnedSlice(gpa);
}

const Cursor = struct {
    buf: []const u8,
    index: usize = 0,

    fn readVarint(self: *Cursor) error{TruncatedVarint}!u32 {
        var value: u32 = 0;
        var shift: u5 = 0;
        while (self.index < self.buf.len) {
            const byte = self.buf[self.index];
            self.index += 1;
            value |= @as(u32, byte & 0x7f) << shift;
            if (byte & 0x80 == 0) return value;
            if (shift > 28) break;
            shift += 7;
        }
        return error.TruncatedVarint;
    }
};

pub fn decode(body: []const u8) Message {
    var cursor = Cursor{ .buf = body };
    var found = Message{};
    while (cursor.index < body.len) {
        const tag = body[cursor.index];
        cursor.index += 1;
        const field = tag >> 3;
        const wire = tag & 7;
        if (wire == 0) {
            _ = cursor.readVarint() catch break;
        } else if (wire == 2) {
            const length = cursor.readVarint() catch break;
            const end = cursor.index + length;
            if (end > body.len) break;
            const chunk = body[cursor.index..end];
            cursor.index = end;
            switch (field) {
                2 => found.source = chunk,
                3 => found.dest = chunk,
                4 => found.namespace = chunk,
                6 => found.payload = chunk,
                else => {},
            }
        } else break;
    }
    return found;
}

test "frame round trip keeps the json payload" {
    const gpa = std.testing.allocator;
    const payload = "{\"type\":\"PING\"}";
    const frame = try encode(gpa, source_id, receiver_id, heartbeat, payload);
    defer gpa.free(frame);
    try std.testing.expect(frame.len > 4);
    const size = std.mem.readInt(u32, frame[0..4], .big);
    try std.testing.expectEqual(frame.len - 4, size);
    const message = decode(frame[4..]);
    try std.testing.expectEqualStrings(source_id, message.source);
    try std.testing.expectEqualStrings(receiver_id, message.dest);
    try std.testing.expectEqualStrings(heartbeat, message.namespace);
    try std.testing.expectEqualStrings(payload, message.payload);
}
