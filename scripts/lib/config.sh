#!/usr/bin/env bash
# Environment configuration loading for the deployment scripts.
# Source this file; do not execute it directly.

if [[ -n "${__FABRIC_CONFIG_SH_LOADED:-}" ]]; then
  return 0
fi
__FABRIC_CONFIG_SH_LOADED=1

__CONFIG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/log.sh
source "${__CONFIG_DIR}/log.sh"

# Repository root, derived from this file's location (scripts/lib -> repo root).
FABRIC_REPO_ROOT="$(cd "${__CONFIG_DIR}/../.." && pwd)"

# Load environment configuration.
#
# When --env <name> is used, the matching config/<name>.env file is sourced if
# present. Variables already set in the environment (for example CI/CD variables
# injected by CI/CD (e.g., GitLab)) always win and are never overwritten by the file.
#
# Args: <env_name>
fabric::load_config() {
  local env_name="$1"
  [[ -z "$env_name" ]] && die "An environment name is required (use --env <name>)"

  local config_file="${FABRIC_REPO_ROOT}/config/${env_name}.env"
  if [[ -f "$config_file" ]]; then
    log_debug "Loading configuration from ${config_file}"
    # Only set variables that are not already present in the environment.
    local line key value
    while IFS= read -r line || [[ -n "$line" ]]; do
      # Skip comments and blank lines.
      [[ "$line" =~ ^[[:space:]]*# ]] && continue
      [[ "$line" =~ ^[[:space:]]*$ ]] && continue
      # Strip an optional leading "export ".
      line="${line#export }"
      key="${line%%=*}"
      value="${line#*=}"
      # Trim surrounding whitespace from the key.
      key="${key//[[:space:]]/}"
      [[ -z "$key" ]] && continue
      # Strip matching surrounding quotes from the value.
      value="${value%\"}"; value="${value#\"}"
      value="${value%\'}"; value="${value#\'}"
      if [[ -z "${!key:-}" ]]; then
        export "${key}=${value}"
      fi
    done <"$config_file"
  else
    log_debug "No config file at ${config_file}; relying on environment variables"
  fi

  # Validate the variables every script needs.
  : "${FABRIC_TENANT_ID:?FABRIC_TENANT_ID is required (set it in config/${env_name}.env or the environment)}"
  : "${FABRIC_WORKSPACE_NAME:?FABRIC_WORKSPACE_NAME is required}"

  # If the config explicitly requests Azure CLI auth, clear any inherited SPN vars
  # so auth.sh routes to az-cli mode even when the parent shell has SPN creds.
  if [[ -f "$config_file" ]] && grep -Eq '^(export[[:space:]]+)?FABRIC_AUTH_MODE=azcli($|[[:space:]]|#)' "$config_file"; then
    unset FABRIC_CLIENT_SECRET 2>/dev/null || true
    unset FABRIC_CLIENT_ID 2>/dev/null || true
  fi

  # SPN-specific vars are only required when FABRIC_CLIENT_SECRET is set (SPN mode).
  if [[ -n "${FABRIC_CLIENT_SECRET:-}" ]]; then
    : "${FABRIC_CLIENT_ID:?FABRIC_CLIENT_ID is required for SPN auth}"
  fi
}
