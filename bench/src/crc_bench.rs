//! CRC32C with the crc32c crate (the one OkayWAL checks its chunks with),
//! over the buffers chronicle's checksum job uses.
use std::time::Instant;

fn smoke() -> bool { std::env::var("BENCH_SMOKE").as_deref() == Ok("1") }

fn main() {
    let total: usize = if smoke() { 64 * 1024 } else { 256 << 20 };
    let bytes: Vec<u8> = (0..64 * 1024usize).map(|i| (i.wrapping_mul(131).wrapping_add(7)) as u8).collect();
    for (n, work) in [(64usize, "checksum-64"), (1024, "checksum-1k"), (64 * 1024, "checksum-64k")] {
        let rounds = total / n;
        let mut sum = 0u64;
        let start = if smoke() { None } else { Some(Instant::now()) };
        for i in 0..rounds {
            let from = (i * 64) % (bytes.len() - n + 1);
            sum += u64::from(crc32c::crc32c(&bytes[from..from + n]));
        }
        let secs = start.map_or(1e-9, |s| s.elapsed().as_secs_f64());
        println!("rust-crc32c\t{work}\tbytes\t{:.6}\tMB/s", (rounds * n) as f64 / secs / 1e6);
        println!("rust-crc32c\t{work}\tsum\t{sum}\tchecksum");
    }
}
