# Linux-VM fio testing

Bash-based parallel of the host (`bin/`) and Windows-VM (`win/`) frameworks,
intended to run *inside* a Proxmox Ubuntu Server VM whose disks live on the
same ZFS pool. With this in hand, the same SQL Server-shaped workload is
measurable across three layers on the same physical node:

```
host     fio on /dev/zvol/...        (no VM stack at all)
Linux VM fio on ext4 file            (adds: virtio-scsi + ext4)
Windows  fio on NTFS file            (adds: virtio-scsi + NTFS + Windows IO)
```

Linux-VM minus host = `virtio + ext4` overhead.
Windows-VM minus Linux-VM = `NTFS + Windows IO stack` delta.

## Target VM (recommended configuration)

Spin up a **fresh** Ubuntu Server 24.04 LTS VM on the Proxmox node where the
host suite ran. Match the Windows VM as closely as possible so the three-way
comparison is clean:

- 16 cores, 566 GiB RAM, OVMF (UEFI), TPM 2.0
- 1× 200 GiB OS disk (the Ubuntu install)
- 3× 100 GiB virtio-SCSI data disks
- Each data disk: `discard=on`, `iothread=1`, `ssd=1`
- The VM must reside on the **same physical Proxmox node** as the host suite
  ran on, otherwise hardware divergence (Samsung-vs-Micron NVMe, see
  `docs/findings-2026-04-25.md` §6) invalidates the comparison.

## Layout

```
linux-vm/
├── README.md                          this file
├── bin/
│   ├── install-prerequisites.sh       apt install fio sysstat nvme-cli ...
│   ├── prepare-test-volumes.sh        format vd[bcd] / sd[bcd] as ext4,
│   │                                  mount /mnt/sql-{data,log,tempdb} with
│   │                                  noatime, set CPU governor performance,
│   │                                  disable transparent hugepages, save
│   │                                  state for revert
│   ├── reset-test-volumes.sh          revert host adjustments (volumes kept)
│   ├── collect-env.sh                 system, storage, kernel-tuning,
│   │                                  fio/services/tool-availability snapshots
│   ├── monitor.sh                     iostat + vmstat + mpstat + diskstats
│   │                                  with MONITORS_SUMMARY.txt
│   └── run-suite.sh                   orchestrator (mirrors bin/run-suite.sh)
└── jobs/
    ├── _global-linux.fio              ioengine=io_uring, shared options
    ├── baseline/sanity-check.fio      ~6 min smoke test
    ├── workloads/sqlserver-vm-sim.fio              primary SQL Server VM test
    ├── workloads/sqlserver-vm-checkpoint-storm.fio
    └── endurance/sqlserver-vm-26h.fio              26h endurance counterpart
```

## Prerequisites

`bin/install-prerequisites.sh` installs everything from apt:

- `fio` (the benchmark)
- `sysstat` (iostat, mpstat for monitor.sh)
- `util-linux`, `nvme-cli`, `linux-tools-generic`, `procps`, `coreutils`,
  `bsdmainutils`, `jq`, `python3`, `uuid-runtime`

The script enables and starts sysstat collection. Idempotent; safe to re-run.

## First-time setup

On a freshly-installed Ubuntu Server VM, **run as root**:

```bash
cd /root/fio-zfs-performance-test/linux-vm

# 1. Install all required tools (apt + sysstat enable)
sudo bin/install-prerequisites.sh

# 2. Format the three test virtio disks as ext4, mount /mnt/sql-{data,log,tempdb},
#    set CPU governor to performance, disable THP. Asks before formatting each
#    disk; pass FORCE=1 to skip prompts.
sudo bin/prepare-test-volumes.sh         # interactive
sudo FORCE=1 bin/prepare-test-volumes.sh # non-interactive
```

Original state of the host adjustments (CPU governor, THP, /etc/fstab) is
saved to `/var/lib/fio-test/saved-state` so `bin/reset-test-volumes.sh` can
restore them later.

## Running tests

```bash
sudo bin/run-suite.sh baseline/sanity-check.fio    # smoke test (~6 min)
sudo bin/run-suite.sh workloads                    # both SQL workloads
sudo bin/run-suite.sh endurance/sqlserver-vm-26h.fio  # 26h endurance
sudo bin/run-suite.sh -a                            # everything
```

Long runs should be started inside `tmux` or `screen` so an SSH disconnect
doesn't kill the job. Results land at
`<repo>/results/linux-vm/<timestamp>-<suite>-<job>/` in the same shape as
the host and Windows result directories.

## What gets captured per run

For each job:
- `fio.json`         clean parseable JSON (post-extracted from fio's combined output)
- `fio.summary.txt`  human-readable per-job summary
- `effective.fio`    the exact job file fio ran (global prelude + selected job)
- `fio.log`          stdout/stderr from fio (eta, progress, errors)
- `env/`             system, storage, kernel-tuning, fio, services,
                     tool-availability snapshots
- `monitor/`         iostat.log, vmstat.log, mpstat.log, diskstats.log,
                     MONITORS_SUMMARY.txt
- `df-before/after.txt` mount free-space deltas

Per-stream `bw_*.log`, `iops_*.log`, `lat_*.log` time series for the
multi-stream workloads (with `new_group=1` set in those files so per-stream
JSON survives).

## Three-way comparison protocol

For the comparison to be meaningful:

1. **Same physical Proxmox node.** Both Linux-VM and Windows-VM and any
   host-side reference run must be on the same physical hardware (same
   NVMe vendor batch). The framework records the hostname in
   `env/system.txt` so any cross-host mistake is visible after the fact.
2. **Same pool fragmentation state.** Run all three tests reasonably close
   together, ideally without a full pool clean-up in between (so they
   share the same fragmentation regime).
3. **Same file sizes.** All three frameworks default to 30/8/4 GiB
   (data/tempdb/log) for the SQL Server workloads. Don't change one
   without changing the others.
4. **Read `docs/sqlserver-comparison.md`** for the layer-by-layer
   breakdown of what each VM stack adds on top of the raw pool.

## Reverting host adjustments

```bash
sudo bin/reset-test-volumes.sh
```

Unmounts /mnt/sql-{data,log,tempdb}, restores the original `/etc/fstab`,
restores the original CPU governor, restores transparent hugepages.
The ext4 filesystems on the data disks are left in place; if you want
to wipe them, `wipefs -a /dev/<disk>` after unmounting.

## Caveats specific to in-VM measurement on this stack

- **The host's ARC will mask reads.** With a 30 GiB data file inside the VM
  and the host's `zfs_arc_max` up to 256 GiB, the VM's working set fits
  entirely in host ARC. Read-side IOPS in this framework will therefore
  measure the warm-cache path through `qemu virtio-scsi -> zvol -> ZFS ARC`,
  not the pool's NVMe read throughput.
- **Write-side latency is the meaningful comparison.** Especially the
  synchronous `sql-log` stream. Writes drain to disk regardless of ARC,
  so log p99 / p99.9 stays apples-to-apples with both the host and
  Windows-VM equivalents.
- **Inside-VM is blind to ZFS state.** No zpool, arcstat, or zfs_dirty_data
  visibility from the guest; if you need it, run `bin/monitor.sh` (host-side)
  on the Proxmox node in parallel and timestamp-correlate.
