[简体中文](operations.zh-CN.md)

# Operations

All commands run on the host as root; `bin/` is `/opt/incus-gha-runners/bin/`. Token commands run where `gh`
is logged in (`OWNER/REPO` as in `GITHUB_URL`; `orgs/ORG/…` for an organisation). Check `status` before
anything that stops a runner: column `JOB` must be `no`.

## More runners

Raise `RUNNER_COUNT` in the configuration, then add the new numbers:

```bash
gh api -X POST repos/OWNER/REPO/actions/runners/registration-token --jq .token \
  | ssh HOST sudo bin/add-runner --token-stdin 5 6
```

## Fewer runners

```bash
ssh HOST sudo bin/status
gh api -X POST repos/OWNER/REPO/actions/runners/remove-token --jq .token \
  | ssh HOST sudo bin/remove-runner --token-stdin --yes 6
```

Then lower `RUNNER_COUNT`. `remove-runner` refuses a runner that is running a job (`--force` overrides it,
and that job fails). Everything in the container goes with it, including its Docker images and caches.

## A new template

When every runner needs something new (a newer Docker, `EXTRA_PACKAGES`, a changed hook that should not just
be applied in place):

```bash
sudo bin/build-template --rebuild --yes
```

It builds `<prefix>-tpl-new` and only replaces the old template when the build succeeded. Existing runners are
not changed. Recreate them one at a time, so the others keep taking jobs:

```bash
# for each N, when status shows it idle:
gh api -X POST repos/OWNER/REPO/actions/runners/remove-token --jq .token \
  | ssh HOST sudo bin/remove-runner --token-stdin --yes N
gh api -X POST repos/OWNER/REPO/actions/runners/registration-token --jq .token \
  | ssh HOST sudo bin/add-runner --token-stdin N
```

A recreated runner starts with empty caches, so its first jobs are slower.

The runner program updates itself (GitHub pushes updates to idle runners); no rebuild is needed for that.
The base image (`igr/debian-<release>` with `BASE_IMAGE=mmdebstrap`) is reused by every rebuild, and the
template build runs `apt-get full-upgrade`. To start from a fresh base image anyway:
`incus image delete igr/debian-trixie` before rebuilding.

## Hooks for project dependencies

Hooks are `*.sh` files in `HOOKS_DIR` (default `/etc/incus-gha-runners/hooks.d/<CONTAINER_PREFIX>`). Each is
pushed into the container and run as root, in file-name order, with the configuration in its environment:
`NETWORK_PRESET`, `DEBIAN_SUITE`, `DEBIAN_MIRROR`, `DEBIAN_SECURITY_MIRROR`, `DOCKER_APT_URL`, `HUB_MIRROR`,
`HUB_MIRROR_ADDR` (with `HUB_MIRROR=on`), `EXTRA_PACKAGES`, `DOCKER_BUILDER_KEEP`. A hook must be safe to run
again, and must exit non-zero when it fails.

What belongs in a hook: whatever a workflow would need root for, because the `runner` user has no sudo —
`apt-get install` of system libraries, `playwright install --with-deps`, a system-wide toolchain. What does
not: anything a workflow installs into the user's home (Node with `actions/setup-node`, pnpm, the Playwright
browsers themselves). Those are cached in the container between jobs anyway.

`build-template` runs all hooks in the template. After changing a hook, bring existing runners up to date
without recreating them:

```bash
sudo bin/apply-hooks --all
```

It stops each runner's service while the hooks run and skips runners that are running a job (exit code 3;
run it again later).

### Example: Playwright

[`examples/hooks/50-playwright-chromium.sh`](../examples/hooks/50-playwright-chromium.sh) installs a
throwaway Node, runs `npx playwright@<version> install-deps chromium`, and removes Node. Set
`PLAYWRIGHT_VERSION` in it to the project's `@playwright/test` version. The workflow then runs
`playwright install chromium` (without `--with-deps`). After the project upgrades Playwright and e2e
complains about missing libraries, update the version in the hook and run `apply-hooks --all`.

```bash
sudo install -d /etc/incus-gha-runners/hooks.d/ci
sudo cp /opt/incus-gha-runners/examples/hooks/50-playwright-chromium.sh /etc/incus-gha-runners/hooks.d/ci/
```

## Several pools on one host

One configuration file per pool, each with its own `CONTAINER_PREFIX` (and usually its own `GITHUB_URL` or
labels): `sudo bin/add-runner --config /etc/incus-gha-runners/other.env --all`. The host part
(`prepare-host`) is shared; run it with either file.

## Migrating runners that run directly on the host

1. Build the template and add container runners under **new names** first (a different
   `RUNNER_NAME_PREFIX`, or numbers after the existing ones), so both run side by side for a while.
2. When the container runners have passed a few runs, stop the old ones when idle:
   `sudo ./svc.sh stop && sudo ./svc.sh uninstall` in each old runner directory, then
   `./config.sh remove --token …` (a remove-token) as the user the runner was configured as.
3. Only then delete the old runner directories, and the old user if it existed only for the runners.

To replace containers that were built by hand with containers built by these scripts, use the same
container names and runner names: `build-template` refuses an existing template it did not build until you
pass `--rebuild --yes`; recreate the runners one at a time as in "A new template". `add-runner` registers with
`--replace`, so the new container takes over the old registration of the same name.

## Updating these scripts

```bash
sudo git -C /opt/incus-gha-runners pull
```

Existing containers and templates keep working; changes to what a template contains take effect with the
next `build-template --rebuild`.
