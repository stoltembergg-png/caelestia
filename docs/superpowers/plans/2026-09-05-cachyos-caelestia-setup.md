# CachyOS Caelestia Setup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a public, reproducible setup repository that applies the user’s validated CachyOS + Hyprland + Caelestia configuration from one visible terminal command, with backups, dry-run validation, safe package handling, and a read-only health report.

**Architecture:** A Bash entrypoint delegates to small, testable modules. A versioned manifest separates official repositories, AUR, and Flatpak sources. Sanitized templates use explicit placeholders for home-dependent paths. Installation is transactional at the configuration level: capture user files and an optional Snapper pre-snapshot before changes, then provide an explicit restore path. Hardware firmware, BIOS, Secure Boot, partitions, and bootloader state remain outside the installer’s scope.

**Tech Stack:** Bash 5, `pacman`, `paru` when available for AUR, `flatpak`, `snapper`, `btrfs`, `systemd`, `hyprpm`, Caelestia CLI/Shell, Hyprland Lua configuration, ShellCheck, shfmt, Bats Core, GitHub Actions.

**Spec:** `docs/superpowers/specs/2026-09-05-cachyos-caelestia-setup-design.md`

## Global Constraints

- [ ] Never invoke Alacritty. Documentation and manual verification must use Kitty or the user’s already-visible terminal.
- [ ] Never request, read, store, echo, or automate a password. Privileged commands remain interactive and are executed in the visible terminal.
- [ ] Never change BIOS, Secure Boot, firmware, disk partitions, bootloader, or system-wide secrets.
- [ ] Do not copy the entire existing `~/.config/fish/fish_variables`; generate only the managed theme fragment and preserve unrelated user state.
- [ ] Do not ship personal media, credentials, absolute `/home/gabriel/...` paths, compiled `.so` files, or machine-specific identifiers.
- [ ] Every destructive or potentially irreversible operation must be opt-in, explain its scope, and have a validated target. Package-cache cleanup and orphan removal are not part of the default setup.
- [ ] The installer must be idempotent: rerunning it updates only managed files and does not duplicate lines, services, keybinds, repositories, or Flatpak remotes.
- [ ] `--dry-run` must perform no package, file, service, plugin, or snapshot mutation.
- [ ] All generated configuration must pass a source-policy scan before it is committed.
- [ ] Keep commits small and focused; each task below ends with one independently reviewable commit.

## Repository Map

The implementation will establish this layout:

```text
.
├── install.sh
├── LICENSE
├── README.md
├── docs/
│   ├── COMPONENTS.md
│   ├── HARDWARE.md
│   ├── RECOVERY.md
│   └── troubleshooting.md
│   └── superpowers/
│       ├── specs/2026-09-05-cachyos-caelestia-setup-design.md
│       └── plans/2026-09-05-cachyos-caelestia-setup.md
├── config/
│   ├── caelestia/
│   │   ├── cli.json
│   │   ├── shell.json
│   │   ├── pt-BR.json
│   │   ├── monitors/DP-1/shell.json
│   │   └── local-overrides/...
│   ├── fish/
│   │   └── conf.d/caelestia-theme.fish
│   ├── hypr/
│   │   ├── config/autostart.lua
│   │   ├── config/keybinds.lua
│   │   ├── config/env.lua
│   │   ├── config/variables.lua
│   │   └── hyprland.lua
│   └── nwg-dock-hyprland/
│       ├── style.css
│       └── caelestia-dynamic.css
├── packages/
│   ├── official.txt
│   ├── aur.txt
│   └── flatpak.txt
├── lib/
│   ├── preflight.sh
│   ├── packages.sh
│   ├── config.sh
│   ├── services.sh
│   └── verify.sh
├── scripts/
│   ├── cachy-health
│   ├── restore-backup
│   ├── check-source-policy.sh
│   └── render-config.sh
└── tests/
    ├── bats/
    ├── smoke.sh
    ├── fixtures/
    └── shell/
```

