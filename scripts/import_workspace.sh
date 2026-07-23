#!/usr/bin/env bash
# Import Fabric item definitions from a local folder into a workspace using the
# Bulk Import Item Definitions API.
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
Import Fabric item definitions from a local folder into a workspace.

Usage:
  import_workspace.sh --env <name> [options]

Options:
  --env <name>              Environment to load from config/<name>.env (required).
  --source <dir>            Folder holding item definitions (default: fabric).
  --allow-pairing-by-name   Pair items by display name and type when no logical
                            ID exists in the source (default: off).
  --dry-run                 Build and validate the payload without calling Fabric.
  -h, --help                Show this help.

Configuration variables (from config/<name>.env or the environment):
  FABRIC_TENANT_ID, FABRIC_CLIENT_ID, FABRIC_CLIENT_SECRET, FABRIC_WORKSPACE_NAME
EOF
}

# Build the bulk import request body from every file under the source folder.
# Args: <source_dir> <allow_pairing_by_name:true|false>
# Echoes the request JSON.
build_request_body() {
  local source_dir="$1" allow_pairing="$2"
  local parts_file file rel
  parts_file="$(mktemp)"
  printf '[]' > "$parts_file"

  while IFS= read -r -d '' file; do
    rel="/${file#"${source_dir}/"}"
    local payload_file
    payload_file="$(mktemp)"
    base64 < "$file" | tr -d '\n' > "$payload_file"
    jq -c \
      --arg path "$rel" \
      --rawfile payload "$payload_file" \
      '. + [{path: $path, payload: $payload, payloadType: "InlineBase64"}]' \
      "$parts_file" > "${parts_file}.tmp" && mv "${parts_file}.tmp" "$parts_file"
    rm -f "$payload_file"
  done < <(find "$source_dir" -type f -print0 | sort -z)

  jq -nc \
    --argjson pairing "$allow_pairing" \
    --slurpfile parts "$parts_file" \
    '{definitionParts: $parts[0], options: {allowPairingByName: $pairing}}'
  rm -f "$parts_file"
}

main() {
  local env_name="" source_dir="" allow_pairing="false" dry_run="false"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --env) env_name="${2:-}"; shift 2 ;;
      --source) source_dir="${2:-}"; shift 2 ;;
      --allow-pairing-by-name) allow_pairing="true"; shift ;;
      --dry-run) dry_run="true"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Unknown argument: $1" ;;
    esac
  done

  [[ -z "$env_name" ]] && { usage; die "Missing required --env"; }

  source_dir="${source_dir:-${FABRIC_REPO_ROOT}/fabric}"
  [[ -d "$source_dir" ]] || die "Source folder not found: ${source_dir}"
  # Strip any trailing slash for consistent path math.
  source_dir="${source_dir%/}"

  local file_count
  file_count="$(find "$source_dir" -type f | wc -l | tr -d ' ')"
  [[ "$file_count" == "0" ]] && die "No files found under ${source_dir}"

  log_info "Building request body from ${file_count} files in ${source_dir}"
  local request_body
  request_body="$(build_request_body "$source_dir" "$allow_pairing")"

  # Validate the payload as well-formed JSON before going further.
  jq empty <<<"$request_body" || die "Constructed request body is not valid JSON"
  local part_count
  part_count="$(jq '.definitionParts | length' <<<"$request_body")"
  log_info "Request body contains ${part_count} definition parts (allowPairingByName: ${allow_pairing})"

  if [[ "$dry_run" == "true" ]]; then
    log_info "Dry run requested; skipping authentication and import"
    jq '{definitionParts: (.definitionParts | map({path})), options}' <<<"$request_body"
    return 0
  fi

  fabric::load_config "$env_name"

  log_info "Authenticating to tenant ${FABRIC_TENANT_ID}"
  FABRIC_TOKEN="$(fabric::get_token)"
  export FABRIC_TOKEN

  local ws_id
  if [[ -n "${FABRIC_WORKSPACE_ID:-}" ]]; then
    ws_id="$FABRIC_WORKSPACE_ID"
    log_info "Using workspace ID from config: ${ws_id}"
  else
    log_info "Resolving workspace '${FABRIC_WORKSPACE_NAME}'"
    ws_id="$(fabric::resolve_workspace_id "$FABRIC_WORKSPACE_NAME")"
  fi
  log_info "Workspace ID: ${ws_id}"

  log_info "Importing item definitions"
  local result
  result="$(fabric::bulk_import "$ws_id" "$request_body")"

  # Summarize per-item results.
  log_info "Import results:"
  jq -r '.importItemDefinitionsDetails[]
    | "  [\(.operationStatus)] \(.operationType) \(.itemType) \"\(.itemDisplayName)\" (\(.itemId))"' \
    <<<"$result" >&2

  local failed
  failed="$(jq '[.importItemDefinitionsDetails[] | select(.operationStatus == "Failed")] | length' <<<"$result")"
  if [[ "$failed" != "0" ]]; then
    die "${failed} item(s) failed to import"
  fi

  log_info "Import complete; all items succeeded"
}

main "$@"
