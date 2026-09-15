# CachyOS Caelestia Setup

Portable setup manifests and documentation for a CachyOS/Arch desktop using a
Hyprland session and Caelestia. Review manifests before installing; package
availability, especially in the AUR, must be checked at install time.

This repository does not contain credentials, personal media, host binaries,
wallpapers, firmware settings, BIOS or Secure Boot changes. Privileged actions
remain interactive in Kitty or another visible terminal; passwords are never
accepted by the project.

See [component attribution](docs/COMPONENTS.md) and [hardware assumptions](docs/HARDWARE.md).

## Installation

This repository is private, so the installer is fetched with an authenticated
`gh` session (or a `GH_TOKEN` with read access to the repo):

```bash
# one-liner: clone to a temp dir and run the installer
bash -c 'tmp=$(mktemp -d) && gh repo clone stoltembergg-png/cachyos-caelestia-setup "$tmp" && bash "$tmp/install.sh"'
```

Or clone it first and review the plan before running:

```bash
gh repo clone stoltembergg-png/cachyos-caelestia-setup
cd cachyos-caelestia-setup
./install.sh --dry-run   # review what will be done
./install.sh
```

Run `./install.sh --help` for all options (`--dry-run`, `--yes`, `--restore`, `--skip-monitor`).
