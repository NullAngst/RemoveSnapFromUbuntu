#!/bin/bash

# AptRemoveSnapdInstallFlatpak.sh
# Removes snapd and all snap packages, then installs Flatpak with Flathub.
# Made with love by NullAngst — revised for robustness.

set -euo pipefail

# ── Helpers ──────────────────────────────────────────────────────────────────

info()    { echo -e "\e[1;34m[INFO]\e[0m  $*"; }
success() { echo -e "\e[1;32m[OK]\e[0m    $*"; }
warn()    { echo -e "\e[1;33m[WARN]\e[0m  $*"; }

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "This script must be run with sudo or as root."
        echo "Usage: sudo bash $0"
        exit 1
    fi
}

# ── Pre-flight ────────────────────────────────────────────────────────────────

require_root

# ── Step 1: Update system ─────────────────────────────────────────────────────

info "Updating system before making changes..."
systemctl daemon-reload
apt-get update -y
apt-get full-upgrade -y
apt-get autoremove -y
success "System updated."
echo ""

# ── Step 2: Remove all installed snaps ───────────────────────────────────────

if command -v snap &>/dev/null; then
    info "Removing user-installed snap packages..."

    # Repeat removal passes to handle dependency ordering
    for pass in 1 2 3; do
        # Skip header line and snap packages that are base/core types last
        mapfile -t user_snaps < <(snap list 2>/dev/null | tail -n +2 | awk '{print $1}' | grep -Ev '^(snapd|bare|core.*)$' || true)
        if [[ ${#user_snaps[@]} -gt 0 ]]; then
            info "Pass $pass — removing: ${user_snaps[*]}"
            for snap_pkg in "${user_snaps[@]}"; do
                snap remove --purge "$snap_pkg" 2>/dev/null || warn "Could not remove $snap_pkg (may already be gone)"
            done
        fi
    done

    # Remove base snaps in dependency order
    info "Removing base/core snaps..."
    for base_snap in bare core22 core20 core18 core snapd; do
        snap remove --purge "$base_snap" 2>/dev/null || true
    done

    success "Snap packages removed."
else
    warn "snap command not found — skipping snap package removal."
fi
echo ""

# ── Step 3: Stop snapd service ────────────────────────────────────────────────

info "Stopping and disabling snapd services..."
for unit in snapd.service snapd.socket snapd.seeded.service snapd.apparmor.service; do
    systemctl stop "$unit"    2>/dev/null || true
    systemctl disable "$unit" 2>/dev/null || true
done
success "snapd services stopped."
echo ""

# ── Step 4: Purge snapd package ───────────────────────────────────────────────

info "Purging snapd package..."
apt-get purge snapd -y
systemctl daemon-reload
success "snapd purged."
echo ""

# ── Step 5: Remove leftover directories ──────────────────────────────────────

info "Removing snapd data directories..."
rm -rf /var/lib/snapd /var/snap /snap /root/snap
# Remove per-user snap directories
find /home -maxdepth 2 -name snap -type d -exec rm -rf {} + 2>/dev/null || true
success "snapd directories removed."
echo ""

# ── Step 6: Prevent snapd from being reinstalled ─────────────────────────────

info "Pinning snapd to prevent reinstallation..."

# apt-mark hold
apt-mark hold snapd

# Belt-and-suspenders: apt preferences pin
cat > /etc/apt/preferences.d/no-snapd.pref << 'EOF'
Package: snapd
Pin: release a=*
Pin-Priority: -10
EOF

success "snapd is now blocked from reinstallation."
echo ""

# ── Step 7: Install Flatpak ───────────────────────────────────────────────────

info "Installing Flatpak..."
apt-get install -y flatpak
success "Flatpak installed."
echo ""

info "Adding Flathub (stable) remote..."
flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
success "Flathub stable added."

info "Adding Flathub Beta remote..."
flatpak remote-add --if-not-exists flathub-beta https://flathub.org/beta-repo/flathub-beta.flatpakrepo
success "Flathub Beta added."
echo ""

# ── Optional: GNOME Software Flatpak plugin ───────────────────────────────────
# Uncomment to enable graphical Flatpak installation through the Software app:
# info "Installing GNOME Software Flatpak plugin..."
# apt-get install -y gnome-software-plugin-flatpak
# success "GNOME Software plugin installed."

# ── Optional: Install common software via Flatpak ────────────────────────────
# Uncomment to automatically install a starter set of apps:
# info "Installing starter Flatpak apps..."
# flatpak install -y flathub \
#     org.mozilla.firefox \
#     io.mpv.Mpv \
#     org.videolan.VLC \
#     com.spotify.Client \
#     com.github.tchx84.Flatseal \
#     org.onlyoffice.desktopeditors \
#     org.gnome.Loupe
# success "Starter apps installed."

# ── Final cleanup ─────────────────────────────────────────────────────────────

info "Final apt cleanup..."
apt-get autoremove -y
apt-get clean
echo ""

success "All done! snapd has been removed and Flatpak is ready."
echo ""
echo "  • Search for apps : flatpak search <name>"
echo "  • Install an app  : flatpak install flathub <app-id>"
echo "  • List installed  : flatpak list"
echo ""
echo "  NOTE: A reboot is recommended to ensure all mounts are cleanly unmounted."
echo ""
echo "Made with love by NullAngst"
