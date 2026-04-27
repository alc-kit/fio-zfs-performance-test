#!/usr/bin/env bash
# Sweep zfs_dirty_data_max across a series of values, running a focused fio
# job set at each value so each result directory carries a directly comparable
# measurement of "how much does dirty-buffer size cost or save us?".
#
# Companion to sweep-arc.sh. Same shape: live tuning via /sys/module/zfs/
# parameters/zfs_dirty_data_max, no module reload, no reboot, original value
# captured up front and restored via trap on EXIT/INT/TERM.
#
# Background — why this sweep matters on this pool
# -------------------------------------------------
# zfs_dirty_data_max controls the maximum amount of unwritten data ZFS holds
# in memory before forcing a transaction-group (txg) flush. Defaults derive
# from physical memory (typically 10% of RAM, capped at zfs_dirty_data_max_max,
# default 25%). A larger dirty buffer permits bigger, less-frequent txg
# flushes — better aggregate write throughput, but each flush is more bursty
# and can collide with sync write streams (SQL log commits in particular).
#
# The 2026-04-27 ARC sweep on m-p-proxmox-08 (Samsung PM9A3) showed sql-log
# write p99.9 climbing from 25 ms (ARC=32 GiB) to 308 ms (ARC=256 GiB). The
# leading hypothesis is that growing zfs_arc_max also let zfs_dirty_data_max
# grow, the resulting bigger txg flushes overwhelmed the Samsung NVMe write
# path more than they did the Micron drives in -05. This sweep tests the
# hypothesis directly by varying dirty_data_max while leaving arc_max alone.
#
# Usage:
#   bin/sweep-dirty-data.sh                 # default sweep: 256 1024 4096 16384 65536 MiB
#   bin/sweep-dirty-data.sh 1024 4096       # custom sizes (MiB) in any order
#
# Env overrides:
#   SWEEP_JOBS    space-separated list of suite names or paths to .fio files
#                 (default: jobs/workloads/sqlserver-zvol.fio
#                           jobs/workloads/sqlserver-zvol-checkpoint-storm.fio)
#   FIO_RUNTIME   per-job runtime in seconds (default 600 — long enough for the
#                 txg flush rhythm to reach steady state at every dirty-buffer
#                 size; the standard 120 s is too short)
#   ASSUME_YES=1  skip safety prompt for sizes >= the kernel's dirty_data_max_max
#
# Each result directory produced gets a SWEEP_TAG.txt sidecar and an entry in
# results/sweep-dirty-data-<timestamp>/sweep.tsv for grouping.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

require_root
require_cmd fio

PARAM=/sys/module/zfs/parameters/zfs_dirty_data_max
PARAM_MAX=/sys/module/zfs/parameters/zfs_dirty_data_max_max
[[ -w "$PARAM" ]] || die "$PARAM not writable (root + ZFS module loaded?)"

