#!/bin/bash
# Runs as root inside the template container (pushed there by bin/build-template).
# Configuration arrives as environment variables (see hook_env in lib/common.sh) plus RUNNER_ARCHIVE.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt_get() { apt-get -o Dpkg::Options::=--force-confold -y "$@"; }

echo "  ->     apt sources"
rm -f /etc/apt/sources.list
cat >/etc/apt/sources.list.d/debian.sources <<EOF
Types: deb
URIs: $DEBIAN_MIRROR
Suites: $DEBIAN_SUITE $DEBIAN_SUITE-updates
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb
URIs: $DEBIAN_SECURITY_MIRROR
Suites: $DEBIAN_SUITE-security
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
apt-get update -q
apt_get full-upgrade
apt_get install ca-certificates curl git gnupg iproute2 locales sudo xz-utils

echo "  ->     Docker"
install -d -m 0755 /etc/apt/keyrings
curl -fsSL "$DOCKER_APT_URL/gpg" -o /etc/apt/keyrings/docker.asc
cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: $DOCKER_APT_URL
Suites: $DEBIAN_SUITE
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
apt-get update -q
# shellcheck disable=SC2086 # EXTRA_PACKAGES is a space-separated list
apt_get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin $EXTRA_PACKAGES

mirror=
if [[ $HUB_MIRROR == on ]]; then
	mirror=$(printf '\n  "registry-mirrors": ["http://%s"],\n  "insecure-registries": ["%s"],' "$HUB_MIRROR_ADDR" "$HUB_MIRROR_ADDR")
fi
cat >/etc/docker/daemon.json <<EOF
{
  "builder": { "gc": { "enabled": true, "defaultKeepStorage": "$DOCKER_BUILDER_KEEP" } },$mirror
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
EOF
systemctl restart docker
docker info >/dev/null

echo "  ->     user runner"
id runner >/dev/null 2>&1 || useradd --create-home --shell /bin/bash runner
usermod -aG docker runner

echo "  ->     runner program"
dir=/home/runner/actions-runner
rm -rf "$dir"
install -d -o runner -g runner "$dir"
tar -xzf "$RUNNER_ARCHIVE" -C "$dir"
rm -f "$RUNNER_ARCHIVE"
chown -R runner:runner "$dir"
"$dir/bin/installdependencies.sh" >/dev/null
