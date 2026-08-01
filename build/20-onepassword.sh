#!/usr/bin/env bash

# Exit on error, unset variable, or pipe failure
set -euo pipefail

###############################################################################
# 1Password Desktop + CLI
###############################################################################
# Installs 1Password from its official RPM repository, following the
# Universal Blue/Bluefin third-party repo conventions:
#
# - Always clean up temporary repository files after installation
# - Use dnf5 exclusively (never dnf or yum)
# - Always use -y flag for non-interactive operations
# - Remove repo files to keep the image clean (repos don't work at runtime)
#
# NOTE: the 1password package installs into /opt/1Password. The Containerfile
# must keep /opt as a real directory rather than symlinking it to /var/opt, or
# these files land in runtime state and vanish from the image. See the /opt
# block in Containerfile.
###############################################################################

echo "Installing 1Password..."

# Add 1Password RPM repository GPG key
rpm --import https://downloads.1password.com/linux/keys/1password.asc

# Add 1Password RPM repository
cat >/etc/yum.repos.d/1password.repo <<'EOF'
[1password]
name=1Password Stable Channel
baseurl=https://downloads.1password.com/linux/rpm/stable/$basearch
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://downloads.1password.com/linux/keys/1password.asc
EOF

# Desktop app plus the `op` CLI, which also backs the SSH agent and
# `op run` secret injection
dnf5 install -y 1password 1password-cli

# Clean up repo file (required - repos don't work at runtime in bootc images)
rm -f /etc/yum.repos.d/1password.repo

echo "1Password installed successfully"
