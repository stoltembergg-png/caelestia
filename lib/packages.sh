#!/usr/bin/env bash

# Package planning and application. This module is sourced by the installer;
# it deliberately performs no work while being sourced.

PACKAGE_MANIFEST_ROOT="${PACKAGE_MANIFEST_ROOT:-$REPO_ROOT}"

declare -a OFFICIAL_INSTALLED=()
declare -a OFFICIAL_TO_INSTALL=()
declare -a AUR_INSTALLED=()
declare -a AUR_TO_INSTALL=()
declare -a OPTIONAL_SKIPPED=()
declare -a BLOCKING_PACKAGES=()

reset_package_plan() {
  OFFICIAL_INSTALLED=()
  OFFICIAL_TO_INSTALL=()
  AUR_INSTALLED=()
  AUR_TO_INSTALL=()
  OPTIONAL_SKIPPED=()
  BLOCKING_PACKAGES=()
}

package_is_optional() {
  [[ "$1" == 'zen-browser-bin' ]]
}

read_package_manifest() {
  local manifest="$1" array_name="$2" line package
  local -n destination="$array_name"
  local -A seen=()

  [[ -r "$manifest" ]] || die "Package manifest is unreadable: $manifest"
  destination=()

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -n "$line" ]] || continue
    package="$line"
    if [[ ! "$package" =~ ^[A-Za-z0-9@._+:-]+$ ]]; then
      die "invalid package entry in $manifest: $package"
      return $?
    fi
    if [[ -v "seen[$package]" ]]; then
      die "duplicate package entry: $package"
      return $?
    fi
    seen["$package"]=1
    destination+=("$package")
  done < "$manifest"
}

package_installed() {
  pacman -Q "$1" >/dev/null 2>&1
}

official_package_available() {
  pacman -Si "$1" >/dev/null 2>&1
}

aur_package_available() {
  paru -Si "$1" >/dev/null 2>&1
}

add_optional_skip() {
  OPTIONAL_SKIPPED+=("$1 ($2)")
}

add_blocking_package() {
  BLOCKING_PACKAGES+=("$1 ($2)")
}

plan_packages() {
  local -a official_packages=() aur_packages=()
  local package

  reset_package_plan
  read_package_manifest "$PACKAGE_MANIFEST_ROOT/packages/official.txt" official_packages || return $?
  read_package_manifest "$PACKAGE_MANIFEST_ROOT/packages/aur.txt" aur_packages || return $?

  if (( ${DRY_RUN:-0} )); then
    OFFICIAL_TO_INSTALL=("${official_packages[@]}")
    AUR_TO_INSTALL=("${aur_packages[@]}")
    log_info 'Dry-run does not query package presence or availability; all manifest entries are planned.'
    return 0
  fi

  command -v pacman >/dev/null 2>&1 || {
    die 'pacman is required to inspect and install official packages'
    return $?
  }

  for package in "${official_packages[@]}"; do
    if package_installed "$package"; then
      OFFICIAL_INSTALLED+=("$package")
    elif official_package_available "$package"; then
      OFFICIAL_TO_INSTALL+=("$package")
    else
      add_blocking_package "official: $package" 'unavailable from configured repositories'
    fi
  done

  for package in "${aur_packages[@]}"; do
    if package_installed "$package"; then
      AUR_INSTALLED+=("$package")
    elif ! command -v paru >/dev/null 2>&1; then
      if package_is_optional "$package"; then
        add_optional_skip "$package" 'paru is unavailable'
      else
        add_blocking_package "$package" 'paru is unavailable; install manually'
      fi
    elif aur_package_available "$package"; then
      AUR_TO_INSTALL+=("$package")
    elif package_is_optional "$package"; then
      add_optional_skip "$package" 'unavailable through paru'
    else
      add_blocking_package "$package" 'unavailable through paru'
    fi
  done

  (( ${#BLOCKING_PACKAGES[@]} == 0 ))
}

print_package_plan_group() {
  local label="$1" prefix="$2"
  shift 2
  if (( $# == 0 )); then
    log_info "  $label: none"
    return 0
  fi
  log_info "  $label: $prefix$*"
}

print_package_plan() {
  log_info 'Package plan:'
  log_info '  official-system-update: pacman -Syu (confirmed before execution)'
  print_package_plan_group 'already-installed (official)' 'official: ' "${OFFICIAL_INSTALLED[@]}"
  print_package_plan_group 'already-installed (aur)' 'aur: ' "${AUR_INSTALLED[@]}"
  print_package_plan_group 'to-install (official)' 'official: ' "${OFFICIAL_TO_INSTALL[@]}"
  print_package_plan_group 'to-install (aur)' 'aur: ' "${AUR_TO_INSTALL[@]}"
  print_package_plan_group 'unavailable-optional' '' "${OPTIONAL_SKIPPED[@]}"
  print_package_plan_group 'blocking' '' "${BLOCKING_PACKAGES[@]}"
}

apply_package_plan() {
  local plan_status
  local -a official_transaction=(-Syu)

  if plan_packages; then
    plan_status=0
  else
    plan_status=$?
  fi
  print_package_plan
  if (( plan_status != 0 || ${#BLOCKING_PACKAGES[@]} > 0 )); then
    die 'Package plan has blocking entries; no package transaction was started.'
    return $?
  fi

  confirm 'Apply the package plan?' || {
    log_warn 'Package plan was not confirmed; no package transaction was started.'
    return 1
  }

  if (( ${#OFFICIAL_TO_INSTALL[@]} > 0 )); then
    official_transaction+=(--needed "${OFFICIAL_TO_INSTALL[@]}")
  fi

  if (( ${DRY_RUN:-0} )); then
    run pacman "${official_transaction[@]}"
  else
    run_privileged pacman "${official_transaction[@]}"
  fi

  if (( ${#AUR_TO_INSTALL[@]} > 0 )); then
    run paru -S --needed "${AUR_TO_INSTALL[@]}"
  fi
}
