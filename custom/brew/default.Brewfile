# Default Brewfile for jamberry-os
# Uncomment packages you want to install, or add your own.
# Users install via: ujust install-default-apps
#
# Anything that must exist before Homebrew does is baked into the image instead:
# zsh, just, chezmoi, neovim and tmux with dnf in build/10-build.sh, ghostty from
# a COPR in that same script, 1Password in build/20-onepassword.sh, and git from
# the base image as git-core. Homebrew owns user-space tooling that should track
# upstream and stay identical to the macOS side.
#
# Overlap between the two is allowed only where the dnf copy is a bootstrap or
# rescue fallback. neovim is the one such case: chezmoi installs a Homebrew copy
# on Linux. The image keeps /usr/bin ahead of Homebrew - ublue's brew.sh appends
# to PATH on purpose, so Homebrew cannot shadow system binaries like dbus - so the
# Homebrew copy wins only in shells whose own config prepends it, as these dotfiles
# do. EDITOR is a bare command name, so it follows whichever the session resolves.