The exact monitor directory is kept as a template example only; the renderer must detect the active monitor name and either render the selected profile or skip it with a clear message when `--skip-monitor` is used.

---

## Task 1: Establish manifests, metadata, and contribution-safe repository boundaries

**Files:** `packages/official.txt`, `packages/aur.txt`, `packages/flatpak.txt`, `README.md`, `LICENSE`, `.gitignore`, `docs/COMPONENTS.md`, `docs/HARDWARE.md`, `tests/bats/manifests.bats`

- [ ] Write `packages/official.txt` with one package per line and comments for groups. Include the known official packages: `fish`, `flatpak`, `fwupd`, `hyprland`, `nwg-dock-hyprland`, `pamac-aur`, `snapper`, `btrfs-progs`, `btrfs-assistant`, `bazaar`, `flameshot`, `swappy`, `playerctl`, `pavucontrol`, `cliphist`, `wl-clipboard`, `slurp`, `grim`, `wl-gammarelay-rs`, `ttf-cascadia-code-nerd`, and `ttf-material-symbols-variable`.
- [ ] Write `packages/aur.txt` with `caelestia-cli`, `caelestia-shell`, `quickshell-git`, `qt6-m3shapes-git`, `ttf-rubik-vf`, and `zen-browser-bin`, noting that package availability must be checked rather than assumed.
- [ ] Write `packages/flatpak.txt` with the approved optional GUI store/application identifiers only after verifying their exact IDs; do not include a guessed application ID.
- [ ] Add MIT licensing and an ignore file that excludes logs, rendered temporary files, backup archives, personal wallpapers, `.env` files, and build artifacts.
- [ ] Document component attribution and supported assumptions in `docs/COMPONENTS.md` and `docs/HARDWARE.md`: CachyOS/Arch, Hyprland session, Btrfs/Snapper optional, Kitty or another visible terminal, a logged-in desktop session, the guarded `DP-1` profile, and explicit BIOS/CPPC/Secure Boot exclusions.
- [ ] Add Bats tests that reject duplicate package names, blank identifiers, shell metacharacters in package identifiers, and a missing manifest file.

Verification:

```bash
bats tests/bats/manifests.bats
git diff --check
```

Commit: `chore: establish setup manifests and repository policy`

## Task 2: Implement the shared command-line contract and safe execution layer

**Files:** `install.sh`, `lib/preflight.sh`, `tests/smoke.sh`, `tests/bats/common.bats`, `tests/fixtures/fake-bin/`

- [ ] Implement strict Bash startup (`set -Eeuo pipefail`), deterministic repository-root discovery, and a temporary workspace with cleanup traps.
- [ ] Parse `--dry-run`, `--yes`, `--restore TIMESTAMP`, `--skip-monitor`, `--help`, and `--version`; reject unknown options and missing option values with exit code 2.
- [ ] Provide `log_info`, `log_warn`, `log_error`, `die`, `run`, `run_privileged`, and `confirm` helpers. In dry-run mode, `run` logs the exact argv without executing it; `run_privileged` never embeds a password or invokes a GUI password helper.
- [ ] Use argument arrays for package and command execution. Do not build package commands through `eval`, `sh -c`, or unquoted interpolation.
- [ ] Add preflight checks for Bash version, interactive/visible terminal guidance, supported distribution, network reachability, `sudo` availability, desktop session, and required base commands. Make checks actionable and distinguish hard failures from optional capabilities.
- [ ] Ensure `--help` and `--version` work without root, network, or package-manager access.
- [ ] Test argument parsing, dry-run non-execution, exit-code propagation, signal cleanup, and rejection of shell metacharacters through Bats fixtures.

Verification:

```bash
bash -n install.sh lib/*.sh scripts/*.sh
bats tests/bats/common.bats
```

Commit: `feat: add safe installer command contract`

## Task 3: Add package installation with official/AUR separation and idempotency

