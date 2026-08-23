#!/usr/bin/env bash
# tests/lib.sh - Shared helpers for the libvirt-based CVMFS test harness.
#
# Provides ANSI colors, logging helpers, state-file helpers, SSH wrappers,
# and optional failure diagnostics.
#
# This file is sourced, not executed. Do not set shell options here; the
# caller owns error handling.

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

DEFAULT_VM_NAME='cvmfs-test'

# Supported targets. Source of truth for the test harness.
# Format: <distro>:<version>. Add a new entry here AND extend
# resolve_target() below.
TARGETS_ALL=(
    ubuntu:22.04 ubuntu:24.04 ubuntu:26.04
    debian:11    debian:12    debian:13
)
# shellcheck disable=SC2034  # consumed by scripts that source this file
DEFAULT_TARGET='ubuntu:26.04'

log_info()  { printf '%b[INFO]%b %s\n'  "$GREEN"  "$NC" "$*"; }
log_warn()  { printf '%b[WARN]%b %s\n'  "$YELLOW" "$NC" "$*" >&2; }
log_error() { printf '%b[ERROR]%b %s\n' "$RED"    "$NC" "$*" >&2; }
die()       { log_error "$*"; exit 1; }

targets_all() {
    printf '%s\n' "${TARGETS_ALL[@]}"
}

# Pick an --os-variant string virt-install / libosinfo accepts. Prefer the
# exact match for the requested distro+version; fall back to a known-good
# recent variant when libosinfo on the control host predates the request.
_os_variant_for_target() {
    local distro="${1:?distro required}"
    local version="${2:?version required}"
    local candidate fallback
    case "$distro" in
        ubuntu) candidate="ubuntu${version}"; fallback='ubuntu24.04' ;;
        debian) candidate="debian${version}"; fallback='debian12'    ;;
        *)      die "Unsupported distro for --os-variant: '${distro}'" ;;
    esac
    if command -v osinfo-query >/dev/null 2>&1; then
        if osinfo-query -f short-id os 2>/dev/null | awk '{print $1}' | grep -qx "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    fi
    printf '%s\n' "$fallback"
}

# resolve_target <distro:version>
#
# Populates RESOLVED_* globals describing every per-target field the harness
# needs: distro, version, VM name, default IP, cloud image URL, base image
# cache path, libvirt --os-variant, and cloud-init SSH user. Aborts on
# unknown targets so a typo at the CLI does not silently target the wrong
# image.
#
# The RESOLVED_* assignments look "unused" to shellcheck because callers
# pick them up after sourcing this file.
# shellcheck disable=SC2034
resolve_target() {
    local target="${1:?target required (e.g. ubuntu:22.04)}"
    local distro="${target%%:*}"
    local version="${target##*:}"
    [[ "$distro" != "$target" && -n "$version" ]] \
        || die "Malformed target '${target}' (expected distro:version, e.g. ubuntu:22.04)"

    local ver_dashed="${version//./-}"
    local codename

    case "$target" in
        ubuntu:22.04) RESOLVED_VM_IP='192.168.122.22' ;;
        ubuntu:24.04) RESOLVED_VM_IP='192.168.122.24' ;;
        ubuntu:26.04) RESOLVED_VM_IP='192.168.122.26' ;;
        debian:11)    RESOLVED_VM_IP='192.168.122.31'; codename=bullseye ;;
        debian:12)    RESOLVED_VM_IP='192.168.122.32'; codename=bookworm ;;
        debian:13)    RESOLVED_VM_IP='192.168.122.33'; codename=trixie   ;;
        *)
            die "Unsupported target: '${target}' (supported: ${TARGETS_ALL[*]})"
            ;;
    esac

    RESOLVED_TARGET="$target"
    RESOLVED_DISTRO="$distro"
    RESOLVED_VERSION="$version"
    RESOLVED_VM_NAME="${DEFAULT_VM_NAME}-${distro}-${ver_dashed}"
    RESOLVED_VM_BASE_IMAGE="/var/lib/libvirt/images/${distro}-${version}-base.qcow2"
    RESOLVED_VM_OS_VARIANT="$(_os_variant_for_target "$distro" "$version")"
    # Debian 13 generic image has no BIOS bootloader and only boots under
    # UEFI; every other supported target boots fine on SeaBIOS.
    RESOLVED_VM_FIRMWARE='bios'
    [[ "$target" == 'debian:13' ]] && RESOLVED_VM_FIRMWARE='uefi'

    case "$distro" in
        ubuntu)
            RESOLVED_VM_IMAGE_URL="https://cloud-images.ubuntu.com/releases/${version}/release/ubuntu-${version}-server-cloudimg-amd64.img"
            RESOLVED_SSH_USER='ubuntu'
            ;;
        debian)
            # `generic` variant ships cloud-init enabled and standard
            # kernel; `nocloud` has no cloud-init installed and
            # `genericcloud` ships cloud-init disabled. Generic is the
            # only one that reads our NoCloud cidata seed and creates
            # the `debian` user we ssh in as.
            RESOLVED_VM_IMAGE_URL="https://cloud.debian.org/images/cloud/${codename}/latest/debian-${version}-generic-amd64.qcow2"
            RESOLVED_SSH_USER='debian'
            ;;
    esac
}

