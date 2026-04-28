#!/usr/bin/env bash
# Prepare three ext4 test volumes inside an Ubuntu VM, matching the SQL Server
# best-practice layout (data / log / tempdb on dedicated spindles) and the
# parallel layout used by the Windows VM tests in win/.
#
# Idempotent. Operates only on raw (un-partitioned, un-mounted) disks no larger
# than $MAX_DISK_GIB so the OS disk and any existing test volumes are never
# touched. Picks the first three matching disks by name. Formats them as ext4
# with default block size and labels SQL-Data / SQL-Log / SQL-Tempdb. Mounts
# them at /mnt/sql-data, /mnt/sql-log, /mnt/sql-tempdb with noatime,nodiratime
# (Linux equivalent of Windows' DisableLastAccess).
#
# Also applies host-level adjustments that real production Linux SQL Server
# installs typically apply:
#   1. CPU governor -> performance (no clock down-throttling under load)
#   2. noatime mount option (avoids one write per read)
#   3. transparent hugepages disabled (matches mssql-server install guide)
#
# Original state is captured to /var/lib/fio-test/saved-state for revert.
set -euo pipefail

MAX_DISK_GIB=${MAX_DISK_GIB:-150}
FORCE=${FORCE:-0}

if [[ $EUID -ne 0 ]]; then
    echo "error: must be run as root" >&2
    exit 1
fi

