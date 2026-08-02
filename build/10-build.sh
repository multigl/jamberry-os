#!/usr/bin/bash

set -euo pipefail

###############################################################################
# Main Build Script
###############################################################################
# This script follows the @ublue-os/bluefin pattern for build scripts.
# It uses set -euo pipefail for strict error handling.
###############################################################################

# Source helper functions
# shellcheck source=/dev/null
source /ctx/build/copr-helpers.sh

# Enable nullglob for all glob operations to prevent failures on empty matches
shopt -s nullglob

echo "::group:: Copy Bluefin Config from Common"

# 00-entry.just is the ujust entrypoint, and its imports of apps.just,
# default.just, shared.just and update.just are not optional. common splits the
# just files across two trees: bluefin/ carries 00-entry, changelog, system and
# 60-bonedigger, and shared/ carries the other four. Copying bluefin/ alone
# leaves those four imports dangling and every ujust invocation dies with
# "could not find source file for import" at 00-entry.just:11.
mkdir -p /usr/share/ublue-os/just/
shopt -s nullglob
cp -r /ctx/oci/common/bluefin/usr/share/ublue-os/just/* /usr/share/ublue-os/just/
cp -r /ctx/oci/common/shared/usr/share/ublue-os/just/* /usr/share/ublue-os/just/
shopt -u nullglob

# Those files need a runner, and the base image has none. Take the wrapper and
# its completions by name rather than overlaying common's shared/ tree, which is
# 183 files including systemd units, ublue-*-setup helpers, fastfetch and umotd
# MOTD integration and uupd config - all of which would change boot behaviour.
# The fish completion is skipped because fish is not installed.
install -Dm0755 /ctx/oci/common/shared/usr/bin/ujust /usr/bin/ujust
install -Dm0644 /ctx/oci/common/shared/usr/share/bash-completion/completions/ujust \
	/usr/share/bash-completion/completions/ujust
install -Dm0644 /ctx/oci/common/shared/usr/share/zsh/site-functions/_ujust \
	/usr/share/zsh/site-functions/_ujust

echo "::endgroup::"

echo "::group:: Overlay Brew Integration Files"

# Brew integration files from @ublue-os/brew OCI (tarball, systemd services, shell integration)
rsync -rvK /ctx/oci/brew/ /

echo "::endgroup::"

echo "::group:: Copy Custom Files"

# Copy Brewfiles to standard location
mkdir -p /usr/share/ublue-os/homebrew/
cp /ctx/custom/brew/*.Brewfile /usr/share/ublue-os/homebrew/

# Consolidate Just Files
find /ctx/custom/ujust -iname '*.just' -exec printf "\n\n" \; -exec cat {} \; >>/usr/share/ublue-os/just/60-custom.just

# Copy Flatpak preinstall files
mkdir -p /usr/share/flatpak/preinstall.d/
cp /ctx/custom/flatpaks/*.preinstall /usr/share/flatpak/preinstall.d/

echo "::endgroup::"

echo "::group:: Install Packages"

# Baked in rather than left to Brew: these are wanted on every boot of every
# install, including before Homebrew has been extracted by brew-setup.service.
# just is the command runner the ujust wrapper execs. neovim overlaps with the copy
# chezmoi installs from Homebrew, and that overlap is deliberate. The image keeps
# /usr/bin ahead of Homebrew - ublue's /etc/profile.d/brew.sh strips brew
# shellenv's own PATH= line and appends instead, so Homebrew cannot shadow system
# binaries like dbus - so this copy is what a stock session resolves. A shell whose
# own config prepends /home/linuxbrew/.linuxbrew/bin, as these dotfiles do, gets
# the Homebrew copy; this one remains the floor for first boot and rescue.
dnf5 install -y tmux neovim chezmoi just zsh

# Ghostty is not packaged in Fedora or on Flathub. scottames/ghostty is the COPR
# linked from the Ghostty docs; it tracks tagged releases and also carries the
# gtk4-layer-shell dependency, which Fedora does not ship either.
copr_install_isolated "scottames/ghostty" ghostty

# Example using COPR with isolated pattern:
# copr_install_isolated "ublue-os/staging" package-name

echo "::endgroup::"

echo "::group:: System Configuration"

# Enable/disable systemd services
systemctl enable podman.socket
systemctl enable brew-setup.service
systemctl enable brew-update.timer
systemctl enable brew-upgrade.timer
# Example: systemctl mask unwanted-service

# EDITOR is the bare command name on purpose: it resolves through whatever PATH
# the session actually has at exec time instead of pinning every session to one
# copy of neovim. The image itself keeps /usr/bin ahead of Homebrew - ublue's
# /etc/profile.d/brew.sh drops brew shellenv's own PATH= line and appends, so
# Homebrew cannot shadow system binaries like dbus - so a stock session gets the
# dnf copy. A shell whose own config prepends /home/linuxbrew/.linuxbrew/bin, as
# these dotfiles do, gets the Homebrew copy. An absolute path here would take that
# choice away from the session.
#
# /etc/environment is read by pam_env.so, which /etc/authselect/system-auth has in
# its auth stack, so this reaches every PAM session - login shells, ssh and GDM.
# It also runs before profile.d, so Fedora's nano-default-editor snippet finds
# EDITOR already set, hits its own [ -z "$EDITOR" ] guard, and does nothing.
#
# The file exists and is empty in the base image, so this appends rather than
# creates. /etc is a three-way merge target in bootc: a host that edits this file
# locally keeps its edit across bootc upgrade, making this a default rather than
# enforced policy, which is the intent.
cat >>/etc/environment <<'EOF'
EDITOR=nvim
VISUAL=nvim
EOF

# The same defaults again, for the shells /etc/environment never reaches. The
# file's own header explains why it is not redundant.
cat >/etc/profile.d/zz-jamberry-editor.sh <<'EOF'
# jamberry-os: default editor for login shells that never see /etc/environment.
#
# This is NOT redundant with /etc/environment. pam_env.so appears only in the auth
# stack of /etc/authselect/system-auth, never the session stack, and a rescue shell
# - systemd-sulogin-shell handing off to sulogin - runs with no PAM at all, so it
# never reads that file. Without this snippet such a shell sources Fedora's
# nano-default-editor.sh, finds EDITOR unset, and lands on nano. That rescue shell
# is exactly what the baked neovim exists for.
#
# The zz- prefix makes this sort after nano-default-editor.sh, whose own
# [ -z "$EDITOR" ] guard would otherwise win. Setting the variables
# unconditionally is deliberate: a user's ~/.bashrc or ~/.zshrc runs later still
# and can override them.
#
# Bare command names, not absolute paths, so they resolve through the session's
# own PATH - see build/10-build.sh for why that matters.
export EDITOR=nvim
export VISUAL=nvim
EOF
chmod 0644 /etc/profile.d/zz-jamberry-editor.sh

echo "::endgroup::"

# Restore default glob behavior
shopt -u nullglob

echo "Custom build complete!"