runtime_dir_for_vm() {
    local vm_name="${1:?vm name required}"
    printf '%s/cvmfs-setup/%s\n' "${TMPDIR:-/tmp}" "$vm_name"
}

print_ssh_hint() {
    local host="${1:?host required}"
    local ssh_user="${2:?ssh user required}"
    local ssh_key="${3:?ssh key required}"

    log_info "Interactive SSH:"
    printf '  ssh -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \\\n'
    printf '    -i "%s" %s@%s\n' "$ssh_key" "$ssh_user" "$host"
}

state_file_for_vm() {
    local vm_name="${1:-${VM_NAME:-$DEFAULT_VM_NAME}}"
    printf '%s/state.env\n' "$(runtime_dir_for_vm "$vm_name")"
}

load_vm_state() {
    local vm_name="${1:-${VM_NAME:-$DEFAULT_VM_NAME}}"
    local state_file="${2:-$(state_file_for_vm "$vm_name")}"

    [[ -f "$state_file" ]] || return 1

    # shellcheck disable=SC1090
    source "$state_file"
}

SSH_OPTS=(
    -o StrictHostKeyChecking=no
    -o UserKnownHostsFile=/dev/null
    -o ConnectTimeout=10
    -o IdentitiesOnly=yes
    -o LogLevel=ERROR
)

ssh_host() {
    local host="${1:?host required}"
    shift

    local ssh_user="${SSH_USER:-ubuntu}"
    local ssh_key="${SSH_KEY_FILE:-}"
    local -a opts=("${SSH_OPTS[@]}")

    if [[ -n "$ssh_key" ]]; then
        opts+=(-i "$ssh_key")
    fi

    # shellcheck disable=SC2029  # remote command intentionally expands on the local side
    ssh "${opts[@]}" "${ssh_user}@${host}" "$@"
}

ssh_host_bash() {
    local host="${1:?host required}"
    shift
    local cmd="$*"
    local quoted_cmd

    printf -v quoted_cmd '%q' "$cmd"
    ssh_host "$host" "bash -lc ${quoted_cmd}"
}

diag_dump_vm() {
    [[ "${TEST_DIAG:-0}" == "1" ]] || return 0

    local host="${1:?host required}"
    local label="${2:?label required}"
    local stamp log

    stamp="$(date +%Y%m%d-%H%M%S)"
    log="${TEST_DIAG_LOG:-${TMPDIR:-/tmp}/cvmfs-test-diag-${stamp}.log}"
    export TEST_DIAG_LOG="$log"

    {
        printf '\n===== %s @ %s =====\n' "$label" "$stamp"
        printf '\n--- system ---\n'
        ssh_host "$host" "hostname; uname -a; id"

        printf '\n--- autofs ---\n'
        ssh_host "$host" "sudo systemctl status autofs --no-pager -l || true"

        printf '\n--- cvmfs checks ---\n'
        ssh_host "$host" "sudo cvmfs_config chksetup || true"
        ssh_host "$host" "sudo cvmfs_config probe soft.computecanada.ca || true"
        ssh_host "$host" "sudo cvmfs_config probe neurodesk.ardc.edu.au || true"

        printf '\n--- cvmfs stat ---\n'
        ssh_host "$host" "cvmfs_config stat -v soft.computecanada.ca || true"
        ssh_host "$host" "cvmfs_config stat -v neurodesk.ardc.edu.au || true"

        printf '\n--- mounts ---\n'
        ssh_host "$host" "mount | grep cvmfs || true"

        printf '\n--- module avail ---\n'
        ssh_host "$host" "bash -lc 'module avail 2>&1 || true'"

        printf '\n--- lmod config / spider cache ---\n'
        ssh_host "$host" "bash -lc 'module --config 2>&1 || true'"
        ssh_host "$host" "ls -l /var/cache/lmod 2>&1 || true"
        ssh_host "$host" "sudo systemctl status lmod-spider-cache.timer --no-pager -l || true"
    } >> "$log" 2>&1

    log_warn "Wrote diagnostics to ${log}"
}
