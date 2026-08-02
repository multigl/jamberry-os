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
# chezmoi installs from Homebrew, and that overlap is deliberate - Homebrew's
# bin directory precedes /usr/bin on PATH, so its copy wins once dotfiles have
# been applied, and this one is the floor for first boot and rescue.
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

# EDITOR is the bare command name on purpose. Homebrew's profile.d snippet puts
# /home/linuxbrew/.linuxbrew/bin ahead of /usr/bin, so resolving through PATH at
# exec time is what lets a brew-installed neovim take over once chezmoi has run,
# while the dnf copy stays the floor for first boot and rescue. An absolute path
# here would pin every session to the dnf copy forever.
#
# /etc/environment rather than /etc/profile.d: pam_env.so is in the auth stack of
# /etc/authselect/system-auth, so this reaches every PAM session - login shells,
# ssh and GDM - where a profile.d snippet reaches login shells only. It also runs
# before profile.d, so Fedora's nano-default-editor snippet finds EDITOR already
# set, hits its own [ -z "$EDITOR" ] guard, and does nothing.
#
# The file exists and is empty in the base image, so this appends rather than
# creates. /etc is a three-way merge target in bootc: a host that edits this file
# locally keeps its edit across bootc upgrade, making this a default rather than
# enforced policy, which is the intent.
cat >>/etc/environment <<'EOF'
EDITOR=nvim
VISUAL=nvim
EOF

echo "::endgroup::"

# Restore default glob behavior
shopt -u nullglob

echo "Custom build complete!"
