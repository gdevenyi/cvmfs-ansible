# Repository Guidelines

## Project Overview

This repository provisions an Ubuntu or Debian host with:

- CVMFS client
- two CVMFS repositories:
  - `soft.computecanada.ca` (Alliance/Compute Canada software stack)
  - `neurodesk.ardc.edu.au` (Neurodesk tools and containers)
- Lmod integration so both repositories are usable through `module`

Supported targets: Ubuntu 22.04 / 24.04 / 26.04 and Debian 11 / 12 / 13.
`site.yml` asserts this up front and aborts on anything else. The libvirt
test harness is target-aware; the target table in `tests/lib.sh` is the
source of truth.

This is infrastructure-as-code, not an application repo. There is no `src/`, service runtime, or build pipeline. The main deliverable is the Ansible playbook plus a libvirt-based validation workflow.

## Architecture & Data Flow

### Provisioning flow

`site.yml` is the entry point. It applies changes in this order:

1. install OS prerequisites (`fuse3`, `autofs`, `wget`, `lsb-release`; plus `software-properties-common` on Ubuntu)
2. install CVMFS release package and `cvmfs`, then unmount any repository left
   as a dead Fuse endpoint by an earlier package upgrade so autofs remounts it
3. write CVMFS config files from Jinja templates
4. install Lmod
5. install Apptainer (needed by Neurodesk containers) — PPA on Ubuntu, upstream GitHub `.deb` on Debian
6. deploy shell integration for Alliance + Neurodesk modules
7. restart `autofs` if needed and verify mounts/probes/apptainer
8. build the Lmod spider cache for both module trees and enable the systemd
   timer that refreshes it hourly (skipped, and undone, on the Lmod 6.6
   targets Ubuntu 22.04 / Debian 11)

### Data/config flow

- `group_vars/all.yml` defines the repository-wide knobs
- `site.yml` consumes those variables
- `templates/*.j2` render target files under `/etc/cvmfs`, `/usr/share`, and `/etc/profile.d`
- `tests/lib.sh` centralizes test-harness logging, SSH options, runtime state loading, the target table / resolver, and optional diagnostics
- `tests/create-vm.sh` provisions an Ubuntu or Debian VM for validation (defaults to `ubuntu:26.04`; pick another with `TARGET=<distro:version>`)
- `tests/test-vm.sh` verifies the deployed behavior over SSH
- `tests/test-single.sh` runs the full create → apply → verify → teardown lifecycle for one target (defaults to `ubuntu:26.04`; select with `TARGET=<distro:version>`)
- `tests/test-all.sh` runs create → apply → verify → teardown sequentially for every supported target
- `tests/teardown-vm.sh` destroys the VM and removes transient state

### Important runtime paths on the target host

- `/etc/cvmfs/default.local`
- `/etc/cvmfs/config.d/neurodesk.ardc.edu.au.conf`
- `/etc/cvmfs/keys/ardc.edu.au/neurodesk.ardc.edu.au.pub`
- `/usr/share/module.sh`
- `/etc/profile.d/zz-cvmfs-modules.sh` (named so it sorts after `lmod.sh`)
- `/etc/lmod/lmodrc.lua` (`scDescriptT` pointing at the spider cache)
- `/usr/local/sbin/update-lmod-spider-cache`
- `/etc/systemd/system/lmod-spider-cache.{service,timer}`
- `/var/cache/lmod/` (spider cache + `system.txt` timestamp)
- `/etc/auto.master.d/cvmfs.autofs`
- `/cvmfs/soft.computecanada.ca`
- `/cvmfs/neurodesk.ardc.edu.au`

## Key Directories

- `site.yml` — main playbook
- `group_vars/` — shared variables; currently `group_vars/all.yml`
- `templates/` — Jinja2 templates for CVMFS and shell/module integration
- `tests/` — VM lifecycle + verification scripts, plus `tests/lib.sh` for shared harness helpers
- `ansible.cfg` — Ansible defaults for this repo
- `inventory` — placeholder inventory; single-host usage normally passes `-i <host>,`

There are no separate docs/build/source directories. Do not assume a larger application layout exists.

