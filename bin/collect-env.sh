#!/usr/bin/env bash
# Snapshot the state of the host that influences benchmark results.
# Output goes to $1 (a directory). Intended to be called by run-suite.sh.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

out="${1:?usage: collect-env.sh <output-dir>}"
mkdir -p "$out"

{
    echo "=== date ==="; date -u --iso-8601=seconds
    echo "=== uname ==="; uname -a
    echo "=== /etc/os-release ==="; cat /etc/os-release 2>/dev/null || true
    echo "=== cpu ==="; lscpu
    echo "=== memory ==="; free -h; echo; cat /proc/meminfo | head -20
    echo "=== kernel cmdline ==="; cat /proc/cmdline
} > "$out/system.txt" 2>&1

{
    echo "=== zpool version ==="; zpool version 2>/dev/null || cat /sys/module/zfs/version 2>/dev/null
    echo "=== zpool list ==="; zpool list -v
    echo "=== zpool status ==="; zpool status -v
    echo "=== zpool get all ==="; zpool get all "$ZFS_POOL"
    echo "=== zfs get all (pool + test root) ==="
    zfs get all "$ZFS_POOL" 2>/dev/null || true
    if dataset_exists "$TEST_ROOT"; then
        zfs get -r all "$TEST_ROOT"
    fi
    echo "=== zfs list -t all ==="; zfs list -t all -o name,used,avail,refer,mountpoint
} > "$out/zfs.txt" 2>&1

{
    echo "=== module params (zfs) ==="
    for f in /sys/module/zfs/parameters/zfs_arc_max \
             /sys/module/zfs/parameters/zfs_arc_min \
             /sys/module/zfs/parameters/zfs_dirty_data_max \
             /sys/module/zfs/parameters/zfs_txg_timeout \
             /sys/module/zfs/parameters/zfs_vdev_async_write_max_active \
             /sys/module/zfs/parameters/zfs_vdev_sync_write_max_active \
             /sys/module/zfs/parameters/zfs_prefetch_disable \
             /sys/module/zfs/parameters/zfs_compressed_arc_enabled \
             /sys/module/zfs/parameters/zil_slog_bulk; do
        [[ -r "$f" ]] && printf '%s = %s\n' "$f" "$(cat "$f")"
    done
    echo
    echo "=== arcstats ==="
    cat /proc/spl/kstat/zfs/arcstats 2>/dev/null || true
} > "$out/zfs-tunables.txt" 2>&1

{
    echo "=== block devices ==="; lsblk -o NAME,SIZE,ROTA,TYPE,MOUNTPOINT,MODEL,SERIAL
    echo "=== nvme list ==="; nvme list 2>/dev/null || echo "(nvme-cli not installed)"
    echo "=== cryptsetup status (dm-crypt devices) ==="
    for d in /dev/mapper/*; do
        [[ -b "$d" ]] || continue
        name="$(basename "$d")"
        cryptsetup status "$name" 2>/dev/null && echo
    done
    echo "=== scheduler per NVMe ==="
    for d in /sys/block/nvme*; do
        [[ -d "$d" ]] || continue
        printf '%s scheduler=%s queue_depth=%s nr_requests=%s\n' \
            "$(basename "$d")" \
            "$(cat "$d/queue/scheduler" 2>/dev/null)" \
            "$(cat "$d/device/queue_depth" 2>/dev/null)" \
            "$(cat "$d/queue/nr_requests" 2>/dev/null)"
    done
} > "$out/storage.txt" 2>&1

{
    command -v fio >/dev/null && fio --version
    command -v fio >/dev/null && fio --enghelp | head -60
} > "$out/fio.txt" 2>&1

log "env snapshot: $out"
