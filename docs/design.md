[简体中文](design.zh-CN.md)

# Design: script interface, configuration and switches

> This document is the contract for the scripts; change it first when changing what they do.

## 1. The problem

Several GitHub Actions self-hosted runners on one Linux host, running as processes of the same user in the same network namespace, get in each other's way:

- Shared home directory: tools' default install locations (such as `~/setup-pnpm` from `pnpm/action-setup`) are rewritten by parallel jobs at the same time.
- Shared network namespace: another job's `docker compose up/down` adds and removes bridges, Chromium is told the network changed, and aborts in-flight requests with `net::ERR_NETWORK_CHANGED`.
- Shared host Docker: the `docker` group is root on the host, so a job can reach the host's other containers and the other runners' credentials.

This project gives **each runner its own unprivileged Incus system container**, with its own systemd, dockerd, network namespace, `runner` user and runner program. A job sees a machine of its own, and workflows are written as for GitHub-hosted machines. Root in the container maps to an ordinary uid on the host, so the container's `docker` group cannot reach beyond the container.

Out of scope:

- **No ephemeral runners.** Containers are long-lived and keep the pnpm store, browsers, Docker images and build cache between jobs, for speed. The price is that jobs are not fully isolated from each other (jobs of the same repository share one container's state), so use it only for repositories you trust, and never for pull requests from forks.
- No autoscaling and no scheduling like Actions Runner Controller. The number of containers is a number in the configuration.
- Other runners on the host (for example a deploy runner running directly on the host) are left alone.

## 2. Layout

```
host (Debian 13, Docker may also be installed)
├── incusbr0 (bridge managed by Incus, NAT to the outside)
├── hub-mirror (optional Docker Hub pull-through cache, bound to incusbr0's address only)
├── <prefix>-tpl   template container, stopped, only used for copying
├── <prefix>-1     runner container: systemd + dockerd + actions-runner service
├── <prefix>-2
└── …
```

- One configuration file describes **one pool of runners** (one repository or organisation, one set of labels, one container name prefix). A host can have several pools, one file each.
- The template has all software installed but is not registered; `add-runner N` copies it, starts the copy, registers it and installs the runner as a systemd service.
- To change what the template contains (newer Docker, extra system libraries): `build-template --rebuild`, then `remove-runner N && add-runner N` one at a time. The runner program updates itself from GitHub and needs no rebuild.

## 3. Installation and how it runs

- Clone the repository anywhere on the host (suggested: `/opt/incus-gha-runners`) and run the scripts as root (`sudo bin/…`).
- The host needs **no** `gh`, GitHub token or `jq`. The short-lived registration and removal tokens are fetched by the caller (a person or an agent, usually with `gh` on their own computer) and passed on standard input, so they never appear in command-line arguments, the environment or logs:

  ```bash
  gh api -X POST repos/OWNER/REPO/actions/runners/registration-token --jq .token \
    | ssh HOST sudo /opt/incus-gha-runners/bin/add-runner --token-stdin 1
  ```

  Organisation runners use `orgs/ORG/actions/runners/registration-token`; removal uses `…/remove-token`.
- Every script can be run again: steps already in the desired state are skipped with `ok`, only what is missing is done.

## 4. Configuration

Read from `/etc/incus-gha-runners/config.env` by default; `--config FILE` (or the `IGR_CONFIG` environment variable) picks another file, one file per pool. The format is shell `KEY=value`, sourced by the scripts. It holds no secrets. The repository ships a commented `config.example.env`.

### 4.1 The pool

| Key | Default | Meaning |
|---|---|---|
| `GITHUB_URL` | required | `https://github.com/OWNER/REPO` or `https://github.com/ORG` |
| `RUNNER_LABELS` | required | Comma-separated, such as `ci`. GitHub adds `self-hosted`, `linux` and `x64` itself |
| `RUNNER_NAME_PREFIX` | `<hostname>-` | Runners are registered as `<prefix><N>`, such as `bot-dev-1` |
| `RUNNER_GROUP` | empty | Organisation runners only |
| `CONTAINER_PREFIX` | `ci` | The template is `<prefix>-tpl`, runner containers are `<prefix>-N` |
| `RUNNER_COUNT` | `1` | Used by `add-runner --all`, `status` and `doctor`; numbered 1…N |
| `RUNNER_VERSION` | `latest` | Runner version put in the template, such as `2.337.0` |
| `LIMITS_CPU` / `LIMITS_MEMORY` | empty (no limit) | Set as `limits.cpu` / `limits.memory` on every runner container |

### 4.2 Template contents

| Key | Default | Meaning |
|---|---|---|
| `DEBIAN_SUITE` | `trixie` | The containers' Debian release |
| `EXTRA_PACKAGES` | empty | Extra apt packages for the template |
| `DOCKER_BUILDER_KEEP` | `3GB` | Build cache limit of the dockerd in each container (`builder.gc.defaultKeepStorage`) |
| `HOOKS_DIR` | `/etc/incus-gha-runners/hooks.d/<CONTAINER_PREFIX>` | Directory of install scripts for project-specific dependencies, see 4.5 |

### 4.3 Network switches (mainland China)

The three switches are independent. `NETWORK_PRESET=cn` sets defaults that work in mainland China in one go; keys written explicitly win.

| Switch | Default (`NETWORK_PRESET=global`) | With `NETWORK_PRESET=cn` | Effect |
|---|---|---|---|
| `BASE_IMAGE` | `images` | `mmdebstrap` | `images`: download `debian/<release>` from images.linuxcontainers.org. `mmdebstrap`: build a minbase system image on the host from `DEBIAN_MIRROR` and import it (downloads from images.linuxcontainers.org are often reset in mainland China) |
| `DEBIAN_MIRROR` | `https://deb.debian.org/debian` | `https://mirrors.tuna.tsinghua.edu.cn/debian` | Used by mmdebstrap and by apt in the containers |
| `HUB_MIRROR` | `off` | `on` | Runs a Docker Hub pull-through cache on the host (official `registry:3` image in proxy mode), bound to `incusbr0`'s address only; each container's dockerd uses it as a `registry-mirrors` entry. Docker falls back to Docker Hub when the cache is down |

Download locations that follow these switches (each can also be set on its own):

| Key | global | cn |
|---|---|---|
| `DEBIAN_SECURITY_MIRROR` | `https://security.debian.org/debian-security` | `https://mirrors.tuna.tsinghua.edu.cn/debian-security` |
| `DOCKER_APT_URL` | `https://download.docker.com/linux/debian` | `https://mirrors.tuna.tsinghua.edu.cn/docker-ce/linux/debian` |
| `RUNNER_DOWNLOAD_URL` | `https://github.com/actions/runner/releases/download` | same (GitHub downloads usually work in mainland China; point it at your own mirror if slow) |

`HUB_MIRROR_PORT` (default `5000`) and `HUB_MIRROR_NAME` (default `hub-mirror`) can be changed.

### 4.4 Host

| Key | Default | Meaning |
|---|---|---|
| `INCUS_BRIDGE` | `incusbr0` | The bridge created by `incus admin init --minimal` |
| `UPLINK_IF` | interface of the default route | Outgoing interface in the forwarding rules |

### 4.5 Project-specific dependencies: hooks, not configuration

The scripts install only what every pool needs (the OS, Docker, the runner). Which system libraries a project needs (such as Playwright's browser libraries, or a language toolchain) is decided by the person or agent from the project's workflows and written as hook scripts; the configuration has no keys for particular tools.

- Hooks are the `*.sh` files in `HOOKS_DIR`, pushed into the container and run as root in file-name order; they must be safe to run again. The configuration values (such as `DEBIAN_MIRROR`) are in their environment, so hooks can use the same mirrors.
- `build-template` runs every hook in the template; existing runner containers catch up with `apply-hooks [N…|--all]`, without a rebuild (containers running a job are skipped).
- Why preinstall at all: the runner user has no sudo, so workflows cannot install system packages (such as Playwright's `--with-deps`). Things a workflow can install into the user's home (Node, pnpm, the browsers themselves) do not belong in hooks.
- The skill explains how to decide what to install (look for workflow steps that need root), and `docs/operations` gives common examples, including Playwright: install Node temporarily, `npx playwright@<the project's version> install-deps chromium`, remove Node; after upgrading Playwright, `apply-hooks --all`.

## 5. Scripts

All in `bin/`, run as root, sharing `lib/common.sh`. Common options: `--config FILE`, `--dry-run` (print the changes it would make, change nothing), `-h`. Exit codes: `0` success; `1` failure; `2` usage error; `3` confirmation needed (see 5.7).

### 5.1 `prepare-host`

One-time host preparation; safe to run again.

1. Check the system: systemd is required; anything other than Debian 13 gets an "untested" warning, not a refusal.
2. When `incus` is missing (and, with `BASE_IMAGE=mmdebstrap`, `mmdebstrap` and `debian-archive-keyring`): `apt-get install` where there is apt; without apt it does not guess another package manager but lists a step to do by hand (exit code 3), for the person or agent to install them the distribution's way and run it again. Incus must be 6.0 or later.
3. If Incus is not initialised, `incus admin init --minimal` (`dir` storage pool, bridge `incusbr0`); if it is, leave it alone.
4. With firewalld active, or the host's Docker on its nftables firewall backend, leave the firewall alone and list a step to do by hand (exit code 3). Otherwise, if Docker is installed on the host and the `FORWARD` chain's policy is DROP, install `incus-docker-forward.service` (`After=docker.service`, runs at boot): in the `DOCKER-USER` chain it allows only `incusbr0 → UPLINK_IF` and the `RELATED,ESTABLISHED` replies, without opening any other forwarding on the host, and without Incus's `ip-forward-no-drop` style of opening all forwarding. **Changes the firewall: needs confirmation.**
5. With `HUB_MIRROR=on`, start the cache container on the host's Docker (`--restart unless-stopped`, `-p <bridge address>:<port>:5000`, volume `hub-mirror`). Fails with a hint to set `off` when the host has no Docker. **Opens a service on the host (to the container subnet only): needs confirmation.**

A unit or container of the same name that already exists counts as done (compatible with environments built by hand before this project).

### 5.2 `build-template [--rebuild]`

Builds the template container `<prefix>-tpl`, left stopped.

1. System image: `BASE_IMAGE=images` uses `images:debian/<release>` directly; `mmdebstrap` builds a minbase on the host (plus `systemd`, `systemd-resolved`, `udev`, `dbus`, `ca-certificates`, `curl`, `git`, `iproute2`, `gnupg`, `sudo`, `locales`; writes `/etc/systemd/network/eth0.network` for DHCP; without `udev`, networkd waits forever and never gets an address) and imports it under the alias `igr/debian-<release>`, reused afterwards.
2. Launch with `security.nesting=true`, `security.syscalls.intercept.mknod=true`, `security.syscalls.intercept.setxattr=true` (needed for Docker in the container) and wait for the network.
3. Point the container's apt at `DEBIAN_MIRROR`; install `docker-ce`, `docker-ce-cli`, `containerd.io`, `docker-buildx-plugin`, `docker-compose-plugin` from Docker's apt repository (`DOCKER_APT_URL`); write `/etc/docker/daemon.json` (build cache limit, log rotation; plus `registry-mirrors` and `insecure-registries` with `HUB_MIRROR=on`).
4. Install `EXTRA_PACKAGES`.
5. Create user `runner` (in the container's `docker` group only, no sudo). The runner archive is downloaded on the host and cached in `/var/cache/incus-gha-runners/`, pushed into the container and unpacked to `/home/runner/actions-runner`, then its own `bin/installdependencies.sh` is run (libicu and friends are missing otherwise).
6. Run the hooks (see 4.5).
7. Seal: empty `/etc/machine-id` (otherwise every copy gets the same DHCP address), delete `/var/lib/docker/engine-id`, `apt-get clean`, stop the container.

Does nothing when a complete template (with a completion marker) exists. The build happens in `<prefix>-tpl-new`, which replaces `<prefix>-tpl` only when it succeeded, so a failed build never leaves a broken template. `--rebuild` builds and replaces an existing template (needs `--yes`; existing runner containers are untouched).

### 5.3 `add-runner [--token-stdin] N… | --all`

For each number:

1. If `<prefix>-N` does not exist: `incus copy <prefix>-tpl <prefix>-N`, set `boot.autostart=true` and `LIMITS_*`, start it, wait for the network.
2. If it is not registered (no `.runner` file): with the token read from standard input, as user `runner`, run `config.sh --unattended --url GITHUB_URL --token … --name <RUNNER_NAME_PREFIX>N --labels RUNNER_LABELS [--runnergroup …] --replace`, then `svc.sh install runner`. Without a token it stops and explains how to get one (exit code 3).
3. If the service is not running: `svc.sh start`.

One token registers any number of runners (it is valid for an hour), so `--all` needs one token. `--replace` takes over an old registration of the same name, so a rebuilt container does not need the old one deleted on GitHub first.

### 5.4 `remove-runner [--token-stdin] [--force] [--yes] N…`

1. Refuses when the container has a `Runner.Worker` process (a job is running), unless `--force`.
2. With a token (a remove-token): `svc.sh stop && svc.sh uninstall && config.sh remove`. Without one, it warns that an offline runner entry stays on GitHub, to be deleted in the repository settings or taken over later by `add-runner` with the same name (`--replace`).
3. Delete the container (with its Docker data).

**Stopping, deregistering and deleting need confirmation**: without `--yes` it prints what it would do and exits with 3.

### 5.5 `apply-hooks [N…|--all]`

Runs the hooks (see 4.5) in existing runner containers, skipping and reporting containers that are running a job.

### 5.6 `status`, `doctor`

- `status`: per container its state, IP, runner service state, registered name, whether a job is running, disk use; whether the template exists and when it was built. Read-only.
- `doctor`: read-only checks, each printed as `ok` / `FAIL` with the fix: Incus works; the bridge exists; the forwarding rules are in place (when the host has Docker); the pull-through cache is reachable from the containers (with `HUB_MIRROR=on`); every container resolves names, reaches GitHub, runs `docker info` and has its runner service running; the containers' machine-ids differ.

### 5.7 Operations that need confirmation

The scripts never prompt. Operations that change the host or deregister runners are either listed first by `--dry-run` or require `--yes`, and are then run by the person (or by an agent after the person agreed):

| Operation | Script | How |
|---|---|---|
| Changing the firewall (`DOCKER-USER` rules and the systemd unit) | `prepare-host` | show `--dry-run` first |
| Starting a service on the host (the pull-through cache) | `prepare-host` | same |
| Restarting the host's Docker | none (the scripts never restart Docker; `doctor` only suggests it) | the person runs it |
| Stopping, deregistering, deleting runners | `remove-runner` | `--yes` |
| Deleting the template | `build-template --rebuild` | `--yes` |

## 6. Agent skill

`skills/incus-gha-runners/SKILL.md` only orchestrates: find out the goal (new install, more runners, new template, project dependencies, troubleshooting), read the target repository's workflows to decide which system dependencies must be preinstalled and write them as hooks, read this document and the matching parts of `docs/`, and run the scripts in order. Before any operation in the table above, and before deleting users and directories on the host (such as old runners that ran directly on the host before a migration), it tells the person the exact commands and their effect and waits for a yes. Tokens are only piped, never printed.

## 7. Documentation

`README` and `docs/` in English and Simplified Chinese (`*.zh-CN.md`, kept in step). `docs/`: `design` (this document), `setup` (from scratch), `operations` (day to day: more or fewer runners, a new template, writing hooks with common examples such as Playwright, migrating a hand-built setup), `troubleshooting` (known pitfalls: networkd waiting, the same DHCP address, FORWARD DROP, Docker Hub resets, `ERR_NETWORK_CHANGED`).

## 8. Tested on

The containers are always Debian, whatever the host runs; the host needs systemd, Incus 6.0 or later, and Docker's iptables backend when it runs Docker (see the host requirements in `docs/setup`). Tested on a Debian 13 (trixie) host with Docker 29.9 and Incus 6.0.4 (Debian's own package), a QEMU virtual machine with 12 cores and 11G of memory. Tested with `NETWORK_PRESET=cn`; the `global` path with `BASE_IMAGE=images` has not been tested on that host.
