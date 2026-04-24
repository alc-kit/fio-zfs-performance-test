# fio-zfs-performance-test

An fio-based test framework for pushing a ZFS-on-LUKS pool to its edges and
finding the cliffs, without introducing any ZFS tuning that the target Proxmox
installation would not itself apply.

Target host:

- Proxmox VE 9.1, kernel 6.17, OpenZFS 2.4
- 768 GiB RAM
- 6× 14 TB NVMe, LUKS-encrypted, in a single RAID10 zpool named `data`
  (three 2-way mirror vdevs, `ashift=12`)
- Proxmox `zfspool` storage with stock defaults: `sparse=1`, `blocksize` unset
  so zvols get `volblocksize=16K` (PVE 9 default)
- No autotrim, no manually tuned ZFS properties anywhere

## Design rule: stock Proxmox, measured honestly

The framework never sets ZFS properties that Proxmox itself does not set in
normal operation. Tests are organised into three buckets so the distinction is
always explicit:

1. **Production-representative** (`jobs/workloads/`, `jobs/baseline/`) —
   runs on untouched datasets and on a zvol with stock Proxmox defaults. These
   numbers describe what a real VM on this pool will actually experience.
2. **Diagnostic** (`jobs/zfs-diagnostic/`) — runs on datasets that have exactly
   one property deliberately set to a non-default value (e.g. `recordsize=16K`,
   `sync=always`). Used to isolate and explain the effect of a single property.
   Never a candidate production setting.
3. **Stress & scaling** (`jobs/endurance/`, `jobs/scaling/`, `jobs/ioengine-matrix/`)
   — long-running or parameter-sweep jobs that characterise how the stock pool
   behaves under pressure or alternate access modes.

## Layout

```
bin/
  prepare-datasets.sh   create datasets (production-representative + diagnostic)
  prepare-zvols.sh      create the production-representative zvol (PVE 9 defaults)
  run-suite.sh          run a suite or one .fio with env snapshot + monitors
  monitor.sh            background iostat / zpool iostat / arcstat / vmstat / mpstat
  collect-env.sh        one-shot snapshot of system + ZFS + LUKS + NVMe state
  cleanup.sh            destroy all test datasets and the zvol (confirmation-gated)
lib/common.sh           shared bash + env defaults
jobs/
  _global.fio           shared prelude (prepended to every job by run-suite.sh)
  baseline/             seq/rand, read/write, small/large — sanity floor on default dataset
  zfs-diagnostic/       isolated property tests — DIAGNOSTIC / INFORMATIONAL only
  workloads/            production-representative jobs:
                          - sqlserver-zvol.fio                 ← primary SQL Server test
                          - sqlserver-zvol-checkpoint-storm.fio
                          - sqlserver-sim.fio (dataset variant, comparison only)
                          - sqlserver-checkpoint-storm.fio (dataset variant)
                          - oltp-16k.fio, vm-mixed.fio, backup-ingest.fio, metadata-heavy.fio
  endurance/            multi-hour sustained, fragmentation, pool-fill cliff
  scaling/              queue-depth and numjobs sweeps
  ioengine-matrix/      sync / psync / posixaio / libaio / io_uring side-by-side
docs/
  sqlserver-comparison.md   fio-on-host vs SQL-Server-in-VM, and the zvol variant
  interpretation.md         how to read the results
results/<timestamp>/    per-run output (gitignored)
```

## Prerequisites

**Required** — `bin/monitor.sh` aborts the run if any of these is missing:
- `fio` 3.x
- OpenZFS ≥ 2.2 (this host runs 2.4): `zfs`, `zpool`
- `vmstat` (procps — preinstalled on every Debian/PVE)
- `cryptsetup`, `lsblk`

**Required for full per-device / per-CPU monitoring** — the run will *complete*
without these, but the resulting data set is materially less useful for
diagnosing per-NVMe imbalance or LUKS-CPU pinning. `MONITORS_SUMMARY.txt`
clearly logs that these were skipped.
- `iostat` (sysstat)
- `mpstat` (sysstat)

