//! The machine name, through one C function declared by hand.
const std = @import("std");

extern "c" fn gethostname(name: [*]u8, len: usize) c_int;

pub fn hostname(buf: []u8) error{HostnameFailed}![]u8 {
    if (buf.len == 0) return error.HostnameFailed;
    if (gethostname(buf.ptr, buf.len) != 0) return error.HostnameFailed;
    const end = std.mem.indexOfScalar(u8, buf, 0) orelse return error.HostnameFailed;
    return buf[0..end];
}

test "hostname is a non-empty c string" {
    var buf: [256]u8 = undefined;
    const name = try hostname(&buf);
    try std.testing.expect(name.len > 0);
}
