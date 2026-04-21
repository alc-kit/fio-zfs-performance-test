#!/usr/bin/env bash
# Create the zvol that backs the production-representative SQL Server VM test.
# Idempotent.
#
# The zvol is created with ONLY the properties that Proxmox itself sets when it
# creates a VM disk on a stock `zfspool` storage entry — nothing else. The goal
# is to mirror exactly what a real VM disk looks like on this pool:
#
#   - sparse=1          (zfspool: sparse 1 in /etc/pve/storage.cfg)
#   - volblocksize=16K  (PVE 9 default; see memory/pve9_stack_facts.md)
#
# Everything else inherits from the pool. We do not set compression, logbias,
# primarycache, sync, or any other property on the zvol — stock Proxmox does not
# set these either.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

require_root
require_cmd zfs zpool

pool_exists "$ZFS_POOL" || die "pool '$ZFS_POOL' does not exist"

: "${ZVOL_NAME:=fio-test-vol}"
: "${ZVOL_SIZE:=500G}"
: "${ZVOL_VOLBLOCKSIZE:=16K}"

zvol_path="${ZFS_POOL}/${ZVOL_NAME}"
zvol_dev="/dev/zvol/${zvol_path}"

if dataset_exists "$zvol_path"; then
    log "exists: $zvol_path"
else
    log "create: zfs create -s -V $ZVOL_SIZE -b $ZVOL_VOLBLOCKSIZE $zvol_path"
    zfs create -s -V "$ZVOL_SIZE" -b "$ZVOL_VOLBLOCKSIZE" "$zvol_path"
fi

# Wait briefly for udev to publish the device node.
for _ in 1 2 3 4 5; do
    [[ -b "$zvol_dev" ]] && break
    sleep 1
done
[[ -b "$zvol_dev" ]] || die "zvol device never appeared at $zvol_dev"

log "zvol ready"
zfs list -o name,used,avail,refer,volsize,volblocksize,compression,sync "$zvol_path"
log "device node: $zvol_dev"
log ""
log "Note: nothing has been written to this zvol yet; with sparse=1 it occupies"
log "      no pool space until a test writes to it."
