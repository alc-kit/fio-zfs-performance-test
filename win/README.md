# Windows-VM fio testing

PowerShell-based parallel of the host-side framework, intended to run
*inside* a Proxmox Windows Server 2025 VM whose disks live on the same
ZFS pool the host-side tests use. Runs the same shape of SQL Server
workload that the host runs against the zvol, so the difference between
the two result sets quantifies what virtio-SCSI + NTFS add on top of the
raw pool.

## Target VM (verified configuration)

- 16 cores, 566 GiB RAM, OVMF (UEFI), TPM 2.0
- 1× 200 GiB OS disk + 6× 100 GiB virtio-SCSI data disks
- Each data disk: `discard=on`, `iothread=1`, `ssd=1`
- VM resides on a Proxmox 9.1 node with the same stock ZFS configuration
  as the host this framework was originally built for. For host vs VM
  comparison runs, both must run on the same physical Proxmox node.

## Files

```
win/
├── README.md
├── Prepare-TestVolume.ps1   one-time setup: format scsi1-3, drive letters
│                            E:, F:, G: (data/log/tempdb), 64 KiB NTFS,
│                            high-perf power plan, Defender exclusions,
│                            disable last-access-time
├── Reset-TestVolume.ps1     revert host-level adjustments (volumes kept)
├── Collect-Env.ps1          one-shot snapshot of system + storage state
├── Monitor.ps1              background typeperf logging during a run
├── Run-Suite.ps1            orchestrator (mirrors bin/run-suite.sh)
└── jobs/
    ├── _global-win.fio                       windowsaio + shared options
    ├── baseline/sanity-check.fio             ~6 min sanity probe
    ├── workloads/sqlserver-vm-sim.fio        primary SQL Server VM test
    ├── workloads/sqlserver-vm-checkpoint-storm.fio
    └── endurance/sqlserver-vm-26h.fio        26h endurance counterpart
```

## Prerequisites

- Run all scripts as Administrator (PowerShell elevated).
- `fio.exe` already installed and on PATH (assumed; no install step here).
- VM has at least three RAW (un-partitioned) data disks at ≤150 GiB each
  available — the prepare script picks the first three.
- Standard Windows tools must be present: `typeperf.exe`, `powercfg.exe`,
  `fsutil.exe` (all built-in on Server 2025).

## First-time setup

```powershell
cd C:\path\to\fio-zfs-performance-test\win

# Format E:, F:, G: with NTFS 64K AU, set high-perf power plan,
# add Defender exclusions, suspend Windows Update for the test paths.
.\Prepare-TestVolume.ps1                # interactive prompt per disk
.\Prepare-TestVolume.ps1 -Force         # no prompts
```

## Running tests

```powershell
.\Run-Suite.ps1 baseline\sanity-check.fio          # one job
.\Run-Suite.ps1 workloads                          # all jobs in a suite
.\Run-Suite.ps1 -All                               # every suite
.\Run-Suite.ps1 endurance\sqlserver-vm-26h.fio     # 26h run
```

Long runs should be started inside a persistent session — Windows does
not have `tmux`/`screen`. Two acceptable patterns:

- **PowerShell-as-a-service**: `New-ScheduledTask` running on system boot
  and surviving RDP disconnects. Heavier but most reliable for 26h jobs.
- **`Start-Process` + log redirection**: simplest, but requires that the
  RDP session not be fully logged out (disconnect is fine, log out is not).

Results land at `..\results\win\<timestamp>-<suite>-<job>\` — same naming
shape as the Linux side, in a separate `win/` subdirectory of `results/`.

## What gets captured

For each job:
- `fio.json` — clean parseable JSON (post-extracted from fio's combined output)
- `fio.summary.txt` — human-readable per-job summary fio prints
- `fio.log` — eta/progress/errors from fio's stdout/stderr
- `effective.fio` — the exact job file that ran (global prelude + selected job)
- `env/` — system, storage, fio, defender, power, services, tool-availability snapshots
- `monitor/` — `physicaldisk.csv`, `processor.csv`, `system.csv`, `memory.csv`,
  `logicaldisk.csv` (one CSV per typeperf counter group), `MONITORS_SUMMARY.txt`
- `volumes-before.txt` / `volumes-after.txt` — drive free-space deltas
- per-stream `bw_*.log`, `iops_*.log`, `lat_*.log` time series for the
  multi-stream workloads

## Host vs VM comparison protocol

For the comparison to be meaningful:

1. **Same physical node.** Both runs must execute on the same Proxmox host
   so the underlying NVMe + LUKS + ZFS stack is identical. Migrate the VM
   if necessary.
2. **Same pool state.** Run the VM tests reasonably soon after the host
   tests, ideally without a full pool clean-up in between so fragmentation
   state is similar. Or, conversely, clean and re-prepare both.
3. **Equivalent file sizes if possible.** This framework defaults to
   80/30/18 GiB (data/tempdb/log) inside the VM because each virtio data
   disk is 100 GiB. The host tests use 200/40/20 GiB. The shape is the
   same; the absolute throughput numbers will differ partly because of
   working-set size. If you need exact size parity, expand the VM's
   virtio data disks first.
4. **Read the host-side `docs/sqlserver-comparison.md`.** It describes
   each layer the VM stack adds (buffer pool absent here, virtio queue
   serialisation, FUA semantics, qemu iothread). The numbers from this
   framework give the storage-stack delta concretely.

## Reverting

```powershell
.\Reset-TestVolume.ps1
```

Restores the original power plan, last-access-time setting, Defender
exclusions, and Windows Update service state. Test volumes (E:, F:, G:)
are left in place; delete them manually if no longer needed.