## Development Commands

### Core playbook

```bash
ansible-playbook site.yml -i <HOST>,
ansible-playbook site.yml --check -i <HOST>,
ansible-playbook site.yml --syntax-check -i localhost, -c local
```

Notes:

- single-host syntax requires the trailing comma in `-i <HOST>,`
- `--check` is supported; live install/probe tasks are intentionally skipped there

### Local VM validation

Single target (defaults to `ubuntu:26.04`):

```bash
./tests/create-vm.sh
ansible-playbook -i <IP>, -u <SSH_USER> --private-key "${TMPDIR:-/tmp}/cvmfs-setup/<vm-name>/id_ed25519" site.yml
VM_NAME=<vm-name> ./tests/test-vm.sh <IP> <SSH_USER>
./tests/teardown-vm.sh <vm-name>
```

`<SSH_USER>` is `ubuntu` for Ubuntu targets and `debian` for Debian targets.

Interactive SSH to a running test VM:

```bash
ssh -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  -i "${TMPDIR:-/tmp}/cvmfs-setup/<vm-name>/id_ed25519" <SSH_USER>@<IP>
```

When using `test-single.sh` / `test-all.sh`, preserve the VM first with
`SKIP_TEARDOWN=1` or `KEEP_ON_FAILURE=1`. Those orchestrators preserve the
transient SSH key and print the exact SSH command when a VM is left running.

A different target: `TARGET=ubuntu:22.04 ./tests/create-vm.sh` or
`TARGET=debian:13 ./tests/create-vm.sh`.

Single target end-to-end (create → apply → verify → teardown):

```bash
./tests/test-single.sh
TARGET=debian:12 ./tests/test-single.sh
KEEP_ON_FAILURE=1 ./tests/test-single.sh
SKIP_TEARDOWN=1 ./tests/test-single.sh
```

All supported targets sequentially:

```bash
./tests/test-all.sh
```

Env knobs for the orchestrators: `TARGET`, `TARGETS`, `KEEP_ON_FAILURE`,
`SKIP_TEARDOWN`, `CONTINUE_ON_ERROR`.

### Useful target-side checks

```bash
cvmfs_config chksetup
cvmfs_config probe soft.computecanada.ca
cvmfs_config probe neurodesk.ardc.edu.au
ls /cvmfs/soft.computecanada.ca
ls /cvmfs/neurodesk.ardc.edu.au
apptainer --version
bash -lc 'module avail'
bash -lc 'module --config'          # should list /var/cache/lmod
systemctl status lmod-spider-cache.timer
sudo /usr/local/sbin/update-lmod-spider-cache
```

## Code Conventions & Common Patterns

### Ansible patterns

- Prefer `ansible.builtin.*` modules over shell commands.
- Keep tasks idempotent.
  - package bootstrap is gated by `package_facts`
  - `cvmfs_config setup` uses `args.creates`
  - config files come from `template`
  - `/etc/bash.bashrc` is managed with `blockinfile`
- Use handlers for service restarts.
  - template changes notify `Restart autofs`
  - verification happens only after `meta: flush_handlers`
- Keep `--check` safe.
  - tasks that require downloaded artifacts, installed binaries, or live probes are guarded with `when: not ansible_check_mode`
- Dynamic discovery is preferred over hard-coding where it materially helps.
  - Lmod init is consumed through the packaging-provided `/usr/share/lmod/lmod` symlink so version bumps do not require playbook changes

### Shell script patterns

- Scripts use `set -euo pipefail`.
- `create-vm.sh` also uses an `ERR` trap to print the failing line/command.
- SSH options are built as arrays, with `IdentitiesOnly=yes` when a key is provided.
- Test VM state is transient and stored under `/tmp/cvmfs-setup/<vm>/`.
- The VM harness generates a fresh SSH key on every setup run; do not move that key into the repo.

### Naming and structure

- Variable names are descriptive and domain-specific (`cvmfs_repositories`, `neurodesk_server_url`, `cvmfs_quota_limit`)
- Templates map closely to their target files
- Verification scripts assert observable behavior, not internal implementation details

## Important Files

