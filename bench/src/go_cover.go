// The chronicle operations Go has: the CRC32C (hash/crc32, Castagnoli) and,
// through tidwall/wal, reads by index, deferred writes made durable by one
// Sync, and front/back truncation. Rows and checksums are named as
// chronicle's are, so the harness compares them.
//
//	go-cover MODE [DIR] [INPUT]
package main

import (
	"encoding/json"
	"fmt"
	"hash/crc32"
	"os"
	"path/filepath"
	"time"

	"github.com/tidwall/wal"
)

func smoke() bool { return os.Getenv("BENCH_SMOKE") == "1" }
func count(full int) int {
	if smoke() {
		return 1
	}
	return full
}
func now() time.Time {
	if smoke() {
		return time.Time{}
	}
	return time.Now()
}
func since(t time.Time) time.Duration {
	if smoke() {
		return time.Nanosecond
	}
	return time.Since(t)
}
func must(err error) {
	if err != nil {
		panic(err)
	}
}
func row(side, work, metric string, value float64, unit string) {
	fmt.Printf("%s\t%s\t%s\t%.6f\t%s\n", side, work, metric, value, unit)
}
func check(side, work, metric string, value uint64) {
	fmt.Printf("%s\t%s\t%s\t%d\tchecksum\n", side, work, metric, value)
}
func rate(side, work string, items int, elapsed time.Duration) {
	s := elapsed.Seconds()
	row(side, work, "items", float64(items)/s, "items/s")
	row(side, work, "per_item", s*1e9/float64(items), "ns")
}

func checksums() {
	total := 256 << 20
	if smoke() {
		total = 64 * 1024
	}
	bytes := make([]byte, 64*1024)
	for i := range bytes {
		bytes[i] = byte(i*131 + 7)
	}
	table := crc32.MakeTable(crc32.Castagnoli)
	for _, size := range []struct {
		n    int
		work string
	}{{64, "checksum-64"}, {1024, "checksum-1k"}, {64 * 1024, "checksum-64k"}} {
		var sum uint64
		rounds := total / size.n
		start := now()
		for i := 0; i < rounds; i++ {
			from := (i * 64) % (len(bytes) - size.n + 1)
			sum += uint64(crc32.Checksum(bytes[from:from+size.n], table))
		}
		elapsed := since(start)
		row("go-hash-crc32", size.work, "bytes", float64(rounds*size.n)/elapsed.Seconds()/1e6, "MB/s")
		check("go-hash-crc32", size.work, "sum", sum)
	}
}

func options(noSync bool) *wal.Options {
	opts := *wal.DefaultOptions
	opts.NoSync = noSync
	opts.SegmentSize = 8 * 1024 * 1024
	opts.LogFormat = wal.Binary
	opts.NoCopy = true
	opts.AllowEmpty = true
	return &opts
}

// cursors draws what chronicle's seek draws: an LCG, high bits.
type cursors struct{ state uint64 }

func (c *cursors) next(below uint64) uint64 {
	c.state = c.state*6364136223846793005 + 1442695040888963407
	return (c.state >> 33) % below
}

// seek reads one record by index and decodes it, at the cursors chronicle
// replays from.
func seek(dir string) {
	log, err := wal.Open(dir, options(true))
	must(err)
	defer log.Close()
	last, err := log.LastIndex()
	must(err)
	rounds := count(2_000)
	c := cursors{state: 0x2545F4914F6CDD1D}
	var sum uint64
	start := now()
	for i := 0; i < rounds; i++ {
		index := c.next(last) + 1
		data, err := log.Read(index)
		must(err)
		var record struct {
			Value   uint64 `json:"value"`
			Padding string `json:"padding"`
		}
		must(json.Unmarshal(data, &record))
		sum += index
	}
	rate("tidwall-wal", "seek", rounds, since(start))
	check("tidwall-wal", "seek", "sum", sum)
}

func record(i int) []byte {
	return []byte(fmt.Sprintf(`{"value":1,"padding":"%s"}`, padding))
}

var padding = func() string {
	b := make([]byte, 172)
	for i := range b {
		b[i] = 'x'
	}
	return string(b)
}()

// deferred: writes with no sync, then the last one and one Sync, which
// makes every write before it durable.
func deferred(dir string) {
	n := 10_000
	if smoke() {
		n = 2
	}
	must(os.RemoveAll(dir))
	log, err := wal.Open(dir, options(true))
	must(err)
	start := now()
	for i := 1; i <= n; i++ {
		must(log.Write(uint64(i), record(i)))
	}
	must(log.Sync())
	elapsed := since(start)
	last, err := log.LastIndex()
	must(err)
	must(log.Close())
	rate("tidwall-wal", "append-deferred", n, elapsed)
	check("tidwall-wal", "append-deferred", "last", last)
}

// retention: a fresh 200,000-record log each, filled without syncs, then
// TruncateFront (chronicle's compact) or TruncateBack (truncateAfter) with
// syncs on.
func retention(dir string) {
	n := 200_000
	if smoke() {
		n = 20
	}
	for _, op := range []string{"compact", "truncate-after"} {
		path := filepath.Join(dir, op)
		must(os.RemoveAll(path))
		log, err := wal.Open(path, options(true))
		must(err)
		batch := new(wal.Batch)
		for i := 1; i <= n; i++ {
			batch.Write(uint64(i), record(i))
			if i%1000 == 0 || i == n {
				must(log.WriteBatch(batch))
			}
		}
		must(log.Close())
		log, err = wal.Open(path, options(false))
		must(err)
		start := now()
		if op == "compact" {
			must(log.TruncateFront(uint64(n/2 + 1)))
		} else {
			must(log.TruncateBack(uint64(n * 3 / 4)))
		}
		elapsed := since(start)
		first, err := log.FirstIndex()
		must(err)
		last, err := log.LastIndex()
		must(err)
		must(log.Close())
		row("tidwall-wal", op, "elapsed", float64(elapsed.Nanoseconds())/1e6, "ms")
		check("tidwall-wal", op, "last", last)
		check("tidwall-wal", op, "oldest", first)
	}
}

func main() {
	if len(os.Args) < 2 {
		panic("usage: go-cover MODE [DIR]")
	}
	switch os.Args[1] {
	case "checksum":
		checksums()
	case "seek":
		seek(os.Args[2])
	case "deferred":
		deferred(os.Args[2])
	case "retention":
		retention(os.Args[2])
	default:
		panic("unknown mode")
	}
}
