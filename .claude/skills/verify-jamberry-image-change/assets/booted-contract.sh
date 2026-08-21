#!/usr/bin/env bash
###############################################################################
# Assertions that only mean something on a BOOTED system.
#
# Runs inside the test VM. Deliberately does not duplicate
# tests/image-contract.sh - that one already covers everything visible from a
# container. What lives here is the set of properties a container cannot show
# you: whether /opt survived as a real directory, whether a compiled gschema
# resolves through gsettings, whether xdg-settings agrees with mimeapps.list,
# and whether the system reached a healthy state with no failed units.
###############################################################################
pass=0
fail=0

check() {
	if eval "${2}" >/dev/null 2>&1; then
		echo "ok    ${1}"
		pass=$((pass + 1))
	else
		echo "FAIL  ${1}"
		fail=$((fail + 1))
	fi
}

# The base image ships /opt as a symlink to var/opt. /var is machine-local state
# in bootc, so anything a package installs there is absent on a real system. The
# Containerfile replaces it with a real directory; this is that fix, observed
# from the far side of an actual boot.
check "/opt is a real directory, not a symlink" "test -d /opt && ! test -L /opt"
check "/opt/1Password present after boot" "test -d /opt/1Password"
check "/opt/vivaldi present after boot" "test -d /opt/vivaldi"

check "vivaldi-stable installed" "rpm -q vivaldi-stable"
check "vivaldi-stable executable" "test -x /usr/bin/vivaldi-stable"
check "firefox removed" "! rpm -q firefox"
check "firefox-langpacks removed" "! rpm -q firefox-langpacks"

# mimeapps.list is inert unless it actually outranks the base image's bindings.
# xdg-settings answers the question the file only implies.
check "xdg default browser is vivaldi" \
	"test \"\$(xdg-settings get default-web-browser)\" = vivaldi-stable.desktop"

# The gschema override is a text file until glib-compile-schemas runs. gsettings
# reading it back proves the compile step took effect.
check "gsettings favorite-apps leads with vivaldi" \
	"gsettings get org.gnome.shell favorite-apps | grep -q \"^\\['vivaldi-stable.desktop'\""
check "gsettings favorite-apps has no firefox" \
	"! gsettings get org.gnome.shell favorite-apps | grep -q firefox"

check "BROWSER=vivaldi-stable in /etc/environment" \
	"grep -qx 'BROWSER=vivaldi-stable' /etc/environment"
check "EDITOR=nvim in /etc/environment" "grep -qx 'EDITOR=nvim' /etc/environment"

# Build-time repos must not persist: they do not work at runtime in a bootc
# image and an enabled third-party repo violates the project's cleanup rule.
check "vivaldi repo not present" "! test -f /etc/yum.repos.d/vivaldi.repo"
check "vivaldi-tmp repo not present" "! test -f /etc/yum.repos.d/vivaldi-tmp.repo"
check "vivaldi repo-repair cron job absent" "! test -f /etc/cron.daily/vivaldi"

check "1password installed" "rpm -q 1password"
check "ujust on PATH" "command -v ujust"

# A degraded boot still gives you a shell, so this has to be asserted explicitly
# or a broken unit passes unnoticed.
check "system reached running (not degraded)" \
	"test \"\$(systemctl is-system-running)\" = running"
check "no failed units" "test -z \"\$(systemctl --failed --no-legend)\""

echo
echo "passed=${pass} failed=${fail}"
if [[ ${fail} -gt 0 ]]; then
	echo
	echo "Failed unit detail (if any):"
	systemctl --failed --no-legend || true
fi
[[ ${fail} -eq 0 ]]
