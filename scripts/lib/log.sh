#!/usr/bin/env bash
# Leveled logging helpers with optional color and secret masking.
# Source this file; do not execute it directly.

# Guard against double-sourcing.
if [[ -n "${__FABRIC_LOG_SH_LOADED:-}" ]]; then
  return 0
fi
__FABRIC_LOG_SH_LOADED=1

# Enable color only when stderr is a terminal.
if [[ -t 2 ]]; then
  __LOG_RED=$'\033[0;31m'
  __LOG_YELLOW=$'\033[0;33m'
  __LOG_GREEN=$'\033[0;32m'
  __LOG_BLUE=$'\033[0;34m'
  __LOG_RESET=$'\033[0m'
else
  __LOG_RED=""
  __LOG_YELLOW=""
  __LOG_GREEN=""
  __LOG_BLUE=""
  __LOG_RESET=""
fi

# LOG_LEVEL controls verbosity: DEBUG < INFO < WARN < ERROR. Default INFO.
__log_level_value() {
  case "${1:-INFO}" in
    DEBUG) echo 10 ;;
    INFO) echo 20 ;;
    WARN) echo 30 ;;
    ERROR) echo 40 ;;
    *) echo 20 ;;
  esac
}

__log_enabled() {
  local want current
  want="$(__log_level_value "$1")"
  current="$(__log_level_value "${LOG_LEVEL:-INFO}")"
  [[ "$want" -ge "$current" ]]
}

__log_emit() {
  # $1 level, $2 color, rest message.
  local level color
  level="$1"
  color="$2"
  shift 2
  printf '%s[%s]%s %s\n' "$color" "$level" "$__LOG_RESET" "$*" >&2
}

log_debug() { __log_enabled DEBUG && __log_emit DEBUG "$__LOG_BLUE" "$@"; return 0; }
log_info() { __log_enabled INFO && __log_emit INFO "$__LOG_GREEN" "$@"; return 0; }
log_warn() { __log_enabled WARN && __log_emit WARN "$__LOG_YELLOW" "$@"; return 0; }
log_error() { __log_enabled ERROR && __log_emit ERROR "$__LOG_RED" "$@"; return 0; }

# Print an error and exit with the given code (default 1).
die() {
  local code=1
  if [[ "${1:-}" =~ ^[0-9]+$ ]]; then
    code="$1"
    shift
  fi
  log_error "$@"
  exit "$code"
}

# Mask a secret for safe logging, showing only the last 4 characters.
mask_secret() {
  local value="${1:-}"
  local len=${#value}
  if (( len <= 4 )); then
    printf '****'
  else
    printf '****%s' "${value: -4}"
  fi
}
