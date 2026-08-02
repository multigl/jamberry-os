#!/usr/bin/env bash

###############################################################################
# Image contract test
###############################################################################
# Asserts a built image satisfies the fresh-install contract described in
# docs/superpowers/specs/2026-08-02-baked-packages-vs-chezmoi-design.md.
#
# This runs against a built image rather than against the build scripts. Two of
# the failures it is written to catch - a just import that only dangles once the
# files are in place, and an EDITOR set by a package the build never mentions -
# are invisible in the source and appear only in the assembled result.
#
# Usage: tests/image-contract.sh [image-ref]
###############################################################################

set -euo pipefail

image="${1:-localhost/jamberry-os:stable}"
podman="${PODMAN:-podman}"

failures=0

# Every assertion runs in one container. A container per check would dominate
# the runtime of the suite. Each probe prints "<key>:yes" or "<key>:no".
#
# The probe body arrives on stdin as a quoted heredoc rather than as an argument
# to -c, so it can contain quotes of either kind and nothing in it is expanded by
# this shell.
probe=$("${podman}" run --rm -i --entrypoint /bin/bash "${image}" -s <<'PROBE'
	check() { if eval "${2}" >/dev/null 2>&1; then echo "${1}:yes"; else echo "${1}:no"; fi; }

	for package in git-core zsh just neovim chezmoi tmux; do
		check "rpm:${package}" "rpm -q ${package}"
	done

	check "bin:ujust" "command -v ujust"
	check "bin:nvim" "test -x /usr/bin/nvim"
	check "ujust:list" "ujust --list"
	check "ujust:custom" "ujust --list | grep -q install-jamberry-apps"

	# A name in --list proves nothing about which body is bound to it: 00-entry.just
	# sets allow-duplicate-recipes, so an upstream file can silently take over a
	# recipe this repo defines. Pin a body, not a name.
	check "ujust:body" "ujust --show install-jamberry-apps | grep -q install-vivaldi"

	# grep -x pins the entire line, so EDITOR=/usr/bin/nvim fails this check on
	# purpose: an absolute path would defeat PATH resolution at exec time.
	check "env:editor" "grep -qx EDITOR=nvim /etc/environment"
	check "env:visual" "grep -qx VISUAL=nvim /etc/environment"

	# /etc/environment reaches PAM sessions only. This proves a non-PAM login shell
	# - the rescue case - also lands on nvim rather than Fedora's nano default.
	login_editor=$(env -i /bin/bash -lic 'printf %s "$EDITOR"' 2>/dev/null)
	if [ "$login_editor" = nvim ]; then echo "editor:login:yes"; else echo "editor:login:no"; fi
PROBE
)

expect() {
	if grep -qx "${1}:yes" <<<"${probe}"; then
		printf 'ok    %s\n' "${2}"
	else
		printf 'FAIL  %s\n' "${2}"
		failures=$((failures + 1))
	fi
}

echo "Image contract: ${image}"

expect "rpm:git-core" "git installed"
expect "rpm:zsh" "zsh installed"
expect "rpm:just" "just installed"
expect "rpm:neovim" "neovim installed"
expect "rpm:chezmoi" "chezmoi installed"
expect "rpm:tmux" "tmux installed"
expect "bin:ujust" "ujust runner on PATH"
expect "bin:nvim" "/usr/bin/nvim executable"
expect "ujust:list" "ujust --list resolves all imports"
expect "ujust:custom" "custom recipes reachable through ujust"
expect "ujust:body" "install-jamberry-apps resolves to this repo's recipe body"
expect "env:editor" "EDITOR=nvim in /etc/environment, PATH-resolved"
expect "env:visual" "VISUAL=nvim in /etc/environment, PATH-resolved"
expect "editor:login" "non-PAM login shell resolves EDITOR to nvim"

if ((failures > 0)); then
	printf '\n%d assertion(s) failed\n' "${failures}"
	exit 1
fi

printf '\nAll assertions passed\n'
