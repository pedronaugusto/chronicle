package main

import (
	"encoding/json"
	"fmt"
	"os"
	"strconv"
	"time"

	"github.com/tidwall/wal"
)

const recordBytes = 200

type record struct {
	Value uint64 `json:"value"`
}

func fail(err error) {
	if err != nil {
		panic(err)
	}
}

func load(path string, count int) []byte {
	data, err := os.ReadFile(path)
	fail(err)
	need := count * recordBytes
	if count <= 0 || len(data) < need {
		panic("input is shorter than requested count")
	}
	return data[:need]
}

func line(data []byte, i int) []byte {
	start := i * recordBytes
	return data[start : start+recordBytes-1]
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

func reset(path string) {
	fail(os.RemoveAll(path))
}

func printRate(workload, metric, unit string, value float64) {
	fmt.Printf("tidwall-wal\t%s\t%s\t%.6f\t%s\n", workload, metric, value, unit)
}

func appendRecords(workload, input, path string, count int, noSync, batched bool) {
	data := load(input, count)
	reset(path)
	log, err := wal.Open(path, options(noSync))
	fail(err)
	start := time.Now()
	if batched {
		batch := new(wal.Batch)
		for i := 0; i < count; i++ {
			batch.Write(uint64(i+1), line(data, i))
			if (i+1)%100 == 0 {
				fail(log.WriteBatch(batch))
			}
		}
		if count%100 != 0 {
			fail(log.WriteBatch(batch))
		}
	} else {
		for i := 0; i < count; i++ {
			fail(log.Write(uint64(i+1), line(data, i)))
		}
	}
	elapsed := time.Since(start).Seconds()
	fail(log.Close())
	printRate(workload, "records_per_second", "records/s", float64(count)/elapsed)
	if workload == "append_no_fsync" {
		printRate(workload, "megabytes_per_second", "MB/s", float64(len(data))/1e6/elapsed)
	}
}

func prepare(input, path string, count int) {
	data := load(input, count)
	reset(path)
	log, err := wal.Open(path, options(true))
	fail(err)
	batch := new(wal.Batch)
	for i := 0; i < count; i++ {
		batch.Write(uint64(i+1), line(data, i))
		if (i+1)%1000 == 0 {
			fail(log.WriteBatch(batch))
		}
	}
	if count%1000 != 0 {
		fail(log.WriteBatch(batch))
	}
	fail(log.Close())
}

func replay(path string, count, from, repetitions int, workload string) {
	log, err := wal.Open(path, options(true))
	fail(err)
	var elapsed time.Duration
	for repetition := 0; repetition < repetitions; repetition++ {
		start := time.Now()
		var sum uint64
		for i := from; i <= count; i++ {
			bytes, readErr := log.Read(uint64(i))
			fail(readErr)
			var value record
			fail(json.Unmarshal(bytes, &value))
			sum += value.Value
		}
		elapsed += time.Since(start)
		if sum != uint64(count-from+1) {
			panic("fold mismatch")
		}
	}
	fail(log.Close())
	if workload == "replay_all" {
		printRate(workload, "records_per_second", "records/s", float64(count*repetitions)/elapsed.Seconds())
	} else {
		printRate(workload, "elapsed", "ms", float64(elapsed.Nanoseconds())/1e6/float64(repetitions))
	}
}

func reopen(path string, repetitions int) {
	var elapsed time.Duration
	for repetition := 0; repetition < repetitions; repetition++ {
		start := time.Now()
		log, err := wal.Open(path, options(true))
		fail(err)
		last, err := log.LastIndex()
		fail(err)
		elapsed += time.Since(start)
		if last == 0 {
			panic("empty log")
		}
		fail(log.Close())
	}
	printRate("clean_reopen", "elapsed", "ms", float64(elapsed.Nanoseconds())/1e6/float64(repetitions))
}

func main() {
	if len(os.Args) < 5 {
		panic("usage: tidwall-bench WORKLOAD INPUT DIR COUNT [FROM]")
	}
	workload, input, path := os.Args[1], os.Args[2], os.Args[3]
	count, err := strconv.Atoi(os.Args[4])
	fail(err)
	switch workload {
	case "prepare":
		prepare(input, path, count)
	case "append_no_fsync":
		appendRecords(workload, input, path, count, true, false)
	case "append_fsync":
		appendRecords(workload, input, path, count, false, false)
	case "group_commit":
		appendRecords(workload, input, path, count, false, true)
	case "replay_all":
		replay(path, count, 1, 1, workload)
	case "replay_from_n":
		from, parseErr := strconv.Atoi(os.Args[5])
		fail(parseErr)
		repetitions := 1
		if len(os.Args) > 6 {
			repetitions, parseErr = strconv.Atoi(os.Args[6])
			fail(parseErr)
		}
		replay(path, count, from, repetitions, workload)
	case "clean_reopen":
		repetitions := 1
		if len(os.Args) > 5 {
			repetitions, err = strconv.Atoi(os.Args[5])
			fail(err)
		}
		reopen(path, repetitions)
	default:
		panic("unknown workload")
	}
}
