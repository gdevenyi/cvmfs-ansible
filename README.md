# CVMFS + Lmod Setup

An Ansible-based repository for provisioning Ubuntu or Debian hosts with:

- the CVMFS client
- the Alliance software repository: `soft.computecanada.ca`
- the Neurodesk repository: `neurodesk.ardc.edu.au`
- Lmod integration so both repositories are available through `module`

Supported targets: **Ubuntu 22.04 / 24.04 / 26.04** and
**Debian 11 / 12 / 13** (the playbook fails fast on anything else). The
libvirt-based test harness can validate all six in a single sequential run.

This repository is intentionally small: the main deliverable is `site.yml`, supported by Jinja templates, shared variables, and a libvirt-based test harness.

## What This Configures

On a supported Ubuntu or Debian host, the playbook:

1. installs prerequisite packages (`fuse`, `autofs`, `wget`, `lsb-release`; plus `software-properties-common` on Ubuntu)
2. installs the CVMFS release package and `cvmfs`
3. configures CVMFS to use:
   - `soft.computecanada.ca`
   - `neurodesk.ardc.edu.au`
4. installs Lmod
5. installs Apptainer (required by Neurodesk container workflows) — from the upstream PPA on Ubuntu, from the upstream GitHub release `.deb` on Debian (Launchpad PPAs don't serve Debian)
6. deploys shell integration so login shells can see both module trees
7. verifies:
   - `cvmfs_config chksetup`
   - `cvmfs_config probe` for both repositories
   - both `/cvmfs/...` mount points are readable
   - `apptainer --version` succeeds

Key target files created or managed:

- `/etc/cvmfs/default.local`
- `/etc/cvmfs/config.d/neurodesk.ardc.edu.au.conf`
- `/etc/cvmfs/keys/ardc.edu.au/neurodesk.ardc.edu.au.pub`
- `/usr/share/module.sh`
- `/etc/profile.d/zz-cvmfs-modules.sh` (named to sort after `lmod.sh`)
- `/etc/bash.bashrc` (managed block)

## Repository Layout

```text
.
├── site.yml                  # main playbook
├── ansible.cfg               # ansible defaults for this repo
├── inventory                 # optional static inventory
├── requirements.yml          # ansible collection deps
├── group_vars/
│   └── all.yml               # shared configuration variables
├── templates/
│   ├── default.local.j2
│   ├── neurodesk.conf.j2
│   ├── neurodesk.key.j2
│   ├── module.sh.j2
│   └── cvmfs_modules.sh.j2
└── tests/
    ├── lib.sh                # shared logging, SSH, version resolver, diagnostics
    ├── create-vm.sh          # create libvirt VM for testing
    ├── test-vm.sh            # verify the deployment over SSH
    ├── test-all.sh           # sequential create/apply/verify/teardown for every supported target
    └── teardown-vm.sh        # destroy VM and clean up
```

## Requirements

### Control machine

Required to run the playbook:

- Ansible / `ansible-playbook`
- SSH access to the target
- a sudo-capable remote user
- the `community.general` Ansible collection (used for `modprobe`)

Install the collection if needed:

```bash
ansible-galaxy collection install -r requirements.yml
```

### Target machine

Expected target characteristics:

- Ubuntu 22.04 / 24.04 / 26.04 or Debian 11 / 12 / 13
- `apt` available
- internet access to CVMFS mirrors and package repositories
- sudo available for the connecting user

The playbook starts with a guard task that aborts on any other distribution
or release, so misuse fails immediately rather than mid-install.

### Optional local test harness requirements

To use the VM scripts under `tests/`:

- libvirt / KVM
- `virsh`
- `virt-install`
- `qemu-img`
- `cloud-localds`
- `wget`

On Ubuntu, those typically come from packages such as:

```bash
sudo apt install qemu-kvm libvirt-daemon-system libvirt-clients virtinst qemu-utils cloud-image-utils wget
```

You also need access to libvirt, usually via the `libvirt` group.

The test harness centralizes SSH behavior in `tests/lib.sh`. It deliberately uses:

- `StrictHostKeyChecking=no`
- `UserKnownHostsFile=/dev/null`
- `IdentitiesOnly=yes`

so test runs do not write host keys into the user's `~/.ssh/known_hosts`.

## Configuration

Primary configuration lives in `group_vars/all.yml`.

### Default repositories

```yaml
cvmfs_repositories:
  - soft.computecanada.ca
  - neurodesk.ardc.edu.au
```

### Main tunables

- `cvmfs_http_proxy` — defaults to `DIRECT`
- `cvmfs_client_profile` — defaults to `single`
- `cvmfs_quota_limit` — cache size in MB, defaults to `5000`
- `neurodesk_use_geoapi` — enable Neurodesk geoproximity selection
- `neurodesk_server_url` — semicolon-separated Neurodesk mirror chain

Example excerpt:

```yaml
cvmfs_http_proxy: "DIRECT"
cvmfs_client_profile: "single"
cvmfs_quota_limit: 5000
neurodesk_use_geoapi: true
```

## Usage

### 1. Syntax check

```bash
ansible-playbook site.yml --syntax-check -i localhost, -c local
```

### 2. Dry run

```bash
ansible-playbook site.yml --check -i <HOST>,
```

Notes:

- the trailing comma in `-i <HOST>,` matters for a single inline host
- `--check` is supported
- tasks that require live package installs, probes, or downloaded artifacts are intentionally skipped in check mode

### 3. Apply to a host

```bash
ansible-playbook site.yml -i <HOST>,
```

If you need to specify a user explicitly:

```bash
ansible-playbook site.yml -i <HOST>, -u ubuntu
```

If you want to use the checked-in `inventory` file, add hosts there and run:

```bash
ansible-playbook site.yml
```

## How Module Integration Works

The repository exposes both Alliance and Neurodesk module trees through
`MODULEPATH` but **does not activate anything at login**. The user opts in
explicitly with `module load <name>`. This keeps the default shell PATH and
environment clean (sourcing Alliance's profile would otherwise prepend
`/cvmfs/.../gentoo/.../usr/bin` and shadow system tools like `lesspipe`).

### Alliance

Alliance's clean Lmod entry point is `/cvmfs/soft.computecanada.ca/custom/modules`.
`/etc/profile.d/zz-cvmfs-modules.sh` prepends it to `MODULEPATH`:

```bash
MODULEPATH="/cvmfs/soft.computecanada.ca/custom/modules${MODULEPATH:+:$MODULEPATH}"
```

After that, `module avail` lists `StdEnv/2023` etc., and the user can:

```bash
module load StdEnv/2023
```

to bring in the full Alliance environment.

### Neurodesk

Neurodesk publishes one modulefile tree per application under
`/cvmfs/neurodesk.ardc.edu.au/neurodesk-modules/`, so each subdirectory
needs its own `MODULEPATH` entry. `/etc/profile.d/zz-cvmfs-modules.sh`
iterates the directory glob:

```bash
for _nd_dir in /cvmfs/neurodesk.ardc.edu.au/neurodesk-modules/*/; do
    [ -d "$_nd_dir" ] || continue
    _nd_dir="${_nd_dir%/}"
    MODULEPATH="${_nd_dir}${MODULEPATH:+:$MODULEPATH}"
done
```

### Shell startup

- `/usr/share/module.sh` dispatches to the installed Lmod init script
- `/etc/profile.d/zz-cvmfs-modules.sh` wires Alliance + Neurodesk into `MODULEPATH`
  (the `zz-` prefix forces it to sort after `lmod.sh`, which on Ubuntu 22.04
  resets `MODULEPATH` from `/etc/lmod/modulespath` and would otherwise wipe
  our additions)
- `/etc/bash.bashrc` gets a managed block to source both scripts for bash sessions

## Validation After Apply

Useful target-side commands:

```bash
cvmfs_config chksetup
cvmfs_config probe soft.computecanada.ca
cvmfs_config probe neurodesk.ardc.edu.au
ls /cvmfs/soft.computecanada.ca
ls /cvmfs/neurodesk.ardc.edu.au
bash -lc 'module avail'
```

Expected outcomes:

- `chksetup` succeeds
- both `probe` commands succeed
- both mount points list contents
- `module avail` shows Alliance modules (for example `StdEnv/2023`) and Neurodesk modules

## Local End-to-End Testing with Libvirt

The repository includes a local VM workflow to validate the playbook on a
clean Ubuntu or Debian guest. The default target is **`ubuntu:26.04`**;
any of the supported targets can be selected with `TARGET=<distro:version>`.

### Supported targets and per-target defaults

`tests/lib.sh` is the source of truth. Out of the box:

| Target         | VM name                  | VM IP            | base image cache                                  |
| -------------- | ------------------------ | ---------------- | ------------------------------------------------- |
| `ubuntu:22.04` | `cvmfs-test-ubuntu-22-04`| `192.168.122.22` | `/var/lib/libvirt/images/ubuntu-22.04-base.qcow2` |
| `ubuntu:24.04` | `cvmfs-test-ubuntu-24-04`| `192.168.122.24` | `/var/lib/libvirt/images/ubuntu-24.04-base.qcow2` |
| `ubuntu:26.04` | `cvmfs-test-ubuntu-26-04`| `192.168.122.26` | `/var/lib/libvirt/images/ubuntu-26.04-base.qcow2` |
| `debian:11`    | `cvmfs-test-debian-11`   | `192.168.122.31` | `/var/lib/libvirt/images/debian-11-base.qcow2`    |
| `debian:12`    | `cvmfs-test-debian-12`   | `192.168.122.32` | `/var/lib/libvirt/images/debian-12-base.qcow2`    |
| `debian:13`    | `cvmfs-test-debian-13`   | `192.168.122.33` | `/var/lib/libvirt/images/debian-13-base.qcow2`    |

Ubuntu VMs use the `ubuntu` cloud-init user; Debian VMs use `debian`.

### Create the VM

```bash
./tests/create-vm.sh                  # ubuntu:26.04 (default)
TARGET=ubuntu:22.04 ./tests/create-vm.sh
TARGET=debian:13    ./tests/create-vm.sh
```

Other defaults:

- vCPUs: `2`
- RAM: `4096 MB`
- disk: `20 GB`
- gateway: `192.168.122.1`

The script:

- downloads or reuses the Ubuntu cloud image at
  `/var/lib/libvirt/images/ubuntu-<version>-base.qcow2`
- creates a transient SSH key under `${TMPDIR:-/tmp}/cvmfs-setup/<vm>/`
- writes shared runtime state consumed by `tests/lib.sh` and the other test scripts
- builds a cloud-init seed ISO with static networking
- provisions the guest with `virt-install`
- waits for `cloud-init` to finish over SSH

It prints the VM IP and the transient SSH key path on success. Per-knob env
overrides (`VM_NAME`, `VM_IP`, `VM_IMAGE_URL`, `OS_VARIANT`, `BASE_IMAGE`,
`SSH_USER`) still take precedence over the per-target defaults.

### Apply the playbook to the VM

Example (default `ubuntu:26.04` VM):

```bash
ansible-playbook -i 192.168.122.26, -u ubuntu \
  --private-key "${TMPDIR:-/tmp}/cvmfs-setup/cvmfs-test-ubuntu-26-04/id_ed25519" \
  site.yml
```

For a Debian VM the user changes to `debian`, e.g.:

```bash
ansible-playbook -i 192.168.122.33, -u debian \
  --private-key "${TMPDIR:-/tmp}/cvmfs-setup/cvmfs-test-debian-13/id_ed25519" \
  site.yml
```

### Run the verifier

```bash
./tests/test-vm.sh 192.168.122.26 ubuntu
./tests/test-vm.sh 192.168.122.33 debian
```

The verifier checks:

- `cvmfs_config chksetup`
- repository probes for both CVMFS repos
- both `/cvmfs/...` mount points
- `module` availability
- Alliance visibility via `StdEnv/2023`
- Neurodesk visibility via `neurodesk.ardc.edu.au`
- presence of the expected config files

### Tear down the VM

```bash
./tests/teardown-vm.sh cvmfs-test-ubuntu-26-04
```

This removes:

- the libvirt domain
- `/var/lib/libvirt/images/<vm-name>.qcow2`
- `/var/lib/libvirt/images/<vm-name>-cidata.iso`
- `${TMPDIR:-/tmp}/cvmfs-setup/<vm-name>/`

### Run all supported targets in a row

`tests/test-all.sh` walks every supported target sequentially, running
create → apply → verify → teardown for each, and prints a final pass/fail
summary.

```bash
./tests/test-all.sh
```

Useful knobs:

- `TARGETS="ubuntu:22.04 debian:13"` — restrict the target list
- `KEEP_ON_FAILURE=1` — leave a broken VM running for inspection
- `CONTINUE_ON_ERROR=1` — don't stop on the first failed target

The orchestrator uses the target table in `tests/lib.sh` (also the source
of truth for the per-target VM name / IP / cloud image URL / SSH user).

## Idempotence Expectations

The playbook is designed to be rerunnable.

Important idempotence behavior:

- package facts gate CVMFS release bootstrap
- `cvmfs_config setup` is guarded by `creates: /etc/auto.master.d/cvmfs.autofs`
- templates only notify `Restart autofs` when content changes
- verification tasks use `changed_when: false`

A second apply on an already-configured host should ideally end with:

```text
changed=0
```

or at least no unexpected changes.

## Ansible Behavior in This Repo

`ansible.cfg` sets:

- `inventory = inventory`
- `host_key_checking = False`
- `retry_files_enabled = False`
- `stdout_callback = default`
- `callback_result_format = yaml`
- `interpreter_python = auto`
- `become = True`
- `become_method = sudo`

In practice:

- remote changes assume sudo/root access
- host key checking is disabled to make ephemeral test hosts easier to use
- callback output is YAML-formatted for readability

## Troubleshooting

### `--check` looks incomplete

Expected. This repository intentionally skips tasks in check mode that need:

- downloaded `.deb` artifacts
- installed binaries not yet present
- live CVMFS probes or mount checks

Use `--check` as a safety preview, not as a full functional validation.

### `module avail` works for Neurodesk but not Alliance

The verifier checks for `StdEnv/2023`, not the repo FQDN. That is deliberate: Alliance modules do not necessarily print `soft.computecanada.ca` in `module avail` output.

### `create-vm.sh` times out waiting for SSH

Check:

- libvirt/KVM is working
- the chosen `VM_IP` is unused on the default libvirt network
- the base image exists or can be downloaded
- your control machine user has access to libvirt

You can override VM settings, for example:

```bash
VM_NAME=my-cvmfs-test VM_IP=192.168.122.30 ./tests/create-vm.sh
TARGET=ubuntu:22.04 ./tests/create-vm.sh
TARGET=debian:13    ./tests/create-vm.sh
```

### SSH fails with “too many authentication failures”

The VM scripts already force `IdentitiesOnly=yes` when using the generated transient key. If you SSH manually, use the same option:

```bash
ssh -o IdentitiesOnly=yes -i "${TMPDIR:-/tmp}/cvmfs-setup/cvmfs-test-ubuntu-26-04/id_ed25519" ubuntu@192.168.122.26
```

### Alliance profile behaves differently for root

This repo deliberately does not source Alliance's `bash.sh` at login, so the
`UID >= 1000` guard in that script never runs and root sessions can `module
load StdEnv/2023` the same way regular users can.

## Example Workflows

### Deploy directly to a workstation

```bash
ansible-playbook site.yml --syntax-check -i localhost, -c local
ansible-playbook site.yml --check -i 10.0.0.25,
ansible-playbook site.yml -i 10.0.0.25,
```

### Validate locally before touching a real host

```bash
./tests/create-vm.sh
ansible-playbook -i 192.168.122.26, -u ubuntu \
  --private-key "${TMPDIR:-/tmp}/cvmfs-setup/cvmfs-test-ubuntu-26-04/id_ed25519" \
  site.yml
./tests/test-vm.sh 192.168.122.26 ubuntu
./tests/teardown-vm.sh cvmfs-test-ubuntu-26-04
```

### Validate on every supported target

```bash
./tests/test-all.sh
```

## Maintenance Notes

When changing this repository:

- keep `site.yml` idempotent
- keep check mode safe
- prefer Ansible modules over ad-hoc shell
- preserve the exact Neurodesk key and server chain unless intentionally updating them
- preserve the transient-key behavior in `tests/create-vm.sh`
- re-run the VM workflow for non-trivial changes
- `TEST_DIAG=1` on `tests/test-vm.sh` enables a diagnostic dump via `tests/lib.sh` when a check fails
