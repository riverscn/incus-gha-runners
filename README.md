# incus-gha-runners

[简体中文](README.zh-CN.md)

**Several GitHub Actions self-hosted runners on one Linux host, each in its own Incus system container.**

Self-hosted runners that share one host as processes of one user get in each other's way: parallel jobs
rewrite the same tool directories in `$HOME`, one job's `docker compose down` changes the network under
another job's browser (`net::ERR_NETWORK_CHANGED`), and the `docker` group is root on the host. Here every
runner gets an unprivileged Incus system container with its own systemd, dockerd, network namespace and
`runner` user, copied from a template. Jobs see a machine of their own; workflows are written as for
GitHub-hosted runners.

- Bash scripts, run as root on the host: `prepare-host`, `build-template`, `add-runner`, `remove-runner`,
  `apply-hooks`, `status`, `doctor`. All idempotent, with `--dry-run`.
- One configuration file per pool: repository or organisation, labels, names, how many.
- Long-lived containers: caches, images and build cache stay between jobs. Not ephemeral runners.
- Switches for mainland China: Debian mirror, a locally built base image instead of
  images.linuxcontainers.org, a Docker Hub pull-through cache.
- Project-specific system dependencies (such as Playwright's browser libraries) as hook scripts.
- Registration tokens are piped in from `gh` on your computer; the host needs no GitHub credentials.
- An [agent skill](skills/incus-gha-runners/SKILL.md) that runs the scripts and asks before anything that
  changes the host or a runner.

## Quick start

On the host:

```bash
sudo git clone https://github.com/riverscn/incus-gha-runners /opt/incus-gha-runners
sudo install -d /etc/incus-gha-runners
sudo cp /opt/incus-gha-runners/config.example.env /etc/incus-gha-runners/config.env
sudoedit /etc/incus-gha-runners/config.env        # GITHUB_URL, RUNNER_LABELS, RUNNER_COUNT, NETWORK_PRESET
sudo /opt/incus-gha-runners/bin/prepare-host --dry-run   # read it, then run without --dry-run
sudo /opt/incus-gha-runners/bin/build-template
```

On your computer:

```bash
gh api -X POST repos/OWNER/REPO/actions/runners/registration-token --jq .token \
  | ssh HOST sudo /opt/incus-gha-runners/bin/add-runner --token-stdin --all
ssh HOST sudo /opt/incus-gha-runners/bin/doctor
```

Then use the label in a workflow: `runs-on: [self-hosted, ci]`.

> **Using an AI coding agent?** Install the skill (`skills/incus-gha-runners`) or point the agent at
> [SKILL.md](skills/incus-gha-runners/SKILL.md), and ask it to set up runners on your host.

## Documentation

- [Setup](docs/setup.md): from a bare host to working runners
- [Operations](docs/operations.md): more or fewer runners, a new template, hooks, migrating, several pools
- [Troubleshooting](docs/troubleshooting.md)
- [Design](docs/design.md): every configuration key, script, option and exit code

## Tested on

Debian 13 (trixie) host, Docker 29.9, Incus 6.0.4 (Debian's package), as a QEMU virtual machine with 12 cores
and 11G of memory, running 4 runners for a pnpm monorepo CI (type checks, Playwright e2e on desktop and
mobile, Docker image builds with Compose), with `NETWORK_PRESET=cn`. The `images.linuxcontainers.org` path
(`BASE_IMAGE=images`) and other distributions are untested.

## Security

Jobs run the repository's code. The containers are unprivileged and cannot reach the host's files, the host's
Docker or each other, but they can reach the host's network, and a container keeps its state between jobs.
Use these runners only for repositories you trust, and do not let pull requests from forks run on them.

## License

[MIT](LICENSE)
