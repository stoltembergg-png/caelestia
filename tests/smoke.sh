#!/usr/bin/env bash
set -Eeuo pipefail

readonly TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly REPO_ROOT="$(cd -- "$TEST_DIR/.." && pwd -P)"

exec bash "$REPO_ROOT/install.sh" "$@"
