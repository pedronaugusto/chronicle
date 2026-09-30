use okaywal::{Configuration, Entry, EntryId, LogManager, ReadChunkResult, RecoveredSegment, Recovery, SegmentReader, WriteAheadLog};
use serde::Deserialize;
use std::{
    fs,
    io,
    sync::{
        atomic::{AtomicU64, AtomicUsize, Ordering},
        Arc,
    },
    thread,
    time::Instant,
};

const RECORD_BYTES: usize = 200;
const PREALLOCATE: u32 = 256 * 1024 * 1024;
const CHECKPOINT_AFTER: u64 = 240 * 1024 * 1024;

#[derive(Deserialize)]
struct JsonRecord {
    value: u64,
}

#[derive(Debug)]
struct Manager {
    from: u64,
    ordinal: u64,
    parse: bool,
    count: Arc<AtomicU64>,
    sum: Arc<AtomicU64>,
}

impl LogManager for Manager {
    fn should_recover_segment(&mut self, _segment: &RecoveredSegment) -> io::Result<Recovery> {
        Ok(Recovery::Recover)
    }

    fn recover(&mut self, entry: &mut Entry<'_>) -> io::Result<()> {
        self.ordinal += 1;
        if !self.parse || self.ordinal < self.from {
            loop {
                match entry.read_chunk()? {
                    ReadChunkResult::Chunk(mut chunk) => {
                        let _ = chunk.read_all()?;
                        if !chunk.check_crc()? {
                            return Err(io::Error::new(io::ErrorKind::InvalidData, "crc mismatch"));
                        }
                    }
                    ReadChunkResult::EndOfEntry => return Ok(()),
                    ReadChunkResult::AbortedEntry => {
                        return Err(io::Error::new(io::ErrorKind::InvalidData, "aborted entry"));
                    }
                }
            }
        }
        loop {
            match entry.read_chunk()? {
                ReadChunkResult::Chunk(mut chunk) => {
                    let bytes = chunk.read_all()?;
                    if !chunk.check_crc()? {
                        return Err(io::Error::new(io::ErrorKind::InvalidData, "crc mismatch"));
                    }
                    let record: JsonRecord = serde_json::from_slice(&bytes)
                        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
                    self.sum.fetch_add(record.value, Ordering::Relaxed);
                    self.count.fetch_add(1, Ordering::Relaxed);
                }
                ReadChunkResult::EndOfEntry => return Ok(()),
                ReadChunkResult::AbortedEntry => {
                    return Err(io::Error::new(io::ErrorKind::InvalidData, "aborted entry"));
                }
            }
        }
    }

    fn checkpoint_to(
        &mut self,
        _last_checkpointed_id: EntryId,
        _entries: &mut SegmentReader,
        _wal: &WriteAheadLog,
    ) -> io::Result<()> {
        Ok(())
    }
}

fn manager(from: u64, parse: bool) -> (Manager, Arc<AtomicU64>, Arc<AtomicU64>) {
    let count = Arc::new(AtomicU64::new(0));
    let sum = Arc::new(AtomicU64::new(0));
    (
        Manager { from, ordinal: 0, parse, count: count.clone(), sum: sum.clone() },
        count,
        sum,
    )
}

fn config(path: &str) -> Configuration {
    Configuration::default_for(path)
        .preallocate_bytes(PREALLOCATE)
        .checkpoint_after_bytes(CHECKPOINT_AFTER)
        .buffer_bytes(64 * 1024)
}

fn append_config(path: &str) -> Configuration {
    Configuration::default_for(path)
        .preallocate_bytes(4 * 1024 * 1024)
        .checkpoint_after_bytes(3 * 1024 * 1024)
        .buffer_bytes(64 * 1024)
}

fn input(path: &str, count: usize) -> io::Result<Vec<u8>> {
    let mut bytes = fs::read(path)?;
    let needed = count.checked_mul(RECORD_BYTES).ok_or_else(|| io::Error::other("count overflow"))?;
    if bytes.len() < needed || count == 0 {
        return Err(io::Error::new(io::ErrorKind::UnexpectedEof, "short input"));
    }
    bytes.truncate(needed);
    Ok(bytes)
}

fn line(bytes: &[u8], index: usize) -> &[u8] {
    let start = index * RECORD_BYTES;
    &bytes[start..start + RECORD_BYTES - 1]
}

