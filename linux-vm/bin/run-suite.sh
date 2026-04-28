#!/usr/bin/env bash
# Run a Linux-VM fio test suite (or single .fio file) inside an Ubuntu VM.
# Counterpart to win/Run-Suite.ps1 on the Windows side and bin/run-suite.sh
# on the host side. Same shape: per-job timestamped result directory, env
# snapshot, background monitors, fio with json+normal output split into a
# clean fio.json + a human fio.summary.txt + an fio.log of stdout/stderr.
#
# This script does NOT depend on ZFS / zpool / arcstat (none of which run
# inside a VM). It relies only on what install-prerequisites.sh provides.
#
# Usage:
#   run-suite.sh <suite>                       # all .fio in jobs/<suite>/
#   run-suite.sh jobs/path/to/one.fio          # single job
#   run-suite.sh <suite>/<job>.fio             # relative-to-jobs leaf path
#   run-suite.sh -a                            # every suite in jobs/
#
# Env overrides (sensible defaults for an Ubuntu VM with virtio-scsi):
#   FIO_IOENGINE=io_uring    (Linux native async; what modern qemu / Linux apps use)
#   FIO_RUNTIME=120          (seconds; per time-based job)
#   FIO_RAMP_TIME=10         (seconds; warm-up excluded from stats)
#   FIO_NUMJOBS=8
#   FIO_IODEPTH=32
#   RESULTS_DIR=<repo>/results/linux-vm
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

: "${RESULTS_DIR:=$REPO_ROOT/results/linux-vm}"
: "${FIO_IOENGINE:=io_uring}"
: "${FIO_RUNTIME:=120}"
: "${FIO_RAMP_TIME:=10}"
: "${FIO_NUMJOBS:=8}"
: "${FIO_IODEPTH:=32}"
export FIO_IOENGINE FIO_RUNTIME FIO_RAMP_TIME FIO_NUMJOBS FIO_IODEPTH RESULTS_DIR

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

command -v fio >/dev/null || die "fio not on PATH - run bin/install-prerequisites.sh"

# Validate test mounts are present
for mp in /mnt/sql-data /mnt/sql-log /mnt/sql-tempdb; do
    findmnt -nro TARGET "$mp" >/dev/null 2>&1 \
        || die "mount $mp not present - run bin/prepare-test-volumes.sh first"
done

# Raise the soft FD limit so high-numjobs jobs that share a thread group don't
# hit RLIMIT_NOFILE. Mirrors the host-side framework behaviour.
ulimit -Sn "$(ulimit -Hn)" 2>/dev/null || true

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

# Resolve a user-supplied $arg into either a single .fio file or a directory of
# .fio files. Accepts:
#   - absolute / cwd-relative path to a .fio file or directory
#   - a path relative to <REPO_ROOT>/linux-vm/jobs/  (file or directory)
resolve_arg() {
    local arg="$1"
    if [[ -f "$arg" ]]; then echo "FILE:$(readlink -f "$arg")"; return; fi
    if [[ -d "$arg" ]]; then echo "DIR:$(readlink -f "$arg")"; return; fi
    local under="$REPO_ROOT/linux-vm/jobs/$arg"
    if [[ -f "$under" ]]; then echo "FILE:$under"; return; fi
    if [[ -d "$under" ]]; then echo "DIR:$under"; return; fi
    die "no such suite or file: $arg"
}

