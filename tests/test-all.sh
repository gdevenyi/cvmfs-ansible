#!/usr/bin/env bash
# test-all.sh — Run the full create → apply → verify → teardown cycle for
# every supported target, sequentially.
#
# Usage:
#   ./tests/test-all.sh
#   TARGETS='ubuntu:22.04 debian:13' ./tests/test-all.sh
#   KEEP_ON_FAILURE=1 ./tests/test-all.sh        # leave the broken VM up
#   CONTINUE_ON_ERROR=1 ./tests/test-all.sh      # don't stop at first failure
#   SKIP_TEARDOWN=1 ./tests/test-all.sh           # leave all VMs up
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=tests/lib.sh
source "${SCRIPT_DIR}/lib.sh"

# shellcheck disable=SC2206  # intentional word-split on whitespace-separated list
TARGET_LIST=(${TARGETS:-${TARGETS_ALL[*]}})
KEEP_ON_FAILURE="${KEEP_ON_FAILURE:-0}"
CONTINUE_ON_ERROR="${CONTINUE_ON_ERROR:-0}"
SKIP_TEARDOWN="${SKIP_TEARDOWN:-0}"

CURRENT_VM_NAME=''
declare -a PASSED=()
declare -a FAILED=()

cleanup_current_vm() {
    local keep="${1:-0}"
    [[ -n "$CURRENT_VM_NAME" ]] || return 0

    if [[ "$SKIP_TEARDOWN" == "1" ]]; then
        log_warn "Skipping teardown for ${CURRENT_VM_NAME} (SKIP_TEARDOWN=1)"
        CURRENT_VM_NAME=''
        return 0
    fi

    if [[ "$keep" == "1" ]]; then
        log_warn "Skipping teardown for ${CURRENT_VM_NAME} (KEEP_ON_FAILURE=1)"
        CURRENT_VM_NAME=''
        return 0
    fi

    log_info "Tearing down ${CURRENT_VM_NAME}..."
    "${SCRIPT_DIR}/teardown-vm.sh" "$CURRENT_VM_NAME" || true
    CURRENT_VM_NAME=''
}

on_exit() {
    local rc=$?
    # If we exit non-zero with a VM still tracked, an unexpected failure
    # (set -e, signal, etc.) interrupted us; honour KEEP_ON_FAILURE.
    if (( rc != 0 )) && [[ -n "$CURRENT_VM_NAME" ]]; then
        cleanup_current_vm "$KEEP_ON_FAILURE"
    fi
}
trap on_exit EXIT

run_one_target() {
    local target="$1"
    local vm_name vm_ip ssh_user ssh_key_file

    resolve_target "$target"
    vm_name="$RESOLVED_VM_NAME"
    vm_ip="$RESOLVED_VM_IP"
    ssh_user="$RESOLVED_SSH_USER"
    ssh_key_file="$(runtime_dir_for_vm "$vm_name")/id_ed25519"

    printf '\n'
    log_info "================================================================"
    log_info " ${target}: ${vm_name} @ ${vm_ip} (ssh: ${ssh_user})"
    log_info "================================================================"

    CURRENT_VM_NAME="$vm_name"

    if ! TARGET="$target" "${SCRIPT_DIR}/create-vm.sh"; then
        log_error "create-vm.sh failed for ${target}"
        return 1
    fi

    log_info "Applying site.yml against ${vm_ip}..."
    # </dev/null: ansible-playbook insists on blocking stdin and aborts with
    # "Non-blocking file handles detected" when test-all.sh is run from a
    # non-tty parent (CI pipeline, & background shell, captured stdin, etc.).
    if ! ansible-playbook \
            -i "${vm_ip}," \
            -u "$ssh_user" \
            --private-key "$ssh_key_file" \
            "${REPO_DIR}/site.yml" </dev/null; then
        log_error "ansible-playbook failed for ${target}"
        return 1
    fi

    log_info "Verifying ${target}..."
    if ! VM_NAME="$vm_name" SSH_KEY_FILE="$ssh_key_file" \
            "${SCRIPT_DIR}/test-vm.sh" "$vm_ip" "$ssh_user"; then
        log_error "test-vm.sh failed for ${target}"
        return 1
    fi

    cleanup_current_vm 0
    return 0
}

log_info "Multi-target test plan: ${TARGET_LIST[*]}"
log_info "KEEP_ON_FAILURE=${KEEP_ON_FAILURE} CONTINUE_ON_ERROR=${CONTINUE_ON_ERROR} SKIP_TEARDOWN=${SKIP_TEARDOWN}"

for target in "${TARGET_LIST[@]}"; do
    if run_one_target "$target"; then
        PASSED+=("$target")
    else
        FAILED+=("$target")
        cleanup_current_vm "$KEEP_ON_FAILURE"
        if [[ "$CONTINUE_ON_ERROR" != "1" ]]; then
            log_error "Aborting after ${target} (set CONTINUE_ON_ERROR=1 to keep going)."
            break
        fi
    fi
done

printf '\n========================================\n'
printf ' Multi-target Results\n'
printf '========================================\n'
printf '  Passed: %d (%s)\n' "${#PASSED[@]}" "${PASSED[*]:-none}"
printf '  Failed: %d (%s)\n' "${#FAILED[@]}" "${FAILED[*]:-none}"
printf '========================================\n'

if (( ${#FAILED[@]} > 0 )); then
    exit 1
fi
