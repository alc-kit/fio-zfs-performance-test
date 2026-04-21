# shellcheck shell=bash
# Shared helpers. Source this from scripts in bin/.

: "${ZFS_POOL:?set ZFS_POOL, e.g. export ZFS_POOL=data}"
: "${TEST_ROOT:=${ZFS_POOL}/fio-test}"
: "${TEST_MOUNT:=/${TEST_ROOT}}"
: "${RESULTS_DIR:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/results}"
: "${FIO_IOENGINE:=io_uring}"
: "${FIO_RUNTIME:=120}"
: "${FIO_SIZE:=100G}"
: "${FIO_NUMJOBS:=8}"
: "${FIO_IODEPTH:=32}"
: "${FIO_RAMP_TIME:=10}"
: "${ZVOL_NAME:=fio-test-vol}"

export ZFS_POOL TEST_ROOT TEST_MOUNT RESULTS_DIR ZVOL_NAME
export FIO_IOENGINE FIO_RUNTIME FIO_SIZE FIO_NUMJOBS FIO_IODEPTH FIO_RAMP_TIME

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

require_root() {
    [[ $EUID -eq 0 ]] || die "this script requires root (needs zfs/zpool and sysctl)"
}

require_cmd() {
    for c in "$@"; do command -v "$c" >/dev/null || die "missing command: $c"; done
}

pool_exists() { zpool list -H -o name | grep -qx "$1"; }
dataset_exists() { zfs list -H -o name "$1" >/dev/null 2>&1; }

confirm() {
    local msg="$1"
    if [[ "${ASSUME_YES:-0}" == "1" ]]; then return 0; fi
    read -r -p "$msg [y/N] " a
    [[ "$a" =~ ^[Yy]$ ]]
}

timestamp() { date +%Y%m%d-%H%M%S; }

drop_caches() {
    sync
    echo 3 > /proc/sys/vm/drop_caches
    if command -v arc_summary >/dev/null 2>&1; then
        # best-effort ARC shrink hint
        echo 1 > /proc/sys/vm/drop_caches || true
    fi
}
