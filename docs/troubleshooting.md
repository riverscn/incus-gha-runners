[简体中文](troubleshooting.zh-CN.md)

# Troubleshooting

Start with `sudo bin/doctor`: every `FAIL` line comes with a fix. Look inside a container with
`sudo incus exec <prefix>-N -- bash`; the runner's own logs are in `/home/runner/actions-runner/_diag/`, the
service's in `journalctl -u 'actions.runner.*'`.

## Containers get no IPv4 address, or a new container never becomes ready

**`build-template` or `add-runner` stops with "did not get a working network within 3 minutes".**

- A hand-made image without `udev`: systemd-networkd waits for the device forever and never runs DHCP. The
  mmdebstrap image built by `build-template` includes `udev`.
- Every copy got **the same** address: the template's `/etc/machine-id` was not empty, so all copies send
  the same DHCP client ID. `build-template` empties it when sealing; `doctor` reports duplicates. Recreate
  the affected runners from a template built by `build-template`.
- The container has an address but cannot get out: see the next section.

## Containers have an address but no internet (host runs Docker)

Docker sets the `FORWARD` chain's policy to DROP, which also drops traffic from `incusbr0` to the uplink.
`prepare-host` installs `incus-docker-forward.service`, which allows exactly `incusbr0 → uplink` and the
replies, in Docker's `DOCKER-USER` chain. Check:

```bash
sudo iptables -S DOCKER-USER
sudo systemctl status incus-docker-forward.service
```

If the rules are missing (for example after something flushed the chain), restart that service. If the
uplink interface is not the one of the default route, set `UPLINK_IF` and run `prepare-host` again after
deleting the unit file. Do not use Incus's suggestion to let all forwarding through: that opens the host's
Docker networks too.

## firewalld, or Docker's nftables backend

`prepare-host` only knows how to let `incusbr0` out through Docker's iptables rules. With firewalld active,
or Docker set to `"firewall-backend": "nftables"`, it lists this as a step to do by hand and exits with 3,
without changing the firewall. What to do instead (untested here):

- firewalld: put the bridge in the trusted zone,
  `firewall-cmd --zone=trusted --change-interface=incusbr0 --permanent && firewall-cmd --reload`
  (see the Incus documentation on firewalld).
- Docker with nftables: Docker's own chains drop forwarded traffic it does not know; allow `incusbr0` to the
  uplink and the replies back in a table of your own, as described in Docker's nftables documentation.

Then `doctor` must show that containers reach api.github.com.

## Downloads from images.linuxcontainers.org fail (mainland China)

They are often reset. Use `BASE_IMAGE=mmdebstrap` (part of `NETWORK_PRESET=cn`): the base image is built on
the host from `DEBIAN_MIRROR`.

## Docker Hub pulls fail inside the containers (mainland China)

Connections to Docker Hub are often reset, so a fresh container fails the first time a job needs an image.
With `HUB_MIRROR=on`, each container's dockerd asks the cache on the host first, which fetches each image
from Docker Hub once (the cache retries; a reset only costs time). Check it from a container:

```bash
sudo incus exec ci-1 -- curl -fsS http://10.1.231.1:5000/v2/   # the bridge address
sudo incus exec ci-1 -- docker info --format '{{.RegistryConfig.Mirrors}}'
```

The cache serves only Docker Hub. Images from other registries (ghcr.io, quay.io) are pulled directly.

## Chromium fails with `net::ERR_NETWORK_CHANGED`

This is what happens when several runners share one network namespace and another job adds or removes a
Docker network. It cannot happen between these containers (each has its own namespace); if you see it, the
job ran on a runner outside them. Check the runner name in the job log.

## e2e fails with missing shared libraries

The browser's system libraries are installed by a hook, for the Playwright version in the hook. After the
project upgrades Playwright, update the hook's version and `sudo bin/apply-hooks --all`.

## A job needs `sudo`

The `runner` user has no sudo on purpose. Install what the job needs as root with a hook, and drop the
`sudo` step (or `--with-deps`) from the workflow.

## A runner shows as offline on GitHub

- `sudo bin/status`: is the container running, is the service `active`?
- `sudo incus start <prefix>-N` after the host was rebooted with `boot.autostart` off.
- The registration was deleted on GitHub (or the runner was offline for 14 days and GitHub removed it):
  delete `.runner`, `.credentials` and `.credentials_rsaparams` in `/home/runner/actions-runner` after
  `svc.sh uninstall`, or simply recreate the runner (`remove-runner` then `add-runner`).

## Leftovers after a killed job

If the runner was killed in the middle of a job (host power loss), cleanup steps with `if: always()` did not
run. Look inside that container (`docker ps -a`, `docker volume ls`) and remove what the job left behind.
Disk use per container is in `status`.

## `build-template` says the template exists but was not built by this script

The existing `<prefix>-tpl` has no completion marker: it was built by hand, or a build was interrupted. It is
only replaced with `--rebuild --yes`.
