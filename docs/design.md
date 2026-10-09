# Design

What chronicle keeps apart, what it checks and where it reads a number raw. The
promises a user relies on are in the README; the invariants the tests hold are
in `ci/invariants.md`.

## Three kinds of number

A journal talks about where a record sits in the sequence, how many bytes
something is, and how many records there are. All three are `u64`s on the disk
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
- A timestamp, `at`. chronicle stores what it is handed and never reads a clock;
  a caller may pass anything, and the index's bisection treats it as ordered only
  when it is.
- Checksums and schema versions, `u32`s. They are compared with others of their
  own kind and with nothing else.
- Counters that exist for the tests (`index_opens`, `segment_scans`, ...), the
  count of segments, and the sizes of in-memory buffers once they are lengths:
  a slice's length is a `usize`.

## Bytes off a disk

Everything a scan returns is an `envelope.Unparsed`
(`aegis.input.Untrusted([]const u8)`). It cannot be read as a record, a segment
header or a sequence number without handing it to the reader that answers for it,
whose result is a refined value or a named refusal: `parseHeader` for a record's
envelope and checksum, `envelope.members`, `stamp`, `backLink` and `batchOf` for
the parts of one, `parseSegmentHeader` for a file's first line. The places that
use the bytes themselves (copying a record into a compacted segment, keeping a
copy in the tail) say why in a comment.

A header's event span is cut from the line it was read from; handing `eventFrom`
a pair that do not belong together is refused in every build, not only in Debug.

## State that is checked in every build

- `Segment.count` is `span(base_seq, last_seq)` and a segment's last record is
  at most one before its first.
- `continuity.State.accept` refuses a header whose number is zero, above an
  `i64`, or outside its batch.
- `encode` refuses to write a record with such a number: it would be durable
  before anything read it back.
- `Builder.wants` and the log's offsets use checked subtraction, so a record
  that moves backwards in its segment stops the program.

## What was left out, and why

- **`own.Owned` for an encoded record.** A `Built` record's arena moves from a
  local to the tail array, whose elements are moved by `removePrefix`, or is
  released after the write. Owned binds to an address and checks in Debug only; the
  `held` flag is the same discipline, and in every build.
- **`BlockingGuarded` for the journal's state.** One mutex guards a dozen fields
  that three nested owners (a replay, a tailer, the journal itself) and the sinks
  reach, and `waitPast` releases it around a futex wait. Moving the fields behind a
  guard changes ~60 methods for a convention (comments that say "called under the
  lock") that the tests and TSan already hold; it is a candidate for its own batch.
- **`bounded.Limit`.** It takes a raw representation, where every limit here is
  already `Bytes` or `Records`.
- **`handle` and `err`.** No pool or slot map is kept, and errors are named Zig
  sets that carry no context beyond their name.
