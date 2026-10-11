const std = @import("std");
const cli = @import("cli.zig");
const mirror = @import("mirror.zig");
const serve = @import("serve.zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len > 1 and std.mem.eql(u8, args[1], "serve")) return serve.run(init);
    if (args.len >= 4 and std.mem.eql(u8, args[1], "mirror") and std.mem.eql(u8, args[2], "--session")) {
        mirror.session(init, args[3]);
        return;
    }
    try cli.run(init);
}
