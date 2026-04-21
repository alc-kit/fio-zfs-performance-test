# Reading the results

Each `results/<timestamp>-<suite>-<job>/` directory contains everything you
need to reason about one fio run. Here is the order to look at files and what
each one tells you.

## 1. fio.json — the summary

Start with `fio.json` (format is `json+`, one object per job). Fields worth
reading first, per job:

- `read.iops_mean` / `write.iops_mean`
- `read.bw_bytes` / `write.bw_bytes`
- `read.clat_ns.percentile.99.000000` (and p99.9)
- `write.clat_ns.percentile.99.000000`
- `read.drop_ios` / `write.drop_ios` — should be zero; non-zero means fio
  missed its target rate (rare for pure fio, but can happen on very slow paths)

Read `fio.log` alongside for the human-readable summary.

## 2. zpool-before.txt vs zpool-after.txt

Diff these. The important deltas:

- `ALLOC` (growth tells you how much data actually hit the pool, after
  compression; compare to fio's `write.io_bytes` to see the compression
  ratio that actually happened).
- `FRAG` (percent). Watch this across the endurance suite — if it climbs and
  doesn't recover, you are seeing real fragmentation building.
- `CAP` (percent). Past 80% this is when ZFS switches metaslab selection and
  write throughput drops.

## 3. monitor/*.log — time series during the run

### monitor/zpool-iostat.log
Per-vdev I/O every second. Use this to check that **both sides of every mirror
are serving reads** during seq-read tests, and that writes are balanced across
the three mirror vdevs during seq-write tests. An imbalanced mirror is a bug
indicator (e.g. a slow disk, a LUKS CPU pinning issue, or ZFS load-balancing
weirdness).

### monitor/iostat.log
Host-level. For each NVMe, look at:
- `%util` — if it's pegged at 100% on only some drives, you have imbalance.
- `await` / `w_await` — rising latency during the run means the device queue
  is saturated.
- `aqu-sz` — average queue depth the device is seeing; useful to compare
  against what fio submitted.

### monitor/arcstat.log
ARC hit ratio, metadata vs data, size. Key thing: during the **arc-warm-pass**
job of `arc-warm-vs-cold.fio`, ratio should be near 100%. If it isn't, your
working set is larger than ARC or something else is evicting it.

### monitor/vmstat.log
`r` (runqueue), `cs` (context switches), `us`/`sy`/`wa` CPU breakdown. If
`sy`+`us` is pegged during writes, you are CPU-bound (most likely LUKS
crypto). If `wa` is high, you are I/O-bound. Both can be true.

### monitor/mpstat.log
Per-CPU utilization. LUKS historically serialized within a single request so
one or two cores would get hot; modern kernels parallelize much better, but
verify. If you see one CPU pegged at 100% during sequential writes while
others idle, that's your ceiling.

## 4. env/

These are snapshots taken *before* the run starts, so they represent the
state under which fio ran. The ones that actually matter for
reproducibility:

- `env/zfs.txt` — dataset properties. Compare across runs to be sure you
  didn't accidentally change recordsize or compression between tests.
- `env/zfs-tunables.txt` — the module parameters (dirty data max, txg
  timeout, arc max). These materially affect write throughput.
- `env/storage.txt` — which NVMe drives are in the pool, LUKS status per
  device, queue scheduler per block device.

## 5. Expected shapes

Rough sanity expectations for this host (768 GiB RAM, 6×14 TB NVMe RAID10):

- **Sequential 1 MiB read, ARC warm:** multiple tens of GiB/s — you are
  reading from RAM.
- **Sequential 1 MiB read, ARC cold or bypassed:** probably 10-20 GiB/s
  aggregate — limited by device read bandwidth and LUKS decrypt.
- **Sequential 1 MiB write, incompressible:** often 4-8 GiB/s — limited by
  LUKS encrypt + per-device write bandwidth + txg flush cadence.
- **Random 4K read, cold, on 128k recordsize:** tens of thousands of IOPS,
  not millions — the 32× read amplification dominates.
- **Random 4K read, warm in ARC:** millions of IOPS — you're reading from DRAM.
- **Random 16K write, sync=always, QD=1:** hundreds to a few thousand IOPS
  per thread. The ZIL round-trip is the wall.
- **Random 4K write async on 128k recordsize:** tens of thousands of IOPS,
  dropping during txg flushes. Compare vs the same test on the rs-4k dataset
  to quantify RMW cost.

If you see numbers wildly different from these, it is much more likely a
configuration issue (wrong dataset, ARC-masked, compression eating zeros)
than a broken pool.

## 6. Comparing runs

Three most useful diffs:

1. **Same job, two datasets** — e.g. `rand-write-4k` on `default` (rs=128k)
   vs on `rs-4k`. Isolates recordsize effect.
2. **Same job, two ioengines** — use the `ioengine-matrix` suite. Isolates
   engine overhead.
3. **Same job, before vs after endurance** — run `rand-write-4k` once cold,
   then run the full endurance suite for several hours, then run
   `rand-write-4k` again. The delta is no-TRIM + fragmentation cost on this
   host.
