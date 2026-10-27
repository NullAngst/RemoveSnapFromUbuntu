#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME=${0##*/}

ASSUME_YES=0
DRY_RUN=0
KEEP_APPORT=0

TELEMETRY_PACKAGES=(
    whoopsie
    whoopsie-preferences
    ubuntu-report
    ubuntu-insights
    popularity-contest
)

APPORT_PACKAGES=(
    apport
    apport-gtk
    apport-kde
    apport-symptoms
)

TELEMETRY_UNITS=(
    whoopsie.service
    whoopsie.path
    apport.service
    apport-autoreport.service
    apport-autoreport.path
    popularity-contest.timer
)

usage() {
    cat <<EOF
Usage: sudo bash $SCRIPT_NAME [options]

Stops, removes and apt-pins Ubuntu's crash reporting and metrics packages.

Options:
  -y, --yes           Do not prompt for confirmation.
  -n, --dry-run       Print the commands that would run, change nothing.
      --keep-apport   Disable apport but leave the package installed, so
                      local crash dumps still work for your own debugging.
  -h, --help          Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes)      ASSUME_YES=1 ;;
        -n|--dry-run)  DRY_RUN=1 ;;
        --keep-apport) KEEP_APPORT=1 ;;
        -h|--help)     usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

if [[ -t 2 ]]; then
    C_INFO=$'\e[1;34m'; C_OK=$'\e[1;32m'; C_WARN=$'\e[1;33m'
    C_ERR=$'\e[1;31m';  C_OFF=$'\e[0m'
else
    C_INFO=''; C_OK=''; C_WARN=''; C_ERR=''; C_OFF=''
fi

info()    { printf '%s[INFO]%s  %s\n' "$C_INFO" "$C_OFF" "$*" >&2; }
success() { printf '%s[OK]%s    %s\n' "$C_OK"   "$C_OFF" "$*" >&2; }
warn()    { printf '%s[WARN]%s  %s\n' "$C_WARN" "$C_OFF" "$*" >&2; }
err()     { printf '%s[ERROR]%s %s\n' "$C_ERR"  "$C_OFF" "$*" >&2; }

on_err() {
    local rc=$? line=$1
    err "Failed at line $line (exit $rc). The system may be in a partial state."
    err "Fix the problem and re-run; the script is safe to run more than once."
    exit "$rc"
}
trap 'on_err $LINENO' ERR

run() {
    if (( DRY_RUN )); then
        printf '  would run: %s\n' "$*" >&2
    else
        "$@"
    fi
}

write_file() {
    local path="$1" mode="$2" content
    content=$(cat)
    if (( DRY_RUN )); then
        printf '  would write %s:\n' "$path" >&2
        printf '%s\n' "$content" | sed 's/^/    | /' >&2
        return
    fi
    install -d -m 0755 "$(dirname "$path")"
    printf '%s\n' "$content" > "$path"
    chmod "$mode" "$path"
}

if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root."
    err "Usage: sudo bash $SCRIPT_NAME"
    exit 1
fi

if [[ -r /etc/os-release ]]; then
    . /etc/os-release
    if [[ ${ID:-} != ubuntu && ${ID_LIKE:-} != *ubuntu* ]]; then
        warn "This system reports ID=${ID:-unknown}, not Ubuntu."
        warn "The script targets Ubuntu and its flavours. Forcing a prompt."
        ASSUME_YES=0
    fi
fi

for cmd in apt-get dpkg-query systemctl; do
    command -v "$cmd" >/dev/null || { err "Required command not found: $cmd"; exit 1; }
done

if (( ! ASSUME_YES && ! DRY_RUN )); then
    cat >&2 <<'EOF'

This will remove and pin Ubuntu's crash reporting and metrics packages.

Two consequences worth knowing:
  - Removing apport means no local crash dumps either, not just no uploads.
    Use --keep-apport if you want to keep the debugging side.
  - A Pin-Priority of -10 makes these packages uninstallable, so any future
    package that hard-depends on one of them will fail to install until you
    delete the pin file.

EOF
    read -rp "Continue? [y/N] " reply
    [[ ${reply,,} == y || ${reply,,} == yes ]] || { info "Aborted."; exit 0; }
fi

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

pkg_installed() {
    [[ $(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null) == installed ]]
}

if (( ! KEEP_APPORT )); then
    TELEMETRY_PACKAGES+=("${APPORT_PACKAGES[@]}")
fi

info "Stopping and disabling telemetry services..."
for unit in "${TELEMETRY_UNITS[@]}"; do
    systemctl list-unit-files --no-legend --no-pager "$unit" >/dev/null 2>&1 || continue
    if systemctl is-active --quiet "$unit"; then
        run systemctl stop "$unit" || warn "  could not stop $unit"
        info "  stopped $unit"
    fi
    run systemctl disable "$unit" >/dev/null 2>&1 || true
    run systemctl mask "$unit"    >/dev/null 2>&1 || true
done
success "Telemetry services stopped, disabled and masked."

info "Purging telemetry packages..."
removed_any=0
for pkg in "${TELEMETRY_PACKAGES[@]}"; do
    if pkg_installed "$pkg"; then
        info "  purging $pkg"
        if run apt-get purge -y "$pkg"; then
            removed_any=1
        else
            warn "  apt-get purge failed for $pkg"
        fi
    else
        info "  $pkg is not installed; skipping"
    fi
done
if (( DRY_RUN )); then
    info "Dry run: no packages were actually purged."
elif (( removed_any )); then
    success "Telemetry packages purged."
else
    info "None of the telemetry packages were installed."
fi

info "Writing the apt pin..."

for stale in no-ubuntu-report.pref no-whoopsie.pref no-apport.pref; do
    [[ -e /etc/apt/preferences.d/$stale ]] && run rm -f "/etc/apt/preferences.d/$stale"
done

{
    printf '%s\n' \
        '# Written by RemoveSnapFromUbuntu (DisableUbuntuMetrics.sh).' \
        '# Delete this file to allow these packages again.' \
        ''
    for pkg in "${TELEMETRY_PACKAGES[@]}"; do
        printf 'Package: %s\nPin: release *\nPin-Priority: -10\n\n' "$pkg"
    done
} | write_file /etc/apt/preferences.d/no-ubuntu-telemetry.pref 0644

success "Pin written to /etc/apt/preferences.d/no-ubuntu-telemetry.pref"

info "Writing disable flags..."

write_file /etc/popularity-contest.conf 0644 <<'EOF'
# Written by RemoveSnapFromUbuntu (DisableUbuntuMetrics.sh).
PARTICIPATE=no
ENABLED=no
EOF

write_file /etc/default/apport 0644 <<'EOF'
# Written by RemoveSnapFromUbuntu (DisableUbuntuMetrics.sh).
enabled=0
EOF

write_file /etc/default/whoopsie 0644 <<'EOF'
# Written by RemoveSnapFromUbuntu (DisableUbuntuMetrics.sh).
report_crashes=false
EOF

success "Disable flags written."

warn "These files are dpkg conffiles. If you ever reinstall the packages,"
warn "apt will prompt about the modified versions; keep yours."

info "Running apt cleanup..."
run apt-get autoremove -y
run apt-get clean

success "Ubuntu crash reporting and metrics are disabled."

cat >&2 <<'EOF'

  Verify with:
    systemctl status whoopsie apport
    apt-cache policy apport whoopsie ubuntu-report popularity-contest

Made with love by NullAngst
EOF
