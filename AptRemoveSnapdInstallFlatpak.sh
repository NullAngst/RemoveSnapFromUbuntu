#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME=${0##*/}

ASSUME_YES=0
DRY_RUN=0
DO_UPGRADE=0
ADD_BETA=0
INSTALL_GUI_PLUGIN=0
INSTALL_STARTER_APPS=0

STARTER_APPS=(
    org.mozilla.firefox
    io.mpv.Mpv
    org.videolan.VLC
    com.github.tchx84.Flatseal
    org.onlyoffice.desktopeditors
    org.gnome.Loupe
)

usage() {
    cat <<EOF
Usage: sudo bash $SCRIPT_NAME [options]

Removes snapd and all snaps, pins snapd so apt will not reinstall it,
then installs Flatpak and adds the Flathub remote.

Options:
  -y, --yes             Do not prompt for confirmation.
  -n, --dry-run         Print the commands that would run, change nothing.
      --upgrade         Run 'apt-get full-upgrade' before removing anything.
      --beta            Also add the flathub-beta remote.
      --gui-plugin      Install the Flatpak plugin for the desktop's software
                        centre (gnome-software or plasma-discover).
      --starter-apps    Install a small starter set of Flatpak apps.
  -h, --help            Show this help.

This script is destructive. Read it before running it.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -y|--yes)        ASSUME_YES=1 ;;
        -n|--dry-run)    DRY_RUN=1 ;;
        --upgrade)       DO_UPGRADE=1 ;;
        --beta)          ADD_BETA=1 ;;
        --gui-plugin)    INSTALL_GUI_PLUGIN=1 ;;
        --starter-apps)  INSTALL_STARTER_APPS=1 ;;
        -h|--help)       usage; exit 0 ;;
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
else
    warn "/etc/os-release not found; cannot verify the distribution."
fi

for cmd in apt-get apt-mark dpkg-query systemctl getent awk; do
    command -v "$cmd" >/dev/null || { err "Required command not found: $cmd"; exit 1; }
done

if (( ! ASSUME_YES && ! DRY_RUN )); then
    cat >&2 <<'EOF'

This will:
  - remove every installed snap and purge the snapd package
  - delete /snap, /var/snap, /var/lib/snapd, /var/cache/snapd and ~/snap
  - pin snapd to Pin-Priority -10 so apt will not reinstall it
  - install Flatpak and add the Flathub remote

Packages that depend on snapd go with it. On recent releases that includes
the ubuntu-desktop and ubuntu-desktop-minimal metapackages and the firefox
and thunderbird transitional packages. If Firefox is currently a snap, you
will have no browser until you install a replacement.

Run with --dry-run first if you want to see the exact commands.

EOF
    read -rp "Continue? [y/N] " reply
    [[ ${reply,,} == y || ${reply,,} == yes ]] || { info "Aborted."; exit 0; }
fi

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

pkg_installed() {
    [[ $(dpkg-query -W -f='${db:Status-Status}' "$1" 2>/dev/null) == installed ]]
}

snap_mounts_present() {
    awk '$2 ~ "^/(var/)?snap(/|$)" {found = 1} END {exit !found}' /proc/self/mounts
}

info "Refreshing package lists..."
run apt-get update
if (( DO_UPGRADE )); then
    info "Running full-upgrade (requested with --upgrade)..."
    run apt-get full-upgrade -y
fi
success "Package lists ready."

is_base_snap() {
    case "$1" in
        snapd|bare|core|core16|core18|core20|core22|core24) return 0 ;;
        *) return 1 ;;
    esac
}

