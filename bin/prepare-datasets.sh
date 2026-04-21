#!/usr/bin/env bash
# Create the dataset tree used by the test suites. Idempotent.
#
# Two classes of datasets exist:
#
#   Production-representative — zero property customisation. Inherits exactly
#   what Proxmox itself sets when it creates a dataset on an untouched stock
#   installation. Tests against these datasets describe what a real VM on stock
#   Proxmox will actually experience.
#
#     $TEST_ROOT/default    — general-purpose production-representative dataset
#     $TEST_ROOT/endurance  — same, with a quota as a safety rail against
#                             runaway fill-the-pool jobs
#
#   Diagnostic — datasets with one property deliberately set to a non-stock
#   value. Used to explain *why* a stock property behaves as it does. Never run
#   in production; never a candidate production setting.
#
#     $TEST_ROOT/diagnostic-rs-4k         recordsize=4K
#     $TEST_ROOT/diagnostic-rs-16k        recordsize=16K
#     $TEST_ROOT/diagnostic-rs-1m         recordsize=1M
#     $TEST_ROOT/diagnostic-no-compress   compression=off
#     $TEST_ROOT/diagnostic-no-cache      primarycache=metadata (ARC bypass)
#     $TEST_ROOT/diagnostic-sync-always   sync=always
#     $TEST_ROOT/diagnostic-sync-disabled sync=disabled   (data-loss risk; diag only)
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

require_root
require_cmd zfs zpool

pool_exists "$ZFS_POOL" || die "pool '$ZFS_POOL' does not exist"

: "${TEST_QUOTA:=4T}"

ensure() {
    local ds="$1"; shift
    if dataset_exists "$ds"; then
        log "exists: $ds"
    else
        log "create: $ds $*"
        zfs create "$@" "$ds"
    fi
}

set_props() {
    local ds="$1"; shift
    for kv in "$@"; do
        zfs set "$kv" "$ds"
    done
}

# Parent. Quota is a safety rail; no property customisation.
ensure "$TEST_ROOT" -o "quota=${TEST_QUOTA}"

# --- production-representative ---
# No -o arguments; no explicit zfs set. These datasets inherit every property
# from the pool exactly as Proxmox would leave them.
ensure "$TEST_ROOT/default"
ensure "$TEST_ROOT/endurance" -o "quota=1T"

# --- diagnostic ---
# Each of these sets exactly one property to a non-default value so that its
# effect can be isolated. NEVER promoted to production.
ensure "$TEST_ROOT/diagnostic-rs-4k"
set_props "$TEST_ROOT/diagnostic-rs-4k" recordsize=4K

ensure "$TEST_ROOT/diagnostic-rs-16k"
set_props "$TEST_ROOT/diagnostic-rs-16k" recordsize=16K

ensure "$TEST_ROOT/diagnostic-rs-1m"
set_props "$TEST_ROOT/diagnostic-rs-1m" recordsize=1M

ensure "$TEST_ROOT/diagnostic-no-compress"
set_props "$TEST_ROOT/diagnostic-no-compress" compression=off

ensure "$TEST_ROOT/diagnostic-no-cache"
set_props "$TEST_ROOT/diagnostic-no-cache" primarycache=metadata

ensure "$TEST_ROOT/diagnostic-sync-always"
set_props "$TEST_ROOT/diagnostic-sync-always" sync=always

ensure "$TEST_ROOT/diagnostic-sync-disabled"
set_props "$TEST_ROOT/diagnostic-sync-disabled" sync=disabled

log "datasets ready under $TEST_ROOT"
zfs list -r -o name,used,avail,quota,recordsize,compression,primarycache,sync "$TEST_ROOT"