- `site.yml` — authoritative provisioning logic
- `group_vars/all.yml` — all supported tuning knobs
- `templates/default.local.j2` — main CVMFS client settings
- `templates/neurodesk.conf.j2` — Neurodesk repo configuration
- `templates/neurodesk.key.j2` — Neurodesk public key
- `templates/module.sh.j2` — shell-specific Lmod dispatcher
- `templates/cvmfs_modules.sh.j2` — profile script that wires Alliance + Neurodesk into shell sessions (deployed as `/etc/profile.d/zz-cvmfs-modules.sh` so it sorts after `lmod.sh`)
- `templates/lmodrc.lua.j2` — points Lmod at the system spider cache
- `templates/update-lmod-spider-cache.j2` — spider cache refresh script; derives `MODULEPATH` by sourcing the deployed profile script
- `templates/lmod-spider-cache.service.j2` / `templates/lmod-spider-cache.timer.j2` — hourly refresh units
- `tests/lib.sh` — shared test-harness logging, SSH wrappers, state loading, target table + resolver, and optional diagnostics (`TEST_DIAG=1`)
- `tests/create-vm.sh` — local libvirt test environment creation (target-aware via `TARGET=distro:version`)
- `tests/test-vm.sh` — remote behavior verification
- `tests/test-single.sh` — single-target create/apply/verify/teardown orchestrator
- `tests/test-all.sh` — sequential orchestrator across all supported targets
- `tests/teardown-vm.sh` — cleanup
- `ansible.cfg` — callback format, privilege escalation, inventory defaults
- `inventory` — optional static host list

## Runtime/Tooling Preferences

- Target OS: Ubuntu/Debian-style systems with `apt`
- Orchestration tool: Ansible
- Module system: Lmod from distro packages
- CVMFS setup relies on `autofs` and FUSE
- Local test runtime: libvirt/KVM + `virt-install` + `cloud-localds`
- Shell assumptions in tests: bash

Important constraints:

- preserve `become: true` / `sudo` behavior
- preserve trailing-comma inventory examples for single-host runs
- preserve transient SSH key workflow in `tests/create-vm.sh`
- preserve shared SSH harness options in `tests/lib.sh`, especially `UserKnownHostsFile=/dev/null` so tests do not write to the user's SSH known_hosts
- preserve exact Neurodesk server URL chain unless you are intentionally updating mirrors
- do not auto-source Alliance's `bash.sh` from `cvmfs_modules.sh.j2`; only add `MODULEPATH` entries so users opt in via `module load`
- keep the spider cache's `MODULEPATH` derived from `/etc/profile.d/zz-cvmfs-modules.sh` rather than reimplemented; a cache built over a different path set silently misreports what `module avail` shows
- keep `lmod_cache_writer_broken` as the single gate for both `LMOD_IGNORE_CACHE` and the spider cache tasks

## Testing & QA

### Main validation path

Use the VM harness for end-to-end checks:

Single target, fully automated:

```bash
./tests/test-single.sh
```

Or step by step:

1. `./tests/create-vm.sh`
2. apply `site.yml` to the VM
3. `VM_NAME=<vm-name> ./tests/test-vm.sh <IP> <SSH_USER>`
4. `./tests/teardown-vm.sh <vm-name>`

All supported targets:

```bash
./tests/test-all.sh
```

### What the verifier proves

`tests/test-vm.sh` checks:

- `cvmfs_config chksetup`
- probes for both repositories
- both `/cvmfs/...` mount points are readable
- `module` command is available
- Alliance modules are visible (`StdEnv/2023`)
- Neurodesk modules are visible
- the Lmod spider cache exists, Lmod reports it, the refresh timer is
  enabled and active, and a manual refresh succeeds (skipped on Ubuntu
  22.04 / Debian 11)
- expected config files exist

### Quality expectations for changes

When modifying the repo:

- run `ansible-playbook site.yml --syntax-check -i localhost, -c local`
- run `ansible-playbook site.yml --check -i <HOST>,` when possible
- validate behavior with the VM scripts for non-trivial changes
- re-run the playbook on an already-configured host to preserve idempotence (`changed=0` on second apply is the target)
