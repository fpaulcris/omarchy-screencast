//! Small JSON reader for Cast messages, Hyprland, and the cast file.
const std = @import("std");

pub const Value = union(enum) {
    null,
    boolean: bool,
    integer: i64,
    float: f64,
    string: []u8,
    array: std.ArrayList(Value),
    object: std.ArrayList(Field),

    pub fn get(self: Value, key: []const u8) ?Value {
        switch (self) {
            .object => |fields| {
                for (fields.items) |field| {
                    if (std.mem.eql(u8, field.name, key)) return field.value;
                }
                return null;
            },
            else => return null,
        }
    }

    pub fn asString(self: Value) ?[]const u8 {
        return switch (self) {
            .string => |text| text,
            else => null,
        };
    }

    pub fn asInt(self: Value) ?i64 {
        return switch (self) {
            .integer => |n| n,
            .float => |n| @intFromFloat(n),
            else => null,
        };
    }

    pub fn asFloat(self: Value) ?f64 {
        return switch (self) {
            .float => |n| n,
            .integer => |n| @floatFromInt(n),
            else => null,
        };
    }

    pub fn asBool(self: Value) ?bool {
        return switch (self) {
            .boolean => |bit| bit,
            else => null,
        };
    }
};

pub const Field = struct {
    name: []u8,
    value: Value,
};

pub fn parse(arena: std.mem.Allocator, text: []const u8) error{ InvalidJson, OutOfMemory }!Value {
    var parser = Parser{ .text = text, .arena = arena };
    const value = try parser.parseValue();
    parser.skip();
    if (parser.i != parser.text.len) return error.InvalidJson;
    return value;
}

