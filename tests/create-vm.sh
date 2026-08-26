#!/usr/bin/env bash
# create-vm.sh — Provision a libvirt VM for CVMFS testing.
#
# Creates an Ubuntu, Debian or Arch cloud-image VM on the default libvirt NAT
# network with a static IP, per-run SSH key injection, and waits for
# cloud-init.
#
# Defaults target ${DEFAULT_TARGET} (see tests/lib.sh). Pick a different
# supported target with TARGET=ubuntu:22.04 / TARGET=debian:12 / etc.
# Individual knobs (VM_NAME, VM_VCPUS, VM_MEMORY_MB, VM_DISK_GB, VM_IP,
# GATEWAY, VM_IMAGE_URL, OS_VARIANT, VM_FIRMWARE, BASE_IMAGE, SSH_USER)
# still override the per-target defaults.
#
# Usage:
#   ./tests/create-vm.sh
#   TARGET=ubuntu:22.04 ./tests/create-vm.sh
#   TARGET=debian:13    ./tests/create-vm.sh
#   TARGET=arch:rolling ./tests/create-vm.sh
set -euo pipefail
# shellcheck disable=SC2154
trap 's=$?; echo >&2 "$0: Error on line $LINENO: $BASH_COMMAND"; exit $s' ERR

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tests/lib.sh
source "${SCRIPT_DIR}/lib.sh"

TARGET="${TARGET:-$DEFAULT_TARGET}"
resolve_target "$TARGET"

VM_NAME="${VM_NAME:-$RESOLVED_VM_NAME}"
VM_VCPUS="${VM_VCPUS:-2}"
VM_MEMORY_MB="${VM_MEMORY_MB:-4096}"
VM_DISK_GB="${VM_DISK_GB:-20}"
VM_IMAGE_URL="${VM_IMAGE_URL:-$RESOLVED_VM_IMAGE_URL}"
VM_IP="${VM_IP:-$RESOLVED_VM_IP}"
GATEWAY="${GATEWAY:-192.168.122.1}"
SSH_USER="${SSH_USER:-$RESOLVED_SSH_USER}"
OS_VARIANT="${OS_VARIANT:-$RESOLVED_VM_OS_VARIANT}"
VM_FIRMWARE="${VM_FIRMWARE:-$RESOLVED_VM_FIRMWARE}"

BASE_IMAGE="${BASE_IMAGE:-$RESOLVED_VM_BASE_IMAGE}"
DISK_PATH="/var/lib/libvirt/images/${VM_NAME}.qcow2"
SEED_ISO="/var/lib/libvirt/images/${VM_NAME}-cidata.iso"
RUNTIME_DIR="$(runtime_dir_for_vm "$VM_NAME")"
STATE_FILE="$(state_file_for_vm "$VM_NAME")"
SSH_KEY_FILE="${RUNTIME_DIR}/id_ed25519"
SSH_PUB_KEY="${SSH_KEY_FILE}.pub"

check_prereqs() {
    if [[ "$EUID" -ne 0 ]] && ! id -nG "$USER" 2>/dev/null | grep -qw libvirt; then
        die "User '$USER' not in libvirt group. Run: sudo usermod -aG libvirt $USER  then log out/in"
    fi

    for cmd in virsh virt-install qemu-img wget cloud-localds ssh timeout ping ssh-keygen; do
        command -v "$cmd" >/dev/null 2>&1 || die "Missing required command: $cmd"
    done

    if virsh dominfo "$VM_NAME" >/dev/null 2>&1; then
        die "VM '${VM_NAME}' already exists. Run tests/teardown-vm.sh first."
    fi

    if ping -c 1 -W 1 "$VM_IP" >/dev/null 2>&1; then
        die "IP '${VM_IP}' already responds on the default network. Set VM_IP to a free address."
    fi
}

download_base_image() {
    if [[ -f "$BASE_IMAGE" ]]; then
        log_info "Base image cached: ${BASE_IMAGE}"
        return
    fi

    log_info "Downloading ${TARGET} cloud image (~600MB)..."
    wget --show-progress -nv -O "$BASE_IMAGE" "$VM_IMAGE_URL"
}

