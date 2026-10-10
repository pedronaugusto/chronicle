# Journal invariants

- The public journal, batches, replay walks, tailers and reader lists are opaque
  owners at stable allocated addresses. Each is released once, after its users
  stop. The implementation's lock, an aegis `BlockingGuarded` over one `State`,
  protects the journal sequence, tail, sinks, persistence failure flag, nudge
  count, log and the buffers records are written through, and is reachable only
  through a guard. `waitPast` waits on an aegis `Condition` associated with it.
- Records are newline-delimited JSON. Sequence numbers are positive signed-64
  integers, advance without gaps, and link each CRC32C checksum to the preceding
  record or segment root. Atomic batch bounds contain the record's sequence and
  remain within one segment. Envelope spans stay within the covered bytes.
- Sequence numbers (`Seq`), byte counts (`Bytes`) and record counts (`Records`) are
  distinct aegis types; arithmetic on them is checked in every build, and a number
  from outside the process is range-checked where it enters (a segment name from 1
  to `maxInt(i64)`, an index header's record count that must end at or below it).
- A segment has a positive base and `last_seq >= base_seq - 1`. Its header lies
  before its records. Known timestamp ranges contain the last timestamp; an
  unknown range is explicitly empty. Segments are ordered by increasing base.
- A writable log has an active segment and at least one segment. Read-only logs
  have no active writer. Appending one complete record advances the active
  segment's sequence, byte count and chain tip together. Index errors cannot
  change the record durability promise: indexes are rebuildable caches.
- Index headers contain 96 bytes and entries contain 24 bytes, with fixed
  little-endian integer fields and CRC32C checks. An index whose header does not
  describe its segment, including a record count no record number can end, is stale
  and rebuilt. Entry offsets refer to complete
  record starts; index length is header length plus whole entries. Writers and
  readers agree on field offsets and widths.
- Scan base and limit slices have equal length and fit their retained storage;
  the current segment index never exceeds their length. Readers hand out one
  bounded line at a time, as bytes nothing has parsed, and validate continuity
  before handing on a record.
- A retained tail is ordered by sequence; its live window fits its allocation.
  A record and the arena owning its bytes enter and leave it together. Replay
  positions carry a positive sequence and an increasing byte range, checked
  against the source record before reuse.
- Snapshot and cursor documents carry `document_format`. Cursor names exclude
  path separators and reserved journal filenames. Snapshots cannot get ahead of
  the journal sequence. Tailer cursor updates are explicit and may move backwards.
- The allocating encoding writer installs only its own vtable, and records
  allocation failures without confusing them with a stringify hook's refusal.
- Best-effort destruction and failed-operation rollback release resources even
  when flushing or removing files fails. Durable operations report record-file
  failures; optional cache and copy-optimization failures are logged explicitly.
