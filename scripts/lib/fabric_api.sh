#!/usr/bin/env bash
# Thin wrappers over the Fabric REST API: workspace resolution, long-running
# operation polling, and the bulk export/import endpoints.
# Source this file; do not execute it directly.

if [[ -n "${__FABRIC_API_SH_LOADED:-}" ]]; then
  return 0
fi
__FABRIC_API_SH_LOADED=1

__API_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/log.sh
source "${__API_DIR}/log.sh"

# Base URL for the Fabric REST API. Override only for sovereign clouds.
FABRIC_API_BASE_URL="${FABRIC_API_BASE_URL:-https://api.fabric.microsoft.com/v1}"

# Maximum number of LRO poll attempts before giving up.
FABRIC_LRO_MAX_ATTEMPTS="${FABRIC_LRO_MAX_ATTEMPTS:-120}"
# Default seconds to wait between polls when the service sends no Retry-After.
FABRIC_LRO_DEFAULT_DELAY="${FABRIC_LRO_DEFAULT_DELAY:-5}"

# Internal: perform an authenticated request. 
# Sets globals: __API_LAST_STATUS (HTTP code), __API_LAST_BODY (response body).
# Args: <method> <url> [data] [headers_out_file]
# Callers read __API_LAST_STATUS and __API_LAST_BODY after calling.
__API_LAST_STATUS=0
__API_LAST_BODY=""
__fabric_call() {
  local method="$1" url="$2" data="${3:-}" headers_out="${4:-/dev/null}"
  local response body_file=""
  if [[ -n "$data" ]]; then
    body_file="$(mktemp)"
    printf '%s' "$data" > "$body_file"
    response="$(curl -sS -w $'\n%{http_code}' -X "$method" "$url" \
      -H "Authorization: Bearer ${FABRIC_TOKEN}" \
      -H "Content-Type: application/json" \
      -D "$headers_out" \
      --data-binary "@${body_file}")" || { rm -f "$body_file"; die "Request to ${url} failed (network error)"; }
    rm -f "$body_file"
  else
    response="$(curl -sS -w $'\n%{http_code}' -X "$method" "$url" \
      -H "Authorization: Bearer ${FABRIC_TOKEN}" \
      -D "$headers_out")" || die "Request to ${url} failed (network error)"
  fi
  __API_LAST_STATUS="$(printf '%s\n' "$response" | tail -n1 | tr -d '\r')"
  __API_LAST_BODY="$(printf '%s\n' "$response" | sed '$d')"
}

# Read a header value (case-insensitive) from a curl headers dump file.
__fabric_header() {
  local file="$1" name="$2"
  grep -i "^${name}:" "$file" | tail -n1 | cut -d':' -f2- | tr -d '\r' | sed 's/^ *//'
}

# Find a workspace ID by display name, following continuation tokens.
# Args: <workspace_display_name>
# Echoes the workspace ID, or an empty string when not found.
fabric::find_workspace_id() {
  local name="$1"
  local url="${FABRIC_API_BASE_URL}/workspaces"
  local token="" id=""

  while :; do
    local request_url="$url"
    if [[ -n "$token" ]]; then
      request_url="${url}?continuationToken=$(jq -rn --arg t "$token" '$t | @uri')"
    fi
    local body
    __fabric_call GET "$request_url"; body="$__API_LAST_BODY"
    if [[ "$__API_LAST_STATUS" -ge 400 ]]; then
      log_debug "List workspaces returned HTTP ${__API_LAST_STATUS}; treating as not found"
      break
    fi
    log_debug "List workspaces returned $(jq '(.value // []) | length' <<<"$body") items (HTTP ${__API_LAST_STATUS})"
    id="$(jq -r --arg n "$name" '(.value // [])[] | select(.displayName == $n) | .id' <<<"$body" | head -n1)"
    if [[ -n "$id" ]]; then
      break
    fi
    token="$(jq -r '.continuationToken // empty' <<<"$body")"
    [[ -z "$token" ]] && break
  done

  printf '%s' "$id"
}

# Resolve a workspace ID by display name; exits if the workspace is not found.
# Args: <workspace_display_name>
# Echoes the workspace ID.
fabric::resolve_workspace_id() {
  local name="$1" id
  id="$(fabric::find_workspace_id "$name")"
  [[ -z "$id" ]] && die "Workspace '${name}' not found or not accessible to the caller"
  printf '%s' "$id"
}

# Create a workspace and optionally assign it to a capacity.
# Args: <display_name> [capacity_id]
# Echoes the new workspace ID.
fabric::create_workspace() {
  local name="$1" capacity_id="${2:-}"
  local url="${FABRIC_API_BASE_URL}/workspaces"
  local request_body
  if [[ -n "$capacity_id" ]]; then
    request_body="$(jq -nc --arg n "$name" --arg c "$capacity_id" '{displayName: $n, capacityId: $c}')"
  else
    request_body="$(jq -nc --arg n "$name" '{displayName: $n}')"
  fi

  local body
  __fabric_call POST "$url" "$request_body"; body="$__API_LAST_BODY"
  if [[ "$__API_LAST_STATUS" -ge 400 ]]; then
    die "Failed to create workspace '${name}' (HTTP ${__API_LAST_STATUS}): $(jq -r '.message // .errorCode // .' <<<"$body" 2>/dev/null)"
  fi

  local ws_id
  ws_id="$(jq -r '.id // empty' <<<"$body")"
  [[ -z "$ws_id" ]] && die "Create workspace returned no workspace ID (HTTP ${__API_LAST_STATUS}). Response: $(echo "$body" | head -c 200)"
  printf '%s' "$ws_id"
}

