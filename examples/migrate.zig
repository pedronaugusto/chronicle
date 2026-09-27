//! A schema that moves: records written at version 1 read back by a program
//! at version 2, through a `migrate` hook.
//!
//! Version 1 said who opened an account in one string, "Ada Lovelace".
//! Version 2 keeps the given name and the family name apart. The records on
//! disk are never rewritten; each is translated as it is read, into the arena
//! that owns it.
//!
//! `zig build examples` builds AND runs this.

const std = @import("std");
const chronicle = @import("chronicle");

/// The events as this program writes them now, at version 2.
const Event = union(enum) {
    account_opened: struct { id: u32, given: []const u8, family: []const u8 },
    deposited: struct { id: u32, cents: i64 },
};

/// The same events as version 1 wrote them. Only the arm that changed is
/// needed; an unchanged arm parses as the new type.
const V1 = union(enum) {
    account_opened: struct { id: u32, owner: []const u8 },
    deposited: struct { id: u32, cents: i64 },
};

const Ledger = chronicle.Journal(Event);
const LedgerV1 = chronicle.Journal(V1);

/// Called for every record written below version 2. `arena` is the record's:
/// the old shape is parsed into it, and so are the new strings, so they live
/// exactly as long as the record and nothing is freed by hand.
fn migrate(arena: std.mem.Allocator, from_version: u32, value: std.json.Value) Ledger.MigrateError!Event {
    if (from_version != 1) return error.Unmigratable;
    const old = std.json.parseFromValueLeaky(V1, arena, value, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.Unmigratable,
    };
    return switch (old) {
        .account_opened => |opened| split: {
            const space = std.mem.lastIndexOfScalar(u8, opened.owner, ' ') orelse opened.owner.len;
            break :split .{ .account_opened = .{
                .id = opened.id,
                .given = try arena.dupe(u8, opened.owner[0..space]),
                .family = try arena.dupe(u8, std.mem.trim(u8, opened.owner[space..], " ")),
            } };
        },
        .deposited => |d| .{ .deposited = .{ .id = d.id, .cents = d.cents } },
    };
}

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_allocator.deinit();
    const gpa = debug_allocator.allocator();

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var dir = std.Io.Dir.cwd();
    defer dir.deleteTree(io, "chronicle-migrate-example") catch {};
    const path = "chronicle-migrate-example/ledger";

    // Last year's program, at version 1.
    {
        var ledger = try LedgerV1.open(gpa, io, path, .{ .schema_version = 1 });
        defer ledger.deinit(io);
        _ = try ledger.append(io, 0, .{ .account_opened = .{ .id = 1, .owner = "Ada Lovelace" } });
        _ = try ledger.append(io, 0, .{ .deposited = .{ .id = 1, .cents = 5_000 } });
    }

    // This year's, at version 2. The old records come back as today's
    // events; the new one is written at version 2.
    var ledger = try Ledger.open(gpa, io, path, .{ .schema_version = 2, .migrate = migrate });
    defer ledger.deinit(io);
    _ = try ledger.append(io, 0, .{ .deposited = .{ .id = 1, .cents = 700 } });

    var cents: i64 = 0;
    for (ledger.records().records) |record| {
        switch (record.event) {
            .account_opened => |opened| {
                std.debug.print("v{d}: {s}, family {s}\n", .{ record.version, opened.given, opened.family });
                if (!std.mem.eql(u8, opened.family, "Lovelace")) return error.MigrationMismatch;
            },
            .deposited => |d| cents += d.cents,
        }
    }
    std.debug.print("balance: {d} cents\n", .{cents});
    if (cents != 5_700) return error.MigrationMismatch;
}
