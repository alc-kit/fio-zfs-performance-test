#!/usr/bin/env bash
# Sweep zfs_arc_max across a series of sizes, running a focused fio job set at
# each size so each result directory carries a directly comparable measurement
# of "what does N GiB of ARC buy this workload?".
#
# Live tuning via /sys/module/zfs/parameters/zfs_arc_max — no module reload, no
# reboot. Original arc_max captured up front and restored on exit (trap), so an
# interrupted sweep cannot leave the pool in a non-default state.
#
# Usage:
#   bin/sweep-arc.sh                       # default sweep: 8 32 64 128 256 GiB
#   bin/sweep-arc.sh 8 64 256              # custom sizes (GiB) in any order
#
# Env overrides:
#   SWEEP_JOBS    space-separated list of suite names or paths to .fio files
#                 (default: jobs/scaling/access-latency.fio jobs/workloads/sqlserver-zvol.fio)
#   FIO_RUNTIME   per-job runtime in seconds (default 300 — much longer than the
#                 standard 120 because ARC needs time to populate to the new max)
#   ASSUME_YES=1  skip safety prompt for sizes >50% of system RAM
#
# Each result directory produced gets a SWEEP_TAG.txt sidecar identifying the
# stage it belongs to, so post-run analysis can group by ARC size without
# parsing fio.json or env snapshots.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

require_root
require_cmd fio

ARC_PARAM=/sys/module/zfs/parameters/zfs_arc_max
[[ -w "$ARC_PARAM" ]] || die "$ARC_PARAM not writable (root + ZFS module loaded?)"

# --- parse / validate sizes -------------------------------------------
sizes=( "$@" )
[[ ${#sizes[@]} -eq 0 ]] && sizes=( 8 32 64 128 256 )

TOTAL_RAM_GIB=$(awk '/MemTotal/ {print int($2/1024/1024)}' /proc/meminfo)
for gib in "${sizes[@]}"; do
    [[ "$gib" =~ ^[0-9]+$ ]] || die "size must be a positive integer (GiB): '$gib'"
    if (( gib > TOTAL_RAM_GIB )); then
        die "size ${gib} GiB exceeds total RAM (${TOTAL_RAM_GIB} GiB)"
    fi
    if (( gib > TOTAL_RAM_GIB / 2 )); then
        confirm "ARC ${gib} GiB > 50% of RAM (${TOTAL_RAM_GIB} GiB). Continue?" || die "aborted"
    fi
done

# --- defaults ---------------------------------------------------------
: "${SWEEP_JOBS:=jobs/scaling/access-latency.fio jobs/workloads/sqlserver-zvol.fio}"
: "${FIO_RUNTIME:=300}"
export FIO_RUNTIME

# --- capture original + install restore trap --------------------------
ORIG_ARC=$(cat "$ARC_PARAM")
log "original arc_max = $ORIG_ARC bytes ($(( ORIG_ARC / 1024**3 )) GiB)"
log "sweep sizes (GiB): ${sizes[*]}"
log "jobs per size    : $SWEEP_JOBS"
log "FIO_RUNTIME      : ${FIO_RUNTIME}s"
log "RAM total        : ${TOTAL_RAM_GIB} GiB"

restore_arc() {
    log "restoring arc_max to $ORIG_ARC bytes ($(( ORIG_ARC / 1024**3 )) GiB)"
    echo "$ORIG_ARC" > "$ARC_PARAM" 2>/dev/null || true
}
trap restore_arc EXIT INT TERM

# --- sweep summary file in the results root ---------------------------
sweep_dir="$RESULTS_DIR/sweep-arc-$(timestamp)"
mkdir -p "$sweep_dir"
sweep_log="$sweep_dir/sweep.log"
sweep_idx="$sweep_dir/sweep.tsv"
{
    echo "# bin/sweep-arc.sh — $(date -u --iso-8601=seconds)"
    echo "# host          : $(hostname)"
    echo "# original arc_max: $ORIG_ARC ($(( ORIG_ARC / 1024**3 )) GiB)"
    echo "# sweep sizes   : ${sizes[*]} (GiB)"
    echo "# jobs          : $SWEEP_JOBS"
    echo "# FIO_RUNTIME   : $FIO_RUNTIME"
    echo "# RAM total     : ${TOTAL_RAM_GIB} GiB"
} > "$sweep_log"
printf 'iso_timestamp\tarc_gib\tarc_bytes_set\tarc_bytes_readback\tjob\tresult_dir\n' > "$sweep_idx"

# --- sweep loop -------------------------------------------------------
for gib in "${sizes[@]}"; do
    bytes=$(( gib * 1024**3 ))
    log "==========================================================="
    log "STAGE: arc_max -> ${gib} GiB"
    log "==========================================================="

    # Evict prior ARC content so each stage starts roughly cold:
    # 1. drop arc_max to 1 GiB briefly (forces eviction of everything above)
    # 2. wait so the kernel can reclaim
    # 3. set arc_max to target value; ARC will grow during the run
    echo $((1 * 1024**3)) > "$ARC_PARAM"
    sleep 5
    echo "$bytes" > "$ARC_PARAM"
    sleep 2
    actual=$(cat "$ARC_PARAM")
    log "arc_max readback: $actual bytes ($(( actual / 1024**3 )) GiB)"
    if [[ "$actual" != "$bytes" ]]; then
        log "WARN: kernel set arc_max to $actual instead of $bytes"
    fi

    for j in $SWEEP_JOBS; do
        log "--- run: $j (arc=${gib} GiB) ---"
        # Capture mtime before so we can identify the result dir afterwards
        before=$(date +%s)
        "$SCRIPT_DIR/run-suite.sh" "$j" || true

        # Find the result directory created by this invocation: the most
        # recently modified directory in $RESULTS_DIR whose mtime is >= $before.
        latest=$(find "$RESULTS_DIR" -maxdepth 1 -type d -newermt "@${before}" -name '202*' \
                 -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)
        if [[ -n "$latest" && -d "$latest" ]]; then
            {
                echo "sweep stage  : arc_max = ${gib} GiB"
                echo "set bytes    : $bytes"
                echo "readback     : $actual"
                echo "sweep dir    : $sweep_dir"
                echo "iso_timestamp: $(date -u --iso-8601=seconds)"
                echo "job          : $j"
            } > "$latest/SWEEP_TAG.txt"
            printf '%s\t%d\t%d\t%d\t%s\t%s\n' \
                "$(date -u --iso-8601=seconds)" "$gib" "$bytes" "$actual" "$j" "$latest" >> "$sweep_idx"
            log "tagged $latest"
        else
            log "WARN: could not identify result dir for stage=${gib}GiB job=$j"
        fi
    done
done

log "sweep complete"
log "  summary: $sweep_log"
log "  index  : $sweep_idx"
log "  result dirs are tagged via SWEEP_TAG.txt"