remove_all_snaps() {
    local pass=0 previous=-1 current name
    local -a snaps regular bases

    while (( pass < 10 )); do
        mapfile -t snaps < <(snap list 2>/dev/null | awk 'NR > 1 {print $1}')
        current=${#snaps[@]}
        (( current == 0 )) && return 0

        if (( current == previous )); then
            warn "No progress on pass $pass; $current snap(s) still present:"
            warn "  ${snaps[*]}"
            return 1
        fi
        previous=$current
        (( ++pass ))

        regular=(); bases=()
        for name in "${snaps[@]}"; do
            if is_base_snap "$name"; then bases+=("$name"); else regular+=("$name"); fi
        done

        info "Pass $pass: ${#regular[@]} app snap(s), ${#bases[@]} base snap(s) left."
        for name in "${regular[@]}" "${bases[@]}"; do
            snap remove --purge "$name" \
                || warn "Could not remove snap '$name' on this pass."
        done
    done

    warn "Gave up after $pass passes."
    return 1
}

if command -v snap >/dev/null; then
    if (( DRY_RUN )); then
        info "Snaps that would be removed:"
        snap list 2>/dev/null >&2 || info "  (none)"
    else
        info "Removing installed snaps..."
        if remove_all_snaps; then
            success "All snaps removed."
        else
            warn "Some snaps could not be removed. Continuing, but check"
            warn "'mount | grep snap' and 'losetup -a' after rebooting."
        fi
    fi
else
    info "snap command not present; nothing to remove."
fi

info "Stopping and disabling snapd units..."
mapfile -t snapd_units < <(
    systemctl list-unit-files --no-legend --no-pager 'snapd*' 2>/dev/null | awk '{print $1}'
)
for unit in "${snapd_units[@]}"; do
    run systemctl stop "$unit"    >/dev/null 2>&1 || true
    run systemctl disable "$unit" >/dev/null 2>&1 || true
done
for unit in snapd.service snapd.socket; do
    run systemctl mask "$unit" >/dev/null 2>&1 || true
done
success "snapd units stopped, disabled and masked."

if pkg_installed snapd; then
    info "Purging snapd..."
    run apt-get purge -y snapd
    run systemctl daemon-reload
    success "snapd purged."
else
    info "snapd package is not installed; nothing to purge."
fi

info "Unmounting any remaining snap mounts..."
while read -r mountpoint; do
    [[ -n $mountpoint ]] || continue
    info "  unmounting $mountpoint"
    run umount -l "$mountpoint" || warn "  could not unmount $mountpoint"
done < <(awk '$2 ~ "^/(var/)?snap(/|$)" {print $2}' /proc/self/mounts | sort -r)

if command -v losetup >/dev/null; then
    while read -r loopdev; do
        [[ -n $loopdev ]] || continue
        info "  detaching $loopdev"
        run losetup -d "$loopdev" || warn "  could not detach $loopdev"
    done < <(losetup -ln -O NAME,BACK-FILE 2>/dev/null | awk '$2 ~ /snap/ {print $1}')
fi

if (( ! DRY_RUN )) && snap_mounts_present; then
    warn "Snap mounts are still active; skipping directory removal so that"
    warn "nothing is deleted through a live mount. Reboot and re-run to finish."
else
    info "Removing snap data directories..."
    run rm -rf /var/lib/snapd /var/cache/snapd /var/snap /snap

    while IFS=: read -r _ _ uid _ _ home _; do
        [[ -n $home && $home != / && -d $home ]] || continue
        (( uid == 0 || uid >= 1000 )) || continue
        run rm -rf -- "$home/snap" "$home/.snap"
    done < <(getent passwd)
    success "Snap data removed."
fi

info "Blocking snapd reinstallation..."
run apt-mark hold snapd

if (( DRY_RUN )); then
    printf '  would write: /etc/apt/preferences.d/no-snapd.pref\n' >&2
else
    install -d -m 0755 /etc/apt/preferences.d
    cat > /etc/apt/preferences.d/no-snapd.pref <<'EOF'
# Written by RemoveSnapFromUbuntu.
# To allow snapd again: delete this file and run 'apt-mark unhold snapd'.
Package: snapd
Pin: release *
Pin-Priority: -10
EOF
    chmod 0644 /etc/apt/preferences.d/no-snapd.pref
fi
success "snapd is held and pinned to -10."

info "Installing Flatpak..."
run apt-get install -y flatpak
success "Flatpak installed."

if (( ! DRY_RUN )) && ! command -v flatpak >/dev/null; then
    err "flatpak is not on PATH after installation; cannot configure remotes."
    exit 1
fi

info "Adding the Flathub remote..."
run flatpak remote-add --if-not-exists \
    flathub https://dl.flathub.org/repo/flathub.flatpakrepo
success "Flathub added."

if (( ADD_BETA )); then
    info "Adding the Flathub Beta remote..."
    run flatpak remote-add --if-not-exists \
        flathub-beta https://flathub.org/beta-repo/flathub-beta.flatpakrepo
    success "Flathub Beta added."
fi

if (( INSTALL_GUI_PLUGIN )); then
    plugin=""
    if pkg_installed gnome-software || command -v gnome-software >/dev/null; then
        plugin=gnome-software-plugin-flatpak
    elif pkg_installed plasma-discover || command -v plasma-discover >/dev/null; then
        plugin=plasma-discover-backend-flatpak
    fi
    if [[ -n $plugin ]]; then
        info "Installing $plugin..."
        run apt-get install -y "$plugin"
        success "$plugin installed."
    else
        warn "No supported software centre detected; skipping the GUI plugin."
    fi
fi

if (( INSTALL_STARTER_APPS )); then
    info "Installing starter Flatpak apps..."
    for app in "${STARTER_APPS[@]}"; do
        run flatpak install -y flathub "$app" \
            || warn "Could not install $app; continuing."
    done
    success "Starter apps done."
fi

info "Running apt cleanup..."
run apt-get autoremove -y
run apt-get clean

success "Finished. snapd is removed and Flatpak is ready."

cat >&2 <<'EOF'

  Search for apps : flatpak search <name>
  Install an app  : flatpak install flathub <app-id>
  List installed  : flatpak list

  Reboot now. Flatpak apps will not show up in the application menu until
  you log out and back in, because XDG_DATA_DIRS is set at session start.

Made with love by NullAngst
EOF
