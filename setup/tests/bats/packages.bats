#!/usr/bin/env bats

setup() {
  repo_root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd -P)"
  fake_bin="$repo_root/tests/fixtures/fake-bin"
  audit="$BATS_TEST_TMPDIR/package-audit"
}

source_packages() {
  source "$repo_root/install.sh"
  source "$repo_root/lib/packages.sh"
}

@test "sourcing the package module does not query or install packages" {
  query_audit="$BATS_TEST_TMPDIR/package-query-audit"

  run env PATH="$fake_bin:$PATH" PACKAGE_QUERY_AUDIT="$query_audit" \
    bash -c 'source "$1"; source "$2"' _ \
    "$repo_root/install.sh" "$repo_root/lib/packages.sh"

  [ "$status" -eq 0 ]
  [ ! -e "$query_audit" ]
}

@test "installed package is not planned for another transaction" {
  manifest_root="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$manifest_root/packages"
  printf 'fish\nflatpak\n' > "$manifest_root/packages/official.txt"
  printf 'caelestia-cli\n' > "$manifest_root/packages/aur.txt"

  run env PATH="$fake_bin:$PATH" FAKE_PACMAN_INSTALLED='fish caelestia-cli' \
    FAKE_PACMAN_AVAILABLE='flatpak' PACKAGE_MANIFEST_ROOT="$manifest_root" \
    bash -c 'source "$1"; source "$2"; plan_packages; print_package_plan' _ \
    "$repo_root/install.sh" "$repo_root/lib/packages.sh"

  [ "$status" -eq 0 ]
  [[ "$output" == *'official: fish'* ]]
  [[ "$output" == *'aur: caelestia-cli'* ]]
  [[ "$output" == *'official: flatpak'* ]]
}

@test "duplicate manifest entries block the package plan" {
  manifest_root="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$manifest_root/packages"
  printf 'fish\nfish\n' > "$manifest_root/packages/official.txt"
  : > "$manifest_root/packages/aur.txt"

  run env PATH="$fake_bin:$PATH" PACKAGE_MANIFEST_ROOT="$manifest_root" \
    bash -c 'source "$1"; source "$2"; plan_packages' _ \
    "$repo_root/install.sh" "$repo_root/lib/packages.sh"

  [ "$status" -ne 0 ]
  [[ "$output" == *'duplicate package entry: fish'* ]]
}

@test "missing required package blocks before a transaction" {
  manifest_root="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$manifest_root/packages"
  printf 'missing-official\n' > "$manifest_root/packages/official.txt"
  : > "$manifest_root/packages/aur.txt"

  run env PATH="$fake_bin:$PATH" PACKAGE_MANIFEST_ROOT="$manifest_root" \
    bash -c 'source "$1"; source "$2"; if plan_packages; then plan_status=0; else plan_status=$?; fi; print_package_plan; exit "$plan_status"' _ \
    "$repo_root/install.sh" "$repo_root/lib/packages.sh"

  [ "$status" -ne 0 ]
  [[ "$output" == *'official: missing-official (unavailable from configured repositories)'* ]]
}

@test "missing paru lists each required AUR package for manual handling" {
  manifest_root="$BATS_TEST_TMPDIR/repo"
  without_paru="$BATS_TEST_TMPDIR/without-paru"
  mkdir -p "$manifest_root/packages"
  mkdir -p "$without_paru"
  ln -s "$fake_bin/pacman" "$without_paru/pacman"
  : > "$manifest_root/packages/official.txt"
  printf 'required-one\nrequired-two\nzen-browser-bin\n' > "$manifest_root/packages/aur.txt"

  run env PACKAGE_MANIFEST_ROOT="$manifest_root" \
    /bin/bash -c 'source "$1"; PATH="$3"; source "$2"; if plan_packages; then plan_status=0; else plan_status=$?; fi; print_package_plan; exit "$plan_status"' _ \
    "$repo_root/install.sh" "$repo_root/lib/packages.sh" "$without_paru"

  [ "$status" -ne 0 ]
  [[ "$output" == *'required-one (paru is unavailable; install manually)'* ]]
  [[ "$output" == *'required-two (paru is unavailable; install manually)'* ]]
  [[ "$output" == *'zen-browser-bin (paru is unavailable)'* ]]
}

@test "dry-run records transactions without invoking package managers or sudo" {
  run env PATH="$fake_bin:$PATH" PACKAGE_AUDIT="$audit" \
    bash -c 'source "$1"; source "$2"; DRY_RUN=1; apply_package_plan' _ \
    "$repo_root/install.sh" "$repo_root/lib/packages.sh"

  [ "$status" -eq 0 ]
  [[ "$output" == *'DRY-RUN: pacman -Syu --needed'* ]]
  [[ "$output" == *'DRY-RUN: paru -S --needed'* ]]
  [ ! -e "$audit" ]
}

@test "all-installed packages still run one confirmed official update without paru" {
  manifest_root="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$manifest_root/packages"
  printf 'official-one\n' > "$manifest_root/packages/official.txt"
  printf 'aur-one\n' > "$manifest_root/packages/aur.txt"

  run env PATH="$fake_bin:$PATH" PACKAGE_MANIFEST_ROOT="$manifest_root" PACKAGE_AUDIT="$audit" \
    FAKE_PACMAN_INSTALLED='official-one aur-one' \
    bash -c 'source "$1"; source "$2"; ASSUME_YES=1; run_privileged() { run "$@"; }; apply_package_plan' _ \
    "$repo_root/install.sh" "$repo_root/lib/packages.sh"

  [ "$status" -eq 0 ]
  [ "$(cat "$audit")" = 'pacman -Syu' ]
  [ "$(grep -c '^paru ' "$audit" || true)" -eq 0 ]
}

@test "only the explicit AUR manifest reaches paru and yay is never invoked" {
  manifest_root="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$manifest_root/packages"
  printf 'official-one\n' > "$manifest_root/packages/official.txt"
  printf 'aur-one\n' > "$manifest_root/packages/aur.txt"

  run env PATH="$fake_bin:$PATH" PACKAGE_MANIFEST_ROOT="$manifest_root" PACKAGE_AUDIT="$audit" \
    FAKE_PACMAN_AVAILABLE='official-one' FAKE_PARU_AVAILABLE='aur-one' \
    bash -c 'source "$1"; source "$2"; ASSUME_YES=1; run_privileged() { run "$@"; }; apply_package_plan' _ \
    "$repo_root/install.sh" "$repo_root/lib/packages.sh"

  [ "$status" -eq 0 ]
  [ "$(wc -l < "$audit")" -eq 2 ]
  [[ "$(sed -n '1p' "$audit")" == *'pacman -Syu --needed official-one'* ]]
  [[ "$(sed -n '2p' "$audit")" == *'paru -S --needed aur-one'* ]]
  [[ "$(cat "$audit")" != *yay* ]]
}