**Files:** `lib/packages.sh`, `tests/bats/packages.bats`, `docs/troubleshooting.md`

- [ ] Implement package presence detection with `pacman -Q`, repository availability detection with `pacman -Si`, and AUR availability detection through the selected helper.
- [ ] Run the complete official-system update (`pacman -Syu`) and install official packages in one planned transaction, refreshing package databases only after confirmation or `--yes`; never perform a partial database refresh.
- [ ] Detect `paru` and use it only for packages explicitly listed in the AUR manifest. If `paru` is absent, report the exact AUR packages that need manual handling and stop before partial AUR installation; do not reinstall `yay`.
- [ ] Handle an unavailable optional package by recording it as skipped with a reason; fail for required packages that are unavailable in both configured repositories and the permitted AUR path.
- [ ] Keep package names in arrays created from validated manifest lines. Do not pass comments or blank lines to package managers.
- [ ] Add a package plan summary that clearly separates already-installed, to-install, unavailable optional, and blocking packages.
- [ ] Add fixture tests for installed packages, duplicate entries, unavailable packages, missing `paru`, dry-run behavior, and the “no `yay` reintroduction” invariant.

Verification:

```bash
bats tests/bats/packages.bats
shellcheck lib/packages.sh
```

Commit: `feat: install validated official and aur package sets`

## Task 4: Implement backups, Snapper pre-snapshots, and explicit restore

**Files:** `lib/config.sh`, `scripts/restore-backup`, `tests/bats/snapshots.bats`, `docs/RECOVERY.md`, `docs/troubleshooting.md`

- [ ] Create state under `~/.local/state/cachyos-caelestia-setup/` and backups under `backups/<UTC-timestamp>/` with restrictive permissions.
- [ ] Before touching managed files, copy each existing target while preserving relative paths and metadata where possible; record a manifest with checksums and whether each file was absent.
- [ ] Detect Btrfs and a usable Snapper root configuration. Create a labeled pre-setup snapshot only when both are available and never treat snapshot creation as permission to alter unrelated subvolumes.
- [ ] If no Snapper configuration exists, continue with file backups and state that rollback is file-level only.
- [ ] Implement `--restore TIMESTAMP` in `install.sh` and `scripts/restore-backup` with exact backup-directory validation, a confirmation unless `--yes` is supplied, restoration of only managed targets, and a final reload/restart suggestion. Refuse path traversal and symlink escapes.
- [ ] Make restore idempotent and preserve files that were created after the backup unless they are managed targets explicitly recorded in the manifest.
- [ ] Test snapshot capability branches with mocked `findmnt`, `snapper`, and `btrfs`; test backup/restore, invalid timestamps, absent files, permissions, and path traversal rejection.

Verification:

```bash
bats tests/bats/snapshots.bats
shellcheck lib/config.sh
```

Commit: `feat: add reversible configuration backups and restore`

## Task 5: Render and validate sanitized configuration templates

**Files:** `scripts/render-config.sh`, `lib/config.sh`, `config/caelestia/**`, `config/fish/conf.d/caelestia-theme.fish`, `config/hypr/**`, `config/nwg-dock-hyprland/**`, `tests/bats/render-config.bats`

- [ ] Port only the user-approved, non-personal configuration from the live setup into templates, retaining the working pt-BR translations, concise audio-device labels, battery percentage placement/toggle, wallpaper selector behavior, dock styling, and clean window/theme borders.
- [ ] Replace machine-dependent values with exactly these supported placeholders: `__HOME__`, `__WALLPAPER_DIR__`, and `__HYPRFOCUS_PLUGIN__`. Use the package-provided `zen-browser` command in keybinds instead of an absolute extracted path.
- [ ] Render `__HOME__` from the invoking user’s actual home, `__WALLPAPER_DIR__` from an XDG default with an existing-directory fallback, and `__HYPRFOCUS_PLUGIN__` only as a runtime-managed plugin reference; never hard-code the current monitor or username.
- [ ] Keep Fish integration in a dedicated `conf.d` file that reads the generated Caelestia scheme or uses a safe fallback. Do not overwrite `fish_variables`.
- [ ] Keep the current `DP-1` profile versioned for the same-machine target, generate/apply it only after querying active outputs, preserve a portable default, and honor `--skip-monitor` when the output does not match or the user requests a skip.
- [ ] Install files atomically with temporary files inside the destination filesystem, mode `0644` for ordinary config and `0755` for executable scripts, after backup capture.
- [ ] Add renderer tests for all placeholders, home paths with spaces, missing wallpaper directories, absent monitor data, no absolute `/home/` paths, no tokens/keys, and no binary plugin payloads.

