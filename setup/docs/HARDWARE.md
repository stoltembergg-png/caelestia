# Hardware and session assumptions

The supported target is the current CachyOS machine with a logged-in Hyprland
session. The guarded `DP-1` monitor profile is a same-machine convenience and
must not be applied blindly to another output; another layout should skip or
edit that profile.

Btrfs and Snapper support is optional. BIOS settings, Secure Boot keys,
firmware updates, partitions, bootloaders, and CPU/CPPC settings are explicit
exclusions. CPPC may be documented as an observation or optional host choice,
but this repository never changes it.
