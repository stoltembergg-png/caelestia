# Troubleshooting

## Package planning

The installer checks the official manifest with `pacman -Q` and `pacman -Si`.
It checks only the explicit AUR manifest through `paru`; it never installs or
reinstalls `yay`. If `paru` is absent, install the listed required AUR packages
manually, then rerun the installer. `zen-browser-bin` is optional and is
recorded as skipped when unavailable.

If a required package is unavailable, the package plan stops before starting
either the official or AUR transaction. Review the package name and configured
repositories, then retry. Dry-run prints the planned argv without querying or
invoking a package manager.