Verification:

```bash
bats tests/bats/render-config.bats
bash scripts/check-source-policy.sh
```

Commit: `feat: render portable caelestia and hyprland configuration`

## Task 6: Integrate Hyprland, official hyprfocus, keybinds, and dock services

**Files:** `lib/services.sh`, `config/hypr/config/autostart.lua`, `config/hypr/config/keybinds.lua`, `config/hypr/hyprland.lua`, `config/nwg-dock-hyprland/**`, `tests/bats/integrations.bats`, `docs/RECOVERY.md`, `docs/troubleshooting.md`

- [ ] Remove the stale manual `~/.config/hypr/plugins/hyprfocus.so` loading path from the managed template; never copy the incompatible binary from the current machine.
- [ ] Detect `hyprpm`, add `https://github.com/hyprwm/hyprland-plugins` only when absent, enable `hyprfocus`, run `hyprpm update`, and reload the plugin through the supported Hyprland mechanism. Record a clear optional-skip reason when Hyprland/plugin support is unavailable.
- [ ] Preserve the approved subtle focus animation defaults and avoid installing visual plugins such as `hyprbars` or `borders-plus-plus`.
- [ ] Restore the official Caelestia wallpaper-picker keybind (`SUPER+W`) using the installed Caelestia CLI command and verify that it does not open the settings page. Keep `SUPER+1` through `SUPER+9` mapped to workspace switching.
- [ ] Replace the extracted Zen absolute path with the stable `zen-browser` launcher command supplied by `zen-browser-bin`.
- [ ] Install/update the user `nwg-dock-hyprland` service and its Caelestia dynamic theme path only when the service is available; keep dock transparency, low border height, theme-colored background, raised position, and stronger hover/click feedback in the templates.
- [ ] Make user-service operations explicit and idempotent (`systemctl --user daemon-reload`, enable/restart only managed units). Do not enable unrelated services.
- [ ] Enable weekly TRIM, monthly Btrfs scrub, and Snapper timeline/cleanup only when the corresponding filesystem, configuration, and systemd units are available; report skipped maintenance without blocking desktop setup.
- [ ] Test hyprpm branches, stale-plugin absence, exact keybind strings, service-unit idempotency, and dry-run command traces using fixtures.

Verification:

```bash
bats tests/bats/integrations.bats
shellcheck lib/services.sh
```

Commit: `feat: integrate official hyprfocus and desktop services`

## Task 7: Add desktop integrations and user-facing localization defaults

**Files:** `lib/services.sh`, `config/caelestia/**`, `config/fish/**`, `docs/COMPONENTS.md`, `docs/RECOVERY.md`, `tests/bats/desktop-integrations.bats`

