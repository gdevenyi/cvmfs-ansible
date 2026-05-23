#!/usr/bin/env bash
# test-vm.sh — Verify CVMFS + Lmod setup on a target host.
#
# Usage: ./tests/test-vm.sh <HOST_IP> [SSH_USER]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
source "${SCRIPT_DIR}/lib.sh"

HOST="${1:?Usage: $0 <HOST_IP> [SSH_USER]}"
_arg_ssh_user="${2:-}"
SSH_USER="${2:-ubuntu}"
VM_NAME="${VM_NAME:-$DEFAULT_VM_NAME}"
STATE_FILE="$(state_file_for_vm "$VM_NAME")"

SSH_KEY_FILE="${SSH_KEY_FILE:-}"
if [[ -z "$SSH_KEY_FILE" ]]; then
    load_vm_state "$VM_NAME" "$STATE_FILE" || true
fi
# An explicit CLI $2 must win over whatever the state file set.
SSH_USER="${_arg_ssh_user:-$SSH_USER}"

pass=0
fail=0

run_check() {
    local desc="$1"
    shift
    local cmd="$*"

    printf "  %-60s " "$desc"
    if ssh_host_bash "$HOST" "$cmd" >/dev/null 2>&1; then
        printf "%bPASS%b\n" "$GREEN" "$NC"
        pass=$((pass + 1))
    else
        printf "%bFAIL%b\n" "$RED" "$NC"
        fail=$((fail + 1))
        diag_dump_vm "$HOST" "$desc"
    fi
}

printf '========================================\n'
printf ' CVMFS + Lmod Verification\n'
printf ' Target: %s@%s\n' "$SSH_USER" "$HOST"
printf '========================================\n\n'

printf '%s\n' '--- CVMFS Configuration ---'
run_check "cvmfs_config chksetup succeeds" "sudo cvmfs_config chksetup"
run_check "cvmfs_config probe soft.computecanada.ca" "sudo cvmfs_config probe soft.computecanada.ca"
run_check "cvmfs_config probe neurodesk.ardc.edu.au" "sudo cvmfs_config probe neurodesk.ardc.edu.au"

printf '\n%s\n' '--- CVMFS Mount Points ---'
run_check "/cvmfs/soft.computecanada.ca is accessible" "ls /cvmfs/soft.computecanada.ca"
run_check "/cvmfs/neurodesk.ardc.edu.au is accessible" "ls /cvmfs/neurodesk.ardc.edu.au"

printf '\n%s\n' '--- Module System ---'
run_check "module command is available" "type module"
run_check "Alliance modules visible (StdEnv/2023)" "module avail 2>&1 | grep -q 'StdEnv/2023'"
run_check "Neurodesk modules visible (neurodesk.ardc.edu.au)" "module avail 2>&1 | grep -q neurodesk.ardc.edu.au"

printf '\n%s\n' '--- Apptainer ---'
run_check "apptainer --version succeeds" "apptainer --version"

printf '\n%s\n' '--- Configuration Files ---'
run_check "/etc/cvmfs/default.local exists" "test -f /etc/cvmfs/default.local"
run_check "Neurodesk config.d exists" "test -f /etc/cvmfs/config.d/neurodesk.ardc.edu.au.conf"
run_check "Neurodesk public key exists" "test -f /etc/cvmfs/keys/ardc.edu.au/neurodesk.ardc.edu.au.pub"
run_check "/etc/profile.d/zz-cvmfs-modules.sh exists" "test -f /etc/profile.d/zz-cvmfs-modules.sh"
run_check "/usr/share/module.sh exists" "test -f /usr/share/module.sh"

printf '\n========================================\n'
printf ' Results: %b%s passed%b, %b%s failed%b\n' "$GREEN" "$pass" "$NC" "$RED" "$fail" "$NC"
printf '========================================\n'

if [[ "$fail" -gt 0 ]]; then
    exit 1
fi
