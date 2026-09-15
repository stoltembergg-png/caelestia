# caelestia

**A Linux desktop workspace for native tools, shell integrations, and reproducible setup.**

[![Linux](https://img.shields.io/badge/Linux-111827?style=flat-square&logo=linux&logoColor=white)](https://www.linux.org/)
[![Wayland](https://img.shields.io/badge/Wayland-111827?style=flat-square&logo=wayland&logoColor=white)](https://wayland.freedesktop.org/)
[![Go](https://img.shields.io/badge/Go-111827?style=flat-square&logo=go&logoColor=white)](https://go.dev/)
[![QML](https://img.shields.io/badge/QML-111827?style=flat-square&logo=qt&logoColor=white)](https://doc.qt.io/qt-6/qmlapplications.html)
[![AGPL-3.0](https://img.shields.io/badge/License-AGPL--3.0-111827?style=flat-square)](LICENSE)

`caelestia` brings together the working parts of a Linux desktop environment: a native WhatsApp integration, shell add-ons, a reproducible CachyOS setup, and focused personal layers on upstream projects.

## Start here

- [WhatsApp integration](whatsapp/README.md) — daemon, CLI, and Quickshell interface.
- [Shell extras](extras/README.md) — Quick Actions, Dock, quota engine, and WhatsApp panel.
- [CachyOS setup](setup/README.md) — package manifests and the guarded installer.

## Directory map

| Directory | Language / technology | Purpose |
|---|---|---|
| [`whatsapp/`](whatsapp/) | Go, QML, Quickshell, SQLite | Native WhatsApp for Caelestia, using a whatsmeow daemon and Unix domain socket. |
| [`extras/`](extras/) | QML, Quickshell | Caelestia add-ons ported from Serpantinum. |
| [`setup/`](setup/) | Shell, CachyOS, Hyprland | Reproducible setup with official and AUR package manifests. |
| [`custom/serpantinum/`](custom/serpantinum/) | QML, unified diff | Personal layer over `ilyamiro/serpantinum`, with provenance and regeneration material. |
| [`custom/shell/`](custom/shell/) | Git format-patch | Contribution patch series against `caelestia-dots/shell`. |

## Workspace components

### `whatsapp/`

Caelestia-whatsapp provides a native WhatsApp integration: a Go whatsmeow daemon, the `cwctl` CLI, and a QML/Quickshell UI over a Unix domain socket. It uses systemd user services and SQLite storage, with no WebView, Chromium, or Electron.

See the [WhatsApp README](whatsapp/README.md) for installation and usage.

### `extras/`

Caelestia-extras contains shell add-ons ported from Serpantinum: Quick Actions with Notepad and the whiteboard “Lousa”, a Dock, the No Limits quota engine from KodexBar, and a WhatsApp panel.

See the [extras README](extras/README.md) for installation and usage.

### `setup/`

This is the reproducible CachyOS + Hyprland + Caelestia setup. It contains official and AUR package manifests, plus a safe installer with `--dry-run` and `--restore` support and interactive privileged actions.

This subtree was private before entering the public monorepo. Review the scripts and planned changes before installing.

See the [setup README](setup/README.md) for installation details.

## Integration model

- **Shell UI:** Quickshell and QML provide the desktop-facing interfaces and add-ons.
- **WhatsApp service:** the Go daemon handles WhatsApp through whatsmeow; the CLI and UI use its Unix domain socket.
- **System setup:** CachyOS and Hyprland are described by package manifests and a guarded installer.
- **Personal changes:** upstream differences are kept as changed files or an explicit format-patch series rather than a separate hidden fork.

## History and provenance

The `whatsapp/`, `extras/`, and `setup/` directories retain the full subtree history of their original repositories.

The custom directories document their relationship to upstream rather than presenting the layers as independent projects. Use the included `UPSTREAM.md` files to understand provenance and regenerate the tracked changes.

## Personal layers vs upstream

The `custom/` directory separates personal changes from the upstream projects they extend:

- **[`custom/serpantinum/`](custom/serpantinum/)** contains only files changed against the merge-base of [`ilyamiro/serpantinum`](https://github.com/ilyamiro/serpantinum), plus `serpantinum-custom.patch` and `UPSTREAM.md`. The patch records the complete unified diff and `UPSTREAM.md` explains provenance and regeneration.
- **[`custom/shell/`](custom/shell/)** contains a format-patch series for contribution branches against [`caelestia-dots/shell`](https://github.com/caelestia-dots/shell), covering bar audio popout width, dashboard weather wrapping, and localized PAM errors in the lock screen. It also includes PR evidence and `UPSTREAM.md`.

The root repository is licensed under [AGPL-3.0](LICENSE). The Serpantinum material is based on AGPL-3.0 upstream; the shell patch series targets GPL-3.0 upstream. These upstream licensing terms and provenance remain part of the context when the combined workspace is used or redistributed.

## Upstream projects

- [`caelestia-dots/shell`](https://github.com/caelestia-dots/shell) — the GPL-3.0 shell receiving the contribution patch series.
- [`ilyamiro/serpantinum`](https://github.com/ilyamiro/serpantinum) — the AGPL-3.0 shell used as the base for the personal layer.

## License

The monorepo root is [AGPL-3.0](LICENSE). Refer to the included `UPSTREAM.md` files and upstream repositories for provenance and the applicable upstream terms.