- [ ] Configure user Flathub idempotently and verify the remote scope is `user`; do not write system-wide remotes by default.
- [ ] Provide Bazaar/Pamac availability checks and document that package installation/update actions remain user-confirmed by the GUI or package manager.
- [ ] Install optional Flatpak manifest entries only after their exact IDs are verified and only after the user-level Flathub remote is ready; record unavailable optional IDs without failing the desktop setup.
- [ ] Configure the approved pt-BR local translation/overrides without claiming upstream support. Keep untranslated upstream strings visible in a documented fallback list rather than silently corrupting text.
- [ ] Normalize audio device labels at the presentation layer, preserve full device names in tooltips or details, and keep Bluetooth battery percentage behind a settings toggle with a stable default.
- [ ] Keep the wallpaper carousel’s central image undimmed, dim only the selection backdrop, support arrow navigation and outside-click dismissal, and apply the selected wallpaper through the normal Caelestia path.
- [ ] Keep lock screen, energy controls, updates, plugins, display, Bluetooth, and wallpaper pages aligned with the current theme and Portuguese labels; do not alter firmware or BIOS settings.
- [ ] Test remote idempotency, localization fallback, label truncation/tooltip behavior, toggle persistence, and the wallpaper-picker state transitions from static fixtures.

Verification:

```bash
bats tests/bats/desktop-integrations.bats
```

Commit: `feat: preserve desktop integrations and pt-br defaults`

## Task 8: Add the read-only `cachy-health` audit command

**Files:** `scripts/cachy-health`, `lib/verify.sh`, `tests/bats/health.bats`, `docs/HARDWARE.md`, `docs/RECOVERY.md`

- [ ] Report OS/kernel, CPU driver/governor, ZRAM, swap, Btrfs device stats, Snapper/timers, TRIM, package update count, orphan count, firmware update availability, Hyprland/Caelestia versions, and user-service state.
- [ ] Classify findings as OK, NOTICE, or ACTION with a remediation explanation; do not automatically change a setting, remove packages, run firmware updates, enable Secure Boot, or change CPPC.
- [ ] Make every probe optional and timeout-safe so a missing tool produces a notice instead of aborting the whole report.
- [ ] Support `--json` for scripts while keeping the default human-readable Portuguese report. Escape JSON correctly and use stable field names.
- [ ] Add fixture tests for healthy, missing-tool, unsupported-filesystem, pending-update, and command-failure scenarios.

Verification:

```bash
bats tests/bats/health.bats
shellcheck scripts/cachy-health lib/verify.sh
```

Commit: `feat: add read-only cachyos health audit`

## Task 9: Compose the installer flow, safety gates, and recovery messaging

**Files:** `install.sh`, `lib/*.sh`, `scripts/restore-backup`, `tests/bats/installer.bats`, `tests/smoke.sh`, `tests/fixtures/`

- [ ] Compose the flow in this order: parse arguments; preflight; resolve manifests; show plan; confirm; capture backups/snapshot; install packages; render configs; configure user integrations; configure plugin/services; run validations; print rollback and health commands.
- [ ] In `--dry-run`, show all planned package, file, plugin, service, Flatpak, and snapshot actions without mutating state or requiring root.
- [ ] In normal mode, stop on required failures, preserve the backup reference in the error message, and never continue after a failed package transaction or failed atomic config write.
- [ ] In `--yes`, suppress only confirmations explicitly listed in the plan; still print privileged commands and rely on the visible terminal for authentication.
- [ ] Write a machine-readable run record containing timestamp, version, selected options, installed/skipped components, and backup/snapshot IDs, excluding passwords and personal file contents.
- [ ] Add end-to-end fixture tests covering clean install, rerun, dry-run, optional component failure, required component failure, restore, and interruption cleanup.

Verification:

```bash
bats tests/bats/installer.bats
bash -n install.sh lib/*.sh scripts/*.sh
```

Commit: `feat: compose safe idempotent setup workflow`

## Task 10: Add CI, source-policy enforcement, and documentation for one-command use

**Files:** `.github/workflows/ci.yml`, `scripts/check-source-policy.sh`, `.shellcheckrc`, `.editorconfig`, `README.md`, `docs/COMPONENTS.md`, `docs/HARDWARE.md`, `docs/RECOVERY.md`, `docs/troubleshooting.md`, `tests/bats/**`, `tests/smoke.sh`

