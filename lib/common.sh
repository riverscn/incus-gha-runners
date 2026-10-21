# shellcheck shell=bash
# shellcheck disable=SC2034 # the variables set here are used by bin/*
# Shared helpers for bin/*. Sourced, not executed.

set -euo pipefail

IGR_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
IGR_CACHE=/var/cache/incus-gha-runners
IGR_DEFAULT_CONFIG=/etc/incus-gha-runners/config.env

# ---- output -----------------------------------------------------------------

ok() { printf '  ok     %s\n' "$*"; }
step() { printf '  ->     %s\n' "$*"; }
warn() { printf '  warn   %s\n' "$*" >&2; }
die() {
	printf 'error: %s\n' "$*" >&2
	exit 1
}
usage_error() {
	printf 'error: %s\n' "$*" >&2
	exit 2
}
# Exit code 3: the operation needs the person's confirmation (or a token).
needs_confirmation() {
	printf 'confirm: %s\n' "$*" >&2
	exit 3
}

# run CMD...: execute, or only print it under --dry-run.
run() {
	if ((DRY_RUN)); then
		[[ $1 == quiet ]] && shift
		printf '  would  %s\n' "$(printf '%q ' "$@")"
	else
		"$@"
	fi
}

# write_file PATH MODE < content: write stdin to PATH, or only report it under --dry-run.
write_file() {
	local path=$1 mode=$2 content
	content=$(cat)
	if ((DRY_RUN)); then
		printf '  would  write %s:\n' "$path"
		printf '%s\n' "$content" | sed 's/^/           | /'
	else
		install -d "$(dirname "$path")"
		printf '%s\n' "$content" >"$path"
		chmod "$mode" "$path"
	fi
}

# quiet CMD...: with IGR_LOG set, send the command's output to that file and show its tail only on failure.
quiet() {
	if [[ -z ${IGR_LOG:-} ]]; then
		"$@"
	elif ! "$@" >>"$IGR_LOG" 2>&1; then
		tail -n 40 "$IGR_LOG" | sed 's/^/           | /' >&2
		printf 'error: see %s\n' "$IGR_LOG" >&2
		return 1
	fi
}

# ---- arguments --------------------------------------------------------------

# parse_args ALLOWED_FLAGS -- "$@"
# Sets CONFIG, DRY_RUN, YES, FORCE, ALL, TOKEN_STDIN, REBUILD and NUMBERS (array).
# ALLOWED_FLAGS is a space-separated list such as "--dry-run --yes"; --config and -h are always allowed.
parse_args() {
	local allowed=" $1 "
	shift 2
	CONFIG=${IGR_CONFIG:-$IGR_DEFAULT_CONFIG}
	DRY_RUN=0 YES=0 FORCE=0 ALL=0 TOKEN_STDIN=0 REBUILD=0
	NUMBERS=()
	while (($#)); do
		case $1 in
		-h | --help)
			usage
			exit 0
			;;
		--config)
			(($# >= 2)) || usage_error "--config needs a file"
			CONFIG=$2
			shift
			;;
		--config=*) CONFIG=${1#*=} ;;
		--*)
			[[ $allowed == *" $1 "* ]] || usage_error "unknown option $1 (see -h)"
			case $1 in
			--dry-run) DRY_RUN=1 ;;
			--yes) YES=1 ;;
			--force) FORCE=1 ;;
			--all) ALL=1 ;;
			--token-stdin) TOKEN_STDIN=1 ;;
			--rebuild) REBUILD=1 ;;
			esac
			;;
		*)
			[[ $allowed == *" N "* ]] || usage_error "unexpected argument $1 (see -h)"
			[[ $1 =~ ^[1-9][0-9]*$ ]] || usage_error "runner numbers are positive integers, got $1"
			NUMBERS+=("$1")
			;;
		esac
		shift
	done
}