prepare_runtime() {
    rm -rf "$RUNTIME_DIR"
    mkdir -p "$RUNTIME_DIR"

    ssh-keygen -q -t ed25519 -f "$SSH_KEY_FILE" -N "" -C "${VM_NAME}-test"

    cat > "$STATE_FILE" <<EOF
VM_NAME='${VM_NAME}'
VM_IP='${VM_IP}'
SSH_USER='${SSH_USER}'
SSH_KEY_FILE='${SSH_KEY_FILE}'
TARGET='${TARGET}'
EOF
    chmod 600 "$STATE_FILE"

    log_info "Generated transient SSH key: ${SSH_KEY_FILE}"
}

create_seed_iso() {
    local tmp_dir ssh_key upgrade_line=''
    tmp_dir="$(mktemp -d)"
    ssh_key="$(cat "$SSH_PUB_KEY")"

    # Arch is rolling, and the images/latest/ snapshot is always some days
    # behind the mirrors. Installing onto that mismatch is the classic Arch
    # partial-upgrade failure, and it is what breaks the AUR source builds
    # the playbook runs. Bring the image current before Ansible touches it.
    # The pinned Ubuntu/Debian images have no equivalent problem.
    if [[ "${RESOLVED_DISTRO:-}" == 'arch' ]]; then
        upgrade_line='package_upgrade: true'
    fi

    cat > "${tmp_dir}/meta-data" <<EOF
instance-id: ${VM_NAME}
local-hostname: ${VM_NAME}
EOF

    cat > "${tmp_dir}/user-data" <<EOF
#cloud-config
hostname: ${VM_NAME}
fqdn: ${VM_NAME}
manage_etc_hosts: false
${upgrade_line}
users:
  - name: ${SSH_USER}
    ssh_authorized_keys:
      - ${ssh_key}
    sudo: ALL=(ALL) NOPASSWD:ALL
    shell: /bin/bash
write_files:
  - path: /etc/hosts
    content: |
      127.0.0.1 localhost
      ${VM_IP} ${VM_NAME}
    owner: root:root
    permissions: '0644'
EOF

    # Network device naming and cloud-init quirks differ per distro:
    #   - Ubuntu cloud images present as either `ens3` or `enp1s0` depending
    #     on systemd version, and render through netplan, which honors a v2
    #     `match:` block. That glob is the only form that covers both names.
    #   - Debian cloud images always present as `enp1s0`, but Debian 11's
    #     cloud-init 20.4 mistranslates v2 `match:` blocks into a literal
    #     `interface0` device name and silently fails.
    #   - Arch boots with `net.ifnames=0` (GRUB_CMDLINE_LINUX in the image),
    #     so the NIC is plain `eth0`. Arch also renders through networkd, and
    #     that renderer DROPS `match:` outright — it writes `Name=<config
    #     key>` and the unit then matches nothing, leaving the guest with no
    #     address and systemd-networkd-wait-online hung forever.
    # So only Ubuntu gets the `match:` form; everything else names the device.
    local net_device=''
    case "${RESOLVED_DISTRO:-}" in
        debian) net_device='enp1s0' ;;
        arch)   net_device='eth0'   ;;
    esac

    if [[ -n "$net_device" ]]; then
        cat > "${tmp_dir}/network-config" <<EOF
version: 2
ethernets:
  ${net_device}:
    dhcp4: false
    addresses:
      - ${VM_IP}/24
    routes:
      - to: default
        via: ${GATEWAY}
    nameservers:
      addresses:
        - ${GATEWAY}
EOF
    else
        cat > "${tmp_dir}/network-config" <<EOF
version: 2
ethernets:
  interface0:
    match:
      name: "en*"
    dhcp4: false
    addresses:
      - ${VM_IP}/24
    routes:
      - to: default
        via: ${GATEWAY}
    nameservers:
      addresses:
        - ${GATEWAY}
EOF
    fi

    rm -f "$SEED_ISO"
    cloud-localds "$SEED_ISO" "${tmp_dir}/user-data" "${tmp_dir}/meta-data" \
        --network-config "${tmp_dir}/network-config"
    rm -rf "$tmp_dir"

    log_info "Created seed ISO: ${SEED_ISO}"
}

