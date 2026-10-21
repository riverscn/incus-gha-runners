---
name: incus-gha-runners
description: >-
  Set up, extend and troubleshoot GitHub Actions self-hosted runners on one Linux host, each runner in its
  own long-lived unprivileged Incus system container with its own Docker. Use when someone wants several
  self-hosted runners on one machine without them interfering, wants to add or remove runners, rebuild the
  runner template, install system dependencies a project's CI needs (such as Playwright's browser
  libraries), migrate runners that run directly on the host, or asks why such a runner is offline or a job
  fails only on it.
---

# incus-gha-runners

incus-gha-runners puts each GitHub Actions self-hosted runner of a host in its own unprivileged Incus system
container: its own systemd, dockerd, network namespace and `runner` user, copied from a stopped template
container. Bash scripts in `bin/` do the work; this skill only says which script to run when, and what to ask
the person first.

## The documentation is the source of truth

Read the part for the step you are on before acting. Raw files:
`https://raw.githubusercontent.com/riverscn/incus-gha-runners/main/<path>`, or the clone on the host.

- `docs/design.md`: every configuration key, script, option and exit code.
- `docs/setup.md`: from a bare host to working runners.
- `docs/operations.md`: adding and removing runners, a new template, hooks for project dependencies,
  migrating runners that run directly on the host.
- `docs/troubleshooting.md`: known failures with their cause and fix.

Every document has a Simplified Chinese version (`<name>.zh-CN.md`). Talk to the person in the language they
write in, and quote the Chinese documents when that is Chinese.

## Rules

1. **Ask before each of these, naming the exact command and what it changes, and wait for a yes:**
   - changing the host firewall (`prepare-host` installing `incus-docker-forward.service`);
   - starting a service on the host (`prepare-host` starting the Docker Hub cache);
   - restarting the host's Docker (the scripts never do it; when it seems needed, say why and let the person
     decide);
   - stopping, deregistering, deleting or recreating a runner (`remove-runner`, `build-template --rebuild`);
   - deleting users, directories or systemd units on the host (for example old runners from before a
     migration).
   For `prepare-host`, run it with `--dry-run` first and show the output; that output is what you ask about.
   One yes covers what you showed, not later steps.
2. **Never touch a runner that is running a job.** Check with `status` (column `JOB`) right before acting;
   `remove-runner` refuses busy runners, and `--force` needs its own yes. Recreate runners one at a time so
   the pool keeps taking jobs.
3. **Tokens only through a pipe, never printed, never in a file or a command argument.** Fetch them with `gh`
   where the person is logged in and pipe them into `--token-stdin`:

   ```bash
   gh api -X POST repos/OWNER/REPO/actions/runners/registration-token --jq .token \
     | ssh HOST sudo /opt/incus-gha-runners/bin/add-runner --token-stdin 1 2
   ```

   Use `remove-token` for `remove-runner`, and `orgs/ORG/…` for organisation runners.
4. **Leave other runners and services on the host alone**, including runners running directly on the host
   (for example a deploy runner) and its Docker containers.
5. **Exit code 3 means the script stopped for a confirmation, a token, or a step it leaves to people**
   (`todo` lines from `prepare-host`). Read its `confirm:` and `todo` lines, ask the person (or fetch the
   token), then rerun with what it asked for.

## Step 1: find out what the person wants

| Goal | Go to |
|---|---|
| Runners on a host that has none of this yet | Step 2 |
| More or fewer runners in an existing pool | `docs/operations.md`, then Step 4 |
| The project's CI needs system packages | Step 3 |
| New Docker or Debian packages in every runner | `docs/operations.md` (new template) |
| Runners running directly on the host should move into containers | `docs/operations.md` (migrating) |
| A runner is offline, or jobs fail only on these runners | `doctor`, then `docs/troubleshooting.md` |

Find out the host (`ssh HOST` works, the person has sudo there), the repository or organisation, the labels
the workflows use in `runs-on`, how many jobs should run at once, and whether the host is in mainland China
(`NETWORK_PRESET=cn`). Read the repository's workflows yourself instead of asking where you can.

## Step 2: a new host

0. Check the host against the requirements in `docs/setup.md` (`/etc/os-release`, `incus version`, systemd,
   firewalld, `docker info` firewall backend). The containers are Debian whatever the host runs, so only
   the host side may need adapting:
   - Debian or Ubuntu: nothing to do, `prepare-host` installs Incus with apt.
   - Another distribution: install Incus 6.0+ (and, with `BASE_IMAGE=mmdebstrap`, `mmdebstrap` and the
     Debian archive keyring, or choose `BASE_IMAGE=images`) the way that distribution documents it. Show
     the person the commands and wait for a yes (rule 1).
   - firewalld or Docker's nftables backend: the scripts will not change that firewall. Explain what
     `docs/troubleshooting.md` suggests and let the person decide; do not write firewall rules of your own
     without their yes.
   Tell the person that hosts other than Debian 13 are untested.
1. Clone the repository to `/opt/incus-gha-runners` on the host, write `/etc/incus-gha-runners/config.env`
   from `config.example.env` with the values from Step 1, and show it to the person.
2. `sudo bin/prepare-host --dry-run`; show the output, ask (rule 1), then run it without `--dry-run`.
3. Step 3 for the project's dependencies, before the template is built.
4. `sudo bin/build-template` (several minutes), then Step 4.

## Step 3: dependencies the project's CI needs

The runner user has no sudo, so anything a workflow installs with `sudo apt-get` or with a tool's
`--with-deps` must be in the template already. Read the workflows (`.github/workflows/*.yml`) and the project
for steps that need root: `apt-get`, `playwright install --with-deps`, native build toolchains, and so on.
Everything a workflow installs into the user's home (Node via `actions/setup-node`, pnpm, the browsers
themselves) stays in the workflow.

Write each need as a hook in `HOOKS_DIR` (see `docs/operations.md`; `examples/hooks/` has a Playwright
example, with its version matched to the project). Show the person the hook. A new template runs all hooks;
existing runners catch up with `sudo bin/apply-hooks --all`, which skips busy runners (exit code 3: run it
again later).

## Step 4: runners

1. `sudo bin/add-runner --token-stdin --all` (or the numbers), with the token piped as in rule 3.
2. `sudo bin/doctor` must print no `FAIL`.
3. Check on GitHub that the runners are online with the right labels:
   `gh api repos/OWNER/REPO/actions/runners --jq '.runners[] | [.name, .status, .busy, ([.labels[].name] | join(","))] | @tsv'`.
4. Ask the person whether to run a workflow to prove it, and watch that run.
