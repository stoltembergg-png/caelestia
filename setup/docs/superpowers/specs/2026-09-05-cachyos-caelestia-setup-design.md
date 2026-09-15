# CachyOS Caelestia Setup — Design

## Purpose

Create a public, personal-profile repository that restores Gabriel's current
CachyOS + Hyprland desktop after a clean CachyOS installation. A user should be
able to paste one documented command into a terminal, authenticate through
`sudo`, and receive the same Caelestia-centered desktop without copying
credentials, personal media, or firmware settings.

## Scope

The setup installs and configures:

- CachyOS/Arch packages and selected AUR packages.
- Caelestia Shell, Caelestia CLI, Quickshell, local pt-BR translation, and the
  current local Caelestia overrides.
- Hyprland Lua configuration, the current monitor profile, dock integration,
  Fish, and the official `hyprfocus` plugin from
  `https://github.com/hyprwm/hyprland-plugins`, installed through `hyprpm` for
  the installed Hyprland version.
- Zen Browser from the CachyOS `zen-browser-bin` package, with its launcher
  referenced by name instead of the current manually extracted executable.
- `nwg-dock-hyprland` styling and dynamic Caelestia color integration.
- Pamac for Arch/AUR, Flatpak with Flathub, and Bazaar for Flatpak discovery.
- Btrfs/Snapper maintenance, weekly TRIM, monthly scrub, and `fwupd` auditing.
- A read-only `cachy-health` command that reports package updates, snapshots,
  Btrfs scrub, TRIM, ZRAM, and firmware availability.

The repository does not change BIOS options, Secure Boot keys, CPU governors,
firmware, disk partitions, users, passwords, or bootloader configuration.

## Target and prerequisites

The target is a newly installed CachyOS session with Hyprland on the same
machine. The installer requires network access, a normal user with `sudo`, and
an existing CachyOS package configuration. Btrfs/Snapper behavior is enabled
only when those facilities are already available; user configuration backup is
always available.

The default profile includes the current `DP-1` monitor configuration to
recreate this machine exactly. The README warns that another monitor layout
requires editing or skipping that profile.

## Installation interface

The README's primary command downloads a tagged release installer:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/stoltembergg-png/cachyos-caelestia-setup/v1.0.0/install.sh)
```

The README also documents a clone-and-review alternative. The default command
is updated only for new tagged releases; it never points at `main`.

`install.sh` supports:

- no arguments: interactive installation;
- `--dry-run`: print all intended package, file, and service actions;
- `--yes`: accept the final setup confirmation after the user has reviewed the
  documented command;
- `--restore <timestamp>`: restore the matching configuration backup;
- `--skip-monitor`: do not apply the `DP-1` monitor profile.

The script validates CachyOS, network reachability, required commands, and
`sudo` before any state-changing operation. It never accepts passwords as
arguments, input variables, or environment variables.

## Repository layout

```text
cachyos-caelestia-setup/
├── install.sh
├── lib/
│   ├── preflight.sh
│   ├── packages.sh
│   ├── config.sh
│   ├── services.sh
│   └── verify.sh
├── config/
│   ├── caelestia/
│   ├── hypr/
│   ├── nwg-dock-hyprland/
│   └── fish/
├── packages/
│   ├── official.txt
│   ├── aur.txt
│   └── flatpak.txt
├── scripts/
│   ├── cachy-health
│   └── restore-backup
├── docs/
│   ├── COMPONENTS.md
│   ├── HARDWARE.md
│   ├── RECOVERY.md
│   └── superpowers/specs/2026-09-05-cachyos-caelestia-setup-design.md
└── tests/
    ├── smoke.sh
    └── fixtures/
```

## Installation flow

1. Preflight identifies the CachyOS environment, checks the network, validates
   `sudo`, and prints the selected profile.
2. A timestamped backup is created at
   `~/.local/state/cachyos-caelestia-setup/backups/<timestamp>/` for each
   destination that already exists.
3. If the root filesystem is Btrfs and the `root` Snapper configuration exists,
   a pre-installation snapshot is created. Missing Btrfs or Snapper never
   blocks the desktop configuration step.
4. `pacman` performs a complete system update and installs official packages.
   `paru` is used only after it is confirmed present to install the explicit AUR
   manifest. The installer does not use a partial database refresh.
5. Flatpak is configured with the user-level Flathub remote and optional
   manifest entries are installed.
6. Versioned configuration templates are copied to `~/.config`. The installer
   substitutes only approved runtime values such as `$HOME`, the XDG pictures
   directory, the plugin path, and the optional Zen executable path. Copy
   operations preserve backups and never publish the source machine's absolute
   home directory. The Zen binding uses the package-provided executable and is
   omitted with a clear message when that optional package is skipped.
7. `hyprpm update`, `hyprpm add https://github.com/hyprwm/hyprland-plugins`,
   `hyprpm enable hyprfocus`, and `hyprpm reload -n` install and load the
   official plugin. The repository never stores the host-specific `.so` binary.
8. User services for the dock/theme integration and system timers for TRIM,
   Snapper cleanup/timeline, and Btrfs scrub are enabled when their dependencies
   are present.
9. Verification reports package versions, configuration targets, service state,
   Flatpak remote status, and the required logout/login action.

## Configuration capture policy

The project versions only portable configuration and standard Caelestia
wallpapers. Before adding source files, a capture check rejects:

- absolute home-directory paths that are not approved placeholders;
- SSH keys, private-key headers, token-like values, and common credential file
  names;
- host-specific binary artifacts, including `hyprfocus.so`.

Approved placeholders are `__HOME__`, `__WALLPAPER_DIR__`, and
`__HYPRFOCUS_PLUGIN__`; the installer replaces them with values derived from
the target user's environment or skips the optional plugin when it is
unavailable. The Zen configuration uses a stable command name supplied by the
`zen-browser-bin` package and does not encode a home-directory path.

The current monitor profile is intentionally versioned because the primary use
case is this same system. It is isolated so `--skip-monitor` is exact and
reversible.

## Backup and recovery

`--restore <timestamp>` restores configuration destinations from the selected
backup and restarts only relevant user services after confirmation. It never
deletes a backup. `docs/RECOVERY.md` describes manual restoration, disabling a
user service, selecting a Btrfs snapshot from Limine, and removing the profile
from a recovery TTY.

## Reliability and verification

The project gates publication on:

- `bash -n` for every shell script;
- `shellcheck` with documented, narrow exclusions only;
- `shfmt -d`;
- `tests/smoke.sh --dry-run` in a fixture home directory;
- manifest validation for duplicates and package-name syntax;
- capture-policy scans for credentials, `/home/gabriel`, and binary artifacts;
- a manual clean-CachyOS installation checklist before tagging a release.

Errors identify the failing module and leave the backup intact. The installer
stops on an unexpected error; it never reports a partially applied module as
successful.

## Documentation and attribution

`README.md` presents the one-command installation, the clone-and-review path,
supported scope, quick recovery, and screenshots added only after a clean
install validation. `docs/COMPONENTS.md` attributes CachyOS, Hyprland,
Caelestia, Quickshell, nwg-dock-hyprland, Fish, Pamac, Flatpak, Flathub,
Bazaar, Snapper, Btrfs, fwupd, and hyprfocus. `docs/HARDWARE.md` explains the
monitor profile, optional CPPC, and why BIOS/Secure Boot/firmware are excluded.

## License

The repository uses the MIT License. Upstream licenses remain applicable to
their respective projects and are not relicensed by this repository.
