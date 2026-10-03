"""Every public operation: the journal, follow, raw and counted-work jobs and the rest."""
import shutil

PACKAGE = 'chronicle'
COMPARISONS = ['Go tidwall/wal v1.2.1', 'Rust OkayWAL 0.3.1', 'plain Zig files (strong and weak sync)',
               'CRC32C: Go hash/crc32 (Castagnoli), Rust crc32c 0.6.8, Zig std Crc32Iscsi',
               'chronicle open with verify = .full beside OkayWAL recovery (both read every record)',
               'backup: a byte copy with the same syncs (Zig std files)']
UNAVAILABLE = [
    'OkayWAL: no no-sync or explicit batching API (append_no_fsync, group_commit)',
    'before: copySince is new since the before pin (waitPast handed back the records then)',
    'verify, seq-at, subscribe-from, refresh, wait-past, tailer, snapshot, close: tidwall/wal and OkayWAL have no '
    'equivalent (no record checksums to verify in tidwall, no time index, no subscriptions, no in-process wait, '
    'no named cursors, no snapshot beside the log)',
    'seek, deferred, compact, truncate-after in OkayWAL: no read by entry id without a recovery scan, no explicit sync, '
    'its checkpoint is not a cut at a sequence',
    'drop-before in tidwall/wal: TruncateFront always rewrites the segment it cuts (that is compact)',
]


def agree(workload):
    """Every `checksum` row must match across the sides that print it."""
    seen = {}
    def validate(side, rows):
        found = [r for r in rows if r['unit'] == 'checksum']
        if not found:
            raise RuntimeError(f'{workload}/{side}: no checksum rows')
        for r in found:
            key = (r['workload'], r['metric'])
            first = seen.setdefault(key, (side, r['value']))
            if first[1] != r['value']:
                raise RuntimeError(f'{workload}/{side}: {key[0]} {key[1]} differs from {first[0]}')
    return validate


