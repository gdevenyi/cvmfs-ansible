#!/usr/bin/env bash
# test-single.sh — Full create → apply → verify → teardown cycle for one target.
#
# Usage:
#   ./tests/test-single.sh
#   TARGET=debian:12 ./tests/test-single.sh
#   KEEP_ON_FAILURE=1 ./tests/test-single.sh
#   SKIP_TEARDOWN=1 ./tests/test-single.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib.sh
source "${SCRIPT_DIR}/lib.sh"

TARGET="${TARGET:-$DEFAULT_TARGET}"
KEEP_ON_FAILURE="${KEEP_ON_FAILURE:-0}"
SKIP_TEARDOWN="${SKIP_TEARDOWN:-0}"

resolve_target "$TARGET"

vm_name="$RESOLVED_VM_NAME"
vm_ip="$RESOLVED_VM_IP"
ssh_user="$RESOLVED_SSH_USER"
ssh_key_file="$(runtime_dir_for_vm "$vm_name")/id_ed25519"

can_offer_ssh() {
    [[ -f "$ssh_key_file" ]] || return 1
    virsh dominfo "$vm_name" >/dev/null 2>&1
}

tear_down() {
    local keep="${1:-0}"
    if [[ "$SKIP_TEARDOWN" == "1" ]]; then
        log_warn "Skipping teardown for ${vm_name} (SKIP_TEARDOWN=1)"
        if can_offer_ssh; then
            log_info "SSH key preserved at ${ssh_key_file}"
            print_ssh_hint "$vm_ip" "$ssh_user" "$ssh_key_file"
        fi
        return 0
    fi
    if [[ "$keep" == "1" ]]; then
        log_warn "Skipping teardown for ${vm_name} (KEEP_ON_FAILURE=1)"
        if can_offer_ssh; then
            log_info "SSH key preserved at ${ssh_key_file}"
            print_ssh_hint "$vm_ip" "$ssh_user" "$ssh_key_file"
        fi
        return 0
    fi
    log_info "Tearing down ${vm_name}..."
    "${SCRIPT_DIR}/teardown-vm.sh" "$vm_name" || true
}

on_exit() {
    local rc=$?
    if (( rc != 0 )); then
        tear_down "$KEEP_ON_FAILURE"
    fi
}
trap on_exit EXIT

log_info "=== CVMFS Single-Target Test (${TARGET}) ==="
log_info "  VM:   ${vm_name}"
log_info "  IP:   ${vm_ip}"
log_info "  User: ${ssh_user}"
printf '\n'

log_info ">>> Creating VM..."
if ! TARGET="$TARGET" "${SCRIPT_DIR}/create-vm.sh"; then
    log_error "create-vm.sh failed"
    exit 1
fi

log_info ">>> Applying site.yml..."
if ! ansible-playbook \
        -i "${vm_ip}," \
        -u "$ssh_user" \
        --private-key "$ssh_key_file" \
        "${REPO_DIR}/site.yml" </dev/null; then
    log_error "ansible-playbook failed"
    exit 1
fi

log_info ">>> Running verification..."
if ! VM_NAME="$vm_name" SSH_KEY_FILE="$ssh_key_file" \
        "${SCRIPT_DIR}/test-vm.sh" "$vm_ip" "$ssh_user"; then
    log_error "Verification failed"
    tear_down "$KEEP_ON_FAILURE"
    trap - EXIT
    exit 1
fi

tear_down 0
trap - EXIT

printf '\n'
log_info "=== PASSED: ${TARGET} ==="
