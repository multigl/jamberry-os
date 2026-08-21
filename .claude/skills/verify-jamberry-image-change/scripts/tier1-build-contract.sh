#!/usr/bin/env bash
###############################################################################
# Tier 1: lint, build rootful, assert the container contract.
#
# Run this for every image change. It is the cheap loop - a warm rebuild plus
# the contract suite finishes in a few minutes.
###############################################################################
set -euo pipefail

# Refuse hosts where this loop cannot produce a trustworthy result.
# Resolved at runtime relative to this script; shellcheck cannot follow it
# from the repo root, where `just lint` runs.
# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/preflight.sh"
require_supported_host 1

# This skill lives outside the repo (~/.claude/skills), so the repo is wherever
# the caller is, not wherever this script is. Refuse to run anywhere that is not
# a jamberry-os checkout.
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || {
	echo "Not inside a git repository. cd to your jamberry-os checkout first." >&2
	exit 1
}
cd "${REPO_ROOT}"
if [[ ! -f Containerfile || ! -f Justfile || ! -f tests/image-contract.sh ]]; then
	echo "${REPO_ROOT} does not look like a jamberry-os checkout." >&2
	exit 1
fi

IMAGE_NAME=${IMAGE_NAME:-jamberry-os}
TAG=${TAG:-stable}

step() { printf '\n\033[1m==> %s\033[0m\n' "$*"; }

# sudo here preserves XDG_RUNTIME_DIR, so a rootful `just` or `podman` drops
# root-owned state into the user's runtime dir and every later rootless call
# fails with EACCES - `just lint` dies on a permission error creating its temp
# dir. Scrub the variable from all rootful calls, and sweep any leftovers from
# a previous run so this script is self-healing.
sudoif() { sudo -E env -u XDG_RUNTIME_DIR "$@"; }

if [[ -n ${XDG_RUNTIME_DIR:-} ]] && find "${XDG_RUNTIME_DIR}" -maxdepth 1 -user root -print -quit 2>/dev/null | grep -q .; then
	step "Sweeping root-owned leftovers from ${XDG_RUNTIME_DIR}"
	sudo find "${XDG_RUNTIME_DIR}" -mindepth 1 -maxdepth 1 -user root -exec rm -rf {} +
fi

step "Shellcheck (just lint)"
just lint

step "Justfile syntax (just check)"
just check

# Rootful on purpose: a rootless build fails at `bootc container lint` because
# /sys/kernel/security/ima/binary_runtime_measurements is unreadable. That is an
# artifact of rootless podman, not a fault in the image.
step "Build ${IMAGE_NAME}:${TAG} (rootful, matches CI)"
sudoif just build "${IMAGE_NAME}" "${TAG}"

step "Container contract (tests/image-contract.sh)"
sudoif ./tests/image-contract.sh "localhost/${IMAGE_NAME}:${TAG}"

step "Image summary"
sudoif podman image inspect "localhost/${IMAGE_NAME}:${TAG}" \
	--format 'version={{index .Config.Labels "org.opencontainers.image.version"}}
size={{.Size}}
layers={{len .RootFS.Layers}}'

cat <<'EOF'

Tier 1 passed.

Note: OCI labels on a local build are not meaningful - GITHUB_REPOSITORY_OWNER
and GITHUB_SHA are unset outside Actions, so vendor and source fall back to
placeholder values. CI sets them correctly.

If this change could affect boot, services, /opt, /var, or systemd units, run
tier 2 before opening a PR:

  .claude/skills/verify-image-change/scripts/tier2-vm-boot.sh
EOF
