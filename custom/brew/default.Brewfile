# Default Brewfile for jamberry-os
# Uncomment packages you want to install, or add your own.
# Users install via: ujust install-default-apps
#
# Anything that must exist before Homebrew does - git, zsh, just, chezmoi,
# neovim, tmux, ghostty, 1Password - is installed with dnf in build/10-build.sh
# instead. Homebrew owns user-space tooling that should track upstream and stay
# identical to the macOS side.
#
# Overlap between the two is allowed only where the dnf copy is a bootstrap or
# rescue fallback. neovim is the one such case: chezmoi installs a Homebrew copy
# on Linux, and because /home/linuxbrew/.linuxbrew/bin precedes /usr/bin on PATH,
# that copy deliberately shadows the baked one.
