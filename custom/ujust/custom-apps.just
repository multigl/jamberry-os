# vim: set ft=make :
####################
### custom-apps.just
####################
## Example application installation commands
## See .agents/skills/finpilot-custom.md for runtime layer guidance
## See .agents/skills/finpilot-examples.md for activation patterns

# Install default applications via Homebrew
[group('Apps')]
install-default-apps:
    #!/usr/bin/env bash
    echo "Installing default applications via Homebrew..."
    brew bundle --file /usr/share/ublue-os/homebrew/default.Brewfile

# Install development tools via Homebrew
[group('Apps')]
install-dev-tools:
    #!/usr/bin/env bash
    echo "Installing development tools via Homebrew..."
    brew bundle --file /usr/share/ublue-os/homebrew/development.Brewfile

# Install fonts via Homebrew
[group('Apps')]
install-fonts:
    #!/usr/bin/env bash
    echo "Installing fonts via Homebrew..."
    brew bundle --file /usr/share/ublue-os/homebrew/fonts.Brewfile

# Install all Brewfiles at once
[group('Apps')]
install-all-brew:
    #!/usr/bin/env bash
    echo "Installing all applications from Brewfiles..."
    brew bundle --file /usr/share/ublue-os/homebrew/default.Brewfile
    brew bundle --file /usr/share/ublue-os/homebrew/development.Brewfile
    brew bundle --file /usr/share/ublue-os/homebrew/fonts.Brewfile

# install-jetbrains-toolbox and its jetbrains-toolbox alias used to live here.
# @projectbluefin/common's apps.just defines both, 00-entry.just sets
# allow-duplicate-recipes, and upstream wins - so the copies here were unreachable
# dead code. Use the upstream recipes, which install the ublue-os/tap cask.

# Install a Flatpak application from Flathub
[group('Apps')]
install-flatpak APP_ID:
    #!/usr/bin/bash
    echo "Installing {{ APP_ID }} from Flathub..."
    flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
    flatpak install -y flathub {{ APP_ID }}

# Example: Install VSCode via Flatpak
[group('Apps')]
install-vscode:
    ujust install-flatpak com.visualstudio.code

# Example: Install GIMP via Flatpak
[group('Apps')]
install-gimp:
    ujust install-flatpak org.gimp.GIMP

# Install the Vivaldi browser via Flatpak
# Preinstalled on first boot; this re-installs it if it was removed
[group('Apps')]
install-vivaldi:
    ujust install-flatpak com.vivaldi.Vivaldi

# neovim, chezmoi, zsh, just and Ghostty come from build/10-build.sh, and
# 1Password from build/20-onepassword.sh, so all of them are always present and
# are not repeated here. The
# neovim overlap with the chezmoi-managed Homebrew copy is deliberate: the dnf
# copy is the floor for first boot and rescue, and since the image keeps /usr/bin
# ahead of Homebrew it is also what a stock session resolves. Shells whose own
# config prepends Homebrew - as these dotfiles do - get the Homebrew copy instead.
# Install everything jamberry-os ships on top of the base image that is not already baked in
[group('Apps')]
install-jamberry-apps:
    #!/usr/bin/env bash
    echo "Installing jamberry-os runtime applications..."
    brew bundle --file /usr/share/ublue-os/homebrew/default.Brewfile
    ujust install-vivaldi