run_one_job() {
    local job="$1"   # absolute path to .fio
    local suite="$2"
    local job_name; job_name="$(basename "$job" .fio)"
    local ts; ts="$(date +%Y%m%d-%H%M%S)"
    local out="$RESULTS_DIR/$ts-$suite-$job_name"
    mkdir -p "$out"

    log "=============================================================="
    log "job    : $job"
    log "suite  : $suite"
    log "output : $out"
    log "engine : $FIO_IOENGINE  runtime=${FIO_RUNTIME}s  ramp=${FIO_RAMP_TIME}s"
    log "         numjobs=$FIO_NUMJOBS iodepth=$FIO_IODEPTH"
    log "=============================================================="

    "$SCRIPT_DIR/collect-env.sh" "$out/env"

    # Drop page caches so each job starts from a known state. ZFS ARC on the
    # host is not reachable from inside the VM; this only clears the guest's
    # own page cache.
    sync
    [[ -w /proc/sys/vm/drop_caches ]] && echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true

    "$SCRIPT_DIR/monitor.sh" "$out/monitor"
    local pidfile="$out/monitor/monitors.pid"
    trap 'stop_monitors "$pidfile"' EXIT INT TERM

    # Volume free-space snapshot before/after for delta analysis
    df -hT /mnt/sql-data /mnt/sql-log /mnt/sql-tempdb > "$out/df-before.txt" 2>&1 || true

    # Build effective.fio: shared global prelude + selected job
    local effective="$out/effective.fio"
    {
        cat "$REPO_ROOT/linux-vm/jobs/_global-linux.fio"
        printf '\n'
        cat "$job"
    } > "$effective"

    # Run fio from the result dir so per-second bw/iops/lat log files land
    # next to fio.json. We capture json+normal to fio.out and post-extract
    # a parseable fio.json + a human fio.summary.txt.
    local fio_out="$out/fio.out"
    local fio_log="$out/fio.log"
    local rc=0
    set +e
    ( cd "$out" && fio \
        --output-format=json+,normal \
        --output="$fio_out" \
        --eta=always --eta-newline=10 \
        "$effective" ) 2>&1 | tee "$fio_log"
    rc=${PIPESTATUS[0]}
    set -e

    # Split fio.out -> fio.json + fio.summary.txt (same logic as host side)
    if [[ -f "$fio_out" ]]; then
        python3 - "$fio_out" "$out/fio.json" "$out/fio.summary.txt" <<'PY' || log "warn: fio.out split failed"
import sys, pathlib
src, json_dst, txt_dst = sys.argv[1], sys.argv[2], sys.argv[3]
buf = pathlib.Path(src).read_text()
start = -1
for i, line in enumerate(buf.splitlines(keepends=True)):
    if line.startswith("{"):
        start = sum(len(l) for l in buf.splitlines(keepends=True)[:i])
        break
if start < 0:
    pathlib.Path(txt_dst).write_text(buf)
    pathlib.Path(json_dst).write_text("")
    sys.exit(0)
depth, end = 0, -1
for i in range(start, len(buf)):
    c = buf[i]
    if c == "{": depth += 1
    elif c == "}":
        depth -= 1
        if depth == 0: end = i + 1; break
if end < 0:
    sys.exit("unbalanced JSON braces in fio.out")
pathlib.Path(txt_dst).write_text(buf[:start].rstrip() + "\n")
pathlib.Path(json_dst).write_text(buf[start:end] + "\n")
PY
    fi

    df -hT /mnt/sql-data /mnt/sql-log /mnt/sql-tempdb > "$out/df-after.txt" 2>&1 || true

    stop_monitors "$pidfile"
    trap - EXIT INT TERM

    if [[ $rc -ne 0 ]]; then
        log "FIO EXIT $rc - see $fio_log"
    else
        log "done: $out"
    fi
    return $rc
}

overall_rc=0
if [[ $run_all -eq 1 ]]; then
    for d in "$REPO_ROOT"/linux-vm/jobs/*/; do
        suite="$(basename "$d")"
        for j in "$d"/*.fio; do
            [[ -f "$j" ]] || continue
            run_one_job "$j" "$suite" || overall_rc=$?
        done
    done
else
    for arg in "$@"; do
        kind_path="$(resolve_arg "$arg")"
        kind="${kind_path%%:*}"
        path="${kind_path#*:}"
        if [[ "$kind" == "FILE" ]]; then
            suite="$(basename "$(dirname "$path")")"
            run_one_job "$path" "$suite" || overall_rc=$?
        else
            suite="$(basename "$path")"
            for j in "$path"/*.fio; do
                [[ -f "$j" ]] || continue
                run_one_job "$j" "$suite" || overall_rc=$?
            done
        fi
    done
fi

exit "$overall_rc"
