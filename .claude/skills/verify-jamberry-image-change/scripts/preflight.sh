#!/usr/bin/env bash
###############################################################################
# Host preflight. Sourced by the tier scripts; not meant to be run directly.
#
# The hazard this exists for is specific and quiet. The pinned silverblue base
# is a multi-arch index carrying BOTH linux/amd64 and linux/arm64, while CI
# publishes amd64 only. So on an Apple Silicon Mac `podman build` does not fail
# - it happily selects the arm64 base, builds an arm64 image, and sails through
# tests/image-contract.sh. You get a green run for an artifact that will never
# ship. A false pass is worse than a crash, so refuse up front.
###############################################################################

# shellcheck shell=bash

_pf_die() {
	printf '\n\033[31m%s\033[0m\n' "UNSUPPORTED HOST" >&2
	printf '%s\n' "$@" >&2
	exit 1
}

# require_supported_host <tier>   tier is 1 or 2
require_supported_host() {
	local tier=${1:?tier required}
	local os arch
	os=$(uname -s)
	arch=$(uname -m)

	if [[ ${os} != Linux ]]; then
		_pf_die \
			"Detected ${os} (${arch}); this loop needs Linux with KVM." \
			"" \
			"On macOS, podman runs inside its own Linux VM and there is no /dev/kvm" \
			"to nest a bootc VM inside, so tier 2 cannot boot the image at all." \
			"" \
			"Build and verify on the x86-64 Linux host instead, or let CI do it:" \
			"  gh workflow run build-image.yml --ref <your-branch>"
	fi

	if [[ ${arch} != x86_64 ]]; then
		_pf_die \
			"Detected ${os}/${arch}; this image is published for amd64 only." \
			"" \
			"The silverblue base is a multi-arch index, so a build here would" \
			"SUCCEED against the arm64 base and pass the contract test - while" \
			"testing an image CI never publishes. That false pass is the reason" \
			"this check is fatal rather than a warning." \
			"" \
			"Set VERIFY_ALLOW_UNSUPPORTED_HOST=1 to override for tier 1 only, and" \
			"treat the result as advisory. Tier 2 has no override: without KVM" \
			"there is nothing to boot."
	fi

	command -v podman >/dev/null || _pf_die "podman not found on PATH."

	[[ ${tier} == 2 ]] || return 0

	# Tier 2 additionally needs to actually boot something.
	[[ -w /dev/kvm ]] || _pf_die \
		"/dev/kvm is missing or not writable." \
		"" \
		"Tier 2 boots the built image under KVM. Without it there is nothing to" \
		"run. Check that virtualisation is enabled and you are in the 'kvm' group." \
		"" \
		"Tier 1 (build + container contract) still works without KVM."

	local missing=()
	local tool
	for tool in virsh virt-install qemu-img expect; do
		command -v "${tool}" >/dev/null || missing+=("${tool}")
	done
	if ((${#missing[@]})); then
		_pf_die \
			"Missing tier 2 tooling: ${missing[*]}" \
			"" \
			"On Fedora:  sudo dnf install -y libvirt virt-install qemu-img expect" \
			"Then:       sudo systemctl enable --now virtqemud.socket virtnetworkd.socket"
	fi
}

# Honour the tier-1-only override after the fact, so the message above is still
# what an unprepared caller sees first.
if [[ ${VERIFY_ALLOW_UNSUPPORTED_HOST:-0} == 1 ]]; then
	require_supported_host() {
		local tier=${1:?tier required}
		if [[ ${tier} == 2 ]]; then
			_pf_die "VERIFY_ALLOW_UNSUPPORTED_HOST does not apply to tier 2: KVM is not optional."
		fi
		printf '\033[33m%s\033[0m\n' \
			"WARNING: host check overridden. Building on $(uname -s)/$(uname -m)." \
			"Results are advisory only and may not reflect the amd64 image CI ships."
	}
fi
