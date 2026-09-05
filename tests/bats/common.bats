#!/usr/bin/env bats

setup() {
  repo_root="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd -P)"
  fake_bin="$repo_root/tests/fixtures/fake-bin"
}

@test "help and version bypass preflight" {
  run bash "$repo_root/install.sh" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage:"* ]]

  run bash "$repo_root/install.sh" --version
  [ "$status" -eq 0 ]
  [ "$output" = "cachyos-caelestia-setup 0.1.0" ]
}

@test "accepted options are reported by the dry-run contract" {
  run bash "$repo_root/install.sh" --dry-run --yes --restore 20260905T120000Z --skip-monitor

  [ "$status" -eq 0 ]
  [[ "$output" == *"dry-run=yes"* ]]
  [[ "$output" == *"yes=yes"* ]]
  [[ "$output" == *"restore=20260905T120000Z"* ]]
  [[ "$output" == *"skip-monitor=yes"* ]]
}

@test "dry-run does not create a temporary workspace" {
  audit="$BATS_TEST_TMPDIR/mktemp-called"

  run env PATH="$fake_bin:$PATH" FIXTURE_AUDIT="$audit" \
    bash "$repo_root/install.sh" --dry-run

  [ "$status" -eq 0 ]
  [ ! -e "$audit" ]
}

@test "unknown options exit with usage status" {
  run bash "$repo_root/install.sh" --not-an-option

  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown option"* ]]
}

@test "restore requires a timestamp value" {
  run bash "$repo_root/install.sh" --restore

  [ "$status" -eq 2 ]
  [[ "$output" == *"requires a TIMESTAMP"* ]]
}

@test "restore rejects shell metacharacters without executing them" {
  marker="$BATS_TEST_TMPDIR/should-not-exist"

  run bash "$repo_root/install.sh" --dry-run --restore "20260905;touch$marker"

  [ "$status" -eq 2 ]
  [ ! -e "$marker" ]
}

@test "dry-run logs argv and does not execute the command" {
  capture="$BATS_TEST_TMPDIR/capture"
  literal="literal;touch $BATS_TEST_TMPDIR/should-not-exist"

  run env CAPTURE_FILE="$capture" bash -c 'source "$1"; DRY_RUN=1; run "$2" "$3"' _ \
    "$repo_root/install.sh" "$fake_bin/capture-argv" "$literal"

  [ "$status" -eq 0 ]
  [[ "$output" == *"DRY-RUN:"* ]]
  [[ "$output" == *"literal\\;touch"* ]]
  [ ! -e "$capture" ]
  [ ! -e "$BATS_TEST_TMPDIR/should-not-exist" ]
}

@test "run propagates a command failure status" {
  run bash -c 'source "$1"; run "$2"' _ \
    "$repo_root/install.sh" "$fake_bin/fail-42"

  [ "$status" -eq 42 ]
}

@test "signal traps remove the temporary workspace" {
  run bash -c 'source "$1"; setup_workspace; printf "%s\\n" "$WORKSPACE"; kill -TERM $$' _ \
    "$repo_root/install.sh"

  [ "$status" -eq 143 ]
  [ ! -e "${lines[0]}" ]
}

@test "invalid terminal short-circuits before sudo authentication" {
  audit="$BATS_TEST_TMPDIR/sudo-called"

  run env PATH="$fake_bin:$PATH" FIXTURE_AUDIT="$audit" TERM=dumb \
    XDG_CURRENT_DESKTOP=Hyprland bash -c 'source "$1"; preflight' _ \
    "$repo_root/install.sh"

  [ "$status" -ne 0 ]
  [ ! -e "$audit" ]
}