# --- parse / validate sizes -------------------------------------------
sizes_mib=( "$@" )
[[ ${#sizes_mib[@]} -eq 0 ]] && sizes_mib=( 256 1024 4096 16384 65536 )

# Read the kernel's hard ceiling on dirty_data_max so we don't ask for impossible.
if [[ -r "$PARAM_MAX" ]]; then
    MAX_BYTES=$(cat "$PARAM_MAX")
    MAX_MIB=$(( MAX_BYTES / 1024 / 1024 ))
else
    MAX_MIB=999999
    log "warn: $PARAM_MAX not readable; cannot validate against kernel ceiling"
fi
log "kernel zfs_dirty_data_max_max = ${MAX_MIB} MiB"

for mib in "${sizes_mib[@]}"; do
    [[ "$mib" =~ ^[0-9]+$ ]] || die "size must be a positive integer (MiB): '$mib'"
    if (( mib > MAX_MIB )); then
        confirm "size ${mib} MiB exceeds zfs_dirty_data_max_max (${MAX_MIB} MiB). Continue?" \
            || die "aborted"
    fi
    if (( mib < 1 )); then
        die "size $mib MiB is too small (kernel will reject)"
    fi
done

# --- defaults ---------------------------------------------------------
: "${SWEEP_JOBS:=jobs/workloads/sqlserver-zvol.fio jobs/workloads/sqlserver-zvol-checkpoint-storm.fio}"
: "${FIO_RUNTIME:=600}"
export FIO_RUNTIME

# --- capture original + install restore trap --------------------------
ORIG=$(cat "$PARAM")
ORIG_MIB=$(( ORIG / 1024 / 1024 ))
log "original zfs_dirty_data_max = $ORIG bytes (${ORIG_MIB} MiB)"
log "sweep sizes (MiB): ${sizes_mib[*]}"
log "jobs per size    : $SWEEP_JOBS"
log "FIO_RUNTIME      : ${FIO_RUNTIME}s"

restore() {
    log "restoring zfs_dirty_data_max to $ORIG bytes (${ORIG_MIB} MiB)"
    echo "$ORIG" > "$PARAM" 2>/dev/null || true
}
trap restore EXIT INT TERM

# --- sweep summary file in the results root ---------------------------
sweep_dir="$RESULTS_DIR/sweep-dirty-data-$(timestamp)"
mkdir -p "$sweep_dir"
sweep_log="$sweep_dir/sweep.log"
sweep_idx="$sweep_dir/sweep.tsv"
{
    echo "# bin/sweep-dirty-data.sh — $(date -u --iso-8601=seconds)"
    echo "# host           : $(hostname)"
    echo "# original value : $ORIG bytes (${ORIG_MIB} MiB)"
    echo "# kernel ceiling : ${MAX_MIB} MiB (zfs_dirty_data_max_max)"
    echo "# sweep sizes    : ${sizes_mib[*]} (MiB)"
    echo "# jobs           : $SWEEP_JOBS"
    echo "# FIO_RUNTIME    : $FIO_RUNTIME"
    echo "# also-relevant module params at start:"
    for p in zfs_arc_max zfs_arc_min zfs_dirty_data_sync_percent zfs_txg_timeout; do
        if [[ -r "/sys/module/zfs/parameters/$p" ]]; then
            printf '#   %s = %s\n' "$p" "$(cat /sys/module/zfs/parameters/$p)"
        fi
    done
} > "$sweep_log"
printf 'iso_timestamp\tdirty_mib\tdirty_bytes_set\tdirty_bytes_readback\tjob\tresult_dir\n' \
    > "$sweep_idx"

# --- sweep loop -------------------------------------------------------
for mib in "${sizes_mib[@]}"; do
    bytes=$(( mib * 1024 * 1024 ))
    log "==========================================================="
    log "STAGE: zfs_dirty_data_max -> ${mib} MiB"
    log "==========================================================="

    # Set the new value. Unlike ARC, dirty_data_max takes effect immediately
    # on the next txg; no eviction step is meaningful here (the dirty buffer
    # naturally drains at each txg flush).
    echo "$bytes" > "$PARAM"
    sleep 1
    actual=$(cat "$PARAM")
    log "zfs_dirty_data_max readback: $actual bytes ($(( actual / 1024 / 1024 )) MiB)"
    if [[ "$actual" != "$bytes" ]]; then
        log "WARN: kernel set zfs_dirty_data_max to $actual instead of $bytes"
    fi

    for j in $SWEEP_JOBS; do
        log "--- run: $j (dirty_data_max=${mib} MiB) ---"
        before=$(date +%s)
        "$SCRIPT_DIR/run-suite.sh" "$j" || true

        latest=$(find "$RESULTS_DIR" -maxdepth 1 -type d -newermt "@${before}" -name '202*' \
                 -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)
        if [[ -n "$latest" && -d "$latest" ]]; then
            {
                echo "sweep type   : zfs_dirty_data_max"
                echo "stage MiB    : ${mib}"
                echo "set bytes    : $bytes"
                echo "readback     : $actual"
                echo "sweep dir    : $sweep_dir"
                echo "iso_timestamp: $(date -u --iso-8601=seconds)"
                echo "job          : $j"
            } > "$latest/SWEEP_TAG.txt"
            printf '%s\t%d\t%d\t%d\t%s\t%s\n' \
                "$(date -u --iso-8601=seconds)" "$mib" "$bytes" "$actual" "$j" "$latest" \
                >> "$sweep_idx"
            log "tagged $latest"
        else
            log "WARN: could not identify result dir for stage=${mib}MiB job=$j"
        fi
    done
done

log "sweep complete"
log "  summary: $sweep_log"
log "  index  : $sweep_idx"
log "  result dirs are tagged via SWEEP_TAG.txt"
