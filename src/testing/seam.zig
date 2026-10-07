//! airlock's raw calls under shakedown: the `Io` a test hands the code that
//! syncs. It is a `FaultIo` under the layer whose `fileSync` is airlock's
//! `hookedSync`, so every sync airlock makes is a step of the `FaultIo`'s
//! trace, counted there, and a plan of airlock calls can fail one.
const std = @import("std");
const builtin = @import("builtin");
const airlock = @import("airlock");
const shakedown = @import("shakedown");

pub const Call = airlock.sys.Call;
pub const Plan = shakedown.Plan(Call, airlock.sys.Result);
const Hooked = shakedown.Layer(airlock.sys.HookedState, .{ .fileSync = airlock.sys.hookedSync });

/// One test's hooked `Io`. Must not move once `io` is called; `create`
/// allocates it.
pub const Seam = struct {
    gpa: std.mem.Allocator,
    fio: *shakedown.FaultIo,
    plan: Plan,
    counters: [4]u32 = undefined,
    mutex: std.atomic.Mutex = .unlocked,
    hook: airlock.sys.Hook,
    hooked: Hooked,

    /// `entries` must outlive the seam, and hold at most four entries.
    pub fn create(gpa: std.mem.Allocator, base: std.Io, entries: []const Plan.Entry) !*Seam {
        const fio = try shakedown.FaultIo.init(gpa, base, .{ .trace = .all });
        errdefer fio.deinit();
        const s = try gpa.create(Seam);
        s.* = .{ .gpa = gpa, .fio = fio, .plan = undefined, .hook = undefined, .hooked = undefined };
        std.debug.assert(entries.len <= s.counters.len);
        s.plan = .init(entries, .{ .steps = fio.steps(), .counters = &s.counters });
        s.hook = .{ .ctx = s, .call = decide, .base = fio.io() };
        s.hooked = .init(fio.io(), .{ .hook = &s.hook });
        return s;
    }

    pub fn destroy(s: *Seam) void {
        s.fio.deinit();
        s.gpa.destroy(s);
    }

    /// Replaces the plan, its counts starting again: for faults planned once a
    /// fixture is set up. Not while calls are in flight.
    pub fn setPlan(s: *Seam, entries: []const Plan.Entry) void {
        std.debug.assert(entries.len <= s.counters.len);
        s.plan = .init(entries, .{ .steps = s.fio.steps(), .counters = &s.counters });
    }

    /// The `Io` to hand the code under test.
    pub fn io(s: *Seam) std.Io {
        return s.hooked.io();
    }

    /// How many times airlock made `call`.
    pub fn count(s: *Seam, call: Call) u32 {
        var n: u32 = 0;
        for (s.fio.trace().records()) |record| {
            const foreign = record.event.foreign orelse continue;
            if (foreign.call == @backingInt(call)) n += 1;
        }
        return n;
    }

    /// How many syncs of any kind airlock made: full, barrier, data, plain
    /// and writeout alike.
    pub fn syncs(s: *Seam) u32 {
        var n: u32 = 0;
        inline for (.{ .sync_full, .sync_barrier, .sync_data, .sync_plain, .sync_writeout }) |call| n += s.count(call);
        return n;
    }

    fn decide(ctx: *anyopaque, call: Call, path: ?[]const u8) ?airlock.sys.Result {
        const s: *Seam = @ptrCast(@alignCast(ctx)); // safe: `create` makes the hook with its own seam as ctx
        const begun = s.fio.beginForeign(Call, call, path);
        const result = result: {
            while (!s.mutex.tryLock()) std.atomic.spinLoopHint();
            defer s.mutex.unlock();
            break :result s.plan.decideAt(begun.step, call, path);
        };
        s.fio.endForeign(begun, if (result) |r| switch (r) {
            .code => .{ .err = error.Injected },
            .canceled => .{ .err = error.Canceled },
            .value => |v| .{ .ok = v },
        } else .{ .ok = 0 });
        return result;
    }
};

/// The platform's I/O error, as the code a raw call returns.
pub const io_error: airlock.sys.Code = if (builtin.target.os.tag == .windows) .IO_DEVICE_ERROR else .IO;

/// The code a filesystem that cannot be asked for `call` returns.
pub const refused: airlock.sys.Code = if (builtin.target.os.tag == .windows) .NOT_SUPPORTED else .INVAL;

/// The sync a data-level `airlock.syncFile` makes on this platform first.
pub const data_sync: Call = if (builtin.target.os.tag.isDarwin()) .sync_full else .sync_data;

/// The plan entry that answers the `n`-th `call` with `code`.
pub fn fail(call: Call, n: u32, code: airlock.sys.Code) Plan.Entry {
    return .{ .at = .{ .nth = .{ .call = call, .n = n } }, .fault = .{ .code = code } };
}
