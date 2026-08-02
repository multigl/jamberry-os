#!/usr/bin/env bash

# Exit on error, unset variable, or pipe failure
set -euo pipefail

###############################################################################
# Vivaldi browser, replacing Firefox
###############################################################################
# jamberry-os ships Vivaldi as its default browser and does not ship Firefox at
# all. Both halves of that swap live here rather than being split across
# 10-build.sh and a separate defaults script, so the whole browser decision can
# be read, reviewed and reverted as one unit.
#
# NOTE: vivaldi-stable unpacks into /opt/vivaldi. The Containerfile must keep
# /opt as a real directory rather than the base image's symlink to var/opt, or
# rpm cannot unpack through it and the install fails with
# "cpio: mkdir failed - File exists". The /opt block in Containerfile already
# does this for 1Password; that line is load-bearing for this script too.
###############################################################################

echo "::group:: Remove Firefox"

# firefox-langpacks is the only package that requires firefox, so the pair comes
# out cleanly. This frees 336 MiB and the vivaldi-stable that replaces it costs
# 444 MiB, so the image grows by roughly 108 MiB - a deliberate trade, not an
# oversight.
dnf5 remove -y firefox firefox-langpacks

echo "::endgroup::"

echo "::group:: Install Vivaldi"

# The archive channel is what Vivaldi's own vivaldi-fedora.repo points at, and it
# retains every release rather than only the current one.
rpm --import https://repo.vivaldi.com/archive/linux_signing_key.pub

# Named vivaldi-tmp.repo rather than vivaldi.repo on purpose: the package's %post
# writes a vivaldi.repo of its own. Distinct names mean the cleanup below cannot
# remove one file while appearing to have removed both.
cat >/etc/yum.repos.d/vivaldi-tmp.repo <<'EOF'
[vivaldi-tmp]
name=Vivaldi (build-time only)
baseurl=https://repo.vivaldi.com/archive/rpm/$basearch
enabled=1
gpgcheck=1
gpgkey=https://repo.vivaldi.com/archive/linux_signing_key.pub
EOF

dnf5 install -y vivaldi-stable

# Both repo files have to go - the one written above and the one the %post
# created. Repos do not work at runtime in a bootc image, and an enabled
# third-party repo left in the image breaks the project's cleanup rule.
rm -f /etc/yum.repos.d/vivaldi-tmp.repo /etc/yum.repos.d/vivaldi.repo

# This cron job exists specifically to recreate /etc/yum.repos.d/vivaldi.repo.
# cronie is not installed in the base image so it cannot fire today, but leaving
# it would silently undo the cleanup above if cron were ever layered in.
rm -f /etc/cron.daily/vivaldi

echo "::endgroup::"

echo "::group:: Default Browser"

# /etc/xdg/mimeapps.list does not exist in the base image, and it outranks both
# files that currently claim the web types: /usr/share/applications/mimeapps.list
# binds them to Firefox, and gnome-mimeapps.list binds them to Epiphany, which is
# not installed. It is also the location the XDG spec reserves for system
# administrators.
#
# /etc is a three-way merge target in bootc, so a user who picks a different
# browser keeps that choice across bootc upgrade. This is a default, not policy.
#
# Only the four web types are bound. vivaldi-stable.desktop also claims
# application/pdf and four image types; binding those would displace GNOME Papers
# and Loupe, which is not what "default browser" means.
cat >/etc/xdg/mimeapps.list <<'EOF'
[Default Applications]
text/html=vivaldi-stable.desktop
application/xhtml+xml=vivaldi-stable.desktop
x-scheme-handler/http=vivaldi-stable.desktop
x-scheme-handler/https=vivaldi-stable.desktop
EOF
chmod 0644 /etc/xdg/mimeapps.list

# org.gnome.shell's favorite-apps default is set in the schema XML itself and
# begins with org.mozilla.firefox.desktop, so removing that RPM without this
# override leaves a dead launcher in the first dash slot of every new account.
# This is the base image's own list with Firefox swapped for Vivaldi and nothing
# else changed.
#
# The zz- prefix sorts this after the eight overrides the base image already
# ships, so it wins. glib-compile-schemas must run afterwards or it is inert.
cat >/usr/share/glib-2.0/schemas/zz-jamberry-browser.gschema.override <<'EOF'
[org.gnome.shell]
favorite-apps=['vivaldi-stable.desktop', 'org.gnome.Calendar.desktop', 'org.gnome.Nautilus.desktop', 'org.gnome.Software.desktop', 'org.gnome.TextEditor.desktop', 'org.gnome.Calculator.desktop']
EOF
chmod 0644 /usr/share/glib-2.0/schemas/zz-jamberry-browser.gschema.override
glib-compile-schemas /usr/share/glib-2.0/schemas/

# BROWSER for the CLI tools that read it directly rather than shelling out to
# xdg-open. Same two-file treatment as EDITOR/VISUAL in build/10-build.sh, for
# the reason that script's comments record: /etc/environment is read by
# pam_env.so and so reaches PAM sessions, while a profile.d snippet reaches the
# non-PAM login shells that pam_env never touches.
#
# A bare command name rather than an absolute path, so it resolves through
# whatever PATH the session has at exec time.
cat >>/etc/environment <<'EOF'
BROWSER=vivaldi-stable
EOF

cat >/etc/profile.d/zz-jamberry-browser.sh <<'EOF'
# jamberry-os: default browser for login shells that never see /etc/environment.
#
# This is NOT redundant with /etc/environment. pam_env.so appears only in the auth
# stack of /etc/authselect/system-auth, never the session stack, and a rescue
# shell - systemd-sulogin-shell handing off to sulogin - runs with no PAM at all,
# so it never reads that file.
#
# Bare command name, not an absolute path, so it resolves through the session's
# own PATH - see build/10-build.sh for why that matters.
export BROWSER=vivaldi-stable
EOF
chmod 0644 /etc/profile.d/zz-jamberry-browser.sh

echo "::endgroup::"

echo "Vivaldi installed successfully"