# Add a role assignment to a workspace.
# Args: <workspace_id> <email_or_id> <role:Admin|Member|Contributor|Viewer> [principal_type:User|Group|ServicePrincipal]
fabric::add_workspace_role() {
  local ws_id="$1" principal="$2" role="$3" principal_type="${4:-User}"
  local url="${FABRIC_API_BASE_URL}/workspaces/${ws_id}/roleAssignments"
  local request_body
  request_body="$(jq -nc --arg p "$principal" --arg r "$role" --arg t "$principal_type" \
    '{principal: {id: $p, type: $t}, role: $r}')"

  local body
  __fabric_call POST "$url" "$request_body"; body="$__API_LAST_BODY"
  if [[ "$__API_LAST_STATUS" -ge 400 ]]; then
    die "Failed to add role '${role}' for '${principal}' (HTTP ${__API_LAST_STATUS}): $(jq -r '.message // .errorCode // .' <<<"$body" 2>/dev/null)"
  fi
}

# Poll a long-running operation to completion and return its result body.
# Args: <operation_id>
# Echoes the result JSON from /operations/{id}/result on success.
fabric::poll_operation() {
  local op_id="$1"
  local status_url="${FABRIC_API_BASE_URL}/operations/${op_id}"
  local result_url="${FABRIC_API_BASE_URL}/operations/${op_id}/result"
  local attempt=0

  while (( attempt < FABRIC_LRO_MAX_ATTEMPTS )); do
    local body status
    __fabric_call GET "$status_url"; body="$__API_LAST_BODY"
    if [[ "$__API_LAST_STATUS" -ge 400 ]]; then
      die "Failed to poll operation ${op_id} (HTTP ${__API_LAST_STATUS})"
    fi
    status="$(jq -r '.status // empty' <<<"$body")"
    log_debug "Operation ${op_id} status: ${status:-unknown} (attempt $((attempt + 1)))"

    case "$status" in
      Succeeded)
        local result
        __fabric_call GET "$result_url"; result="$__API_LAST_BODY"
        if [[ "$__API_LAST_STATUS" -ge 400 ]]; then
          die "Operation ${op_id} succeeded but result fetch failed (HTTP ${__API_LAST_STATUS})"
        fi
        printf '%s' "$result"
        return 0
        ;;
      Failed)
        local err details
        err="$(jq -r '.error.message // "no error detail"' <<<"$body")"
        details="$(jq -r '(.error.moreDetails // [])[] | "  [\(.relatedResource.resourceType // "unknown"):\(.relatedResource.resourceId // "?")] \(.errorCode // ""): \(.message // "" | .[0:300])"' <<<"$body" 2>/dev/null)"
        log_error "Operation ${op_id} failed: ${err}"
        if [[ -n "$details" ]]; then
          log_error "Details:"
          printf '%s\n' "$details" >&2
        fi
        exit 1
        ;;
      *)
        sleep "$FABRIC_LRO_DEFAULT_DELAY"
        ;;
    esac
    attempt=$((attempt + 1))
  done

  die "Operation ${op_id} did not complete within ${FABRIC_LRO_MAX_ATTEMPTS} attempts"
}

# Internal: POST a bulk request and resolve it (sync 200 or async 202).
# Args: <url> <request_body> <sync_result_key>
# Echoes the final result JSON.
__fabric_bulk_call() {
  local url="$1" request_body="$2" sync_key="$3"
  local headers_file body
  headers_file="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '$headers_file'" RETURN

  __fabric_call POST "$url" "$request_body" "$headers_file"; body="$__API_LAST_BODY"

  case "$__API_LAST_STATUS" in
    200)
      log_debug "Bulk operation completed synchronously"
      printf '%s' "$body"
      ;;
    202)
      local op_id
      op_id="$(__fabric_header "$headers_file" "x-ms-operation-id")"
      [[ -z "$op_id" ]] && die "Accepted (202) but no x-ms-operation-id header returned"
      log_info "Operation accepted; polling ${op_id}"
      fabric::poll_operation "$op_id"
      ;;
    *)
      die "Bulk operation failed (HTTP ${__API_LAST_STATUS}): $(jq -r '.message // .errorCode // .' <<<"$body" 2>/dev/null)"
      ;;
  esac
  # Reference the key for callers/documentation; not used directly here.
  : "$sync_key"
}

# Bulk export item definitions from a workspace.
# Args: <workspace_id> <mode:All|Selective> [items_json_array]
# Echoes the export result JSON (itemDefinitionsIndex + definitionParts).
fabric::bulk_export() {
  local ws_id="$1" mode="$2" items_json="${3:-}"
  local url="${FABRIC_API_BASE_URL}/workspaces/${ws_id}/items/bulkExportDefinitions"
  local request_body
  if [[ "$mode" == "Selective" ]]; then
    [[ -z "$items_json" ]] && die "Selective export requires a list of item IDs"
    request_body="$(jq -nc --argjson items "$items_json" '{mode: "Selective", items: $items}')"
  else
    request_body="$(jq -nc '{mode: "All"}')"
  fi
  __fabric_bulk_call "$url" "$request_body" "definitionParts"
}

# Bulk import item definitions into a workspace.
# Args: <workspace_id> <request_body_json>
# Echoes the import result JSON (importItemDefinitionsDetails).
fabric::bulk_import() {
  local ws_id="$1" request_body="$2"
  local url="${FABRIC_API_BASE_URL}/workspaces/${ws_id}/items/bulkImportDefinitions"
  __fabric_bulk_call "$url" "$request_body" "importItemDefinitionsDetails"
}