def run(p, bins):
    print('Preparing existing same-job tools' if p.preparing else 'Using prepared same-job tools', flush=True)
    p.setup_command([p.tool('cargo'), 'build', '-j1', '--release', '--locked'])
    tidwall = p.scratch / 'tidwall-bench'
    p.setup_command([p.tool('go'), 'build', '-p=1', '-mod=readonly', '-trimpath', '-ldflags=-s -w',
               '-o', tidwall, './src/tidwall_bench.go'])
    count, sync_count, from_seq, raw_count, wakes = (1, 1, 1, 1, 1) if p.smoke else (1_000_000, 10_000, 900_000, 200_000, 10_000)
    input_path, corpus = p.scratch / 'records.jsonl', p.scratch / 'raw-events.jsonl'
    p.setup_command([p.tool('python'), 'src/generate_input.py', input_path, count])
    p.setup_command([p.tool('python'), 'src/generate_input.py', corpus, 1 if p.smoke else 571])
    p.prepared.require(input_path)
    p.prepared.require(corpus)
    tools = [('before', bins['before'] / 'chronicle-bench'),
             ('after', bins['after'] / 'chronicle-bench'), ('tidwall', tidwall),
             ('OkayWAL', p.env['CARGO_TARGET_DIR'] + '/release/okaywal-bench'),
             ('plain', bins['after'] / 'plain-zig-bench')]
    data = {}
    for side, exe in tools:
        data[side] = p.scratch / f'{side}-data'
        p.setup_command([exe, 'prepare', input_path, data[side], count])
        p.prepared.require(data[side])
    for mode in ('append_no_fsync', 'append_fsync', 'group_commit', 'replay_all', 'replay_from_n', 'clean_reopen'):
        sides = []
        for side, exe in tools:
            n = sync_count if mode == 'append_fsync' else count
            path = data[side] if mode.startswith('replay') or mode == 'clean_reopen' else p.scratch / f'{side}-{mode}'
            args = [exe, mode, input_path, path, n]
            if mode == 'replay_from_n':
                # Retain tool-specific repetitions, normalizing each reported value.
                reps = 1 if p.smoke else {'before': 5, 'after': 5, 'tidwall': 5, 'OkayWAL': 1, 'plain': 10}[side]
                args += [from_seq, reps]
            elif mode == 'clean_reopen':
                reps = 1 if p.smoke else {'before': 200, 'after': 200, 'tidwall': 100, 'OkayWAL': 1, 'plain': 20000}[side]
                args += [reps]
            sides.append((side, args))
        if mode == 'clean_reopen':
            # The same work as OkayWAL's open: every record read and checked.
            sides += [(f'{side}-verify-full', [bins[side] / 'cover-bench', 'reopen-full', data[side], 1 if p.smoke else 5])
                      for side in ('before', 'after')]
        if mode == 'append_fsync':
            sides.append(('plain-weak-sync', [bins['after'] / 'plain-zig-bench', 'append_fsync_weak',
                                            input_path, p.scratch / 'plain-weak-sync', sync_count]))
        p.group(mode, sides)
    for mode in ('follow_replay', 'follow_resume', 'follow_rearm'):
        p.group(mode, [(side, [exe, mode, input_path, p.scratch / f'{side}-{mode}', count, wakes])
                       for side, exe in tools[:2]])
    for side, exe in tools[:2]:
        p.setup_command([exe, 'raw_prepare', corpus, p.scratch / f'{side}-raw-data', raw_count])
        p.prepared.require(p.scratch / f'{side}-raw-data')
    for mode in ('raw_append', 'raw_replay_all'):
        p.group(mode, [(side, [exe, mode, corpus,
                              p.scratch / f'{side}-raw-data' if mode == 'raw_replay_all' else p.scratch / f'{side}-raw-append',
                              raw_count]) for side, exe in tools[:2]])
    p.group('counted-work', [(side, [bins[side] / 'work-bench', p.scratch / f'{side}-counted-work'])
                             for side in ('before', 'after')], parser='work')

    # The rest of the public operations.
    go_cover = p.scratch / 'go-cover'
    p.setup_command([p.tool('go'), 'build', '-p=1', '-mod=readonly', '-trimpath', '-ldflags=-s -w',
                     '-o', go_cover, './src/go_cover.go'])
    p.prepared.require(go_cover)
    crc = p.env['CARGO_TARGET_DIR'] + '/release/crc-bench'
    cover = {side: bins[side] / 'cover-bench' for side in ('before', 'after')}

    def ours(mode, *args, before=True):
        return [(side, [cover[side], mode, *[a(side) if callable(a) else a for a in args]])
                for side in (('before', 'after') if before else ('after',))]
    def fresh(name):
        return lambda side: p.scratch / f'{side}-{name}'
    def clear(name):
        def prepare(side):
            shutil.rmtree(p.scratch / f'{side}-{name}', ignore_errors=True)
        return prepare
    own_data = lambda side: data[side]

    p.group('checksum', ours('checksum') + [('zig-std-Crc32Iscsi', [cover['after'], 'checksum-std']),
                                            ('go-hash-crc32', [go_cover, 'checksum']), ('rust-crc32c', [crc])],
            validate=agree('checksum'))
    p.group('verify', ours('verify', own_data), validate=agree('verify'))
    p.group('seek', ours('seek', own_data) + [('tidwall', [go_cover, 'seek', data['tidwall']])], validate=agree('seek'))
    p.group('seq-at', ours('seq-at', own_data), validate=agree('seq-at'))
    p.group('subscribe-from', ours('subscribe-from', own_data), validate=agree('subscribe-from'))
    for job, mode, before in (('copy-since', 'copy-since', False), ('refresh', 'refresh', True),
                              ('wait-past', 'wait-past', True), ('tailer', 'tailer', True),
                              ('snapshot', 'snapshot', True), ('close', 'close', True)):
        p.group(job, ours(mode, fresh(job), before=before), prepare=clear(job),
                validate=None if job == 'close' else agree(job))
    p.group('append-deferred', ours('deferred', fresh('deferred')) + [('tidwall', [go_cover, 'deferred', fresh('deferred')('tidwall')])],
            prepare=clear('deferred'), validate=agree('append-deferred'))
    def retention_dir(side):
        directory = p.scratch / f'{side}-retention'
        shutil.rmtree(directory, ignore_errors=True)
        directory.mkdir(parents=True)
    p.group('retention', ours('retention', fresh('retention')) + [('tidwall', [go_cover, 'retention', fresh('retention')('tidwall')])],
            prepare=retention_dir, validate=agree('retention'))
    p.group('backup', ours('backup', own_data, fresh('backup')) +
            [('std-copy', [cover['after'], 'backup-copy', data['after'], fresh('backup')('std-copy')])],
            validate=agree('backup'))