# resolve_numbers: turn --all / explicit numbers into NUMBERS; require at least one.
resolve_numbers() {
	if ((ALL)); then
		((${#NUMBERS[@]} == 0)) || usage_error "give runner numbers or --all, not both"
		mapfile -t NUMBERS < <(seq 1 "$RUNNER_COUNT")
	fi
	((${#NUMBERS[@]} > 0)) || usage_error "which runners? give numbers such as 1 2 3, or --all"
}

# read_token: read one line from stdin into TOKEN when --token-stdin was given.
read_token() {
	TOKEN=
	if ((TOKEN_STDIN)); then
		IFS= read -r TOKEN || true
		TOKEN=${TOKEN//[[:space:]]/}
		[[ -n $TOKEN ]] || die "--token-stdin given but standard input was empty"
	fi
}

# ---- environment ------------------------------------------------------------

require_root() {
	((EUID == 0)) || die "run as root (sudo $0 …)"
}

# take_lock: one mutating script at a time per host.
take_lock() {
	((DRY_RUN)) && return 0
	exec 9>/run/lock/incus-gha-runners.lock
	flock -n 9 || die "another incus-gha-runners script is running"
}

load_config() {
	[[ -r $CONFIG ]] || die "config not found: $CONFIG (start from $IGR_ROOT/config.example.env)"
	# shellcheck source=/dev/null
	source "$CONFIG"

	: "${GITHUB_URL:?GITHUB_URL is required in $CONFIG}"
	: "${RUNNER_LABELS:?RUNNER_LABELS is required in $CONFIG}"
	[[ $GITHUB_URL =~ ^https://github\.com/[^/]+(/[^/]+)?/?$ ]] ||
		die "GITHUB_URL must be https://github.com/OWNER/REPO or https://github.com/ORG, got $GITHUB_URL"
	GITHUB_URL=${GITHUB_URL%/}

	: "${RUNNER_NAME_PREFIX:=$(hostname -s)-}"
	: "${RUNNER_GROUP:=}"
	: "${CONTAINER_PREFIX:=ci}"
	: "${RUNNER_COUNT:=1}"
	: "${RUNNER_VERSION:=latest}"
	: "${LIMITS_CPU:=}"
	: "${LIMITS_MEMORY:=}"
	: "${DEBIAN_SUITE:=trixie}"
	: "${EXTRA_PACKAGES:=}"
	: "${DOCKER_BUILDER_KEEP:=3GB}"
	: "${HOOKS_DIR:=/etc/incus-gha-runners/hooks.d/$CONTAINER_PREFIX}"
	: "${INCUS_BRIDGE:=incusbr0}"
	: "${UPLINK_IF:=$(ip -4 route show default 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit }}')}"
	: "${HUB_MIRROR_PORT:=5000}"
	: "${HUB_MIRROR_NAME:=hub-mirror}"
	: "${RUNNER_DOWNLOAD_URL:=https://github.com/actions/runner/releases/download}"

	: "${NETWORK_PRESET:=global}"
	case $NETWORK_PRESET in
	global)
		: "${BASE_IMAGE:=images}"
		: "${DEBIAN_MIRROR:=https://deb.debian.org/debian}"
		: "${DEBIAN_SECURITY_MIRROR:=https://security.debian.org/debian-security}"
		: "${HUB_MIRROR:=off}"
		: "${DOCKER_APT_URL:=https://download.docker.com/linux/debian}"
		;;
	cn)
		: "${BASE_IMAGE:=mmdebstrap}"
		: "${DEBIAN_MIRROR:=https://mirrors.tuna.tsinghua.edu.cn/debian}"
		: "${DEBIAN_SECURITY_MIRROR:=https://mirrors.tuna.tsinghua.edu.cn/debian-security}"
		: "${HUB_MIRROR:=on}"
		: "${DOCKER_APT_URL:=https://mirrors.tuna.tsinghua.edu.cn/docker-ce/linux/debian}"
		;;
	*) die "NETWORK_PRESET must be global or cn, got $NETWORK_PRESET" ;;
	esac
	[[ $BASE_IMAGE == images || $BASE_IMAGE == mmdebstrap ]] || die "BASE_IMAGE must be images or mmdebstrap"
	[[ $HUB_MIRROR == on || $HUB_MIRROR == off ]] || die "HUB_MIRROR must be on or off"
	[[ $RUNNER_COUNT =~ ^[0-9]+$ ]] || die "RUNNER_COUNT must be a number"
	[[ $CONTAINER_PREFIX =~ ^[a-z][a-z0-9-]*$ ]] || die "CONTAINER_PREFIX: lowercase letters, digits and dashes"

	TEMPLATE=$CONTAINER_PREFIX-tpl
}

# ---- host -------------------------------------------------------------------

# version_ge A B: version A >= B
version_ge() { [[ $(printf '%s\n%s\n' "$2" "$1" | sort -V | head -1) == "$2" ]]; }

incus_version() { incus version 2>/dev/null | sed -n 's/^Server version: *//p'; }

# docker_firewall_backend: iptables or nftables (Docker before 28 only has iptables).
docker_firewall_backend() {
	local d
	d=$(docker info --format '{{if .FirewallBackend}}{{.FirewallBackend.Driver}}{{end}}' 2>/dev/null || true)
	printf '%s' "${d:-iptables}"
}

firewalld_active() { systemctl is-active --quiet firewalld 2>/dev/null; }

# ---- incus ------------------------------------------------------------------

container() { printf '%s-%s' "$CONTAINER_PREFIX" "$1"; }
runner_name() { printf '%s%s' "$RUNNER_NAME_PREFIX" "$1"; }

exists() { incus info "$1" >/dev/null 2>&1; }

# state NAME: RUNNING, STOPPED, … (empty when missing)
state() { incus list "^$1\$" -c s -f csv 2>/dev/null; }

bridge_ipv4() {
	local cidr
	cidr=$(incus network get "$INCUS_BRIDGE" ipv4.address 2>/dev/null) || return 1
	[[ -n $cidr && $cidr != none ]] || return 1
	printf '%s' "${cidr%/*}"
}

# wait_ready NAME: wait until systemd is up and the container resolves and reaches the Debian mirror.
wait_ready() {
	local name=$1 host i
	host=$(printf '%s' "$DEBIAN_MIRROR" | sed -E 's#^[a-z]+://([^/:]+).*#\1#')
	for ((i = 0; i < 90; i++)); do
		if incus exec "$name" -- sh -c "systemctl is-system-running --wait >/dev/null 2>&1; getent ahostsv4 $host >/dev/null" 2>/dev/null; then
			return 0
		fi
		sleep 2
	done
	die "$name did not get a working network within 3 minutes (see docs/troubleshooting.md)"
}

RUNNER_DIR=/home/runner/actions-runner

# busy NAME: a job is running in the container.
busy() { [[ $(state "$1") == RUNNING ]] && incus exec "$1" -- pgrep -f Runner.Worker >/dev/null 2>&1; }

registered() { incus exec "$1" -- test -s "$RUNNER_DIR/.runner" 2>/dev/null; }

# service_unit NAME: the runner's systemd unit inside the container (empty if not installed).
service_unit() { incus exec "$1" -- cat "$RUNNER_DIR/.service" 2>/dev/null || true; }

# hook_env: the configuration a hook or the template provisioner can read.
hook_env() {
	local k
	for k in NETWORK_PRESET DEBIAN_SUITE DEBIAN_MIRROR DEBIAN_SECURITY_MIRROR DOCKER_APT_URL \
		HUB_MIRROR HUB_MIRROR_PORT EXTRA_PACKAGES DOCKER_BUILDER_KEEP; do
		printf -- '--env=%s=%s\n' "$k" "${!k}"
	done
	if [[ $HUB_MIRROR == on ]]; then printf -- '--env=HUB_MIRROR_ADDR=%s:%s\n' "$(bridge_ipv4)" "$HUB_MIRROR_PORT"; fi
}

# run_hooks NAME: run every *.sh in HOOKS_DIR inside the container, in file-name order.
run_hooks() {
	local name=$1 hook env
	[[ -d $HOOKS_DIR ]] || {
		ok "no hooks ($HOOKS_DIR does not exist)"
		return 0
	}
	mapfile -t env < <(hook_env)
	shopt -s nullglob
	for hook in "$HOOKS_DIR"/*.sh; do
		step "$name: hook $(basename "$hook")"
		((DRY_RUN)) && continue
		incus file push -q "$hook" "$name/tmp/igr-hook.sh" --mode 0700
		if ! quiet incus exec "$name" "${env[@]}" -- /tmp/igr-hook.sh; then
			printf 'error: hook %s failed in %s\n' "$(basename "$hook")" "$name" >&2
			shopt -u nullglob
			return 1
		fi
		incus exec "$name" -- rm -f /tmp/igr-hook.sh
	done
	shopt -u nullglob
}