create_vm() {
    rm -f "$DISK_PATH"
    qemu-img create -f qcow2 -b "$BASE_IMAGE" -F qcow2 "$DISK_PATH" "${VM_DISK_GB}G"

    local -a firmware_args=()
    [[ "$VM_FIRMWARE" == 'uefi' ]] && firmware_args=(--boot uefi)

    virt-install \
        --name "$VM_NAME" \
        --memory "$VM_MEMORY_MB" \
        --vcpus "$VM_VCPUS" \
        --disk "path=${DISK_PATH},bus=virtio" \
        --disk "path=${SEED_ISO},device=cdrom" \
        --network "network=default,model=virtio" \
        --os-variant "$OS_VARIANT" \
        "${firmware_args[@]}" \
        --import \
        --graphics none \
        --noautoconsole

    log_info "VM '${VM_NAME}' started."
}

wait_for_ssh() {
    local max_wait=600 per_try=20 quoted_cmd
    local -a ssh_opts=("${SSH_OPTS[@]}" -o ConnectTimeout=5 -o BatchMode=yes -i "$SSH_KEY_FILE")

    printf -v quoted_cmd '%q' 'sudo cloud-init status --wait'

    log_info "Waiting for ${VM_NAME} (${VM_IP}) to become ready..."
    SECONDS=0
    while (( SECONDS < max_wait )); do
        if timeout "$per_try" ssh "${ssh_opts[@]}" "${SSH_USER}@${VM_IP}" "bash -lc ${quoted_cmd}" >/dev/null 2>&1; then
            log_info "${VM_NAME} ready (${SECONDS}s)."
            return 0
        fi
        sleep 5
    done

    die "Timed out waiting for ${VM_NAME} after ${max_wait}s."
}

# Arch's cloud-init runs a full `pacman -Syu` (see create_seed_iso). When that
# pulls a new kernel — it usually does, the image snapshot is always a few
# weeks behind — the running kernel's /lib/modules tree is replaced by the new
# one's, so anything that consults it fails with ENOENT. Ansible's modprobe
# module reads /lib/modules/$(uname -r)/modules.builtin and dies there. Boot
# onto the kernel that is actually installed before handing the VM over.
reboot_onto_new_kernel() {
    [[ "${RESOLVED_DISTRO:-}" == 'arch' ]] || return 0

    local -a ssh_opts=("${SSH_OPTS[@]}" -o ConnectTimeout=5 -o BatchMode=yes -i "$SSH_KEY_FILE")

    log_info "Rebooting ${VM_NAME} onto the kernel cloud-init installed..."
    ssh "${ssh_opts[@]}" "${SSH_USER}@${VM_IP}" 'sudo systemctl reboot' >/dev/null 2>&1 || true

    # Wait for it to actually go down first, otherwise wait_for_ssh can
    # succeed against the host that is still shutting down.
    local waited=0
    while (( waited < 60 )) && ping -c 1 -W 1 "$VM_IP" >/dev/null 2>&1; do
        sleep 2
        waited=$((waited + 2))
    done

    wait_for_ssh
}

check_prereqs
log_info "=== CVMFS Test VM Setup (${TARGET}) ==="
printf '\n'

download_base_image
prepare_runtime
create_seed_iso
create_vm
wait_for_ssh
reboot_onto_new_kernel

printf '\n'
log_info "=== VM Ready ==="
log_info "Target:  ${TARGET}"
log_info "Name:    ${VM_NAME}"
log_info "IP:      ${VM_IP}"
log_info "SSH key: ${SSH_KEY_FILE}"
printf '\n'
log_info "Next steps:"
log_info "  ansible-playbook -i ${VM_IP}, -u ${SSH_USER} --private-key ${SSH_KEY_FILE} site.yml"
log_info "  VM_NAME=${VM_NAME} ./tests/test-vm.sh ${VM_IP} ${SSH_USER}"
printf '\n'
printf '%s\n' "$VM_IP"
