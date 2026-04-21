#!/usr/bin/env bash
# Destroy all test datasets under $TEST_ROOT and the test zvol if it exists.
# Destructive; gated behind confirmation.
set -euo pipefail
source "$(dirname "$0")/../lib/common.sh"

require_root
require_cmd zfs

: "${ZVOL_NAME:=fio-test-vol}"
zvol_path="${ZFS_POOL}/${ZVOL_NAME}"

something_to_do=0
if dataset_exists "$TEST_ROOT"; then
    log "will destroy dataset tree: $TEST_ROOT"
    zfs list -r -o name,used "$TEST_ROOT" || true
    something_to_do=1
fi
if dataset_exists "$zvol_path"; then
    log "will destroy zvol: $zvol_path"
    zfs list -o name,used,volsize "$zvol_path" || true
    something_to_do=1
fi

if [[ $something_to_do -eq 0 ]]; then
    log "nothing to clean"
    exit 0
fi

confirm "proceed with destruction?" || { log "aborted"; exit 1; }

if dataset_exists "$TEST_ROOT"; then
    zfs destroy -r "$TEST_ROOT"
    log "destroyed $TEST_ROOT"
fi
if dataset_exists "$zvol_path"; then
    zfs destroy "$zvol_path"
    log "destroyed $zvol_path"
fi
