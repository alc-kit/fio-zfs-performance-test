#!/usr/bin/env bash
# Run background monitors for the duration of a test. Pass the output dir as $1.
# Writes PIDs to $1/monitors.pid so run-suite.sh can stop them, and a
# MONITORS_SUMMARY.txt that records exactly which monitors started, which were
# skipped, and why. Run-suite.sh aborts only if a monitor declared CRITICAL
# (zpool, vmstat) is missing or fails to start.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

out="${1:?usage: monitor.sh <output-dir>}"
mkdir -p "$out"
pidfile="$out/monitors.pid"
summary="$out/MONITORS_SUMMARY.txt"
: > "$pidfile"
{
    echo "# monitor.sh summary — $(date -u --iso-8601=seconds)"
    echo "# CRITICAL = required for the run; SKIPPED/FAILED here aborts the suite."
    echo "# OPTIONAL = enriches analysis but the run proceeds without it."
    echo
} > "$summary"

note() {
    printf '%s\n' "$*" >> "$summary"
    log "$*"
}

# Start a monitor as a background command. Confirms the process is still alive
# 200 ms later, so silent failures (e.g. backgrounded "command not found", bad
# arguments) become visible instead of leaving a tiny error log we never
# notice. Returns non-zero if the monitor failed to start.
start_monitor() {
    local name="$1"; shift
    local logfile="$out/$name.log"
    "$@" > "$logfile" 2>&1 &
    local pid=$!
    echo "$pid:$name" >> "$pidfile"
    sleep 0.2
    if ! kill -0 "$pid" 2>/dev/null; then
        note "FAILED   $name — process exited immediately. First lines of log:"
        sed 's/^/    | /' "$logfile" 2>/dev/null | head -5 >> "$summary" || true
        return 1
    fi
    note "STARTED  $name (pid=$pid) -> $name.log"
    return 0
}

skip_monitor() {
    local kind="$1" name="$2" pkg="$3" why="$4"
    note "SKIPPED  [$kind] $name — $why (install: apt install $pkg)"
}

fatal() {
    note "FATAL    $*"
    note ""
    note "summary so far written to $summary"
    exit 1
}

# === CRITICAL monitors ===

# zpool iostat — per-vdev I/O on the pool. The single most important monitor;
# without it we cannot diagnose mirror-side imbalance or vdev saturation.
if ! command -v zpool >/dev/null; then
    fatal "zpool not in PATH — cannot run any test"
fi
start_monitor zpool-iostat bash -c "zpool iostat -vy '$ZFS_POOL' 1" \
    || fatal "could not start zpool iostat"

# vmstat — runqueue, context switches, aggregate CPU breakdown, memory pressure.
# procps is preinstalled on every Debian/PVE system; failing here means
# something is structurally wrong with the host.
if ! command -v vmstat >/dev/null; then
    fatal "vmstat not in PATH (procps missing) — host environment is broken"
fi
start_monitor vmstat bash -c "vmstat -w 1" \
    || fatal "could not start vmstat"

# === OPTIONAL monitors ===

# iostat — per-block-device throughput / latency / queue depth. Required to
# diagnose per-NVMe device imbalance below the ZFS layer.
if command -v iostat >/dev/null; then
    start_monitor iostat bash -c "iostat -xmt 1" || true
else
    skip_monitor OPTIONAL iostat sysstat "iostat command not found"
fi

# mpstat — per-CPU utilisation. Required to spot LUKS crypto pinning a single
# core, which is the most common write-side ceiling on this hardware class.
if command -v mpstat >/dev/null; then
    start_monitor mpstat bash -c "mpstat -P ALL 1" || true
else
    skip_monitor OPTIONAL mpstat sysstat "mpstat command not found"
fi

# arcstat — formatted ARC counters. If unavailable, fall back to a 5-second
# raw kstat dump from /proc/spl/kstat/zfs/arcstats which contains a superset
# of the same data.
if command -v arcstat >/dev/null; then
    start_monitor arcstat bash -c "arcstat 1" || true
elif [[ -r /proc/spl/kstat/zfs/arcstats ]]; then
    note "INFO     arcstat not installed; using raw kstat fallback every 5 s"
    start_monitor arcstats-proc bash -c \
        "while true; do date --iso-8601=seconds; cat /proc/spl/kstat/zfs/arcstats; echo; sleep 5; done" \
        || true
else
    skip_monitor OPTIONAL arcstat zfsutils-linux "neither arcstat nor /proc/spl/kstat/zfs/arcstats available"
fi

note ""
note "monitors running; pidfile=$pidfile"
