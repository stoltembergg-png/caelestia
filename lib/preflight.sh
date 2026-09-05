#!/usr/bin/env bash

# Shared logging, execution, and environment checks for the installer.

log_info() {
  printf 'INFO: %s\n' "$*" >&2
}

log_warn() {
  printf 'WARN: %s\n' "$*" >&2
}

log_error() {
  printf 'ERROR: %s\n' "$*" >&2
}

die() {
  local message="$1"
  local status="${2:-1}"
  log_error "$message"
  return "$status"
}

format_argv() {
  local argument escaped
  for argument in "$@"; do
    printf -v escaped '%q' "$argument"
    printf '%s ' "$escaped"
  done
}

run() {
  (( $# > 0 )) || die 'run requires an argv array'

  local rendered
  rendered="$(format_argv "$@")"
  if (( ${DRY_RUN:-0} )); then
    log_info "DRY-RUN: $rendered"
    return 0
  fi

  log_info "RUN: $rendered"
  "$@"
}

run_privileged() {
  (( $# > 0 )) || die 'run_privileged requires an argv array'
  if [[ ! -t 0 || ! -t 1 ]]; then
    die 'privileged commands require a visible, interactive terminal'
    return $?
  fi
  command -v sudo >/dev/null 2>&1 || {
    die 'sudo is required for privileged commands'
    return $?
  }

  run sudo -- "$@"
}

confirm() {
  local prompt="$1"
  local answer

  if (( ${DRY_RUN:-0} )); then
    log_info "DRY-RUN: confirmation skipped: $prompt"
    return 0
  fi
  if (( ${ASSUME_YES:-0} )); then
    log_info "Confirmation accepted by --yes: $prompt"
    return 0
  fi

  read -r -p "$prompt [y/N] " answer
  [[ "$answer" == 'y' || "$answer" == 'Y' ]]
}

check_bash_version() {
  if (( BASH_VERSINFO[0] < 4 )); then
    die "Bash 4 or newer is required; found ${BASH_VERSION}"
    return $?
  fi
}

check_interactive_terminal() {
  if [[ ! -t 0 || ! -t 1 || -z "${TERM:-}" || "${TERM:-}" == 'dumb' ]]; then
    die 'Run the installer from a visible, interactive terminal (Kitty or another terminal emulator).'
    return $?
  fi
}

check_supported_distribution() {
  local os_release_file="${OS_RELEASE_FILE:-/etc/os-release}"
  local id='' id_like='' key value

  if [[ ! -r "$os_release_file" ]]; then
    die "Cannot read distribution identity from $os_release_file"
    return $?
  fi

  while IFS='=' read -r key value; do
    value="${value%\"}"
    value="${value#\"}"
    case "$key" in
      ID) id="$value" ;;
      ID_LIKE) id_like="$value" ;;
    esac
  done < "$os_release_file"

  if [[ "$id" != 'cachyos' && "$id" != 'arch' && " $id_like " != *' arch '* ]]; then
    die 'This installer supports CachyOS or another Arch-based system only.'
    return $?
  fi
}

check_required_commands() {
  local missing=0 command_name
  local -a required_commands=(bash curl sudo mktemp rm)

  for command_name in "${required_commands[@]}"; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
      log_error "Required base command is unavailable: $command_name"
      missing=1
    fi
  done
  (( missing == 0 ))
}

check_network() {
  if ! curl --fail --silent --show-error --max-time 10 https://archlinux.org/ >/dev/null; then
    die 'Network reachability check failed. Connect to the internet and retry.'
    return $?
  fi
}

check_sudo() {
  if ! sudo -v; then
    die 'sudo authentication failed. Authenticate in this terminal and retry.'
    return $?
  fi
}

check_desktop_session() {
  if [[ -z "${XDG_CURRENT_DESKTOP:-}" && -z "${WAYLAND_DISPLAY:-}" && -z "${DISPLAY:-}" ]]; then
    die 'A logged-in desktop session is required (set XDG_CURRENT_DESKTOP, WAYLAND_DISPLAY, or DISPLAY).'
    return $?
  fi
}

report_optional_capabilities() {
  local command_name
  local -a optional_commands=(pacman paru flatpak btrfs snapper hyprctl)

  for command_name in "${optional_commands[@]}"; do
    if command -v "$command_name" >/dev/null 2>&1; then
      log_info "Optional capability available: $command_name"
    else
      log_warn "Optional capability unavailable: $command_name"
    fi
  done
}

preflight() {
  local failed=0

  check_bash_version || failed=1
  check_interactive_terminal || failed=1
  check_supported_distribution || failed=1
  check_required_commands || failed=1
  check_network || failed=1
  check_sudo || failed=1
  check_desktop_session || failed=1
  report_optional_capabilities

  (( failed == 0 ))
}
