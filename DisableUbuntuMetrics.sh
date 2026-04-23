#!/bin/bash

# DisableUbuntuMetrics.sh
# Removes and permanently blocks Ubuntu telemetry services:
#   apport, whoopsie, ubuntu-report, popularity-contest
# Made with love by NullAngst.

set -euo pipefail

# ── Helpers ───────────────────────────────────────────────────────────────────

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

# Safe printf-to-file helper (avoids the redirect-as-user permission bug)
write_file() {
    local path="$1"
    local content="$2"
    printf '%s\n' "$content" > "$path"
}

# ── Pre-flight ────────────────────────────────────────────────────────────────

require_root

# ── Step 1: Remove existing telemetry config files ───────────────────────────

info "Removing existing telemetry configuration files..."
rm -rf \
    /etc/popularity-contest.conf \
    /etc/default/no-report \
    /etc/default/apport \
    /etc/default/whoopsie
success "Old telemetry config files removed."
echo ""

# ── Step 2: Stop and disable telemetry services ──────────────────────────────

info "Stopping and disabling telemetry services..."
for service in apport.service whoopsie.service; do
    if systemctl is-active --quiet "$service" 2>/dev/null; then
        systemctl stop "$service"
        info "  Stopped $service"
    fi
    if systemctl is-enabled --quiet "$service" 2>/dev/null; then
        systemctl disable "$service"
        info "  Disabled $service"
    fi
done
success "Telemetry services stopped."
echo ""

# ── Step 3: Uninstall telemetry packages ─────────────────────────────────────

info "Removing telemetry packages..."
apt-get remove -y apport whoopsie ubuntu-report 2>/dev/null || warn "Some packages were not installed; skipping."
success "Telemetry packages removed."
echo ""

# ── Step 4: Create apt preference pins to block reinstallation ───────────────

info "Creating apt preference pins to block telemetry packages..."

mkdir -p /etc/apt/preferences.d

write_file /etc/apt/preferences.d/no-ubuntu-report.pref \
"Package: ubuntu-report
Pin: release a=*
Pin-Priority: -10"

write_file /etc/apt/preferences.d/no-whoopsie.pref \
"Package: whoopsie
Pin: release a=*
Pin-Priority: -10"

write_file /etc/apt/preferences.d/no-apport.pref \
"Package: apport
Pin: release a=*
Pin-Priority: -10"

success "Apt preference pins created."
echo ""

# ── Step 5: Disable ubuntu-report ────────────────────────────────────────────

info "Disabling ubuntu-report..."
touch /etc/default/no-report
success "ubuntu-report disabled."
echo ""

# ── Step 6: Disable popularity-contest ───────────────────────────────────────

info "Disabling Popularity Contest metrics..."

# /etc/popularity-contest.conf is a FILE, not a directory
write_file /etc/popularity-contest.conf "ENABLED=no"

success "Popularity Contest disabled."
echo ""

# ── Step 7: Disable apport crash reporting ───────────────────────────────────

info "Disabling automatic crash reports..."
write_file /etc/default/apport \
"ENABLED=0
ENABLE_AUTO_REPORT_BUGS=0"
success "apport crash reporting disabled."
echo ""

# ── Step 8: Disable whoopsie crash report sending ────────────────────────────

info "Disabling whoopsie crash report uploads..."
write_file /etc/default/whoopsie "report_crashes=false"
success "whoopsie disabled."
echo ""

# ── Step 9: Cleanup ───────────────────────────────────────────────────────────

info "Running apt cleanup..."
apt-get autoremove -y
apt-get clean
echo ""

success "All telemetry and metrics collection has been disabled."
echo ""
echo "Made with love by NullAngst"
