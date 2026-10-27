# Design

What chronicle keeps apart, what it checks and where it reads a number raw. The
promises a user relies on are in the README; the invariants the tests hold are
in `ci/invariants.md`.

## Three kinds of number

A journal talks about where a record sits in the sequence, how many bytes
something is, how many records there are, and when a record happened. The first
three are `u64`s on the disk
and in the first versions of this code were `u64`s everywhere, so a sequence
number could stand where an offset was wanted and compile. They are
[aegis](https://github.com/pedronaugusto/aegis) types now, declared once in
`src/journal/values.zig` and named in the public API:

- `Seq` (`aegis.id.Id`): a position in the sequence. Record 1 is the first of a
  journal that has never been compacted, and zero is the place before it, which
  `beginning` names. It has equality and an order, and nothing else: it cannot
  be added to a count or passed for a byte offset. A cursor, an `Expected.last`,
  a snapshot's `seq`, a segment's name and a record's number are all `Seq`.
- `Bytes` (`aegis.units.Bytes`): a length or an offset in a file or a buffer,
  and every size in `Options`.
- `Records` (`aegis.units.Count`): how many records, whether a segment's limit,
  a tail's, a `verify`'s result or the entries an index holds.
- `Time` (`aegis.units.Instant(.real, .millisecond, i64)`): when the caller
  said a record happened, milliseconds since the Unix epoch. chronicle stores
  what it is handed and never reads a clock; the index's bisection treats the
  times as ordered only when they are. A record's `at`, an `Entry`'s, a
  segment's lowest and highest and `seqAtOrAfter`'s argument are all `Time`.

The relations between the kinds are not in aegis: a sequence number moved by
a count of records, the count between two sequence numbers, the sequence number a
count of records ends at. `values.zig` writes them once on aegis's checked integers
(`successor`, `advance`, `span`, `lastOf`, `back`) beside the few helpers that
read as the code does (`below`, `atMost`, `lesser`, `greater`, `plus`, `minus`).
Nothing else in the package does arithmetic on a raw sequence number, offset or
count.

### Where a number comes from decides what a bad one does

- From outside the process (a segment's name, an index's header, a record's
  line, a cursor or snapshot document, an option): checked at the boundary, and
  refused with the error or the fallback that boundary already had. A segment
  file named for a number no record can carry is not a segment. An index that
  counts records past the last sequence number a record can carry is a stale
  cache and is rebuilt. A record count that cannot belong to its segment is
  `error.CorruptRecord`. A sequence that has run out is
  `error.SequenceExhausted`, from the log as well as the journal.
- From the package's own bookkeeping (a segment's length plus a record, a
  scan's position): `values.plus` and `values.minus` stop the program with a
  message in every build rather than wrap in a release one. These are lengths
  and counts of one segment, far inside 64 bits.
- An option that is a limit and may be any number (`preallocate_bytes`,
  `max_record_bytes`): a sum that passes what a file can hold is cut to the
  limit it was going to be cut to anyway.

### Where a number is read raw

`raw()` and `fromRaw` appear at four kinds of place, and nowhere else.

- **The wire.** Every on-disk integer keeps its width: the segment header's
  `base`, `root` and version, an index header and its 24-byte entries, a
  record's `seq`, `bf` and `bl`, the snapshot and cursor documents. They are
  read and written as `u64`, `i64` and `u32` and wrapped or unwrapped in the
  function that does it, so nothing about the format changed.
- **The operating system.** `setLength`, `readPositionalAll`, `seekTo`,
  `writePositionalAll`, `limited`, and the offsets strand's line reader reports
  are `u64`s or `usize`s.
- **`values.zig`.** The relations above, `limit` and `memory`, which turn a count
  into a length in memory with a checked cast, and `following`, the saturating
  place after a number. They are the one place each of those is written.
- **Tests and benchmarks.** They build expectations with plain integers and
  turn them into the types at the call, or read an answer back with `raw()` to
  count with it. Neither does arithmetic on a `raw()` of an aegis value inline.

### What stays a plain integer

- The slot numbers and byte positions inside one index file
  (`indexEntryAt`, `bisectSeq`, the proof's read loop). They are bounded by the
  file's measured length, and the numbers that matter (the entry count) are
  `Records` at the boundary.
- Checksums and schema versions, `u32`s. They are compared with others of their
  own kind and with nothing else.
- Counters that exist for the tests (`index_opens`, `segment_scans`, ...), the
  count of segments, and the sizes of in-memory buffers once they are lengths:
  a slice's length is a `usize`.

## Bytes off a disk

Everything a scan returns, and every file read whole, is a `values.Unparsed`
(`aegis.input.Untrusted([]const u8)`). It cannot be read as a record, a segment
header or a sequence number without handing it to the reader that answers for it,
whose result is a refined value or a named refusal: `envelope.read` for a
record's members (`Fields`, from which `head`, `stamp`, `backLink` and `batchOf`
are taken), `parseHeader` for a record's envelope with its checksum checked,
`parseSegmentHeader` for a file's first line, `streams.Index.parse` for a
stream index. The places that use the bytes
themselves (copying a record into a compacted segment, keeping a copy in the tail)
say why in a comment.

A line is read once, through strand's member iterator (`json.Members`), in any
spelling JSON allows: members in any order, whitespace anywhere, names escaped.
There is no second reader for the spelling chronicle writes. The read checks that
the line is one JSON object, refuses a member of the envelope given twice, and
takes the checksum where the object's last member is `c`: it covers the line up
to the separator before `c`, the same bytes the writer checksummed. A line whose
damage breaks the JSON is `CorruptRecord` before any checksum is read; a line that
reads as a record and does not match its checksum is `ChecksumMismatch`. A final
line holding zeros (space a writer reserved and never filled) is torn, whatever
else it holds.

A header's event span is cut from the line it was read from; handing `eventFrom`
a pair that do not belong together is refused in every build, not only in Debug.

## Streams

A record in a stream carries `s` (its id) and `sv` (its version) before `ev`,
inside the checksum. Ids are restricted to printable ASCII without `"` or `\`, so
an id has one spelling in JSON and the bytes between its quotes are the id: the
envelope reports where they sit (`InStream.id`), and a record built from a copy
of the line takes its id from the copy.

Versions are an aegis id of their own (`StreamVersion`, moved by `Versions`), so
a stream's version cannot stand for a `Seq`. They are written as JSON integers and
end at `last_version` (`maxInt(i64)`); an append that would pass it is
`StreamVersionExhausted`. Every step from one version to the next is checked.

**Where a stream's records are.** The active segment's are kept in memory (the
book's `placed`, read again from the segment whenever the book may be stale, such
as after an append that failed). Each sealed segment has a stream index beside it,
written when it is sealed: a header naming the segment's first record and length,
a bloom filter (ten bits a stream, seven probes from one Wyhash), then each stream
in order of id with its records in order of version, then a CRC-32C. The index is
read whole through `aegis.own.readFile`, at most the segment's length and a
header, and `Index.parse` is its one reader: the checksum, the segment it names,
and every section lying whole inside the file, each stream once and in order,
each stream's versions rising. What it refuses is rebuilt from the segment; a
segment that cannot give an index `parse` accepts is `CorruptRecord`. An index
`parse` accepted is walked without checks.

**Heads.** A stream's newest version is the active segment's, else the newest
segment whose index holds it, read newest first. The ones found are kept in an
LRU sized by `Options.stream_heads`; one that could not be kept is looked up again.

**Truncation.** `truncateStreamBefore` records the point in the `truncations` file
(one `{"s":..,"tb":..}` line each, written through a temporary renamed into place)
before it returns; a read starts at the point. Should the file not be written,
the point in memory is put back as it was, which allocates nothing. `compact` and
`dropSegmentsBefore` raise the point of every stream whose records they drop to
just past the newest dropped, before dropping them: a stream's version is the
newest of its records or its point, so it never goes back.

**Stubs.** `compact` rewrites each sealed segment holding a record below its
stream's point (the active segment is sealed first) through airlock's
publish-by-rename. Such a record becomes `{seq,at,v,p,[bf,bl],s,sv,"x":1,"sc":..,"c":..}`:
`sc` is the checksum of the stub's bytes before it and `c` is the record's own,
unchanged, which the record after it links to. Nothing after a stub is
rewritten, and `verify` checks a stub against `sc` and the chain through `c`. A
segment with a stub in it is format 2 in its header, so chronicle 0.10 refuses it
rather than read a stub as a record.

## State that is checked in every build

- `Segment.count` is `span(base_seq, last_seq)` and a segment's last record is
  at most one before its first.
- `continuity.State.accept` refuses a header whose number is zero, above an
  `i64`, or outside its batch.
- `encode` refuses to write a record with such a number: it would be durable
  before anything read it back.
- `Builder.wants` and the log's offsets use checked subtraction, so a record
  that moves backwards in its segment stops the program.

## One lock, and what it guards

Everything about a journal that changes once it is open sits in one `State`
(`journal.zig`) behind aegis's `BlockingGuarded`: the log and its segments, the
tail, the sinks, the newest sequence number, the failed-write latch, the nudge
count and the buffers a record is written through. `BlockingGuarded` is an
`Io.Mutex` that owns its data: there is no way to the state but a guard, and a
guard is released explicitly with the `Io` it was taken with. What does not
change after open, the allocator and the `Options`, is read without it.

Because the state is only reachable through a guard, a helper that needs the lock
says so in its signature and cannot be called without one. A method that only
reads or changes state is a method of `State` (`expect`, `tailSince`, `clearTail`,
`dropTailBefore`, `unstage`); one that also needs the allocator or the options
takes the journal and the state (`fillTail`, `encode`, `publish`, `deliver`).
These used to be marked by a comment, "called under the lock", that the tests and
the thread sanitizer held; the compiler holds it now.

### The wait

`waitPast` is the one place a task lets the lock go and takes it back, and it does
so through aegis's `Condition`:

```zig
while (values.atMost(guard.value().seq, cursor) and guard.value().nudges == nudged) {
    self.changed.wait(io, &guard, .none) catch ...;
}
```

`wait` registers the waiter, releases the guard's lock, parks, and returns with the
lock held again on every path, a cancellation included. A borrow of the state does
not survive the call, which is why the loop reads `guard.value()` again after it.
An append or a nudge broadcasts under the lock, after it has published what the
reader is waiting for, so a reader that has checked and not yet parked cannot be
missed: it registers before it lets the lock go.

This replaced a futex word, a waiter count and a count of wakes that the package
kept for itself, written when Zig 0.16's `Io.Condition` lost a cancel that landed
in the same instant as a broadcast. The condition aegis ships looks for a pending
cancellation before it parks and after it wakes, and forwards a signal it was
given if it is canceled, which is the contract that code was written to have;
`a reader stopped as a record arrives is stopped` runs three thousand rounds of
exactly that race against it. Its waiter registry is unlimited here (`changed` is
made with the largest limit): a waiter is a caller's stack frame, so the callers
bound it, and `waitPast` has no error to report a limit with.

An append that nobody waits on costs the condition's own lock taken and released,
and no system call; the suite counts the `Io`'s futex calls through shakedown's
`FaultIo` to hold that, in place of the counters the journal used to keep for it.

### What takes the lock for no state

`openedWith` and `Tailer.cursor` read values the lock does not protect (the options
are fixed at open; a tailer's committed cursor moves only under its own `commit`,
which holds the lock). They take it anyway: an observation of the journal waits its
turn and is canceled there like every other call, and the tests hold the lock to
prove that.

## What was left out, and why

- **`own.Owned` for an encoded record.** A `Built` record's arena moves from a
  local to the tail array, whose elements are moved by `removePrefix`, or is
  released after the write. Owned binds to an address and checks in Debug only; the
  `held` flag is the same discipline, and in every build.
- **`bounded.Limit`.** It takes a raw representation, where every limit here is
  already `Bytes` or `Records`.
- **`handle` and `err`.** No pool or slot map is kept, and errors are named Zig
  sets that carry no context beyond their name.
