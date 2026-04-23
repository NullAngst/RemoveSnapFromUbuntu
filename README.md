# RemoveSnapFromUbuntu
 
A pair of bash scripts to debloat Ubuntu by removing `snapd` and its telemetry stack, replacing it with [Flatpak](https://flatpak.org/) and clean apt-pinning to make sure neither comes back.
 
---
 
## Scripts
 
### `AptRemoveSnapdInstallFlatpak.sh`
 
Completely removes snapd and installs Flatpak as the replacement package manager.
 
**What it does:**
- Updates the system before making any changes
- Removes all installed snap packages (multiple passes for dependency ordering)
- Removes base/core snaps (`bare`, `core22`, `core20`, `snapd`, etc.)
- Stops and disables all `snapd` systemd units
- Purges the `snapd` package and all leftover directories (`/var/lib/snapd`, `/var/snap`, `/snap`, per-user `~/snap`)
- Blocks `snapd` from being reinstalled via both `apt-mark hold` and an apt preferences pin
- Installs Flatpak with both the stable and beta [Flathub](https://flathub.org/) remotes
**Optional (uncomment in script):**
- Install the GNOME Software Flatpak plugin for graphical app management
- Install a curated starter set of Flatpak apps (Firefox, VLC, Spotify, OnlyOffice, etc.)
---
 
### `DisableUbuntuMetrics.sh`
 
Removes Ubuntu's built-in telemetry and crash reporting services and prevents them from being reinstalled.
 
**What it disables:**
 
| Service | Purpose |
|---|---|
| `apport` | Automatic crash report collection |
| `whoopsie` | Crash report upload to Canonical |
| `ubuntu-report` | System hardware/software metrics sent to Canonical |
| `popularity-contest` | Anonymous package usage statistics |
 
**What it does:**
- Removes existing telemetry configuration files cleanly before recreating them
- Stops and disables `apport` and `whoopsie` systemd services
- Uninstalls `apport`, `whoopsie`, and `ubuntu-report` packages
- Creates apt preference pins (`Pin-Priority: -10`) to block all four packages from being reinstalled by future `apt upgrade` runs
- Writes disable flags for each service to `/etc/default/` and `/etc/popularity-contest.conf`
---
 
## Usage
 
Both scripts require root privileges.
 
```bash
# Remove snap and install Flatpak
sudo bash AptRemoveSnapdInstallFlatpak.sh
 
# Disable telemetry and metrics
sudo bash DisableUbuntuMetrics.sh
```
 
You can run them in either order or together. A **reboot is recommended** after running the snap removal script to ensure all snap loop mounts are cleanly unmounted.
 
---
 
## Compatibility
 
Tested targets:
 
| Distro | Versions |
|---|---|
| Ubuntu | 22.04 LTS, 24.04 LTS |
| Ubuntu flavors | Kubuntu, Xubuntu, Ubuntu MATE, etc. |
 
These scripts are not intended for Debian, Linux Mint, or other non-Ubuntu derivatives, though the logic may work with minor adaptation.
 
---
 
## After Installation — Using Flatpak
 
```bash
# Search for an application
flatpak search firefox
 
# Install from Flathub
flatpak install flathub org.mozilla.firefox
 
# Run an installed app
flatpak run org.mozilla.firefox
 
# List installed apps
flatpak list
 
# Update all Flatpak apps
flatpak update
```
 
---
 
## License
 
See [LICENSE](LICENSE) for terms.
 
---
 
*Made with love by NullAngst*
 

