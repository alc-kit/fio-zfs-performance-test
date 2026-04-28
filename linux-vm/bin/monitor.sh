#!/usr/bin/env bash
# Background performance monitors for the duration of an fio run inside a Linux
# VM. Mirrors bin/monitor.sh on the host side and win/Monitor.ps1 on the
# Windows-VM side.
#
# Two tiers:
#   CRITICAL - iostat + vmstat: missing these aborts the run because the result
#              is uninterpretable without per-device IOPS / latency and CPU
#              breakdown.
#   OPTIONAL - mpstat: per-CPU detail; arc not applicable inside a VM.
set -euo pipefail

out="${1:?usage: monitor.sh <output-dir>}"
mkdir -p "$out"
pidfile="$out/monitors.pid"
summary="$out/MONITORS_SUMMARY.txt"
: > "$pidfile"
{
    echo "# monitor.sh summary - $(date -u --iso-8601=seconds)"
    echo "# CRITICAL = required for the run; SKIPPED/FAILED here aborts the suite."
    echo "# OPTIONAL = enriches analysis but the run proceeds without it."
    echo
} > "$summary"

note() {
    printf '%s\n' "$*" >> "$summary"
    printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"
}

start_monitor() {
    local name="$1"; shift
    local logfile="$out/$name.log"
    "$@" > "$logfile" 2>&1 &
    local pid=$!
    echo "$pid:$name" >> "$pidfile"
    sleep 0.2
    if ! kill -0 "$pid" 2>/dev/null; then
        note "FAILED   $name - process exited immediately. First lines:"
        sed 's/^/    | /' "$logfile" 2>/dev/null | head -5 >> "$summary" || true
        return 1
    fi
    note "STARTED  $name (pid=$pid) -> $name.log"
    return 0
}

skip_monitor() {
    local kind="$1" name="$2" pkg="$3" why="$4"
    note "SKIPPED  [$kind] $name - $why (install: apt install $pkg)"
}

fatal() {
    note "FATAL    $*"
    note ""
    note "summary so far written to $summary"
    exit 1
}

# --- CRITICAL ---------------------------------------------------------

# iostat: per-block-device IOPS / bandwidth / latency / queue-length
if command -v iostat >/dev/null; then
    start_monitor iostat bash -c "iostat -xmt 1" \
        || fatal "could not start iostat (sysstat installed but execution failed)"
else
    fatal "iostat not in PATH (sysstat missing) - run bin/install-prerequisites.sh"
fi

# vmstat: aggregate CPU breakdown, memory pressure, runqueue, context switches
if command -v vmstat >/dev/null; then
    start_monitor vmstat bash -c "vmstat -w 1" \
        || fatal "could not start vmstat"
else
    fatal "vmstat not in PATH (procps missing) - run bin/install-prerequisites.sh"
fi

# --- OPTIONAL ---------------------------------------------------------

# mpstat: per-CPU utilisation. Useful when one core is pinned by virtio-iothread
# or by a single-thread sync stream.
if command -v mpstat >/dev/null; then
    start_monitor mpstat bash -c "mpstat -P ALL 1" || true
else
    skip_monitor OPTIONAL mpstat sysstat "mpstat command not found"
fi

# /proc/diskstats - raw counter dump every 5 s. Lightweight and useful as a
# sanity check that block-layer counters are still moving when iostat looks
# unusual.
start_monitor diskstats bash -c \
    "while true; do date --iso-8601=seconds; cat /proc/diskstats; echo; sleep 5; done" || true

note ""
note "monitors running; pidfile=$pidfile"
