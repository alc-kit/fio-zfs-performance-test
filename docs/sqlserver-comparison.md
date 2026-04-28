# fio-on-host vs SQL Server-in-VM: where the numbers diverge

This doc explains what `jobs/workloads/sqlserver-sim.fio` does and does *not*
capture compared to a real SQL Server instance running inside a Proxmox VM on
the same pool. Read this before quoting any fio number as a SQL Server result.

## The I/O path, side by side

**fio, running directly on the host against a ZFS dataset:**
```
fio process
  └── syscall (pread/pwrite/io_uring_enter)
        └── VFS
              └── ZFS (ZPL)
                    └── DMU / ARC / ZIO
                          └── LUKS (dm-crypt)
                                └── NVMe device
```

**SQL Server, inside a Proxmox VM on the same pool:**
```
SQL Server process (in guest)
  └── Windows I/O stack (with FILE_FLAG_WRITE_THROUGH, FILE_FLAG_NO_BUFFERING)
        └── guest virtio-blk/virtio-scsi driver
              └── virtio ring (typically 1-4 queues, ~256 entries each)
                    └── host qemu userspace (iothread, aio=io_uring, cache=none)
                          └── host file on ZFS dataset (or zvol)
                                └── ZFS / ARC / ZIO
                                      └── LUKS
                                            └── NVMe
```

## Every layer the VM adds, and what it changes

### 1. SQL Server buffer pool (enormous)
SQL Server keeps almost all of its data file in RAM. A VM with 64 GiB of memory
will give most of that to the buffer pool (~50-56 GiB). Reads only reach the
disk on a **cold miss** or a first access. In a well-warmed workload the read
rate to the pool is a small fraction of the read rate inside SQL Server.

- **What fio misses:** fio does no application-level caching. Every 8K read
  goes out into the stack. The fio `sql-data` job therefore produces *more*
  read pressure on the pool than SQL Server would produce with the same
  business-level read rate.
- **What to do about it:** interpret fio read numbers as the "pool can do at
  most this much I/O"; the actual SQL Server read rate is capped by
  buffer-pool miss rate, not by fio's throughput.

### 2. Guest page cache and write coalescing
Even with `FILE_FLAG_NO_BUFFERING`, Windows batches some I/O below SQL Server,
and the guest virtio driver further groups submissions into virtio ring
entries. By the time an 8K page arrives at the host, it may have been merged
with neighbors or delayed.

- **What fio misses:** the coalescing effect. fio submits every request
  verbatim.

### 3. virtio queue depth
Proxmox VM disks default to one virtio queue per disk unless you enable
multi-queue. SQL Server in a VM therefore sees a much lower effective queue
depth than fio can drive on the host. An fio `iodepth=32 numjobs=4` test
submits up to 128 in-flight I/Os; the same guest with a single virtio queue
will be capped around the ring size (typically 128-256 but rarely filled).

- **What fio misses:** virtio serialization and the CPU cost in qemu of
  pulling ring entries and turning them into host I/Os.
- **What to do about it:** when you want to match a VM's disruption profile,
  lower `FIO_IODEPTH` and `FIO_NUMJOBS` until the concurrency matches what
  `iostat` inside the guest reports.

### 4. FUA, write-through, and fsync semantics
SQL Server's log writer uses `FILE_FLAG_WRITE_THROUGH`. In qemu with
`cache=none`, that translates to `O_DIRECT | O_DSYNC` on the host file, which
on a ZFS dataset becomes a ZIL commit. On a zvol with default settings it is
similar. In fio we get the same effect by combining `direct=1` with `sync=1`
or `fsync=1`.

- **What fio captures:** the ZIL cost per commit — `sqlserver-sim.fio` uses
  `sync=1` on the log stream exactly for this reason.
- **What fio misses:** the extra hop through qemu for each FUA completion.
  On a busy host this can add tens of microseconds per log write that fio
  will not see.

### 5. Storage format: dataset vs zvol
Proxmox on this host uses `zfspool` storage — every VM disk is a **zvol**.
A real SQL Server VM never sees a dataset; it sees a block device carved out
of `/dev/zvol/data/vm-XXX-disk-N` with `volblocksize=16K` (the PVE 9 default).

The framework covers both paths explicitly:

- **`jobs/workloads/sqlserver-zvol.fio`** and
  **`jobs/workloads/sqlserver-zvol-checkpoint-storm.fio`** — the
  *production-representative* tests. They target a zvol created by
  `bin/prepare-zvols.sh` with `sparse=1` and `volblocksize=16K` and no other
  property customisation. This matches what Proxmox itself sets when it
  creates a VM disk on this pool. **Use these numbers when answering "how
  will a SQL Server VM behave on this pool?".**