- [ ] Add CI jobs for Bash syntax, ShellCheck, shfmt check, Bats tests, source-policy scan, manifest validation, and `git diff --check`.
- [ ] Make the source-policy script fail on absolute `/home/` paths, current-user names, private keys, common token assignments, binary plugin files, `eval`, and uncontrolled `sudo`; allow only the three documented placeholders and explicit command names.
- [ ] Document the public command using the versioned raw URL, explain the trust model, show `--dry-run` first, list package/AUR/Flatpak behavior, and state the scope exclusions.
- [ ] Document recovery with `--restore`, Snapper snapshot discovery, manual service reload, and the read-only `cachy-health` command.
- [ ] Document how to contribute translation/localization improvements upstream without including personal screenshots, credentials, or machine paths.
- [ ] Add a release checklist requiring a clean CI run, a fresh CachyOS/Hyprland validation, an idempotent second run, and a reviewed version tag before publishing the raw install URL.
- [ ] Add `tests/smoke.sh --dry-run` as the fixture-home smoke entrypoint required by the specification and run it in CI.

Verification:

```bash
shellcheck install.sh lib/*.sh scripts/*.sh
shfmt -d install.sh lib scripts tests
bats tests/bats
bash scripts/check-source-policy.sh
git diff --check
```

Commit: `ci: enforce installer quality and source policy`

## Task 11: Validate on the live host and publish the first version

**Files:** `docs/validation/live-host-YYYY-MM-DD.md`, `README.md`, `docs/COMPONENTS.md`, `docs/HARDWARE.md`, `docs/RECOVERY.md`

- [ ] Run the full dry-run on the current host and compare its plan against the validated live setup: Caelestia shell/CLI, pt-BR overrides, wallpaper picker, dock, Fish theme, Hyprfocus, energy pages, audio label normalization, Bluetooth percentage toggle, and workspace keybinds.
- [ ] Run the real installer from a visible Kitty terminal only after reviewing the plan and confirming the backup path. Do not type or relay the user’s password.
- [ ] Verify the post-install session: `SUPER+W` opens the wallpaper selector; arrow/click/outside-click behavior works; `SUPER+1..9` switch workspaces; dock and theme reload; Caelestia pages remain Portuguese; audio labels stay compact; restore metadata exists.
- [ ] Execute the second run and confirm no duplicate config lines, services, plugin registrations, package transactions, or Flatpak remotes.
- [ ] Run `cachy-health --json` and save only sanitized findings in the validation report; exclude usernames, serials, personal paths, and media.
- [ ] Review the final tree with `git status`, source-policy scan, CI results, and a clean diff. Tag `v1.0.0` only after the live validation passes and the user explicitly authorizes publication.

Verification:

```bash
git status --short
bash scripts/check-source-policy.sh
bats tests/bats
```

Commit: `docs: record first live-host validation`

## Final self-review checklist

- [ ] Every requirement in the approved spec has an implementation task and a verification command.
- [ ] The package manifest does not duplicate `caelestia-cli`; it appears only in the AUR list unless live repository verification proves otherwise.
- [ ] No task copies `fish_variables`, the stale `hyprfocus.so`, the extracted Zen binary, wallpapers, credentials, or hardware identifiers.
- [ ] `SUPER+W`, workspace shortcuts, dock behavior, Portuguese localization, theme integration, and optional Bluetooth battery percentage are all covered by tests or an explicit live-host check.
- [ ] Restore behavior, dry-run behavior, privileged-command visibility, and AUR failure behavior are unambiguous.
- [ ] Search for unfinished planning placeholders and suspicious paths:

```bash
rg -n 'TODO|TBD|FIXME|/home/gabriel|/home/|BEGIN (RSA|OPENSSH) PRIVATE KEY|token|password|secret' . --glob '!docs/superpowers/specs/**' --glob '!docs/superpowers/plans/**'
git diff --check
```

- [ ] Confirm the plan file itself has no placeholder wording, no unbounded destructive command, and no instruction to handle passwords.
