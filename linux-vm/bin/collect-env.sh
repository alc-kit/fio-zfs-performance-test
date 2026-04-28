#!/usr/bin/env bash
# Snapshot the state of an Ubuntu VM that influences fio benchmark results.
# Mirrors bin/collect-env.sh on the host side and win/Collect-Env.ps1 on the
# Windows-VM side. Output goes to $1 (a directory).
set -euo pipefail

out="${1:?usage: collect-env.sh <output-dir>}"
mkdir -p "$out"

section() {
    local file="$1" title="$2"
    shift 2
    {
        echo "=== $title ==="
        "$@" 2>&1 || true
        echo
    } >> "$out/$file"
}

# system.txt
section system.txt 'date'                  date -u --iso-8601=seconds
section system.txt 'hostname'              hostname
section system.txt 'uname -a'              uname -a
section system.txt 'os release'            cat /etc/os-release
section system.txt 'cpu'                   lscpu
section system.txt 'memory'                free -h
section system.txt 'meminfo (head)'        head -20 /proc/meminfo
section system.txt 'kernel cmdline'        cat /proc/cmdline
section system.txt 'virt detection'        bash -c 'systemd-detect-virt 2>/dev/null || echo "(systemd-detect-virt missing)"'
section system.txt 'dmidecode (vendor)'    bash -c 'command -v dmidecode >/dev/null && dmidecode -s system-manufacturer 2>/dev/null && dmidecode -s system-product-name 2>/dev/null || echo "(dmidecode missing)"'

# storage.txt
section storage.txt 'lsblk'                lsblk -o NAME,SIZE,ROTA,TYPE,FSTYPE,MOUNTPOINT,MODEL,SERIAL
section storage.txt 'mounts (test paths)' findmnt -no TARGET,SOURCE,FSTYPE,OPTIONS /mnt/sql-data /mnt/sql-log /mnt/sql-tempdb
section storage.txt 'free -hT (test paths)' bash -c 'df -hT /mnt/sql-data /mnt/sql-log /mnt/sql-tempdb 2>/dev/null'
section storage.txt 'ext4 features'        bash -c 'for d in /dev/sd? /dev/vd? /dev/nvme?n?; do [[ -b "$d" ]] || continue; fst=$(lsblk -ndo FSTYPE "$d" 2>/dev/null); [[ "$fst" == "ext4" ]] || continue; echo "-- $d --"; tune2fs -l "$d" 2>/dev/null | head -40; done'
section storage.txt 'block scheduler'      bash -c 'for q in /sys/block/*/queue/scheduler; do printf "%-40s %s\n" "$q" "$(cat "$q")"; done'
section storage.txt 'block nr_requests'    bash -c 'for q in /sys/block/*/queue/nr_requests; do printf "%-40s %s\n" "$q" "$(cat "$q")"; done'
section storage.txt 'nvme list'            bash -c 'command -v nvme >/dev/null && nvme list 2>&1 || echo "(nvme-cli not installed)"'
section storage.txt 'pci storage devs'     bash -c 'lspci | grep -iE "scsi|nvme|sata|virtio" 2>/dev/null || true'

# kernel-tuning.txt - things that affect I/O
section kernel-tuning.txt 'transparent hugepages' bash -c 'cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null'
section kernel-tuning.txt 'cpu governor (cpu0)'   bash -c 'cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null'
section kernel-tuning.txt 'vm.swappiness'         sysctl vm.swappiness
section kernel-tuning.txt 'vm.dirty_ratio'        sysctl vm.dirty_ratio
section kernel-tuning.txt 'vm.dirty_background_ratio' sysctl vm.dirty_background_ratio
section kernel-tuning.txt 'fs.aio-max-nr'         sysctl fs.aio-max-nr
section kernel-tuning.txt 'kernel.io_uring_disabled' bash -c 'sysctl kernel.io_uring_disabled 2>/dev/null || echo "(not present; io_uring enabled by default)"'

# fio.txt
section fio.txt 'fio --version'            fio --version
section fio.txt 'fio engines (head)'       bash -c 'fio --enghelp | head -60'

# services.txt - things that can interfere
section services.txt 'failed services'      systemctl --failed --no-legend
section services.txt 'unattended-upgrades'  bash -c 'systemctl status unattended-upgrades.service --no-pager 2>/dev/null | head -20 || echo "(not installed)"'
section services.txt 'apt timer'            bash -c 'systemctl list-timers --all --no-pager 2>/dev/null | grep -E "apt|update" || echo "(no apt/update timers visible)"'

# tool-availability.txt
{
    echo "# Required: run-suite.sh aborts the run if any of these is missing."
    for tool in fio iostat vmstat lsblk findmnt blkid mkfs.ext4 mount umount; do
        if command -v "$tool" >/dev/null; then
            printf '  REQUIRED  OK       %-12s -> %s\n' "$tool" "$(command -v "$tool")"
        else
            printf '  REQUIRED  MISSING  %s\n' "$tool"
        fi
    done
    echo
    echo "# Optional: enriches analysis but the run proceeds without these."
    for tool in mpstat nvme jq python3 cpupower dmidecode lspci; do
        if command -v "$tool" >/dev/null; then
            printf '  OPTIONAL  OK       %-12s -> %s\n' "$tool" "$(command -v "$tool")"
        else
            printf '  OPTIONAL  MISSING  %s\n' "$tool"
        fi
    done
    echo
    echo "# Apt one-liner to install what is missing:"
    echo "#   bin/install-prerequisites.sh"
} > "$out/tool-availability.txt"

echo "[$(date +%H:%M:%S)] env snapshot: $out"