- **`jobs/workloads/sqlserver-sim.fio`** and
  **`jobs/workloads/sqlserver-checkpoint-storm.fio`** — the dataset variant.
  Runs against the stock default dataset (128K recordsize, lz4, primarycache=all).
  Kept as a comparison point for the rare Proxmox configuration that stores
  VM disks as qcow2/raw files on a filesystem dataset rather than zvols. Not
  representative of this host.

The zvol code path differs from the dataset (ZPL) path in several ways that
matter for SQL Server: compression happens at `volblocksize` granularity, sync
writes land in-pool ZIL with slightly different logbias handling, and ARC
accounting uses the zvol's block map rather than per-file dnode metadata.
Compare the two suites' outputs to see the gap directly.

### 6. SQL Server checkpointing rhythm
SQL Server batches dirty pages and flushes them in bursts. The
`sqlserver-checkpoint-storm.fio` job tries to recreate that pattern — steady
OLTP + sync log + a delayed burst that collides with the log stream. This is
often where real SQL Server workloads hit the ZFS latency ceiling; the steady
state looks fine and the checkpoint burst exposes the collision.

## Summary: what the fio numbers mean

| fio metric                       | Corresponds to (for SQL Server)                          |
|----------------------------------|----------------------------------------------------------|
| `sql-data` read IOPS             | Upper bound on buffer-pool miss rate the pool can absorb |
| `sql-data` write IOPS            | Upper bound on dirty-page flush rate (lazywriter + checkpoint) |
| `sql-log` bw + p99 latency       | Very close to real log commit cost (close to 1:1)        |
| `sql-tempdb` IOPS                | Upper bound on tempdb allocation churn                   |
| `ioengine-matrix/io-uring` IOPS  | Upper bound you *might* see from a Proxmox VM configured with `aio=io_uring` |
| `ioengine-matrix/libaio` IOPS    | Upper bound for VMs configured with `aio=native`         |
| Checkpoint-storm log p99         | Worst-case commit latency under dirty-burst contention — this is the number to compare against your actual DB's write-latency SLO |

## Closing the gap: in-VM tests (`win/` and `linux-vm/`)

Two parallel in-VM frameworks exist alongside the host one. Together they
make a four-way comparison possible, all on the same physical Proxmox node:

| Layer | Where the I/O is issued | What it adds vs the layer above |
|---|---|---|
| **(1) Host on zvol** (`bin/run-suite.sh jobs/workloads/sqlserver-zvol.fio`) | Linux host process, direct on `/dev/zvol/...` | nothing - the floor; pool's raw zvol code path |
| **(2) Linux VM on ext4** (`linux-vm/bin/run-suite.sh workloads/sqlserver-vm-sim.fio`) | Ubuntu Server VM process, ext4 file on virtio-scsi | qemu virtio-scsi + Linux block layer + ext4 |
| **(3) Windows VM on NTFS** (`win/Run-Suite.ps1 workloads\sqlserver-vm-sim.fio`) | Windows Server 2025 VM process, NTFS file on virtio-scsi | qemu virtio-scsi + Windows IO + NTFS |
| **(4) SQL Server itself** | Inside the VM, but adds: buffer pool, log manager, checkpointer, scheduler waits | not measured by this framework |

The deltas decompose the storage stack:

- **(2) - (1)** = `virtio-scsi + ext4` overhead.
- **(3) - (2)** = `Windows-IO + NTFS - Linux-IO - ext4` overhead. With Linux
  removed as a control, this isolates the OS / filesystem contribution that
  was previously confounded by virtio queue depth and other VM-layer
  variables.
- **(3) - (1)** = full Windows VM stack tax (the cumulative cost a real
  Windows-VM-hosted SQL Server pays vs running the same workload on the
  bare host).

The Windows VM (`win/`) is set up exactly as a real SQL Server install guide
would specify: 64 KiB NTFS allocation units, Defender exclusions for the
test paths, high-performance power plan, NTFS last-access-time disabled.

The Linux VM (`linux-vm/`) is set up with the equivalent Linux-side tunings
that production Linux DB hosts apply: ext4 mounted with `noatime,nodiratime`,
CPU governor set to `performance`, transparent hugepages disabled. fio
uses `ioengine=io_uring` (matching what modern Linux applications and qemu
itself use for their own VM disks).

For all comparisons to be valid, every run must execute on the **same
physical Proxmox node**, otherwise hardware divergence (e.g. Samsung-vs-
Micron NVMe drives across nodes - see findings-2026-04-25.md §6) will
swamp the VM-stack signal we're trying to measure. See `linux-vm/README.md`
and `win/README.md` for the comparison protocols and concrete invocations.