step()  { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
skip()  { printf '[%s] (skip) %s\n' "$(date +%H:%M:%S)" "$*"; }
die()   { printf '[%s] error: %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

# --- 1. Identify candidate disks --------------------------------------
# A "candidate" is a block device that is type=disk, not currently mounted, has
# no partitions or filesystem on the whole-disk node, and is at most
# $MAX_DISK_GIB in size.
candidates=()
while IFS= read -r dev; do
    [[ -z "$dev" ]] && continue
    dev="/dev/$dev"
    # skip if has any partitions
    parts=$(lsblk -nlpo NAME,TYPE "$dev" 2>/dev/null | awk '$2=="part"' | wc -l)
    [[ $parts -gt 0 ]] && continue
    # skip if mounted (or any child is)
    mounted=$(lsblk -nlpo MOUNTPOINT "$dev" 2>/dev/null | awk 'NF' | wc -l)
    [[ $mounted -gt 0 ]] && continue
    # skip if has a filesystem on the whole disk already
    fst=$(lsblk -ndo FSTYPE "$dev" 2>/dev/null | awk 'NF')
    [[ -n "$fst" ]] && continue
    # size check
    size_b=$(lsblk -ndbo SIZE "$dev")
    size_gib=$(( size_b / 1024 / 1024 / 1024 ))
    (( size_gib <= MAX_DISK_GIB )) || continue
    candidates+=("$dev")
done < <(lsblk -ndo NAME,TYPE | awk '$2=="disk"{print $1}' | sort)

if [[ ${#candidates[@]} -lt 3 ]]; then
    echo "warning: found only ${#candidates[@]} unprepared raw disk(s); need 3"
    echo "current disk layout:"
    lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT
fi

# --- 2. Layout: role -> mount + label ---------------------------------
declare -a roles=( data log tempdb )
declare -A mount_for=( [data]=/mnt/sql-data [log]=/mnt/sql-log [tempdb]=/mnt/sql-tempdb )
declare -A label_for=( [data]=SQL-Data [log]=SQL-Log [tempdb]=SQL-Tempdb )

# --- 3. Capture original state for later revert -----------------------
state_dir=/var/lib/fio-test
mkdir -p "$state_dir"
state_file="$state_dir/saved-state"

if [[ ! -f "$state_file" ]]; then
    step "capturing original host state -> $state_file"
    {
        echo "TIMESTAMP=$(date -u --iso-8601=seconds)"
        # CPU governor of cpu0 (representative)
        if [[ -r /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]]; then
            echo "ORIG_CPU_GOVERNOR=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
        else
            echo "ORIG_CPU_GOVERNOR="
        fi
        # transparent hugepages
        if [[ -r /sys/kernel/mm/transparent_hugepage/enabled ]]; then
            echo "ORIG_THP=$(cat /sys/kernel/mm/transparent_hugepage/enabled | grep -oP '\[\K[^\]]+')"
        else
            echo "ORIG_THP="
        fi
        # snapshot fstab lines for revert (we will append new lines but record the
        # baseline so we know exactly which lines to remove)
        echo "ORIG_FSTAB_HASH=$(sha256sum /etc/fstab | awk '{print $1}')"
    } > "$state_file"
    cp /etc/fstab "$state_dir/fstab.orig"
else
    skip "$state_file already exists; preserving original captured state."
fi

# --- 4. Prepare each volume -------------------------------------------
prepared=0
for role in "${roles[@]}"; do
    mp="${mount_for[$role]}"
    label="${label_for[$role]}"
    role_path="$mp/fio-test"

    # already mounted with NTFS-equivalent? In our case ext4
    if findmnt -nro TARGET,FSTYPE "$mp" 2>/dev/null | grep -q "ext4"; then
        skip "$mp already mounted (ext4); ensuring $role_path exists"
        mkdir -p "$role_path"
        prepared=$((prepared + 1))
        continue
    fi

    if [[ ${#candidates[@]} -eq 0 ]]; then
        die "no remaining raw disks to assign to role '$role' ($mp)"
    fi

    disk="${candidates[0]}"
    candidates=("${candidates[@]:1}")
    size_gib=$(( $(lsblk -ndbo SIZE "$disk") / 1024 / 1024 / 1024 ))

    if [[ "$FORCE" != "1" ]]; then
        read -r -p "Format $disk (${size_gib} GiB) as ext4, mount as $mp for role '$role'? [y/N] " ans
        [[ "$ans" =~ ^[Yy]$ ]] || die "aborted at $disk"
    fi

    step "mkfs.ext4 -L $label -F $disk"
    mkfs.ext4 -L "$label" -F "$disk" >/dev/null

    uuid=$(blkid -s UUID -o value "$disk")
    [[ -n "$uuid" ]] || die "blkid returned empty UUID for $disk"

    step "mkdir $mp + add fstab entry (UUID=$uuid)"
    mkdir -p "$mp"
    # Append-only addition to fstab; revert will remove these lines
    if ! grep -q "^UUID=$uuid " /etc/fstab; then
        printf 'UUID=%s %s ext4 noatime,nodiratime,errors=remount-ro 0 2  # fio-test %s\n' \
            "$uuid" "$mp" "$role" >> /etc/fstab
    fi

    step "mount $mp"
    mount "$mp"
    mkdir -p "$role_path"
    prepared=$((prepared + 1))
done

if [[ $prepared -lt 3 ]]; then
    die "only $prepared of 3 required volumes are present"
fi

# --- 5. Host-level adjustments ----------------------------------------
step "set CPU governor to 'performance'"
for cpu in /sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_governor; do
    [[ -w "$cpu" ]] && echo performance > "$cpu" 2>/dev/null || true
done
# Also try cpupower in case the sysfs writes are restricted
command -v cpupower >/dev/null && cpupower frequency-set -g performance >/dev/null 2>&1 || true

step "disable transparent hugepages"
if [[ -w /sys/kernel/mm/transparent_hugepage/enabled ]]; then
    echo never > /sys/kernel/mm/transparent_hugepage/enabled
fi
if [[ -w /sys/kernel/mm/transparent_hugepage/defrag ]]; then
    echo never > /sys/kernel/mm/transparent_hugepage/defrag
fi

# --- 6. Summary -------------------------------------------------------
echo
echo "=== volumes ready ==="
findmnt -no TARGET,SOURCE,FSTYPE,OPTIONS /mnt/sql-data /mnt/sql-log /mnt/sql-tempdb 2>/dev/null
echo
echo "=== saved state ==="
echo "  $state_file"
echo "  /var/lib/fio-test/fstab.orig (original /etc/fstab)"
echo "  use bin/reset-test-volumes.sh to revert host adjustments"
echo
echo "ready: /mnt/sql-data, /mnt/sql-log, /mnt/sql-tempdb"
