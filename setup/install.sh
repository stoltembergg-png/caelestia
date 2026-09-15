#!/usr/bin/env bash
set -Eeuo pipefail

readonly INSTALLER_VERSION='0.1.0'
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly REPO_ROOT="$SCRIPT_DIR"

# shellcheck source=lib/preflight.sh
source "$REPO_ROOT/lib/preflight.sh"

DRY_RUN=0
ASSUME_YES=0
RESTORE_TIMESTAMP=''
SKIP_MONITOR=0
WORKSPACE=''

usage() {
  cat <<'USAGE'
Usage: install.sh [OPTIONS]

Options:
  --dry-run              Print planned commands without executing them.
  --yes                  Accept future confirmation prompts.
  --restore TIMESTAMP    Select a UTC backup timestamp (YYYYMMDDTHHMMSSZ).
  --skip-monitor         Do not apply the guarded monitor profile.
  --help                 Show this help and exit.
  --version              Show the installer version and exit.
USAGE
}

usage_error() {
  log_error "$1"
  usage >&2
  return 2
}

validate_restore_timestamp() {
  [[ "$1" =~ ^[0-9]{8}T[0-9]{6}Z$ ]]
}

parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      --dry-run) DRY_RUN=1 ;;
      --yes) ASSUME_YES=1 ;;
      --skip-monitor) SKIP_MONITOR=1 ;;
      --restore)
        if (( $# < 2 )); then
          usage_error '--restore requires a TIMESTAMP value'
          return $?
        fi
        RESTORE_TIMESTAMP="$2"
        if ! validate_restore_timestamp "$RESTORE_TIMESTAMP"; then
          usage_error '--restore TIMESTAMP must be UTC YYYYMMDDTHHMMSSZ'
          return $?
        fi
        shift
        ;;
      --help) SHOW_HELP=1 ;;
      --version) SHOW_VERSION=1 ;;
      *)
        usage_error "unknown option: $1"
        return $?
        ;;
    esac
    shift
  done
}

cleanup_workspace() {
  if [[ -n "${WORKSPACE:-}" && -d "$WORKSPACE" ]]; then
    rm -rf -- "$WORKSPACE"
  fi
}

setup_workspace() {
  WORKSPACE="$(mktemp -d "${TMPDIR:-/tmp}/cachyos-caelestia-setup.XXXXXX")"
  trap cleanup_workspace EXIT
  trap 'cleanup_workspace; exit 130' INT
  trap 'cleanup_workspace; exit 143' TERM
}

print_selected_options() {
  local restore_display='none'
  [[ -n "$RESTORE_TIMESTAMP" ]] && restore_display="$RESTORE_TIMESTAMP"
  log_info "Selected options: dry-run=$([[ "$DRY_RUN" -eq 1 ]] && printf yes || printf no), yes=$([[ "$ASSUME_YES" -eq 1 ]] && printf yes || printf no), restore=$restore_display, skip-monitor=$([[ "$SKIP_MONITOR" -eq 1 ]] && printf yes || printf no)"
}

main() {
  local SHOW_HELP=0 SHOW_VERSION=0
  parse_args "$@"

  if (( SHOW_HELP )); then
    usage
    return 0
  fi
  if (( SHOW_VERSION )); then
    printf 'cachyos-caelestia-setup %s\n' "$INSTALLER_VERSION"
    return 0
  fi

  print_selected_options

  if (( DRY_RUN )); then
    log_info 'Dry-run contract validated; task modules will supply planned actions in later tasks.'
    return 0
  fi

  setup_workspace

  if ! preflight; then
    die 'Preflight failed; no installation actions were performed.'
    return $?
  fi

  log_info 'Preflight passed; installer orchestration is intentionally deferred to later tasks.'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
