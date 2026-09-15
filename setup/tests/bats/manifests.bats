#!/usr/bin/env bats

setup() {
  repo_root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
  manifests=(official.txt aur.txt flatpak.txt)
  printf 'fish\nfish\n' > "$BATS_TEST_TMPDIR/duplicate.txt"
  printf '\n' > "$BATS_TEST_TMPDIR/blank.txt"
  printf 'fish;rm\n' > "$BATS_TEST_TMPDIR/metachar.txt"
}

manifest_entries() {
  sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "$1"
}

validate_manifest() {
  local manifest="$1"
  [ -f "$manifest" ] || return 1
  local entries
  entries="$(manifest_entries "$manifest")"
  [ -n "$entries" ] || { [ "$(basename "$manifest")" = flatpak.txt ]; }
  while IFS= read -r entry; do
    [[ "$entry" =~ ^[A-Za-z0-9@._+:-]+$ ]] || return 1
  done <<< "$entries"
  [ "$(printf '%s\n' "$entries" | sort | uniq -d | wc -l)" -eq 0 ]
}

@test "all package manifests exist and contain valid unique identifiers" {
  for name in "${manifests[@]}"; do
    validate_manifest "$repo_root/packages/$name"
  done
}

@test "duplicate package names are rejected" {
  ! validate_manifest "$BATS_TEST_TMPDIR/duplicate.txt"
}

@test "blank identifiers are rejected" {
  ! validate_manifest "$BATS_TEST_TMPDIR/blank.txt"
}

@test "shell metacharacters are rejected" {
  ! validate_manifest "$BATS_TEST_TMPDIR/metachar.txt"
}

@test "missing manifest is rejected" {
  ! validate_manifest "$BATS_TEST_TMPDIR/missing.txt"
}
