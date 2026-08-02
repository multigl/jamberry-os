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
	check "ujust:body" "ujust --show install-jamberry-apps | grep -q default.Brewfile"

	# grep -x pins the entire line, so EDITOR=/usr/bin/nvim fails this check on
	# purpose: an absolute path would defeat PATH resolution at exec time.
	check "env:editor" "grep -qx EDITOR=nvim /etc/environment"
	check "env:visual" "grep -qx VISUAL=nvim /etc/environment"

	# /etc/environment reaches PAM sessions only. This proves a non-PAM login shell
	# - the rescue case - also lands on nvim rather than Fedora's nano default.
	login_editor=$(env -i /bin/bash -lic 'printf %s "$EDITOR"' 2>/dev/null)
	if [ "$login_editor" = nvim ]; then echo "editor:login:yes"; else echo "editor:login:no"; fi

	for package in vivaldi-stable; do
		check "rpm:${package}" "rpm -q ${package}"
	done

	# Firefox comes from the base image, not from this repo, so these guard
	# against a base-image bump quietly reintroducing it.
	check "rpm:firefox-absent" "! rpm -q firefox"
	check "rpm:firefox-langpacks-absent" "! rpm -q firefox-langpacks"
	check "desktop:firefox-absent" "! test -e /usr/share/applications/org.mozilla.firefox.desktop"

	check "desktop:vivaldi" "test -e /usr/share/applications/vivaldi-stable.desktop"
	# The desktop file's Exec= points here, so a missing binary is a broken
	# launcher rather than a missing package.
	check "bin:vivaldi" "test -x /usr/bin/vivaldi-stable"

	# grep -x pins the whole line. A substring match would also accept a binding
	# to some other desktop id that merely contains this one.
	check "mime:html" "grep -qx 'text/html=vivaldi-stable.desktop' /etc/xdg/mimeapps.list"
	check "mime:xhtml" "grep -qx 'application/xhtml+xml=vivaldi-stable.desktop' /etc/xdg/mimeapps.list"
	check "mime:http" "grep -qx 'x-scheme-handler/http=vivaldi-stable.desktop' /etc/xdg/mimeapps.list"
	check "mime:https" "grep -qx 'x-scheme-handler/https=vivaldi-stable.desktop' /etc/xdg/mimeapps.list"

	# vivaldi-stable.desktop also claims application/pdf and four image types.
	# Leaving them unbound here is deliberate, so a later GNOME Papers or Loupe
	# install can claim them via gnome-mimeapps.list - their absence from this
	# file is the assertion, not an omission.
	check "mime:pdf-untouched" "! grep -q '^application/pdf=' /etc/xdg/mimeapps.list"

	# The vivaldi-stable %post writes /etc/yum.repos.d/vivaldi.repo itself, and
	# /etc/cron.daily/vivaldi exists to put it back. Repos do not work at runtime
	# in a bootc image, so both must be gone.
	check "repo:vivaldi-absent" "! test -e /etc/yum.repos.d/vivaldi.repo"
	check "cron:vivaldi-absent" "! test -e /etc/cron.daily/vivaldi"

	check "env:browser" "grep -qx BROWSER=vivaldi-stable /etc/environment"

	# org.gnome.shell's favorite-apps schema default begins with
	# org.mozilla.firefox.desktop, so removing the RPM without an override leaves
	# a dead launcher in the first dash slot of every new account.
	#
	# XDG_CACHE_HOME is redirected because /root is an ostree symlink to
	# var/roothome, which does not resolve during a container run; dconf's failure
	# to create its cache directory is noisy enough to obscure the value.
	favorites=$(XDG_CACHE_HOME=/tmp/cache gsettings get org.gnome.shell favorite-apps 2>/dev/null)
	case "${favorites}" in
	*vivaldi-stable.desktop*) echo "dash:vivaldi:yes" ;;
	*) echo "dash:vivaldi:no" ;;
	esac
	case "${favorites}" in
	*firefox*) echo "dash:no-firefox:no" ;;
	*) echo "dash:no-firefox:yes" ;;
	esac

	# /etc/environment reaches PAM sessions only. This proves a non-PAM login
	# shell - the rescue case - also has BROWSER set.
	login_browser=$(env -i /bin/bash -lic 'printf %s "$BROWSER"' 2>/dev/null)
	if [ "$login_browser" = vivaldi-stable ]; then echo "browser:login:yes"; else echo "browser:login:no"; fi
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

expect "rpm:vivaldi-stable" "vivaldi installed"
expect "rpm:firefox-absent" "firefox removed"
expect "rpm:firefox-langpacks-absent" "firefox-langpacks removed"
expect "desktop:firefox-absent" "firefox desktop file removed"
expect "desktop:vivaldi" "vivaldi desktop file present"
expect "bin:vivaldi" "/usr/bin/vivaldi-stable executable"
expect "mime:html" "text/html bound to vivaldi"
expect "mime:xhtml" "application/xhtml+xml bound to vivaldi"
expect "mime:http" "http scheme bound to vivaldi"
expect "mime:https" "https scheme bound to vivaldi"
expect "mime:pdf-untouched" "application/pdf not bound in /etc/xdg/mimeapps.list"
expect "repo:vivaldi-absent" "vivaldi repo file not in image"
expect "cron:vivaldi-absent" "vivaldi repo-repair cron job not in image"
expect "env:browser" "BROWSER=vivaldi-stable in /etc/environment, PATH-resolved"
expect "dash:vivaldi" "vivaldi in GNOME dash favorites"
expect "dash:no-firefox" "no firefox launcher in GNOME dash favorites"
expect "browser:login" "non-PAM login shell resolves BROWSER to vivaldi-stable"

if ((failures > 0)); then
	printf '\n%d assertion(s) failed\n' "${failures}"
	exit 1
fi

printf '\nAll assertions passed\n'
