//! The whole cycle on a journal in a temporary directory: append events, fold
//! them into state through a sink, write a snapshot, drop what it covers, and
//! reopen from the snapshot plus the records after it.
//!
//! `zig build examples` builds AND runs this; `zig build docs -- usage` extracts
//! the region between the usage markers into README.md, so the snippet a
//! reader copies is code CI executes.

const std = @import("std");
const chronicle = @import("chronicle");

/// One arm per thing that can happen. Anything `std.json` can write and read
/// back works; a tagged union gives each record a name on disk.
const Event = union(enum) {
    account_opened: struct { id: u32, owner: []const u8 },
    deposited: struct { id: u32, cents: i64 },
    withdrawn: struct { id: u32, cents: i64 },
};

const Ledger = chronicle.Journal(Event);

/// The state the log adds up to. It is built the same way from the disk and
/// from live appends, because the journal calls the sink for both.
const Balances = struct {
    accounts: u32 = 0,
    cents: i64 = 0,

    fn sink(self: *Balances) Ledger.Sink {
        return .{ .ctx = self, .f = apply };
    }

    fn apply(ctx: *anyopaque, record: Ledger.Record) void {
        const self: *Balances = @ptrCast(@alignCast(ctx)); // safe: sink hands apply out with a Balances as its ctx
        switch (record.event) {
            .account_opened => self.accounts += 1,
            .deposited => |e| self.cents += e.cents,
            .withdrawn => |e| self.cents -= e.cents,
        }
    }
};

pub fn main() !void {
    var safe_allocator: std.heap.SafeAllocator = .init(std.heap.page_allocator, .{});
    defer _ = safe_allocator.deinit();
    const gpa = safe_allocator.allocator();

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var display_buffer: [4096]u8 = undefined;
    var display = std.Io.File.stdout().writer(io, &display_buffer);
    const output = &display.interface;

    var dir = std.Io.Dir.cwd();
    defer dir.deleteTree(io, "chronicle-example") catch |err| {
        // Temporary-directory cleanup runs after the journal closes and cannot return an error.
        std.log.debug("example cleanup: {t}", .{err});
    };
    const path = "chronicle-example/ledger";

    // --- README:usage ---

    var balances: Balances = .{};
    var last: u64 = 0;
    {
        const ledger = try Ledger.open(gpa, io, path, .{ .schema_version = 1 });
        defer ledger.deinit(io);

        try ledger.subscribe(io, balances.sink());

        const now = std.Io.Clock.real.now(io).toMilliseconds();
        _ = try ledger.append(io, now, .{ .account_opened = .{ .id = 1, .owner = "ada" } });

        const follower = try ledger.replayAt(io, .after(0));
        defer follower.deinit(io);
        _ = (try follower.next(io)).?;

        last = try ledger.appendAll(io, &.{
            .{ .at = now, .event = .{ .deposited = .{ .id = 1, .cents = 5_000 } } },
            .{ .at = now, .event = .{ .withdrawn = .{ .id = 1, .cents = 1_250 } } },
        }, .group);
        try follower.rearmAt(io, follower.position());
        var followed: usize = 0;
        while (try follower.next(io)) |_| followed += 1;
        if (followed != 2) return error.ReplayMismatch;

        try ledger.snapshot(io, std.mem.asBytes(&balances));
        try ledger.compact(io, last);

        _ = try ledger.append(io, now, .{ .deposited = .{ .id = 1, .cents = 700 } });
    }

    const opened = try Ledger.openWithSnapshot(gpa, io, path, .{ .schema_version = 1 });
    const reopened = opened.journal;
    defer reopened.deinit(io);

    var restored: Balances = .{};
    var from: u64 = 0;
    if (opened.snapshot) |snapshot| {
        defer snapshot.deinit(gpa);
        restored = std.mem.bytesToValue(Balances, snapshot.state[0..@sizeOf(Balances)]);
        from = snapshot.seq;
    }
    try reopened.subscribeFrom(io, restored.sink(), from);
    // --- README:usage ---

    try output.print("snapshot: seq {}, {} cents\n", .{ from, balances.cents });
    try output.print("restored: {} accounts, {} cents, seq {}\n", .{ restored.accounts, restored.cents, try reopened.lastSeq(io) });
    const batch = try reopened.copySince(gpa, io, from);
    defer batch.deinit();
    if (!batch.complete()) return error.IncompleteTail;
    try output.print("replayed: {} record(s) after the snapshot\n", .{batch.records().len});
    const readers = try reopened.readers(gpa, io);
    defer readers.deinit();
    if (readers.items().len != 0) return error.UnexpectedReader;
    if (restored.cents != balances.cents) return error.FoldMismatch;
    if (last != 3) return error.UnexpectedSequence;
    try output.flush();
}
