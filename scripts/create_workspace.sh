#!/usr/bin/env bash
# Create the target Fabric workspace and assign capacity when it does not yet
# exist. Safe to run repeatedly; an existing workspace is left untouched.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/log.sh
source "${SCRIPT_DIR}/lib/log.sh"
# shellcheck source=scripts/lib/config.sh
source "${SCRIPT_DIR}/lib/config.sh"
# shellcheck source=scripts/lib/auth.sh
source "${SCRIPT_DIR}/lib/auth.sh"
# shellcheck source=scripts/lib/fabric_api.sh
source "${SCRIPT_DIR}/lib/fabric_api.sh"

usage() {
  cat <<'EOF'
Create the target Fabric workspace if it does not already exist.

Usage:
  create_workspace.sh --env <name> [--admin <user-object-id>]

Options:
  --env <name>   Environment to load from config/<name>.env (required).
  --admin <id>   Object ID of a user or group to add as workspace Admin.
  -h, --help     Show this help.

Configuration variables (from config/<name>.env or the environment):
  FABRIC_TENANT_ID, FABRIC_CLIENT_ID, FABRIC_CLIENT_SECRET, FABRIC_WORKSPACE_NAME
  FABRIC_CAPACITY_ID (optional; assigns the workspace to this capacity)
EOF
}

main() {
  local env_name="" admin_id=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env) env_name="${2:-}"; shift 2 ;;
      --admin) admin_id="${2:-}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown argument: $1" ;;
    esac
  done

  [[ -z "$env_name" ]] && { usage; die "Missing required --env"; }

  fabric::load_config "$env_name"

  log_info "Authenticating to tenant ${FABRIC_TENANT_ID}"
  FABRIC_TOKEN="$(fabric::get_token)"
  export FABRIC_TOKEN

  local existing
  existing="$(fabric::find_workspace_id "$FABRIC_WORKSPACE_NAME")"
  if [[ -n "$existing" ]]; then
    log_info "Workspace '${FABRIC_WORKSPACE_NAME}' already exists (${existing}); nothing to do"
    printf '%s\n' "$existing"
    return 0
  fi

  log_info "Creating workspace '${FABRIC_WORKSPACE_NAME}'"
  local ws_id
  ws_id="$(fabric::create_workspace "$FABRIC_WORKSPACE_NAME" "${FABRIC_CAPACITY_ID:-}")"
  log_info "Created workspace ${ws_id}"

  if [[ -n "$admin_id" ]]; then
    log_info "Adding ${admin_id} as Admin"
    fabric::add_workspace_role "$ws_id" "$admin_id" "Admin"
  fi

  printf '%s\n' "$ws_id"
}

main "$@"
