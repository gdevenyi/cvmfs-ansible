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
run_check "cvmfs_config probe software.eessi.io" "sudo cvmfs_config probe software.eessi.io"

printf '\n%s\n' '--- CVMFS Mount Points ---'
run_check "/cvmfs/soft.computecanada.ca is accessible" "ls /cvmfs/soft.computecanada.ca"
run_check "/cvmfs/neurodesk.ardc.edu.au is accessible" "ls /cvmfs/neurodesk.ardc.edu.au"
run_check "/cvmfs/software.eessi.io is accessible" "ls /cvmfs/software.eessi.io"

# shellcheck disable=SC2016  # $ID/$VERSION_ID must expand on the target, not here
os_id="$(ssh_host_bash "$HOST" '. /etc/os-release; printf "%s:%s" "$ID" "$VERSION_ID"' 2>/dev/null || true)"

printf '\n%s\n' '--- Module System ---'
run_check "module command is available" "type module"
run_check "Alliance modules visible (StdEnv/2023)" "module avail 2>&1 | grep -q 'StdEnv/2023'"
run_check "Neurodesk modules visible (neurodesk.ardc.edu.au)" "module avail 2>&1 | grep -q neurodesk.ardc.edu.au"
# EESSI's modulefile needs Lmod >= 8.6, so the playbook leaves its tree off
# MODULEPATH on the Lmod 6.6 targets. Users there init EESSI's own Lmod
# instead: source /cvmfs/software.eessi.io/versions/<version>/init/lmod/bash
case "$os_id" in
    ubuntu:22.04 | debian:11)
        printf '  %-60s %bSKIP%b\n' "EESSI modules (needs Lmod 8.6, ${os_id} has 6.6)" "$YELLOW" "$NC"
        run_check "EESSI tree is kept off MODULEPATH" "! module avail 2>&1 | grep -q 'software.eessi.io'"
        ;;
    *)
        run_check "EESSI modules visible (EESSI/)" "module avail 2>&1 | grep -q 'EESSI/'"
        ;;
esac
# Neurodesk modulefiles declare every file in every container as an Lmod
# extension; without LMOD_AVAIL_EXTENSIONS=no the listing dwarfs the modules.
run_check "module avail hides the extensions listing" "! module avail 2>&1 | grep -q 'list of module extensions'"
# The profile script must decide from /proc/mounts, never by testing a /cvmfs
# path: on an unmounted repository that test triggers an autofs mount that
# deadlocks, and every login shell then hangs. Hide /proc (and so the mount
# table) in a private mount namespace; the script must add nothing and return.
run_check "profile script skips CVMFS trees not in /proc/mounts" \
    "sudo timeout -k 3 10 unshare -m sh -c 'mount -t tmpfs none /proc; MODULEPATH=; . /etc/profile.d/zz-cvmfs-modules.sh; [ -z \"\$MODULEPATH\" ]'"

printf '\n%s\n' '--- Lmod Spider Cache ---'
# Ubuntu 22.04 and Debian 11 ship Lmod 6.6, whose cache writer emits a cache
# Lmod cannot read back; the playbook deliberately builds none there.
case "$os_id" in
    ubuntu:22.04 | debian:11)
        printf '  %-60s %bSKIP%b\n' "spider cache (Lmod 6.6 on ${os_id})" "$YELLOW" "$NC"
        run_check "no spider cache is configured" "! test -e /etc/lmod/lmodrc.lua"
        ;;
    *)
        run_check "spider cache has been built" "test -s /var/cache/lmod/spiderT.lua"
        run_check "Lmod reads the system spider cache" "module --config 2>&1 | grep -q /var/cache/lmod"
        run_check "spider cache refresh timer is enabled" "systemctl is-enabled --quiet lmod-spider-cache.timer"
        run_check "spider cache refresh timer is active" "systemctl is-active --quiet lmod-spider-cache.timer"
        run_check "a spider cache refresh succeeds" "sudo /usr/local/sbin/update-lmod-spider-cache"
        ;;
esac

printf '\n%s\n' '--- Apptainer ---'
run_check "apptainer --version succeeds" "apptainer --version"

printf '\n%s\n' '--- Configuration Files ---'
run_check "/etc/cvmfs/default.local exists" "test -f /etc/cvmfs/default.local"
run_check "Neurodesk config.d exists" "test -f /etc/cvmfs/config.d/neurodesk.ardc.edu.au.conf"
run_check "Neurodesk public key exists" "test -f /etc/cvmfs/keys/ardc.edu.au/neurodesk.ardc.edu.au.pub"
run_check "EESSI domain.d config exists" "test -f /etc/cvmfs/domain.d/eessi.io.conf"
run_check "EESSI public key exists" "test -f /etc/cvmfs/keys/eessi.io/eessi.io.pub"
run_check "/etc/profile.d/zz-cvmfs-modules.sh exists" "test -f /etc/profile.d/zz-cvmfs-modules.sh"
run_check "/usr/share/module.sh exists" "test -f /usr/share/module.sh"
# Arch's autofs is built --sysconfdir=/etc/autofs, so the master-map drop-in
# lands one directory deeper than on the Debian family. Ask the guest rather
# than matching on $ID: Arch derivatives report themselves (cachyos, manjaro)
# but lay autofs out the same way.
autofs_conf_dir="$(ssh_host_bash "$HOST" \
    'test -d /etc/autofs/auto.master.d && echo /etc/autofs || echo /etc' 2>/dev/null || echo /etc)"
run_check "${autofs_conf_dir}/auto.master.d/cvmfs.autofs exists" \
    "test -f ${autofs_conf_dir}/auto.master.d/cvmfs.autofs"
run_check "autofs is running" "systemctl is-active --quiet autofs"
run_check "CVMFS probe timer is enabled" "systemctl is-enabled --quiet cvmfs-probe.timer"
run_check "CVMFS probe timer is active" "systemctl is-active --quiet cvmfs-probe.timer"
if [[ "$os_id" != "ubuntu:22.04" && "$os_id" != "debian:11" ]]; then
    run_check "/usr/local/sbin/update-lmod-spider-cache exists" "test -x /usr/local/sbin/update-lmod-spider-cache"
    run_check "/etc/lmod/lmodrc.lua exists" "test -f /etc/lmod/lmodrc.lua"
fi

printf '\n========================================\n'
printf ' Results: %b%s passed%b, %b%s failed%b\n' "$GREEN" "$pass" "$NC" "$RED" "$fail" "$NC"
printf '========================================\n'

if [[ "$fail" -gt 0 ]]; then
    exit 1
fi
