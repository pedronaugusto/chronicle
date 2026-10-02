"""The existing journal, follow, raw and counted-work jobs."""
PACKAGE = 'chronicle'
COMPARISONS = ['Go tidwall/wal v1.2.1', 'Rust OkayWAL 0.3.1', 'plain Zig files (strong and weak sync)']


def run(p, bins):
    print('Building existing same-job tools', flush=True)
    p.command([p.tool('cargo'), 'build', '-j1', '--release', '--locked'])
    tidwall = p.scratch / 'tidwall-bench'
    p.command([p.tool('go'), 'build', '-p=1', '-mod=readonly', '-trimpath', '-ldflags=-s -w',
               '-o', tidwall, './src/tidwall_bench.go'])
    count, sync_count, from_seq, raw_count, wakes = (1, 1, 1, 1, 1) if p.smoke else (1_000_000, 10_000, 900_000, 200_000, 10_000)
    input_path, corpus = p.scratch / 'records.jsonl', p.scratch / 'raw-events.jsonl'
    p.command([p.tool('python'), 'src/generate_input.py', input_path, count])
    p.command([p.tool('python'), 'src/generate_input.py', corpus, 1 if p.smoke else 571])
    tools = [('before', bins['before'] / 'chronicle-bench'),
             ('after', bins['after'] / 'chronicle-bench'), ('tidwall', tidwall),
             ('OkayWAL', p.env['CARGO_TARGET_DIR'] + '/release/okaywal-bench'),
             ('plain', bins['after'] / 'plain-zig-bench')]
    data = {}
    for side, exe in tools:
        data[side] = p.scratch / f'{side}-data'
        p.command([exe, 'prepare', input_path, data[side], count])
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
        if mode == 'append_fsync':
            sides.append(('plain-weak-sync', [bins['after'] / 'plain-zig-bench', 'append_fsync_weak',
                                            input_path, p.scratch / 'plain-weak-sync', sync_count]))
        p.group(mode, sides)
    for mode in ('follow_replay', 'follow_resume', 'follow_rearm'):
        p.group(mode, [(side, [exe, mode, input_path, p.scratch / f'{side}-{mode}', count, wakes])
                       for side, exe in tools[:2]])
    for side, exe in tools[:2]:
        p.command([exe, 'raw_prepare', corpus, p.scratch / f'{side}-raw-data', raw_count])
    for mode in ('raw_append', 'raw_replay_all'):
        p.group(mode, [(side, [exe, mode, corpus,
                              p.scratch / f'{side}-raw-data' if mode == 'raw_replay_all' else p.scratch / f'{side}-raw-append',
                              raw_count]) for side, exe in tools[:2]])
    p.group('counted-work', [(side, [bins[side] / 'work-bench', p.scratch / f'{side}-counted-work'])
                             for side in ('before', 'after')], parser='work')
