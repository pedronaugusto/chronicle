//! Opaque owners for replay walks and named readers.
const std = @import("std");
const Io = std.Io;

pub fn ReplayOwner(comptime State: type, comptime PositionType: type) type {
    return opaque {
        /// Where a walk is, for `rearmAt` and `Journal.replayAt`.
        pub const Position = PositionType;
        const Self = @This();
        fn inner(self: *Self) *State.Replay {
            return @ptrCast(@alignCast(self)); // safe: construction retains this allocated state until deinit.
        }
        /// Private: the owner over the walk a journal built.
        pub fn from(state: *State.Replay) *Self {
            return @ptrCast(state); // safe: hides the stable allocation without copying it.
        }
        fn view(self: *const Self) *const State.Replay {
            return @ptrCast(@alignCast(self)); // safe: observes the same allocated replay state without mutating it.
        }
        /// Release the walk and every record it owns. Its journal must still be alive.
        pub fn deinit(walk: *Self, io: Io) void {
            return State.Replay.deinit(walk.inner(), io);
        }

        /// Start another pass after `position`, keeping this walk's scan
        /// buffer, line buffer, segment storage and record arenas. Call
        /// after the previous pass has ended or when its remaining records
        /// are no longer needed. Any record returned by `next` is invalid
        /// after this call. On error, re-arm or deinit before calling
        /// `next` again.
        ///
        /// The position is checked against the record it names on every
        /// pass. A changed or removed record is `error.StalePosition`.
        pub fn rearmAt(walk: *Self, io: Io, at: Position) State.ReplayAtError!void {
            return State.Replay.rearmAt(walk.inner(), io, at);
        }

        /// The next record, or null at the end of the log. It is valid
        /// until the next call to `next` or to `deinit`.
        pub fn next(walk: *Self, io: Io) State.ReplayError!?State.Record {
            return State.Replay.next(walk.inner(), io);
        }

        /// Where this walk got to: after the last record `next` returned,
        /// or the last one it stepped over on the way to the first. A
        /// walk that ends in an error is at the last record it read
        /// without one, so a walk from here reads the bad one again.
        pub fn position(walk: *const Self) Position {
            return State.Replay.position(walk.view());
        }
    };
}

pub fn TailerOwner(comptime State: type, comptime ReplayType: type) type {
    return opaque {
        /// The walk `replay` returns.
        pub const Replay = ReplayType;
        const Self = @This();
        fn inner(self: *Self) *State.Tailer {
            return @ptrCast(@alignCast(self)); // safe: construction retains this allocated state until deinit.
        }
        /// Private: the owner over the reader a journal built.
        pub fn from(state: *State.Tailer) *Self {
            return @ptrCast(state); // safe: hides the stable allocation without copying it.
        }
        /// Where this reader has got to, copied under the journal lock.
        /// Safe to call from any task or thread, except from inside a sink.
        pub fn cursor(tail: *Self, io: Io) Io.Cancelable!u64 {
            return State.Tailer.cursor(tail.inner(), io);
        }

        /// Release the owner and its name. The cursor file stays on disk; that is
        /// the point of it.
        pub fn deinit(tail: *Self) void {
            return State.Tailer.deinit(tail.inner());
        }

        /// A walk over every record after the committed cursor, read from
        /// the disk. `Journal.replay(io, try tailer.cursor(io))`, named.
        /// The cursor and scan are taken under the journal's lock, so
        /// a concurrent `commit` cannot move the cursor during the choice.
        pub fn replay(tail: *Self, io: Io) State.ReplayError!*Replay {
            return Replay.from(try State.Tailer.replay(tail.inner(), io));
        }

        /// Record `seq` as where this reader has got to, durably, and move
        /// `cursor` to it.
        ///
        /// The file is written beside the log and renamed into place, so a
        /// crash leaves either the whole old cursor or the whole new one —
        /// never a number that was never reached.
        ///
        /// Safe to call from any task or thread.
        pub fn commit(tail: *Self, io: Io, seq: u64) State.TailerError!void {
            return State.Tailer.commit(tail.inner(), io, seq);
        }

        /// Remove this reader's cursor file, so that the next `tailer`
        /// under this name starts from zero. The tailer itself is left at
        /// the cursor it had; `deinit` is still how it ends.
        ///
        /// Safe to call from any task or thread.
        pub fn forget(tail: *Self, io: Io) State.TailerError!void {
            return State.Tailer.forget(tail.inner(), io);
        }

        /// This reader's immutable name, borrowed until deinit.
        pub fn name(tail: *const Self) []const u8 {
            const state: *const State.Tailer = @ptrCast(@alignCast(tail)); // safe: borrows the initialized tailer allocation for its lifetime.
            return state.name;
        }
    };
}