fn reset(path: &str) -> io::Result<()> {
    match fs::remove_dir_all(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}

fn print(side: &str, workload: &str, metric: &str, value: f64, unit: &str) {
    println!("{side}\t{workload}\t{metric}\t{value:.6}\t{unit}");
}

fn print_na(workload: &str, metric: &str, unit: &str) {
    println!("okaywal\t{workload}\t{metric}\tn/a\t{unit}");
}

fn prepare(input_path: &str, path: &str, total: usize) -> io::Result<()> {
    let bytes = Arc::new(input(input_path, total)?);
    reset(path)?;
    let (state, _, _) = manager(1, false);
    let log = config(path).open(state)?;
    let next = Arc::new(AtomicUsize::new(0));
    let workers = thread::available_parallelism().map_or(8, usize::from).clamp(4, 32);
    thread::scope(|scope| {
        let mut handles = Vec::new();
        for _ in 0..workers {
            let log = log.clone();
            let bytes = bytes.clone();
            let next = next.clone();
            handles.push(scope.spawn(move || -> io::Result<()> {
                loop {
                    let index = next.fetch_add(1, Ordering::Relaxed);
                    if index >= total {
                        return Ok(());
                    }
                    let mut entry = log.begin_entry()?;
                    entry.write_chunk(line(&bytes, index))?;
                    entry.commit()?;
                }
            }));
        }
        for handle in handles {
            handle.join().map_err(|_| io::Error::other("prepare worker panicked"))??;
        }
        Ok::<(), io::Error>(())
    })?;
    drop(log);
    Ok(())
}

fn append_fsync(input_path: &str, path: &str, total: usize) -> io::Result<()> {
    let bytes = input(input_path, total)?;
    reset(path)?;
    let (state, _, _) = manager(1, false);
    let log = append_config(path).open(state)?;
    let started = Instant::now();
    for index in 0..total {
        let mut entry = log.begin_entry()?;
        entry.write_chunk(line(&bytes, index))?;
        entry.commit()?;
    }
    let elapsed = started.elapsed().as_secs_f64();
    drop(log);
    print("okaywal", "append_fsync", "records_per_second", total as f64 / elapsed, "records/s");
    Ok(())
}

fn replay(path: &str, total: usize, from: usize, repetitions: usize, workload: &str) -> io::Result<()> {
    let mut elapsed = std::time::Duration::ZERO;
    for _ in 0..repetitions {
        let (state, seen, sum) = manager(from as u64, true);
        let started = Instant::now();
        let log = config(path).open(state)?;
        elapsed += started.elapsed();
        let expected = total - from + 1;
        let actual_seen = seen.load(Ordering::Relaxed);
        let actual_sum = sum.load(Ordering::Relaxed);
        if actual_seen != expected as u64 || actual_sum != expected as u64 {
            return Err(io::Error::other(format!(
                "fold mismatch: expected {expected}, saw {actual_seen}, sum {actual_sum}"
            )));
        }
        drop(log);
    }
    if workload == "replay_all" {
        print("okaywal", workload, "records_per_second", (total * repetitions) as f64 / elapsed.as_secs_f64(), "records/s");
    } else {
        print("okaywal", workload, "elapsed", elapsed.as_secs_f64() * 1000.0 / repetitions as f64, "ms");
    }
    Ok(())
}

fn reopen(path: &str, repetitions: usize) -> io::Result<()> {
    let mut elapsed = std::time::Duration::ZERO;
    for _ in 0..repetitions {
        let (state, _, _) = manager(1, false);
        let started = Instant::now();
        let log = config(path).open(state)?;
        elapsed += started.elapsed();
        drop(log);
    }
    print("okaywal", "clean_reopen", "elapsed", elapsed.as_secs_f64() * 1000.0 / repetitions as f64, "ms");
    Ok(())
}

fn main() -> io::Result<()> {
    let args: Vec<String> = std::env::args().collect();
    if args.len() < 5 {
        return Err(io::Error::other("usage: okaywal-bench WORKLOAD INPUT DIR COUNT [FROM]"));
    }
    let workload = &args[1];
    let total: usize = args[4].parse().map_err(|_| io::Error::other("invalid count"))?;
    match workload.as_str() {
        "prepare" => prepare(&args[2], &args[3], total),
        "append_fsync" => append_fsync(&args[2], &args[3], total),
        "replay_all" => replay(&args[3], total, 1, 1, workload),
        "replay_from_n" => {
            let from = args.get(5).ok_or_else(|| io::Error::other("missing from"))?
                .parse().map_err(|_| io::Error::other("invalid from"))?;
            let repetitions = args.get(6).map_or(Ok(1), |text| text.parse().map_err(|_| io::Error::other("invalid repetitions")))?;
            replay(&args[3], total, from, repetitions, workload)
        }
        "clean_reopen" => {
            let repetitions = args.get(5).map_or(Ok(1), |text| text.parse().map_err(|_| io::Error::other("invalid repetitions")))?;
            reopen(&args[3], repetitions)
        }
        "append_no_fsync" => {
            print_na(workload, "records_per_second", "records/s");
            print_na(workload, "megabytes_per_second", "MB/s");
            Ok(())
        }
        "group_commit" => {
            print_na(workload, "records_per_second", "records/s");
            Ok(())
        }
        _ => Err(io::Error::other("unknown workload")),
    }
}
