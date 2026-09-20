# RemoveSnapFromUbuntu

Two bash scripts that strip `snapd` and Ubuntu's crash reporting and metrics
packages out of a system, replace snap with [Flatpak](https://flatpak.org/),
and apt-pin everything so it does not come back on the next upgrade.

## Read this first

These scripts are destructive and are meant to be. They purge packages, delete
system directories, and set negative apt pins that make packages uninstallable
until you remove the pin file.

Before running either one:

- Run it with `--dry-run` to see the exact commands it will execute.
- Know that purging `snapd` also removes anything that depends on it. On recent
  Ubuntu releases that includes the `ubuntu-desktop` and
  `ubuntu-desktop-minimal` metapackages and the `firefox` and `thunderbird`
  transitional packages. Losing the metapackage does not break a running
  desktop, but it does mean future `ubuntu-desktop` changes stop reaching you.
- If Firefox on your system is the snap, you will have no browser after the
  first script finishes. Install a replacement before you reboot, either
  `flatpak install flathub org.mozilla.firefox` or Mozilla's own apt repository.
- Check the removal plan yourself with `apt-get -s purge snapd` if you want the
  full list for your machine.

Take a snapshot or a backup if the machine matters.

## Scripts

### `AptRemoveSnapdInstallFlatpak.sh`

Removes snapd and installs Flatpak in its place.

What it does:

1. Refreshes apt package lists.
2. Removes every installed snap, looping until the list is empty. App snaps go
   first and base snaps (`core*`, `bare`, `snapd`) last, so dependency ordering
   resolves itself. It stops early if a pass makes no progress instead of
   looping forever.
3. Stops, disables, and masks every `snapd*` systemd unit found on the system
   rather than a hardcoded list.
4. Purges the `snapd` package if it is installed.
5. Unmounts any remaining squashfs mounts under `/snap` and `/var/snap` and
   detaches their loop devices. Only then does it delete `/snap`, `/var/snap`,
   `/var/lib/snapd`, `/var/cache/snapd`, and per-user `~/snap` and `~/.snap`.
   If mounts are still live after the unmount attempt, it skips the deletion
   and tells you to reboot and run it again.
6. Holds `snapd` with `apt-mark` and writes an apt pin at `Pin-Priority: -10`
   to `/etc/apt/preferences.d/no-snapd.pref`.
7. Installs `flatpak` and adds the Flathub remote system-wide.
8. Runs `apt-get autoremove` and `apt-get clean`.

Home directories come from `getent passwd`, so users whose home is not under
`/home` are handled.

Options:

| Flag | Effect |
|---|---|
| `-y`, `--yes` | Skip the confirmation prompt |
| `-n`, `--dry-run` | Print every command instead of running it |
| `--upgrade` | Run `apt-get full-upgrade` before removing anything |
| `--beta` | Also add the `flathub-beta` remote |
| `--gui-plugin` | Install the Flatpak plugin for GNOME Software or Discover, whichever is present |
| `--starter-apps` | Install a small set of Flatpak apps |
| `-h`, `--help` | Show usage |

`--upgrade` is opt-in. A full dist-upgrade before a destructive operation is a
separate decision from removing snap, so the script does not make it for you.

### `DisableUbuntuMetrics.sh`

Removes and blocks Ubuntu's crash reporting and metrics packages.

| Package | What it does |
|---|---|
| `apport` | Catches crashes and writes local crash dumps |
| `whoopsie` | Uploads apport's crash reports to Canonical |
| `ubuntu-report` | Sends a one-time hardware and install report, at install and at release upgrade |
| `ubuntu-insights` | Replacement for `ubuntu-report` from Ubuntu 25.10 onward |
| `popularity-contest` | Weekly package usage survey, off by default on desktop installs |

What it does:

1. Stops, disables, and masks `whoopsie`, `apport`, `apport-autoreport`, and
   `popularity-contest` units, skipping any that do not exist on this release.
2. Purges each package individually, skipping ones that are not installed. This
   also covers `apport-gtk`, `apport-kde`, `apport-symptoms`, and
   `whoopsie-preferences`, which depend on the packages above.
3. Writes one pin file, `/etc/apt/preferences.d/no-ubuntu-telemetry.pref`, with
   a `Pin-Priority: -10` stanza for every package it handled. Older per-package
   pin files written by earlier versions of this script are removed.
4. Writes disable flags to `/etc/default/apport`, `/etc/default/whoopsie`, and
   `/etc/popularity-contest.conf`, so the settings are correct if a package is
   ever reinstalled.
5. Runs `apt-get autoremove` and `apt-get clean`.

Options:

| Flag | Effect |
|---|---|
| `-y`, `--yes` | Skip the confirmation prompt |
| `-n`, `--dry-run` | Print every command instead of running it |
| `--keep-apport` | Disable apport and leave the package installed |
| `-h`, `--help` | Show usage |

Use `--keep-apport` if you want local crash dumps for your own debugging.
Removing `whoopsie` alone stops the uploads; `apport` is what generates the
dump in the first place.

## Usage

Both scripts need root.

```bash
# See what would happen
sudo bash AptRemoveSnapdInstallFlatpak.sh --dry-run
sudo bash DisableUbuntuMetrics.sh --dry-run

# Do it
sudo bash AptRemoveSnapdInstallFlatpak.sh
sudo bash DisableUbuntuMetrics.sh
```

Order does not matter. Reboot after the snap removal script so that any
remaining snap loop mounts are gone, then log out and back in so Flatpak app
launchers appear in your menu. `XDG_DATA_DIRS` is set at session start, which
is why a reboot alone is not always enough.

Both scripts are idempotent. Running one twice is safe and is the documented
way to finish a run that stopped partway.

## Tradeoffs

Things worth knowing before you commit:

- A `Pin-Priority` of `-10` makes a package uninstallable. If some future
  package hard-depends on `snapd` or `apport`, apt will refuse to install it
  and tell you the dependency is unsatisfiable. The fix is to delete the pin
  file, not to fight apt.
- `/etc/default/apport`, `/etc/default/whoopsie`, and
  `/etc/popularity-contest.conf` are dpkg conffiles. Rewriting them means apt
  will prompt you about the modified versions if you ever reinstall those
  packages. Keep your version.
- Masking `snapd.service` and `snapd.socket` survives a reinstall. Unmask them
  if you ever want snap back.
- Flatpak and snap solve the same problem differently. Flatpak apps are
  sandboxed too, have their own runtime downloads, and the first install pulls
  a large runtime. This swaps one set of tradeoffs for another rather than
  removing them.

## Reverting

```bash
# Snap
sudo rm -f /etc/apt/preferences.d/no-snapd.pref
sudo apt-mark unhold snapd
sudo systemctl unmask snapd.service snapd.socket
sudo apt-get update && sudo apt-get install snapd

# Telemetry
sudo rm -f /etc/apt/preferences.d/no-ubuntu-telemetry.pref
sudo systemctl unmask apport.service whoopsie.service
sudo apt-get update && sudo apt-get install apport whoopsie ubuntu-report
```

Reverting does not bring back the snaps you had installed. Reinstall those
by hand.

## Compatibility

Written and used against Ubuntu 22.04 LTS and 24.04 LTS and the desktop
flavours built on them (Kubuntu, Xubuntu, Ubuntu MATE). The scripts check
`/etc/os-release` and prompt before continuing on anything that is not Ubuntu
or Ubuntu-derived.

Not written for Debian or Linux Mint. The apt and systemd logic would carry
over with edits, but the package names and the assumption that snapd is
unwanted do not apply cleanly.

## Flatpak cheat sheet

```bash
flatpak search firefox                        # find an app
flatpak install flathub org.mozilla.firefox   # install it
flatpak run org.mozilla.firefox               # run it
flatpak list                                  # what is installed
flatpak update                                # update everything
flatpak uninstall --unused                    # drop orphaned runtimes
```

## License

AGPL-3.0. See [LICENSE](LICENSE).

*Made with love by NullAngst*