const Parser = struct {
    text: []const u8,
    i: usize = 0,
    arena: std.mem.Allocator,
    depth: u8 = 0,

    fn skip(self: *Parser) void {
        while (self.i < self.text.len and std.ascii.isWhitespace(self.text[self.i])) self.i += 1;
    }

    fn peek(self: *Parser) ?u8 {
        self.skip();
        if (self.i >= self.text.len) return null;
        return self.text[self.i];
    }

    fn parseValue(self: *Parser) error{ InvalidJson, OutOfMemory }!Value {
        const byte = self.peek() orelse return error.InvalidJson;
        if (self.depth > 24) return error.InvalidJson;
        switch (byte) {
            '{' => return self.parseObject(),
            '[' => return self.parseArray(),
            '"' => return .{ .string = try self.parseString() },
            't' => return self.parseLiteral("true", .{ .boolean = true }),
            'f' => return self.parseLiteral("false", .{ .boolean = false }),
            'n' => return self.parseLiteral("null", .null),
            '-', '0'...'9' => return self.parseNumber(),
            else => return error.InvalidJson,
        }
    }

    fn parseLiteral(self: *Parser, word: []const u8, value: Value) error{InvalidJson}!Value {
        if (self.i + word.len > self.text.len) return error.InvalidJson;
        if (!std.mem.eql(u8, self.text[self.i .. self.i + word.len], word)) return error.InvalidJson;
        self.i += word.len;
        return value;
    }

    fn parseObject(self: *Parser) error{ InvalidJson, OutOfMemory }!Value {
        self.i += 1;
        self.depth += 1;
        defer self.depth -= 1;
        var fields: std.ArrayList(Field) = .empty;
        if (self.peek() == '}') {
            self.i += 1;
            return .{ .object = fields };
        }
        while (true) {
            if (self.peek() != '"') return error.InvalidJson;
            const name = try self.parseString();
            if (self.peek() != ':') return error.InvalidJson;
            self.i += 1;
            const value = try self.parseValue();
            try fields.append(self.arena, .{ .name = name, .value = value });
            switch (self.peek() orelse return error.InvalidJson) {
                ',' => self.i += 1,
                '}' => {
                    self.i += 1;
                    break;
                },
                else => return error.InvalidJson,
            }
        }
        return .{ .object = fields };
    }

    fn parseArray(self: *Parser) error{ InvalidJson, OutOfMemory }!Value {
        self.i += 1;
        self.depth += 1;
        defer self.depth -= 1;
        var items: std.ArrayList(Value) = .empty;
        if (self.peek() == ']') {
            self.i += 1;
            return .{ .array = items };
        }
        while (true) {
            try items.append(self.arena, try self.parseValue());
            switch (self.peek() orelse return error.InvalidJson) {
                ',' => self.i += 1,
                ']' => {
                    self.i += 1;
                    break;
                },
                else => return error.InvalidJson,
            }
        }
        return .{ .array = items };
    }

    fn parseNumber(self: *Parser) error{InvalidJson}!Value {
        const start = self.i;
        if (self.text[self.i] == '-') self.i += 1;
        if (self.i >= self.text.len or !std.ascii.isDigit(self.text[self.i])) return error.InvalidJson;
        while (self.i < self.text.len and std.ascii.isDigit(self.text[self.i])) self.i += 1;
        var fractional = false;
        if (self.i < self.text.len and self.text[self.i] == '.') {
            fractional = true;
            self.i += 1;
            if (self.i >= self.text.len or !std.ascii.isDigit(self.text[self.i])) return error.InvalidJson;
            while (self.i < self.text.len and std.ascii.isDigit(self.text[self.i])) self.i += 1;
        }
        if (self.i < self.text.len and (self.text[self.i] == 'e' or self.text[self.i] == 'E')) {
            fractional = true;
            self.i += 1;
            if (self.i < self.text.len and (self.text[self.i] == '+' or self.text[self.i] == '-')) self.i += 1;
            if (self.i >= self.text.len or !std.ascii.isDigit(self.text[self.i])) return error.InvalidJson;
            while (self.i < self.text.len and std.ascii.isDigit(self.text[self.i])) self.i += 1;
        }
        const token = self.text[start..self.i];
        if (fractional) {
            const number = std.fmt.parseFloat(f64, token) catch return error.InvalidJson;
            return .{ .float = number };
        }
        const number = std.fmt.parseInt(i64, token, 10) catch return error.InvalidJson;
        return .{ .integer = number };
    }

    fn parseString(self: *Parser) error{ InvalidJson, OutOfMemory }![]u8 {
        if (self.peek() != '"') return error.InvalidJson;
        self.i += 1;
        var out: std.ArrayList(u8) = .empty;
        while (self.i < self.text.len) {
            const byte = self.text[self.i];
            self.i += 1;
            switch (byte) {
                '"' => return out.toOwnedSlice(self.arena),
                '\\' => {
                    if (self.i >= self.text.len) return error.InvalidJson;
                    const esc = self.text[self.i];
                    self.i += 1;
                    switch (esc) {
                        '"', '\\', '/' => try out.append(self.arena, esc),
                        'b' => try out.append(self.arena, 8),
                        'f' => try out.append(self.arena, 12),
                        'n' => try out.append(self.arena, '\n'),
                        'r' => try out.append(self.arena, '\r'),
                        't' => try out.append(self.arena, '\t'),
                        'u' => {
                            if (self.i + 4 > self.text.len) return error.InvalidJson;
                            const code = std.fmt.parseInt(u21, self.text[self.i .. self.i + 4], 16) catch return error.InvalidJson;
                            self.i += 4;
                            var buf: [4]u8 = undefined;
                            const n = std.unicode.utf8Encode(code, &buf) catch return error.InvalidJson;
                            try out.appendSlice(self.arena, buf[0..n]);
                        },
                        else => return error.InvalidJson,
                    }
                },
                else => try out.append(self.arena, byte),
            }
        }
        return error.InvalidJson;
    }
};

pub fn escape(out: *std.Io.Writer, text: []const u8) std.Io.Writer.Error!void {
    try out.writeByte('"');
    for (text) |byte| switch (byte) {
        '"' => try out.writeAll("\\\""),
        '\\' => try out.writeAll("\\\\"),
        '\n' => try out.writeAll("\\n"),
        '\r' => try out.writeAll("\\r"),
        '\t' => try out.writeAll("\\t"),
        else => {
            if (byte < 0x20) {
                try out.print("\\u{x:0>4}", .{byte});
            } else {
                try out.writeByte(byte);
            }
        },
    };
    try out.writeByte('"');
}

test "object fields keep their text" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const value = try parse(arena_state.allocator(), "{\"fn\":\"Kitchen\",\"ca\":5,\"on\":true}");
    try std.testing.expectEqualStrings("Kitchen", value.get("fn").?.asString().?);
    try std.testing.expectEqual(@as(i64, 5), value.get("ca").?.asInt().?);
    try std.testing.expect(value.get("on").?.asBool().?);
}
