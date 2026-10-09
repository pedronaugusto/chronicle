//! What a project that depends on chronicle writes. Built by
//! `zig build check-consumer` with only aegis, strand, airlock and warp to fetch, so
//! chronicle's build.zig must work without any of its own CI dependencies.
const chronicle = @import("chronicle");

const Event = struct { id: u32 };

pub fn main() void {
    _ = &chronicle.Journal(Event).open;
}
