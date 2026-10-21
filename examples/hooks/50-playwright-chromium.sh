#!/bin/bash
# Hook: system libraries for Playwright's Chromium. The runner user has no sudo, so a
# workflow cannot use `playwright install --with-deps`; it downloads the browser itself
# (`playwright install chromium`) and finds the libraries already here.
#
# Copy to HOOKS_DIR, set PLAYWRIGHT_VERSION to the version the project uses (its
# @playwright/test), and after the project upgrades Playwright run `apply-hooks --all`.
set -euo pipefail
PLAYWRIGHT_VERSION=1.63.0
NODE_MAJOR=24

if [[ $NETWORK_PRESET == cn ]]; then
	node_dist=https://npmmirror.com/mirrors/node
	export npm_config_registry=https://registry.npmmirror.com
else
	node_dist=https://nodejs.org/dist
fi
case $(uname -m) in x86_64) arch=x64 ;; aarch64) arch=arm64 ;; esac

# A throwaway Node, removed afterwards: workflows bring their own with actions/setup-node.
node=$(mktemp -d)
trap 'rm -rf "$node" /root/.npm' EXIT
file=$(curl -fsSL "$node_dist/latest-v$NODE_MAJOR.x/SHASUMS256.txt" | grep -o "node-v[0-9.]*-linux-$arch.tar.xz" | head -1)
curl -fsSL "$node_dist/latest-v$NODE_MAJOR.x/$file" | tar -xJ -C "$node" --strip-components=1
PATH=$node/bin:$PATH npx --yes "playwright@$PLAYWRIGHT_VERSION" install-deps chromium
