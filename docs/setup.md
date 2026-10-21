[简体中文](setup.zh-CN.md)

# Setup: from a bare host to working runners

You need: a Linux host where you have sudo (see the requirements below), Docker on it only if you want the
Docker Hub cache, and `gh` logged in on your own computer with admin access to the repository (or
organisation).

## Host requirements

The containers always run Debian, built by `build-template`, whatever the host runs. The host needs:

- systemd, and Incus 6.0 or later. On Debian 13 and Ubuntu 24.04, `prepare-host` installs Incus with apt.
  On other distributions, install it first the distribution's way
  ([Incus installation guide](https://linuxcontainers.org/incus/docs/main/installing/)); `prepare-host`
  then only checks it.
- With `BASE_IMAGE=mmdebstrap`: `mmdebstrap` and the Debian archive keyring
  (`/usr/share/keyrings/debian-archive-keyring.gpg`). Installed with apt where there is apt; elsewhere
  install them yourself or use `BASE_IMAGE=images`.
- If the host runs Docker: Docker's iptables firewall backend (the default). The scripts do not handle
  firewalld or Docker's nftables backend; `prepare-host` stops and says so (see
  [troubleshooting](troubleshooting.md#firewalld-or-dockers-nftables-backend)).

| Host | Status |
|---|---|
| Debian 13 | tested |
| Ubuntu 24.04 | should work (apt, Incus 6.0 in the archive), untested |
| Other systemd distributions with Incus 6.0+ | should work after installing Incus by hand, untested |

## 1. Get the scripts and write the configuration

```bash
sudo git clone https://github.com/riverscn/incus-gha-runners /opt/incus-gha-runners
sudo install -d /etc/incus-gha-runners
sudo cp /opt/incus-gha-runners/config.example.env /etc/incus-gha-runners/config.env
sudoedit /etc/incus-gha-runners/config.env
```

At least set `GITHUB_URL`, `RUNNER_LABELS` (the label your workflows use, as in `runs-on: [self-hosted, ci]`),
`RUNNER_COUNT`, and `NETWORK_PRESET=cn` for a host in mainland China. Every key is in
[design.md](design.md#4-configuration).

Sizing: each container takes about 5–7G of disk once it has run a few jobs (system, Docker, dependency images,
caches, up to `DOCKER_BUILDER_KEEP` of build cache). Containers share the host's CPUs and memory unless you set
`LIMITS_CPU` / `LIMITS_MEMORY`.

## 2. Prepare the host

```bash
sudo /opt/incus-gha-runners/bin/prepare-host --dry-run
```

Read what it would do. It may change the host firewall (only when Docker on the host sets the `FORWARD`
policy to DROP: then the Incus bridge is allowed out through the uplink and replies back in, nothing else)
and start the Docker Hub cache container (with `HUB_MIRROR=on`, bound to the bridge address only). When you
agree:

```bash
sudo /opt/incus-gha-runners/bin/prepare-host
```

With `HUB_MIRROR=on`, the host itself pulls `registry:3` from Docker Hub once. If that pull is reset, pull it
through any mirror you have, then `docker tag` it as `registry:3`.

## 3. Hooks for what the project's CI needs

The `runner` user has no sudo, so system packages a workflow needs (such as Playwright's browser libraries)
must be in the template. Put install scripts in `HOOKS_DIR` (default
`/etc/incus-gha-runners/hooks.d/<CONTAINER_PREFIX>`) before building it; see
[operations.md](operations.md#hooks-for-project-dependencies). Skip this when the workflows install nothing
with root.

## 4. Build the template

```bash
sudo /opt/incus-gha-runners/bin/build-template
```

This takes a few minutes: the base image (downloaded, or built with mmdebstrap), Docker, the runner program,
the hooks. It ends with a stopped `<prefix>-tpl` and a line such as
`built 2026-10-21T09:30Z: debian trixie, docker-ce 5:29.0.0-1~debian.13~trixie, runner 2.338.0, hooks: 50-playwright-chromium.sh`.

## 5. Add the runners

On your own computer:

```bash
gh api -X POST repos/OWNER/REPO/actions/runners/registration-token --jq .token \
  | ssh HOST sudo /opt/incus-gha-runners/bin/add-runner --token-stdin --all
```

The token goes through the pipe, never into a file or onto a command line. Then:

```bash
ssh HOST sudo /opt/incus-gha-runners/bin/doctor
ssh HOST sudo /opt/incus-gha-runners/bin/status
```

`doctor` prints `ok` for every line; the runners show up as idle in the repository's Settings → Actions →
Runners. Containers start at boot, and so do their runner services.

## Security

Jobs run the repository's code inside the containers. The containers are unprivileged (their root is an
ordinary uid on the host) and cannot reach the host's files, the host's Docker or each other's credentials,
but they can reach the host's network and the bridge address on the host. Containers are long-lived, so one
job can leave things behind for the next one in the same container. Use these runners for repositories you
trust, and keep workflows from running for pull requests from forks (in a public repository: Settings →
Actions → General → require approval for all outside collaborators, or do not use self-hosted runners there).
