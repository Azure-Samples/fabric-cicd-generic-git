#!/usr/bin/env bash
# Export Fabric item definitions from a workspace into the local fabric/ tree
# using the Bulk Export Item Definitions API.
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
Export Fabric item definitions from a workspace into a local folder.

Usage:
  export_workspace.sh --env <name> [options]

Options:
  --env <name>        Environment to load from config/<name>.env (required).
  --output <dir>      Destination folder for item definitions (default: fabric).
  --mode <mode>       Export mode: All or Selective (default: All).
  --items <ids>       Comma-separated item GUIDs (required for Selective mode).
  --prune             Delete local files no longer present in the workspace.
  -h, --help          Show this help.

Configuration variables (from config/<name>.env or the environment):
  FABRIC_TENANT_ID, FABRIC_CLIENT_ID, FABRIC_CLIENT_SECRET, FABRIC_WORKSPACE_NAME
EOF
}

main() {
  local env_name="" output_dir="" mode="All" items_csv="" prune="false"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env) env_name="${2:-}"; shift 2 ;;
      --output) output_dir="${2:-}"; shift 2 ;;
      --mode) mode="${2:-}"; shift 2 ;;
      --items) items_csv="${2:-}"; shift 2 ;;
      --prune) prune="true"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown argument: $1" ;;
    esac
  done

  [[ -z "$env_name" ]] && { usage; die "Missing required --env"; }
  case "$mode" in All|Selective) ;; *) die "Invalid --mode '$mode' (expected All or Selective)" ;; esac

  fabric::load_config "$env_name"
  output_dir="${output_dir:-${FABRIC_REPO_ROOT}/fabric}"

  # Build the optional item list for selective export.
  local items_json=""
  if [[ "$mode" == "Selective" ]]; then
    [[ -z "$items_csv" ]] && die "Selective mode requires --items <comma-separated GUIDs>"
    items_json="$(jq -Rnc --arg csv "$items_csv" \
      '$csv | split(",") | map({id: (. | gsub("^\\s+|\\s+$"; ""))})')"
  fi

  log_info "Authenticating to tenant ${FABRIC_TENANT_ID}"
  FABRIC_TOKEN="$(fabric::get_token)"
  export FABRIC_TOKEN

  log_info "Resolving workspace '${FABRIC_WORKSPACE_NAME}'"
  local ws_id
  ws_id="$(fabric::resolve_workspace_id "$FABRIC_WORKSPACE_NAME")"
  log_info "Workspace ID: ${ws_id}"

  log_info "Exporting item definitions (mode: ${mode})"
  local result
  result="$(fabric::bulk_export "$ws_id" "$mode" "$items_json")"

  local part_count
  part_count="$(jq '.definitionParts | length' <<<"$result")"
  [[ "$part_count" == "0" || "$part_count" == "null" ]] && die "Export returned no definition parts"
  log_info "Received ${part_count} definition parts"

  mkdir -p "$output_dir"

  # Track exported relative paths so --prune can remove stale files.
  local manifest
  manifest="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '$manifest'" EXIT

  # Write each definition part by decoding its base64 payload.
  local count=0
  while IFS= read -r part_b64; do
    local part path payload rel target_dir
    part="$(base64 -d <<<"$part_b64" 2>/dev/null || base64 -D <<<"$part_b64")"
    path="$(jq -r '.path' <<<"$part")"
    payload="$(jq -r '.payload' <<<"$part")"
    # Normalize the leading slash from the API path into a relative path.
    rel="${path#/}"
    echo "$rel" >>"$manifest"
    target_dir="${output_dir}/$(dirname "$rel")"
    mkdir -p "$target_dir"
    base64 -d <<<"$payload" >"${output_dir}/${rel}" 2>/dev/null || base64 -D <<<"$payload" >"${output_dir}/${rel}"
    log_debug "Wrote ${rel}"
    count=$((count + 1))
  done < <(jq -r '.definitionParts[] | @base64' <<<"$result")

  log_info "Wrote ${count} files to ${output_dir}"

  if [[ "$prune" == "true" ]]; then
    log_info "Pruning files not present in the export"
    local existing
    while IFS= read -r existing; do
      local rel="${existing#"${output_dir}/"}"
      if ! grep -Fxq "$rel" "$manifest"; then
        log_warn "Removing stale file: ${rel}"
        rm -f "$existing"
      fi
    done < <(find "$output_dir" -type f)
    # Remove now-empty directories.
    find "$output_dir" -type d -empty -delete 2>/dev/null || true
  fi

  log_info "Export complete"
}

main "$@"
