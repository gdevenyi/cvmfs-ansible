#!/usr/bin/env bash
# teardown-vm.sh — Destroy the CVMFS test VM and clean up.
#
# Usage: ./tests/teardown-vm.sh [VM_NAME]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
source "${SCRIPT_DIR}/lib.sh"

VM_NAME="${VM_NAME:-${1:-$DEFAULT_VM_NAME}}"
RUNTIME_DIR="$(runtime_dir_for_vm "$VM_NAME")"

log_info "Tearing down VM '${VM_NAME}'..."

if virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
    log_info "Destroying domain..."
    virsh destroy "$VM_NAME" >/dev/null 2>&1 || true
    log_info "Undefining domain..."
    virsh undefine "$VM_NAME" --nvram >/dev/null 2>&1 || true
else
    log_info "Domain '${VM_NAME}' not found — skipping"
fi

rm -f \
    "/var/lib/libvirt/images/${VM_NAME}.qcow2" \
    "/var/lib/libvirt/images/${VM_NAME}-cidata.iso" >/dev/null 2>&1 || true
rm -rf "$RUNTIME_DIR"

log_info "Done."
