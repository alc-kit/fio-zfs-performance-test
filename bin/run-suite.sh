#!/usr/bin/env bash
# Run a suite (or a single job file) of fio tests, capturing env + monitors + results.
#
# Usage:
#   run-suite.sh <suite>                       # runs all jobs/<suite>/*.fio
#   run-suite.sh jobs/path/to/one.fio          # runs a single job file
#   run-suite.sh -a                            # runs every suite in jobs/
#
# Env overrides (see lib/common.sh for defaults):
#   ZFS_POOL TEST_ROOT RESULTS_DIR FIO_IOENGINE FIO_RUNTIME FIO_SIZE
#   FIO_NUMJOBS FIO_IODEPTH FIO_RAMP_TIME
#
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

require_cmd fio

# Raise the soft file-descriptor limit toward the hard cap. The metadata-heavy
# job opens thousands of small files and the default systemd soft limit (1024)
# is not enough; the hard limit on PVE 9 is usually 524288 or 1048576. Failing
# quietly is fine for environments where the hard cap is already lower.
ulimit -Sn "$(ulimit -Hn)" 2>/dev/null || true
log "RLIMIT_NOFILE: soft=$(ulimit -Sn) hard=$(ulimit -Hn)"

run_all=0
if [[ "${1:-}" == "-a" ]]; then run_all=1; shift; fi
[[ $# -ge 1 || $run_all -eq 1 ]] || die "usage: $0 <suite|job.fio> | -a"

stop_monitors() {
    local pidfile="$1"
    [[ -f "$pidfile" ]] || return 0
    while IFS=: read -r pid name; do
        [[ -n "${pid:-}" ]] || continue
        kill "$pid" 2>/dev/null || true
    done < "$pidfile"
    sleep 1
    while IFS=: read -r pid name; do
        [[ -n "${pid:-}" ]] || continue
        kill -9 "$pid" 2>/dev/null || true
    done < "$pidfile"
    log "monitors stopped"
}

run_one_job() {
    local job="$1"              # absolute path to .fio file
    local suite="$2"             # suite name (directory under jobs/)
    local job_name
    job_name="$(basename "$job" .fio)"
    local ts; ts="$(timestamp)"
    local out="$RESULTS_DIR/$ts-$suite-$job_name"
    mkdir -p "$out"

    log "=============================================================="
    log "job    : $job"
    log "suite  : $suite"
    log "output : $out"
    log "engine : $FIO_IOENGINE  runtime=${FIO_RUNTIME}s  size=$FIO_SIZE"
    log "         numjobs=$FIO_NUMJOBS iodepth=$FIO_IODEPTH"
    log "=============================================================="

    "$SCRIPT_DIR/collect-env.sh" "$out/env"

    # Drop host caches so each job starts from a known state. Does NOT purge ARC
    # (the test dataset's primarycache setting controls that).
    if [[ -w /proc/sys/vm/drop_caches ]]; then drop_caches; fi

    "$SCRIPT_DIR/monitor.sh" "$out/monitor"
    trap 'stop_monitors "$out/monitor/monitors.pid"' EXIT INT TERM

    # Snapshot pool state before and after for fragmentation / free-space deltas
    zpool list -v "$ZFS_POOL" > "$out/zpool-before.txt" 2>&1 || true
    zfs list -r -o name,used,avail,refer "$TEST_ROOT" > "$out/zfs-before.txt" 2>&1 || true

    # Assemble the effective job file: shared global prelude + the selected job.
    local effective="$out/effective.fio"
    {
        cat "$REPO_ROOT/jobs/_global.fio"
        printf '\n'
        cat "$job"
    } > "$effective"

    # Run fio from the result directory so its per-second bw/iops/lat log files
    # (named via write_*_log in _global.fio and per-job files) land next to
    # fio.json instead of in the invoker's CWD. All paths we hand fio are
    # absolute so the cd is safe.
    set +e
    ( cd "$out" && fio \
        --output-format=json+,normal \
        --output="$out/fio.json" \
        --eta=always --eta-newline=10 \
        "$effective" ) 2>&1 | tee "$out/fio.log"
    local rc=${PIPESTATUS[0]}
    set -e

    zpool list -v "$ZFS_POOL" > "$out/zpool-after.txt" 2>&1 || true
    zfs list -r -o name,used,avail,refer "$TEST_ROOT" > "$out/zfs-after.txt" 2>&1 || true

    stop_monitors "$out/monitor/monitors.pid"
    trap - EXIT INT TERM

    if [[ $rc -ne 0 ]]; then
        log "FIO EXIT $rc — see $out/fio.log"
    else
        log "done: $out"
    fi
    return $rc
}

collect_jobs() {
    local arg="$1"
    if [[ -f "$arg" ]]; then
        echo "$arg"
    elif [[ -d "$REPO_ROOT/jobs/$arg" ]]; then
        find "$REPO_ROOT/jobs/$arg" -maxdepth 1 -type f -name '*.fio' | sort
    else
        die "no such suite or file: $arg"
    fi
}

overall_rc=0
if [[ $run_all -eq 1 ]]; then
    for d in "$REPO_ROOT"/jobs/*/; do
        suite="$(basename "$d")"
        while IFS= read -r j; do
            [[ -z "$j" ]] && continue
            run_one_job "$j" "$suite" || overall_rc=$?
        done < <(collect_jobs "$suite")
    done
else
    for arg in "$@"; do
        if [[ -f "$arg" ]]; then
            suite="$(basename "$(dirname "$arg")")"
            run_one_job "$(readlink -f "$arg")" "$suite" || overall_rc=$?
        else
            while IFS= read -r j; do
                [[ -z "$j" ]] && continue
                run_one_job "$j" "$arg" || overall_rc=$?
            done < <(collect_jobs "$arg")
        fi
    done
fi

exit "$overall_rc"
