#!/usr/bin/env bash
# Run background monitors for the duration of a test. Pass the output dir as $1.
# Writes PIDs to $1/monitors.pid so run-suite.sh can stop them.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

out="${1:?usage: monitor.sh <output-dir>}"
mkdir -p "$out"
pidfile="$out/monitors.pid"
: > "$pidfile"

start() {
    local name="$1"; shift
    local log="$out/$name.log"
    "$@" > "$log" 2>&1 &
    echo "$!:$name" >> "$pidfile"
    log "started $name (pid=$!) -> $log"
}

# zpool iostat: per-vdev I/O on the pool. -y yields averages since last interval.
start zpool-iostat bash -c "zpool iostat -vy '$ZFS_POOL' 1"

# host-level I/O on block devices
start iostat bash -c "iostat -xmt 1"

# ARC hit rates / mrus / sizes
if command -v arcstat >/dev/null 2>&1; then
    start arcstat bash -c "arcstat 1"
else
    start arcstats-proc bash -c "while true; do date --iso-8601=seconds; cat /proc/spl/kstat/zfs/arcstats; echo; sleep 5; done"
fi

# vmstat: memory pressure, context switches, runqueue
start vmstat bash -c "vmstat -w 1"

# mpstat: per-CPU utilization (crypto/LUKS often bottlenecks on individual cores)
if command -v mpstat >/dev/null 2>&1; then
    start mpstat bash -c "mpstat -P ALL 1"
fi

log "monitors running; pidfile=$pidfile"
