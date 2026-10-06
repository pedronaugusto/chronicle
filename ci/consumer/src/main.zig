const chronicle = @import("chronicle");

const Event = struct { id: u32 };

pub fn main() void {
    _ = &chronicle.Journal(Event).open;
}