**Optional** — enriches the env snapshot:
- `arcstat` (zfsutils-linux on most distros) — pretty ARC stats; framework
  falls back to a raw `/proc/spl/kstat/zfs/arcstats` dump if missing
- `arc_summary` — text ARC summary
- `nvme-cli` — NVMe model/serial in env snapshot

**Debian/PVE one-liner — install everything the framework can use:**
```bash
apt install fio sysstat zfsutils-linux nvme-cli cryptsetup procps
```

Run all bin/ scripts as root — they create/destroy datasets and drop caches.

## Quickstart

```bash
export ZFS_POOL=data
sudo -E bin/prepare-datasets.sh
sudo -E bin/prepare-zvols.sh
sudo -E bin/run-suite.sh baseline
sudo -E bin/run-suite.sh workloads
sudo -E bin/run-suite.sh zfs-diagnostic
sudo -E bin/run-suite.sh ioengine-matrix
```

Run the single production-representative SQL Server test:
```bash
sudo -E bin/run-suite.sh jobs/workloads/sqlserver-zvol.fio
```

Run everything:
```bash
sudo -E bin/run-suite.sh -a
```

Tear it all down (datasets + zvol):
```bash
sudo -E bin/cleanup.sh
```

## Environment variables

Defaults live in `lib/common.sh`. Override before running.

| Var              | Default              | Meaning |
|------------------|----------------------|---------|
| `ZFS_POOL`       | (required)           | Pool name, e.g. `data` |
| `TEST_ROOT`      | `$ZFS_POOL/fio-test` | Parent dataset for all test datasets |
| `TEST_MOUNT`     | `/$TEST_ROOT`        | Expected mountpoint |
| `ZVOL_NAME`      | `fio-test-vol`       | Zvol name (full path `$ZFS_POOL/$ZVOL_NAME`) |
| `ZVOL_SIZE`      | `500G`               | Sparse zvol size |
| `ZVOL_VOLBLOCKSIZE` | `16K`             | Zvol block size (PVE 9 default — do not change in production-representative runs) |
| `RESULTS_DIR`    | `./results`          | Output root |
| `FIO_IOENGINE`   | `io_uring`           | Default ioengine |
| `FIO_RUNTIME`    | `120` seconds        | Runtime for time-based jobs |
| `FIO_SIZE`       | `100G`               | Working-set size |
| `FIO_NUMJOBS`    | `8`                  | Default thread count |
| `FIO_IODEPTH`    | `32`                 | Default per-thread QD |
| `FIO_RAMP_TIME`  | `10` seconds         | Warm-up excluded from stats |
| `TEST_QUOTA`     | `4T`                 | Quota on `$TEST_ROOT`, safety cap |
| `ASSUME_YES`     | `0`                  | Skip confirmation prompts |

## Safety rails

- Dataset tree lives under `$TEST_ROOT` with a 4 TiB quota on the parent so
  runaway jobs cannot fill the pool. The endurance child dataset is capped
  tighter (1 TiB).
- The zvol is sparse, so it allocates nothing until tests write to it.
- `cleanup.sh` requires confirmation; `ASSUME_YES=1` overrides.
- `prepare-*.sh` scripts are idempotent.
- `run-suite.sh` snapshots `zpool list -v` and `zfs list` before and after each
  run for pool-level deltas.
- VM 109 (unrelated replica zvols on this pool) is not touched by any script;
  see `memory/pve9_stack_facts.md`.

## What gets captured per run

For each job, `run-suite.sh` creates `results/<timestamp>-<suite>-<job>/`:

- `effective.fio` — exact job file fio ran (global prelude + job)
- `fio.json`, `fio.log` — fio output (json+ + human-readable)
- `bw.*.log`, `iops.*.log`, `lat.*.log` — per-second time series
- `env/` — system, zfs, zfs-tunables, storage, fio version snapshots
- `monitor/` — `zpool-iostat.log`, `iostat.log`, `arcstat.log`, `vmstat.log`, `mpstat.log`
- `zpool-before/after.txt`, `zfs-before/after.txt` — pool / dataset deltas

## Next steps after a run

- `docs/interpretation.md` — what to look at first; rough expected numbers
- `docs/sqlserver-comparison.md` — how these numbers map to a real SQL Server VM
