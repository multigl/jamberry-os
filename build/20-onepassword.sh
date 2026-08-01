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

# The `op` CLI backs the SSH agent and `op run` secret injection. 1Password
# publishes it for both arches, but the desktop app only for x86_64, so an
# aarch64 build gets the CLI alone rather than failing to resolve.
packages=(1password-cli)
groups=(onepassword-cli)

arch=$(rpm --eval '%{_arch}')
if [[ "${arch}" == "x86_64" ]]; then
	packages+=(1password)
	groups+=(onepassword onepassword-mcp)
else
	echo "Skipping the 1Password desktop app: not published for ${arch}"
fi

# The post-install scriptlets create these groups with a bare `groupadd`, which
# in an empty build root starts allocating at GID 1000 - the GID Fedora hands
# the first real user. Each scriptlet skips creation when the group already
# exists, so creating them as system groups first keeps them out of that range.
for group_name in "${groups[@]}"; do
	groupadd --system "${group_name}"
done

# /usr/local is an ostree symlink to ../var/usrlocal, and nothing creates that
# target during a container build, so it dangles. The desktop app's %post runs
# `mkdir -p /usr/local/bin` to put its MCP server on PATH; mkdir -p fails on a
# dangling path component, and `set -eu` in the scriptlet turns that into a
# failed rpm transaction. Create the target rather than replacing the symlink
# with a real directory the way /opt is handled - /usr/local has to stay
# writable at runtime, which is the whole point of pointing it at /var.
mkdir -p /var/usrlocal

dnf5 install -y "${packages[@]}"

# `bootc container lint --fatal-warnings` fails on any /etc/group entry with no
# matching sysusers.d declaration, since /etc is not the source of truth for
# accounts in a bootc image.
for group_name in "${groups[@]}"; do
	printf 'g %s %s\n' "${group_name}" "$(getent group "${group_name}" | cut -d: -f3)" \
		>"/usr/lib/sysusers.d/${group_name}.conf"
done

# Clean up repo file (required - repos don't work at runtime in bootc images)
rm -f /etc/yum.repos.d/1password.repo

# The desktop app's %post drops a convenience symlink for its MCP server under
# /usr/local, which resolves into /var. bootc wants /var content declared in
# tmpfiles.d and created at boot rather than baked into the image, so hand the
# symlink over to systemd-tmpfiles and clear what the scriptlet left behind.
# /var/usrlocal itself is already declared by the base image, in
# rpm-ostree-0-integration-opt-usrlocal.conf.
if [[ -L /var/usrlocal/bin/1password-mcp ]]; then
	cat >/usr/lib/tmpfiles.d/1password-mcp.conf <<-'EOF'
		d /var/usrlocal/bin 0755 root root -
		L /var/usrlocal/bin/1password-mcp - - - - /opt/1Password/1password-mcp
	EOF
fi
rm -rf /var/usrlocal

echo "1Password installed successfully"
