//! The whole cycle on a journal in a temporary directory: append events, fold
//! them into state through a sink, write a snapshot, drop what it covers, and
//! reopen from the snapshot plus the records after it.
//!
//! `zig build examples` builds AND runs this; `ci/readme_usage.sh` extracts
//! the region between the usage markers into README.md, so the snippet a
//! reader copies is code CI executes.

const std = @import("std");
const zjournal = @import("zjournal");

/// One arm per thing that can happen. Anything `std.json` can write and read
/// back works; a tagged union gives each record a name on disk.
const Event = union(enum) {
    account_opened: struct { id: u32, owner: []const u8 },
    deposited: struct { id: u32, cents: i64 },
    withdrawn: struct { id: u32, cents: i64 },
};

const Ledger = zjournal.Journal(Event);

/// The state the log adds up to. It is built the same way from the disk and
/// from live appends, because the journal calls the sink for both.
const Balances = struct {
    accounts: u32 = 0,
    cents: i64 = 0,

    fn sink(self: *Balances) Ledger.Sink {
        return .{ .ctx = self, .f = apply };
    }

    fn apply(ctx: *anyopaque, record: Ledger.Record) void {
        const self: *Balances = @ptrCast(@alignCast(ctx));
        switch (record.event) {
            .account_opened => self.accounts += 1,
            .deposited => |e| self.cents += e.cents,
            .withdrawn => |e| self.cents -= e.cents,
        }
    }
};

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var dir = std.Io.Dir.cwd();
    defer dir.deleteTree(io, "zjournal-example") catch {};
    const path = "zjournal-example/ledger";

    // --- README:usage ---

    var balances: Balances = .{};
    var last: u64 = 0;
    {
        // Open the log. The directory is created if it is not there, the
        // newest records are read back, and the sequence number continues
        // from the last one, so a restart never reuses a number. A second
        // writer would get error.Locked instead of this journal.
        var ledger = try Ledger.open(gpa, io, path, .{ .schema_version = 1 });
        defer ledger.deinit(io);

        // A sink is a fold. Subscribing streams it every record already on
        // disk -- one at a time, however long the history -- and then every
        // record appended, so the state is built the same way whether it
        // came from a file or from a live writer.
        try ledger.subscribe(io, balances.sink());

        // Append. The returned sequence number means the bytes are on the
        // disk: the record is written, flushed and fsynced before any reader
        // can see it.
        const now = std.Io.Clock.real.now(io).toMilliseconds();
        _ = try ledger.append(io, now, .{ .account_opened = .{ .id = 1, .owner = "ada" } });
        _ = try ledger.append(io, now, .{ .deposited = .{ .id = 1, .cents = 5_000 } });
        last = try ledger.append(io, now, .{ .withdrawn = .{ .id = 1, .cents = 1_250 } });

        // Write the fold out beside the log and drop the records it covers,
        // so the next start replays three records instead of three million.
        // Nothing drops history on your behalf; this is the call that does.
        try ledger.snapshot(io, std.mem.asBytes(&balances));
        try ledger.compact(io, last);

        _ = try ledger.append(io, now, .{ .deposited = .{ .id = 1, .cents = 700 } });
    }

    // Starting again: restore the snapshot, then fold only what came after
    // it. Without a snapshot `from` stays 0 and the whole log is replayed.
    const opened = try Ledger.openWithSnapshot(gpa, io, path, .{ .schema_version = 1 });
    var reopened = opened.journal;
    defer reopened.deinit(io);

    var restored: Balances = .{};
    var from: u64 = 0;
    if (opened.snapshot) |snapshot| {
        defer gpa.free(snapshot.state);
        restored = std.mem.bytesToValue(Balances, snapshot.state[0..@sizeOf(Balances)]);
        from = snapshot.seq;
    }
    try reopened.subscribeFrom(io, restored.sink(), from);
    // --- README:usage ---

    std.debug.print("snapshot: seq {}, {} cents\n", .{ from, balances.cents });
    std.debug.print("restored: {} accounts, {} cents, seq {}\n", .{ restored.accounts, restored.cents, try reopened.lastSeq(io) });
    std.debug.print("replayed: {} record(s) after the snapshot\n", .{reopened.since(from).records.len});
    if (restored.cents != balances.cents) return error.FoldMismatch;
    if (last != 3) return error.UnexpectedSequence;
}
