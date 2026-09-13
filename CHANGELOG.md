# Changelog

Each entry says what the old shape could not express, so a port has the reason
and not only the diff. Versions follow [semantic versioning](https://semver.org);
before 1.0 the minor is the breaking one.

## 0.1.0

First release. `Journal(Event)` over any type `std.json` can write and read
back, with:

- One JSON object per line — `seq`, `at`, `v`, `ev` — read back into records
  that keep both the parsed event and the exact bytes it was stored as, so a
  consumer can forward the durable form without re-encoding and `compact` can
  copy a record it could not have re-serialised.
- The crash cases as named outcomes rather than as behaviour: a sequence that
  continues across restarts, an unterminated final line detected and repaired
  with the dropped byte count reported, `error.NewerSchema` and
  `error.OlderSchema` for drift in either direction, a `migrate` hook and an
  `unknown` arm for the older side, and a persistence failure latched for the
  life of the journal so no reader can see a record the disk does not have.
- Sinks that receive the records already on disk and then every record
  appended, so one fold is built the same way from either.
- Snapshots and compaction, both written to a neighbouring file and renamed
  into place; compaction always keeps the newest record, because a journal
  compacted to empty would start counting from one again.
- Every file operation and the wait primitive through `std.Io`, so the suite
  runs on `std.testing.io` and the package runs on a threaded one.
- Fuzz tests over arbitrary journal and snapshot file contents, because the
  file shapes this package exists to survive are the ones nobody chose.
