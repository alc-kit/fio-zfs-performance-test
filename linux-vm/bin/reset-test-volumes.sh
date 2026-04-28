#!/usr/bin/env bash
# Revert the host-level adjustments made by prepare-test-volumes.sh.
# Does NOT delete the ext4 test volumes or their data; the user can clean
# those manually if no longer needed.
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "error: must be run as root" >&2
    exit 1
fi

state_dir=/var/lib/fio-test
state_file="$state_dir/saved-state"
[[ -f "$state_file" ]] || { echo "no saved state at $state_file; nothing to revert"; exit 0; }

# shellcheck disable=SC1090
source "$state_file"

step() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

step "unmount test volumes (data, log, tempdb)"
for mp in /mnt/sql-data /mnt/sql-log /mnt/sql-tempdb; do
    if findmnt -nro TARGET "$mp" >/dev/null 2>&1; then
        umount "$mp" 2>/dev/null || true
    fi
done

step "remove fio-test fstab entries (originals preserved at /var/lib/fio-test/fstab.orig)"
if [[ -f "$state_dir/fstab.orig" ]]; then
    cp "$state_dir/fstab.orig" /etc/fstab
else
    # fall back to deleting only our marked lines
    sed -i '/# fio-test /d' /etc/fstab
fi

step "restore CPU governor to '$ORIG_CPU_GOVERNOR'"
if [[ -n "${ORIG_CPU_GOVERNOR:-}" ]]; then
    for cpu in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
        [[ -w "$cpu" ]] && echo "$ORIG_CPU_GOVERNOR" > "$cpu" 2>/dev/null || true
    done
    command -v cpupower >/dev/null && cpupower frequency-set -g "$ORIG_CPU_GOVERNOR" >/dev/null 2>&1 || true
fi

step "restore transparent hugepages to '$ORIG_THP'"
if [[ -n "${ORIG_THP:-}" && -w /sys/kernel/mm/transparent_hugepage/enabled ]]; then
    echo "$ORIG_THP" > /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || true
fi

echo
echo "host adjustments reverted."
echo "ext4 volumes left in place; delete the partitions / wipefs them manually if unwanted."
