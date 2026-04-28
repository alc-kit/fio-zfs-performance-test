#!/usr/bin/env bash
# Install everything the Linux-VM test framework needs into a fresh Ubuntu VM.
# Idempotent. Runs apt update once, then installs the toolchain. Safe to re-run.
#
# What gets installed and why
# ---------------------------
#   fio              the benchmark engine itself
#   sysstat          iostat + mpstat for monitor.sh (matches the host-side framework)
#   util-linux       lsblk + findmnt + blkid (usually present already on Ubuntu Server)
#   nvme-cli         nvme list / nvme id-ctrl for env snapshots
#   linux-tools-generic  cpupower (CPU governor); needed to set 'performance' governor
#   procps           vmstat (preinstalled but listed for clarity)
#   coreutils        date, awk, sort, etc. (preinstalled)
#   bsdmainutils     column for pretty-printing in summaries
#   jq               JSON post-processing of fio.json (handy for analysis)
#   python3          fio.out -> fio.json splitter (run-suite.sh uses it)
#   uuid-runtime     uuidgen for generating mount-tag IDs (optional)
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "error: must be run as root (apt + cpupower require it)" >&2
    exit 1
fi

if ! command -v apt >/dev/null; then
    echo "error: this script targets Ubuntu / Debian (apt not found)" >&2
    exit 1
fi

PACKAGES=(
    fio
    sysstat
    util-linux
    nvme-cli
    linux-tools-generic
    procps
    coreutils
    bsdmainutils
    jq
    python3
    uuid-runtime
)

echo "[$(date +%H:%M:%S)] apt update"
apt-get update -qq

echo "[$(date +%H:%M:%S)] installing prerequisites: ${PACKAGES[*]}"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${PACKAGES[@]}"

# Enable sysstat collection (Ubuntu installs it disabled by default)
if [[ -f /etc/default/sysstat ]]; then
    sed -i 's/^ENABLED="false"/ENABLED="true"/' /etc/default/sysstat || true
    systemctl enable --now sysstat 2>/dev/null || true
fi

echo
echo "=== installed versions ==="
fio --version 2>/dev/null && fio_ok=yes
echo
iostat -V 2>/dev/null | head -1 && iostat_ok=yes
mpstat -V 2>/dev/null | head -1
vmstat -V 2>/dev/null | head -1
nvme version 2>/dev/null
jq --version 2>/dev/null
python3 --version 2>/dev/null

echo
echo "all prerequisites installed."
echo "next: bin/prepare-test-volumes.sh"
