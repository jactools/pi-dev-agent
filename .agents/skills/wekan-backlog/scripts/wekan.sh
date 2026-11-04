#!/usr/bin/env bash
#
# WeKan Backlog Manager (WeKan CE v12.x REST API)
# Usage: wekan.sh <command> [options]
#
# Commands: create, update, archive, list, boards, lists, validate-config
#
# Security: Reads WEKAN_TOKEN (or WEKAN_USERNAME/WEKAN_PASSWORD) from the
# environment. Never echoes or writes credentials to disk.
# Whitelist: Only operates on boards/lists listed in the config file.
#
# API notes (verified against WeKan CE v12.75):
#   - Login:  POST {instance}/users/login -> flat {"id","token","tokenExpires"}
#   - Auth:   Authorization: Bearer <token> on all /api/* routes
#             (there is NO /api/v2 in v12.x and no X-User-Token header)
#   - Responses are flat objects/arrays (no {data:...} wrapper).
#   - Card create requires swimlaneId in the body.
#   - Labels live embedded on the board doc; colors are named ("sky", "red", ...),
#     not hex. Assign via POST /api/boards/:id/cards/labels.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Helpers (bash 3.2 compatible) ──────────────────────────────────

to_lower() {
  echo "$1" | tr '[:upper:]' '[:lower:]'
}

die() {
  echo "ERROR: $*" >&2
  exit 1
}

# Build a JSON object from key=value pairs (values are JSON-escaped strings)
json_obj() {
  # Usage: json_obj key value [key value ...]
  local args=("$@")
  if [[ ${#args[@]} -eq 0 ]]; then
    echo '{}'
    return 0
  fi
  jq -cn --args '($ARGS.positional) as $a | reduce range(0; ($a|length)/2) as $i ({}; .[$a[($i*2)]] = $a[($i*2+1)])' \
    "${args[@]}"
}

# ─── Config Discovery ────────────────────────────────────────────────

discover_config() {
  # Priority order:
  # 1. $WEKAN_CONFIG_PATH (explicit config file path or repo root)
  # 2. <repo-root>/.wekan-backlog-config.json
  # 3. ~/.config/wekan-backlog/config.json
  # 4. Skill directory template (fallback — warn if used as live config)

  local candidate=""

  if [[ -n "${WEKAN_CONFIG_PATH:-}" ]]; then
    if [[ -f "$WEKAN_CONFIG_PATH" ]]; then
      candidate="$WEKAN_CONFIG_PATH"
    elif [[ -f "${WEKAN_CONFIG_PATH}/.wekan-backlog-config.json" ]]; then
      candidate="${WEKAN_CONFIG_PATH}/.wekan-backlog-config.json"
    fi
  fi

  if [[ -z "$candidate" ]]; then
    local repo_root
    # git may not be installed (e.g., inside the pi-dev-agent container);
    # fall back to the current directory so running from a repo checkout works.
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
    if [[ -z "$repo_root" ]]; then
      repo_root="$PWD"
    fi
    if [[ -f "${repo_root}/.wekan-backlog-config.json" ]]; then
      candidate="${repo_root}/.wekan-backlog-config.json"
    fi
  fi

  if [[ -z "$candidate" && -f ~/.config/wekan-backlog/config.json ]]; then
    candidate=~/.config/wekan-backlog/config.json
  fi

  if [[ -z "$candidate" ]]; then
    echo "WARNING: No live config found. Using template at $SKILL_DIR/config.example.json — this is for reference only." >&2
    candidate="$SKILL_DIR/config.example.json"
  fi

  echo "$candidate"
}

CONFIG_FILE="$(discover_config)"

# ─── TLS CA resolution ──────────────────────────────────────────────
# The config may carry a "ca_cert" field (PEM bundle for a private CA, e.g.
# the Platform Dev Root CA behind *.dev.jac.dot in the kind dev cluster).
# Relative paths resolve against the directory of the config file. When set,
# every curl call below passes --cacert so TLS verification succeeds inside
# containers that don't have the CA in their system trust store.
CURL_CA_ARGS=()

resolve_ca_cert() {
  local ca_ref=""
  ca_ref="$(jq -r '.ca_cert // empty' "$CONFIG_FILE" 2>/dev/null || echo "")"
  [[ -n "$ca_ref" ]] || return 0

  if [[ "$ca_ref" != /* ]]; then
    ca_ref="$(dirname "$CONFIG_FILE")/$ca_ref"
  fi

  if [[ -f "$ca_ref" ]]; then
    CURL_CA_ARGS=(--cacert "$ca_ref")
  else
    echo "WARNING: Config 'ca_cert' file not found: $ca_ref — TLS verification against the private CA will fail." >&2
  fi
}
resolve_ca_cert

# ─── Env-file credential loading ─────────────────────────────────────
# Source env.dev.local / .env.dev.local for WEKAN_TOKEN, WEKAN_USERNAME and
# WEKAN_PASSWORD. Only sets vars that aren't already defined in the environment.

load_env_credentials() {
  local repo_root=""

  # Try git first
  repo_root="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"

  # Fallback: use CWD (assumes we're running from the repo root)
  if [[ -z "$repo_root" ]]; then
    repo_root="$PWD"
  fi

  local env_file candidates=("${repo_root}/env.dev.local" "${repo_root}/.env.dev.local")

  for env_file in "${candidates[@]}"; do
    [[ -f "$env_file" ]] || continue
    while IFS='=' read -r key value; do
      # Skip comments, empty lines, and non-matching keys
      [[ "$key" =~ ^[[:space:]]*# ]] && continue
      [[ -z "$key" ]] && continue
      key="$(echo "$key" | tr -d ' ')"
      case "$key" in
        WEKAN_TOKEN)
          [[ -z "${WEKAN_TOKEN:-}" ]] && export "WEKAN_TOKEN=$value"
          ;;
        WEKAN_USERNAME|WEKAN_ADMIN_USERNAME)
          [[ -z "${WEKAN_USERNAME:-}" ]] && export "WEKAN_USERNAME=$value"
          ;;
        WEKAN_PASSWORD|WEKAN_ADMIN_PASSWORD)
          [[ -z "${WEKAN_PASSWORD:-}" ]] && export "WEKAN_PASSWORD=$value"
          ;;
      esac
    done < "$env_file"
  done
}

# Load credentials from env.dev.local (if not already set in the environment)
load_env_credentials

# ─── Credentials (deferred) ─────────────────────────────────────────

INSTANCE_URL=""
WEKAN_TOKEN_VALUE=""

require_credentials() {
  if [[ -n "${WEKAN_TOKEN_VALUE:-}" ]]; then
    return 0
  fi

  local instance
  instance="$(jq -r '.instance // empty' "$CONFIG_FILE")"
  [[ -n "$instance" && "$instance" != "null" ]] || die "Config missing 'instance'. Set the WeKan instance URL in $CONFIG_FILE"
  # Strip trailing slash
  INSTANCE_URL="${instance%/}"

  if [[ -n "${WEKAN_TOKEN:-}" ]]; then
    WEKAN_TOKEN_VALUE="$WEKAN_TOKEN"
    return 0
  fi

  if [[ -n "${WEKAN_USERNAME:-}" && -n "${WEKAN_PASSWORD:-}" ]]; then
    # Log in to obtain a token for this invocation only. Never echo credentials.
    local login_response
    login_response="$(curl -sS --max-time 30 ${CURL_CA_ARGS[@]+"${CURL_CA_ARGS[@]}"} -X POST "$INSTANCE_URL/users/login" \
      -H "Content-Type: application/json" \
      -d "$(json_obj username "$WEKAN_USERNAME" password "$WEKAN_PASSWORD")" 2>&1)" || {
      die "Login request failed (network error?). Check the instance URL in config."
    }

    WEKAN_TOKEN_VALUE="$(echo "$login_response" | jq -r '.token // empty' 2>/dev/null || echo "")"
    if [[ -z "$WEKAN_TOKEN_VALUE" ]]; then
      die "Login failed. Check WEKAN_USERNAME/WEKAN_PASSWORD or set WEKAN_TOKEN instead."
    fi
    return 0
  fi

  die "No WeKan credentials found. Set WEKAN_TOKEN, or both WEKAN_USERNAME and WEKAN_PASSWORD."
}

# ─── API Helper ──────────────────────────────────────────────────────

# api <METHOD> <path> [json-body]
# Path is relative to the instance root, e.g. "/api/boards/<id>/lists".
api() {
  require_credentials
  local method="$1" path="$2" body="${3:-}"
  local http_code tmp_body tmp_resp

  if [[ -n "$body" ]]; then
    tmp_body="$(mktemp)"
    printf '%s' "$body" > "$tmp_body"
    tmp_resp="$(curl -sS --max-time 60 ${CURL_CA_ARGS[@]+"${CURL_CA_ARGS[@]}"} -w '\n%{http_code}' -X "$method" \
      "$INSTANCE_URL$path" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer $WEKAN_TOKEN_VALUE" \
      --data-binary "@$tmp_body")"
    rm -f "$tmp_body"
  else
    tmp_resp="$(curl -sS --max-time 60 ${CURL_CA_ARGS[@]+"${CURL_CA_ARGS[@]}"} -w '\n%{http_code}' -X "$method" \
      "$INSTANCE_URL$path" \
      -H "Content-Type: application/json" \
      -H "Authorization: Bearer $WEKAN_TOKEN_VALUE")"
  fi

  http_code="${tmp_resp##*$'\n'}"
  local payload="${tmp_resp%$'\n'*}"

  case "$http_code" in
    2*) echo "$payload" ;;
    401) die "Authentication failed (HTTP 401). Refresh WEKAN_TOKEN or check username/password env vars." ;;
    403) die "Permission denied (HTTP 403). Your WeKan user lacks access to this board/list (label changes require board admin)." ;;
    404) echo "$payload" ; return 404 ;;
    *) die "WeKan API error (HTTP $http_code): $(echo "$payload" | head -c 500)" ;;
  esac
}

# ─── Config Validation Helpers ──────────────────────────────────────

# Validate that a board is whitelisted. Prints the board JSON on success.
validate_board() {
  local query="$1"  # board_id or (partial, case-insensitive) board_name

  [[ -s "$CONFIG_FILE" ]] || die "Config file is empty: $CONFIG_FILE"

  local result=""

  # WeKan ids are base64url-style (17 chars, may contain '-' and '_')
  if [[ "$query" =~ ^[0-9a-zA-Z_-]{17}$ ]]; then
    result="$(jq -c --arg bid "$query" '.boards[] | select(.board_id == $bid)' "$CONFIG_FILE")"
  else
    local query_lower
    query_lower="$(to_lower "$query")"
    result="$(jq -c --arg name "$query_lower" \
      '[.boards[] | select((.board_name // "") | ascii_downcase | contains($name))] | first // empty' \
      "$CONFIG_FILE")"

    # If multiple boards match, require a more specific query or the board_id
    local match_count
    match_count="$(jq --arg name "$query_lower" \
      '[.boards[] | select((.board_name // "") | ascii_downcase | contains($name))] | length' \
      "$CONFIG_FILE")"
    if [[ "$match_count" -gt 1 ]]; then
      echo "ERROR: Board query '$query' matches multiple boards:" >&2
      jq -r --arg name "$query_lower" \
        '.boards[] | select((.board_name // "") | ascii_downcase | contains($name)) | "  - ID: \(.board_id) | Name: \(.board_name)"' \
        "$CONFIG_FILE" >&2
      echo "Use the board_id for an unambiguous match." >&2
      exit 1
    fi
  fi

  if [[ -z "$result" ]]; then
    echo "ERROR: Board '$query' not found in config." >&2
    echo "" >&2
    echo "Available boards:" >&2
    jq -r '.boards[] | "  - ID: \(.board_id) | Name: \(.board_name // "(unnamed)")"' "$CONFIG_FILE" >&2
    exit 1
  fi

  echo "$result"
}

# Fetch the live board document (flat object). Dies if not found.
fetch_board() {
  local board_id="$1" response
  response="$(api GET "/api/boards/$board_id")" || die "Board '$board_id' not found on the instance."
  echo "$response" | jq -e '._id // .title' >/dev/null 2>&1 \
    || die "Board '$board_id' not found on the instance (deleted?)."
  echo "$response"
}

# Get-or-create a board label. Prints the label _id.
# v12.x: labels are embedded in the board doc; PUT /api/boards/:id/labels
# returns the existing id for (name,color) or creates and returns a new one.
ensure_label() {
  local board_id="$1" name="$2" color="${3:-sky}" response
  response="$(api PUT "/api/boards/$board_id/labels" \
    "$(jq -cn --arg n "$name" --arg c "$color" '{label: {name: $n, color: $c}}')")" || {
      die "Could not create label '$name' on the board (requires board admin)."
    }
  # Response is a bare id string (or an object in other versions)
  echo "$response" | jq -r 'if type == "string" then . else (._id // empty) end'
}

# ─── Card Resolution ────────────────────────────────────────────────

# Fetch the full card document by id via GET /api/cards/:cardId.
# Works for archived cards too (per-list endpoints hide them). Verifies the
# card belongs to the whitelisted board before returning it.
resolve_card_by_id() {
  local board_json="$1" card_id="$2"
  local board_id card rc=0

  board_id="$(echo "$board_json" | jq -r '.board_id')"
  card="$(api GET "/api/cards/$card_id")" || { rc=$?; [[ $rc -eq 404 ]] && die "Card '$card_id' not found on this instance." || die "Card lookup failed (HTTP $rc)."; }

  if ! echo "$card" | jq -e '._id' >/dev/null 2>&1; then
    die "Card '$card_id' not found."
  fi
  # Whitelist enforcement: the global endpoint works across boards, so make
  # sure this card actually lives on the configured board.
  local card_board
  card_board="$(echo "$card" | jq -r '.boardId // empty')"
  if [[ "$card_board" != "$board_id" ]]; then
    die "Card '$card_id' belongs to a different board (${card_board:-unknown}) and is not whitelisted."
  fi
  echo "$card"
}

# ─── Swimlanes ──────────────────────────────────────────────

# Boards can be split into multiple swimlanes; each lane has its own copy of
# the columns, and card creation REQUIRES a swimlaneId. Lanes are addressed by
# name or 17-char id.
#
# resolve_swimlane <board_id> [ref]
#   With ref: resolves it to a lane _id (dies listing available lanes if absent).
#   Without ref: returns the only lane when there is exactly one; dies with an
#   actionable error when the board has multiple lanes (never guesses).
resolve_swimlane() {
  local board_id="$1" ref="${2:-}" swimlanes count match

  swimlanes="$(api GET "/api/boards/$board_id/swimlanes")" || die "Could not fetch swimlanes for board '$board_id'."

  if [[ -z "$ref" ]]; then
    count="$(echo "$swimlanes" | jq 'length')"
    if [[ "$count" -eq 0 ]]; then
      die "Board has no swimlanes; cannot create a card."
    elif [[ "$count" -gt 1 ]]; then
      echo "ERROR: Board '$board_id' has multiple swimlanes. Specify one with --swimlane <name|id>:" >&2
      echo "$swimlanes" | jq -r '.[] | "  - \(.title) (id: \(._id))"' >&2
      exit 1
    fi
    echo "$swimlanes" | jq -r '[.[]] | first | ._id'
    return 0
  fi

  if [[ "$ref" =~ ^[0-9a-zA-Z_-]{17}$ ]]; then
    match="$(echo "$swimlanes" | jq -c --arg id "$ref" '[.[] | select(._id == $id)] | first // empty')"
  else
    match="$(echo "$swimlanes" | jq -c --arg t "$ref" '[.[] | select(.title == $t)] | first // empty')"
  fi

  if [[ -z "$match" ]]; then
    echo "ERROR: Swimlane '$ref' not found on this board. Available swimlanes:" >&2
    echo "$swimlanes" | jq -r '.[] | "  - \(.title) (id: \(._id))"' >&2
    exit 1
  fi

  echo "$match" | jq -r '._id'
}

# ─── Per-lane column mapping (multi-swimlane boards) ──────────────
# Multi-swimlane boards keep their OWN copy of every column per lane, but the
# REST API does not expose which list belongs to which lane (list docs carry
# only _id/title/modifiedAt/cardsModifiedAt). The mapping is reconstructed:
#   1. GET /api/boards/:id/lists returns lists in consecutive runs — one run
#      per lane, each containing every column title exactly once;
#   2. every card carries a swimlaneId, so any non-empty list anchors its
#      whole run to that lane.
# A lane with zero cards anywhere cannot be anchored (its empty copies are
# indistinguishable); such lanes still display correctly (all columns show 0)
# and create falls back to elimination when unambiguous (see resolve_lane_list).

# fetch_all_list_cards <board_id>
#   Prints JSON: [{listId, title, cards:[...]}, ...] for every non-archived
#   list on the board (all lanes), in API order.
fetch_all_list_cards() {
  local board_id="$1" lists_response out="[]" list_id title cards
  lists_response="$(api GET "/api/boards/$board_id/lists")" || die "Could not fetch lists for board '$board_id'."
  while IFS=$'\t' read -r list_id title; do
    [[ -z "$list_id" ]] && continue
    cards="$(api GET "/api/boards/$board_id/lists/$list_id/cards")" || cards="[]"
    out="$(jq -c --arg id "$list_id" --arg t "$title" --argjson c "$cards" \
      '. + [{listId: $id, title: $t, cards: $c}]' <<<"$out")"
  done < <(echo "$lists_response" | jq -r '.[] | select((.archived // false) | not) | [._id, .title] | @tsv')
  echo "$out"
}

# build_lane_map <board_id>
#   Prints JSON: {"lanes":[{_id,title},...], "segments":[{"lane":<id|null>,
#   "anchored":bool, "columns":[{listId,title,cards:[...]}]}, ...]}
build_lane_map() {
  local board_id="$1" lwc lanes
  lwc="$(fetch_all_list_cards "$board_id")"
  lanes="$(api GET "/api/boards/$board_id/swimlanes")" || die "Could not fetch swimlanes for board '$board_id'."
  jq -c --argjson lanes "$lanes" '
    def segments:
      reduce .[] as $l ({cur: [], segs: []};
        if (.cur | length > 0) and ((.cur | map(.title)) | index($l.title)) then
          {cur: [$l], segs: (.segs + [.cur])}
        else
          {cur: (.cur + [$l]), segs: .segs}
        end)
      | .segs + (if (.cur | length) > 0 then [.cur] else [] end);

    { lanes: $lanes,
      segments: [ segments[]
                  | { lane: ([ .[].cards[].swimlaneId // empty ] | first // null),
                      anchored: (([ .[].cards[].swimlaneId // empty ] | length) > 0),
                      columns: [ .[] | {listId, title, cards} ] } ] }
  ' <<<"$lwc"
}

# require_allowed_list <board_json> <list_name>
#   Whitelist check (config scope); dies listing allowed lists on violation.
require_allowed_list() {
  local board_json="$1" list_name="$2"
  if ! echo "$board_json" | jq -r '.lists[]' | grep -qx -- "$list_name"; then
    echo "ERROR: List '$list_name' is not allowed for this board." >&2
    echo "" >&2
    echo "Allowed lists:" >&2
    echo "$board_json" | jq -r '.lists[]' | sed 's/^/  - /' >&2
    exit 1
  fi
}

# resolve_lane_list <board_json> <board_id> <list_name> <lane_id>
#   Resolves the copy of column <list_name> that belongs to lane <lane_id>.
#   Dies with an actionable error when the mapping is ambiguous (every copy of
#   the column is empty and multiple lanes are unanchored).
resolve_lane_list() {
  local board_json="$1" board_id="$2" list_name="$3" lane_id="$4"
  require_allowed_list "$board_json" "$list_name"

  local map direct
  map="$(build_lane_map "$board_id")"
  direct="$(echo "$map" | jq -r --arg sid "$lane_id" --arg t "$list_name" \
    '[.segments[] | select(.anchored and .lane == $sid) | .columns[] | select(.title == $t) | .listId] | first // empty')"
  if [[ -n "$direct" ]]; then
    echo "$direct"
    return 0
  fi

  # Fallback by elimination: exactly one unanchored segment AND exactly one
  # lane with no cards anywhere -> they must be each other's.
  local unanchored_count zero_lanes_count elim_id
  unanchored_count="$(echo "$map" | jq '[.segments[] | select(.anchored | not)] | length')"
  zero_lanes_count="$(echo "$map" | jq '([ .segments[].columns[].cards[].swimlaneId // empty ] | unique) as $seen | [ .lanes[] | ._id as $lid | select(($seen | index($lid)) == null) ] | length')"
  if [[ "$unanchored_count" -eq 1 && "$zero_lanes_count" -eq 1 ]]; then
    elim_id="$(echo "$map" | jq -r --arg t "$list_name" \
      '[.segments[] | select(.anchored | not) | .columns[] | select(.title == $t) | .listId] | first // empty')"
    if [[ -n "$elim_id" ]]; then
      echo "WARNING: Lane has no cards yet; resolved its '$list_name' column by elimination (only unanchored lane)." >&2
      echo "$elim_id"
      return 0
    fi
  fi

  die "Cannot determine which '$list_name' list belongs to swimlane '$lane_id': every copy of that column is empty and the API does not expose the list->swimlane mapping. Create the lane's first card via the WeKan UI, or target a column that already has cards on this board."
}

# Resolve a card reference (17-char id, URL, or title) on the board.
# Prints the full card JSON (includes listId + swimlaneId). Exits with error if not found or ambiguous.
resolve_card() {
  local board_json="$1"
  local ref="$2"

  local board_id
  board_id="$(echo "$board_json" | jq -r '.board_id')"

  # Case 1: raw card ID (base64url-style: may contain '-' and '_') — global
  # endpoint, verified against the whitelist
  if [[ "$ref" =~ ^[0-9a-zA-Z_-]{17}$ ]]; then
    resolve_card_by_id "$board_json" "$ref"
    return $?
  fi

  # Case 2: URL — extract last path segment as id
  if [[ "$ref" == http* ]]; then
    local id="${ref##*/}"
    id="${id%%\?*}"
    if [[ "$id" =~ ^[0-9a-zA-Z_-]{17}$ ]]; then
      resolve_card "$board_json" "$id"
      return $?
    fi
    ref="$id"  # fall through to title search
  fi

  # Case 3: title match across ALL lists — every lane's copy of each column.
  # (Matching only the first list per title would miss cards in other lanes.)
  local map matches
  map="$(build_lane_map "$board_id")" || map='{"lanes":[],"segments":[]}'
  matches="$(echo "$map" | jq -c --arg ref "$ref" \
    '[.segments[].columns[].cards[] | select((.title // "") | ascii_downcase | contains($ref | ascii_downcase))]')"

  if [[ "$(echo "$matches" | jq 'length')" -eq 0 ]]; then
    die "No card matching '$ref' found on this board's allowed lists."
  fi

  # Normalize: unique cards by id
  local unique
  unique="$(echo "$matches" | jq -c 'unique_by(._id)')"

  local count cid
  count="$(echo "$unique" | jq 'length')"

  if [[ "$count" -eq 0 ]]; then
    die "No card matching '$ref' found on this board's allowed lists."
  elif [[ "$count" -gt 1 ]]; then
    echo "ERROR: Card reference '$ref' is ambiguous. Matches:" >&2
    echo "$unique" | jq -r '.[] | "  - ID: \(._id) | Title: \(.title)"' >&2
    echo "Use the card ID for an unambiguous match." >&2
    exit 1
  fi

  # Re-fetch the full document (per-list arrays omit listId)
  cid="$(echo "$unique" | jq -r '.[0]._id')"
  resolve_card_by_id "$board_json" "$cid"
}

# ─── Commands ────────────────────────────────────────────────────────

cmd_create() {
  local board_query="" title="" list_name="" description="" label="" swimlane_ref="" dry_run=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --board|-b) board_query="$2"; shift 2 ;;
      --title|-t) title="$2"; shift 2 ;;
      --list|-l) list_name="$2"; shift 2 ;;
      --description|-d) description="$2"; shift 2 ;;
      --label) label="$2"; shift 2 ;;
      --swimlane|-s) swimlane_ref="$2"; shift 2 ;;
      --dry-run|-n) dry_run=true; shift ;;
      *) die "Unknown option '$1'" ;;
    esac
  done

  [[ -n "$board_query" && -n "$title" ]] || {
    echo "Usage: wekan.sh create --board <name|id> --title <title> [--list <list>] [--swimlane <name|id>] [--description <text>] [--label <name>] [--dry-run]" >&2
    exit 1
  }

  local board_json
  board_json="$(validate_board "$board_query")"
  require_credentials

  # Default list from config if not specified
  if [[ -z "$list_name" ]]; then
    list_name="$(echo "$board_json" | jq -r '.default_list // empty')"
  fi
  [[ -n "$list_name" ]] || die "No --list given and no default_list in config for this board."

  local list_id board_id swimlane_id
  board_id="$(echo "$board_json" | jq -r '.board_id')"

  # Card create REQUIRES swimlaneId. Boards may have multiple lanes (e.g., one
  # per repo); --swimlane selects by name or id, otherwise a single-lane board
  # uses its only lane and multi-lane boards refuse to guess.
  swimlane_id="$(resolve_swimlane "$board_id" "$swimlane_ref")"

  # Multi-lane boards keep one copy of each column per lane; resolve the copy
  # that belongs to the requested lane (never "first list with this title").
  list_id="$(resolve_lane_list "$board_json" "$board_id" "$list_name" "$swimlane_id")"
  local swimlane_title
  swimlane_title="$(api GET "/api/boards/$board_id/swimlanes" | jq -r --arg id "$swimlane_id" '[.[] | select(._id == $id)] | first | .title // "?"')"

  if $dry_run; then
    echo "[DRY RUN] Would create card on board '$(echo "$board_json" | jq -r '.board_name // "unknown"')':"
    echo "  Title:       $title"
    echo "  List:        $list_name (id: $list_id)"
    echo "  Swimlane:    $swimlane_title (id: $swimlane_id)"
    [[ -n "$description" ]] && echo "  Description: $(echo "$description" | head -1)..."
    [[ -n "$label" ]] && echo "  Label:       $label"
    return 0
  fi

  # Build card body (only include non-empty fields)
  local body
  body="$(jq -cn --arg title "$title" --arg swimlaneId "$swimlane_id" \
    --arg desc "${description:-}" \
    '{title: $title, swimlaneId: $swimlaneId} + (if $desc != "" then {description: $desc} else {} end)')"

  local response card_id instance
  response="$(api POST "/api/boards/$board_id/lists/$list_id/cards" "$body")" || die "Failed to create card."
  card_id="$(echo "$response" | jq -r '._id // empty')"
  [[ -n "$card_id" ]] || die "Card created but could not parse its ID. Response: $(echo "$response" | head -c 300)"

  # Labels are assigned after creation (v12.x card create does not take labels)
  if [[ -n "$label" ]]; then
    local label_id
    label_id="$(ensure_label "$board_id" "$label")"
    [[ -n "$label_id" ]] || die "Could not resolve label '$label'."
    api POST "/api/boards/$board_id/cards/labels" \
      "$(jq -cn --arg cid "$card_id" --arg lid "$label_id" '{cardIds: [$cid], addLabelIds: [$lid]}')" >/dev/null \
      || die "Card created but failed to attach label '$label'."
  fi

  instance="$(jq -r '.instance' "$CONFIG_FILE")"
  echo "Created card '$title':"
  echo "  ID:   $card_id"
  echo "  URL:  ${instance%/}/boards/$board_id/$card_id"
}

cmd_update() {
  local board_query="" card_ref="" title="" description="" list_name="" add_label="" remove_label="" swimlane_ref="" dry_run=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --board|-b) board_query="$2"; shift 2 ;;
      --card|-c) card_ref="$2"; shift 2 ;;
      --title|-t) title="$2"; shift 2 ;;
      --description|-d) description="$2"; shift 2 ;;
      --list|-l) list_name="$2"; shift 2 ;;
      --add-label) add_label="$2"; shift 2 ;;
      --remove-label) remove_label="$2"; shift 2 ;;
      --swimlane|-s) swimlane_ref="$2"; shift 2 ;;
      --dry-run|-n) dry_run=true; shift ;;
      *) die "Unknown option '$1'" ;;
    esac
  done

  [[ -n "$board_query" && -n "$card_ref" ]] || {
    echo "Usage: wekan.sh update --board <name|id> --card <id|url|title> [--title <t>] [--description <d>] [--list <l>] [--swimlane <name|id>] [--add-label <x>] [--remove-label <y>] [--dry-run]" >&2
    exit 1
  }

  local board_json card card_id board_id current_list_id current_lane
  board_json="$(validate_board "$board_query")"
  require_credentials
  card="$(resolve_card "$board_json" "$card_ref")"
  card_id="$(echo "$card" | jq -r '._id')"
  board_id="$(echo "$board_json" | jq -r '.board_id')"
  current_list_id="$(echo "$card" | jq -r '.listId // empty')"
  current_lane="$(echo "$card" | jq -r '.swimlaneId // empty')"

  if $dry_run; then
    echo "[DRY RUN] Would update card #$card_id ('$(echo "$card" | jq -r .title)'):"
    [[ -n "$title" ]] && echo "  Title:       -> $title"
    [[ -n "$description" ]] && echo "  Description: -> $(echo "$description" | head -1)..."
    [[ -n "$list_name" ]] && echo "  Move to list: $list_name"
    [[ -n "$add_label" ]] && echo "  Add label:   $add_label"
    [[ -n "$remove_label" ]] && echo "  Remove label: $remove_label"
    return 0
  fi

  # Field updates (title/description/move) via PUT on the card's current list path.
  # Move = include new listId + a high rank so the card lands at the end.
  local body="{}"
  if [[ -n "$list_name" ]]; then
    local target_lane target_list_id
    # Default to the card's own lane (same-lane status change); --swimlane
    # moves it cross-lane. Multi-lane boards keep one copy of each column per
    # lane, so the target list must be resolved within that lane.
    if [[ -n "$swimlane_ref" ]]; then
      target_lane="$(resolve_swimlane "$board_id" "$swimlane_ref")"
    elif [[ -n "$current_lane" ]]; then
      target_lane="$current_lane"
    else
      target_lane="$(resolve_swimlane "$board_id" "")"
    fi
    target_list_id="$(resolve_lane_list "$board_json" "$board_id" "$list_name" "$target_lane")"

    if [[ "$current_list_id" != "$target_list_id" ]]; then
      echo "Moving card to list '$list_name'..."
      body="$(echo "$body" | jq -c --arg lid "$target_list_id" '. + {listId: $lid, rank: 60590587}')"
      if [[ -n "$swimlane_ref" && "$target_lane" != "$current_lane" ]]; then
        body="$(echo "$body" | jq -c --arg sid "$target_lane" '. + {swimlaneId: $sid}')"
      fi
    else
      echo "Card is already in list '$list_name'."
    fi
  fi

  if [[ -n "$title" ]]; then
    body="$(echo "$body" | jq -c --arg t "$title" '. + {title: $t}')"
  fi
  if [[ -n "$description" ]]; then
    body="$(echo "$body" | jq -c --arg d "$description" '. + {description: $d}')"
  fi

  if [[ "$body" != "{}" && -n "$current_list_id" ]]; then
    api PUT "/api/boards/$board_id/lists/$current_list_id/cards/$card_id" "$body" >/dev/null \
      || die "Failed to update card."
  fi

  # Label changes via the bulk endpoint (labels must exist on the board first)
  if [[ -n "$add_label" ]]; then
    local label_id
    label_id="$(ensure_label "$board_id" "$add_label")"
    [[ -n "$label_id" ]] || die "Could not resolve label '$add_label'."
    api POST "/api/boards/$board_id/cards/labels" \
      "$(jq -cn --arg cid "$card_id" --arg lid "$label_id" '{cardIds: [$cid], addLabelIds: [$lid]}')" >/dev/null \
      || die "Failed to add label '$add_label'."
  fi

  if [[ -n "$remove_label" ]]; then
    local live_board removed_id
    live_board="$(fetch_board "$board_id")"
    removed_id="$(echo "$live_board" | jq -r --arg n "$remove_label" \
      '[.labels[]? | select(.name == $n)] | first | ._id // empty')"
    if [[ -z "$removed_id" ]]; then
      echo "WARNING: Label '$remove_label' not found on board; nothing removed." >&2
    else
      api POST "/api/boards/$board_id/cards/labels" \
        "$(jq -cn --arg cid "$card_id" --arg lid "$removed_id" '{cardIds: [$cid], removeLabelIds: [$lid]}')" >/dev/null \
        || die "Failed to remove label '$remove_label'."
    fi
  fi

  echo "Done! Card #$card_id updated on board '$(echo "$board_json" | jq -r '.board_name // "unknown"')'."
}

cmd_archive() {
  local board_query="" card_ref="" unarchive=false dry_run=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --board|-b) board_query="$2"; shift 2 ;;
      --card|-c) card_ref="$2"; shift 2 ;;
      --unarchive) unarchive=true; shift ;;
      --dry-run|-n) dry_run=true; shift ;;
      *) die "Unknown option '$1'" ;;
    esac
  done

  [[ -n "$board_query" && -n "$card_ref" ]] || {
    echo "Usage: wekan.sh archive --board <name|id> --card <id|url|title> [--unarchive] [--dry-run]" >&2
    exit 1
  }

  local board_json card card_id current_archived board_id list_id
  board_json="$(validate_board "$board_query")"
  require_credentials
  card="$(resolve_card "$board_json" "$card_ref")"
  card_id="$(echo "$card" | jq -r '._id')"
  board_id="$(echo "$board_json" | jq -r '.board_id')"
  list_id="$(echo "$card" | jq -r '.listId // empty')"
  current_archived="$(echo "$card" | jq -r '(.archived // false)')"

  if $dry_run; then
    if $unarchive; then
      echo "[DRY RUN] Would UNARCHIVE card #$card_id ('$(echo "$card" | jq -r .title)')."
    else
      echo "[DRY RUN] Would ARCHIVE card #$card_id ('$(echo "$card" | jq -r .title)')."
    fi
    return 0
  fi

  [[ -n "$list_id" ]] || die "Resolved card has no listId; cannot archive."

  if $unarchive; then
    [[ "$current_archived" == "true" ]] || { echo "Card is not archived; nothing to do."; return 0; }
    echo "Unarchiving card #$card_id..."
    api POST "/api/boards/$board_id/lists/$list_id/cards/$card_id/unarchive" >/dev/null \
      || die "Failed to unarchive card."
    echo "Done! Card #$card_id restored on board '$(echo "$board_json" | jq -r '.board_name // "unknown"')'."
  else
    [[ "$current_archived" == "true" ]] && { echo "Card is already archived; nothing to do."; return 0; }
    echo "Archiving card #$card_id ('$(echo "$card" | jq -r .title)')..."
    api POST "/api/boards/$board_id/lists/$list_id/cards/$card_id/archive" >/dev/null \
      || die "Failed to archive card."
    echo "Done! Card #$card_id archived on board '$(echo "$board_json" | jq -r '.board_name // "unknown"')'."
  fi
}

cmd_list() {
  local board_query="" list_filter="" swimlane_ref=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --board|-b) board_query="$2"; shift 2 ;;
      --list|-l) list_filter="$2"; shift 2 ;;
      --swimlane|-s) swimlane_ref="$2"; shift 2 ;;
      *) die "Unknown option '$1'" ;;
    esac
  done

  [[ -n "$board_query" ]] || {
    echo "Usage: wekan.sh list --board <name|id> [--list <filter>] [--swimlane <name|id>]" >&2
    exit 1
  }

  local board_json board_id map lane_id=""
  board_json="$(validate_board "$board_query")"
  require_credentials
  board_id="$(echo "$board_json" | jq -r '.board_id')"

  if [[ -n "$swimlane_ref" ]]; then
    lane_id="$(resolve_swimlane "$board_id" "$swimlane_ref")"
  fi

  # One pass over every list (all lanes). Each card carries its swimlaneId,
  # which is how per-lane column copies are identified (see build_lane_map).
  map="$(build_lane_map "$board_id")"

  local board_name lanes_count instance
  board_name="$(echo "$board_json" | jq -r '.board_name // "unknown"')"
  lanes_count="$(echo "$map" | jq '.lanes | length')"
  instance="$(jq -r '.instance' "$CONFIG_FILE")"

  echo "=== Board: $board_name (ID: $board_id) ==="

  local list_names
  if [[ -n "$list_filter" ]]; then
    require_allowed_list "$board_json" "$list_filter"
    list_names="$list_filter"
  else
    list_names="$(echo "$board_json" | jq -r '.lists[]')"
  fi

  # Print one column's cards for a lane (count + card lines).
  print_lane_column() {
    local sid="$1" tname="$2" cards_json count
    cards_json="$(echo "$map" | jq -c --arg sid "$sid" --arg t "$tname" \
      '[.segments[] | select(.anchored and .lane == $sid) | .columns[] | select(.title == $t) | .cards[]]')"
    count="$(echo "$cards_json" | jq 'length')"
    echo "  [$tname] ($count card(s))"
    echo "$cards_json" | jq -r '.[] | "    - \(._id): \(.title)"'
  }

  if [[ -n "$lane_id" ]]; then
    local lane_title list_name
    lane_title="$(echo "$map" | jq -r --arg id "$lane_id" '[.lanes[] | select(._id == $id)] | first | .title // "?"')"
    echo "=== Swimlane: $lane_title (ID: $lane_id) ==="
    echo ""
    while IFS= read -r list_name; do
      [[ -z "$list_name" ]] && continue
      print_lane_column "$lane_id" "$list_name"
    done <<< "$list_names"
  elif [[ "$lanes_count" -gt 1 ]]; then
    # Multi-lane board, no lane filter: one section per lane so cards are never
    # silently attributed to the wrong repo.
    local i n_lanes l_id l_title list_name
    echo ""
    for ((i = 0; i < lanes_count; i++)); do
      l_id="$(echo "$map" | jq -r ".lanes[$i]._id")"
      l_title="$(echo "$map" | jq -r ".lanes[$i].title")"
      echo "--- Swimlane: $l_title (ID: $l_id) ---"
      while IFS= read -r list_name; do
        [[ -z "$list_name" ]] && continue
        print_lane_column "$l_id" "$list_name"
      done <<< "$list_names"
      echo ""
    done
  else
    # Single-lane (or lane-less) board: legacy flat output.
    local sid="" list_name cards_json count
    if [[ "$lanes_count" -eq 1 ]]; then
      sid="$(echo "$map" | jq -r '.lanes[0]._id')"
    fi
    echo ""
    while IFS= read -r list_name; do
      [[ -z "$list_name" ]] && continue
      if [[ -n "$sid" ]]; then
        print_lane_column "$sid" "$list_name"
      else
        cards_json="$(echo "$map" | jq -c --arg t "$list_name" '[.segments[].columns[] | select(.title == $t) | .cards[]]')"
        count="$(echo "$cards_json" | jq 'length')"
        echo "  [$list_name] ($count card(s))"
        echo "$cards_json" | jq -r '.[] | "    - \(._id): \(.title)"'
      fi
    done <<< "$list_names"
  fi

  echo ""
  echo "Card URL format: ${instance%/}/boards/$board_id/<card-id> (archived cards are hidden by the API; unarchive with 'wekan.sh archive --unarchive')"
}

cmd_boards() {
  require_credentials
  local response
  # NOTE: GET /api/boards is unreliable on v12.75 (may return []). We use it
  # best-effort, then live-check every whitelisted board by id instead.
  response="$(api GET "/api/boards?me=true" 2>/dev/null)" || response="[]"

  local api_count
  api_count="$(echo "$response" | jq 'if type == "array" then length else 0 end' 2>/dev/null || echo 0)"
  if [[ "${api_count:-0}" -gt 0 ]]; then
    echo "Boards reported by the instance:"
    echo "$response" | jq -r '.[] | "  - ID: \(._id // .id) | Name: \(.title)"'
  fi

  echo ""
  echo "Whitelisted boards (live status):"
  local count i bid bname live
  count="$(jq '.boards | length' "$CONFIG_FILE")"
  for i in $(seq 0 $((count - 1))); do
    bid="$(jq -r ".boards[$i].board_id // empty" "$CONFIG_FILE")"
    bname="$(jq -r ".boards[$i].board_name // \"(unnamed)\"" "$CONFIG_FILE")"
    live="$(api GET "/api/boards/$bid" 2>/dev/null)" || live=""
    if echo "$live" | jq -e '._id' >/dev/null 2>&1; then
      local title archived
      title="$(echo "$live" | jq -r '.title')"
      archived="$(echo "$live" | jq -r '.archived // false')"
      echo "  - ID: $bid | Name: $title${bname:+ (config: $bname)} | archived: $archived"
    else
      echo "  - ID: $bid | NOT FOUND on instance (config: ${bname:-?})"
    fi
  done
}

cmd_lists() {
  require_credentials
  local board_query="${1:-}"
  [[ -n "$board_query" ]] || { echo "Usage: wekan.sh lists --board <name|id>" >&2; exit 1; }

  # Allow --board flag form too
  if [[ "$board_query" == "--board" ]]; then
    board_query="${2:-}"
  fi
  [[ -n "$board_query" ]] || die "Missing board argument."

  local board_json board_id response
  board_json="$(validate_board "$board_query")"
  board_id="$(echo "$board_json" | jq -r '.board_id')"
  response="$(api GET "/api/boards/$board_id/lists")" || die "Could not fetch lists."
  echo "Lists on board '$(echo "$board_json" | jq -r '.board_name // "unknown"')':"
  echo "$response" | jq -r '.[] | "  - ID: \(._id) | Name: \(.title)" + (if .archived == true then " (ARCHIVED)" else "" end)'

  # Multi-lane boards keep one copy of each column per lane, so titles repeat.
  local total distinct
  total="$(echo "$response" | jq 'length')"
  distinct="$(echo "$response" | jq '[.[].title] | unique | length')"
  if [[ "$total" -gt "$distinct" ]]; then
    echo "NOTE: $total lists but only $distinct distinct names — this board has multiple swimlanes, each with its own copy of every column. Use 'wekan.sh list' for lane-grouped output; the API does not expose which copy belongs to which lane directly (it is inferred from card swimlaneIds)."
  fi
}

# List all swimlanes on a board (name + id), for use with --swimlane.
cmd_swimlanes() {
  local board_query="${1:-}"

  # Allow --board flag form too
  if [[ "$board_query" == "--board" ]]; then
    board_query="${2:-}"
  fi
  [[ -n "$board_query" ]] || { echo "Usage: wekan.sh swimlanes --board <name|id>" >&2; exit 1; }

  local board_json board_id response
  board_json="$(validate_board "$board_query")"
  require_credentials
  board_id="$(echo "$board_json" | jq -r '.board_id')"
  response="$(api GET "/api/boards/$board_id/swimlanes")" || die "Could not fetch swimlanes."
  echo "Swimlanes on board '$(echo "$board_json" | jq -r '.board_name // "unknown"')':"
  echo "$response" | jq -r '.[] | "  - ID: \(._id) | Name: \(.title)"'
}

cmd_validate-config() {
  [[ -s "$CONFIG_FILE" ]] || die "Config file '$CONFIG_FILE' is empty or missing."

  local errors=0

  if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
    die "Invalid JSON in config file: $CONFIG_FILE"
  fi

  local instance board_count
  instance="$(jq -r '.instance // empty' "$CONFIG_FILE")"
  if [[ -z "$instance" || "$instance" == "null" ]]; then
    echo "ERROR: Missing 'instance' field (WeKan base URL)." >&2
    errors=$((errors + 1))
  fi

  board_count="$(jq '.boards | length // 0' "$CONFIG_FILE")"
  if [[ "$board_count" -eq 0 ]]; then
    echo "WARNING: No boards defined in config." >&2
    errors=$((errors + 1))
  fi

  local i bid bname lists default_list
  for i in $(seq 0 $((board_count - 1))); do
    bid="$(jq -r ".boards[$i].board_id // empty" "$CONFIG_FILE")"
    bname="$(jq -r ".boards[$i].board_name // \"(unnamed)\"" "$CONFIG_FILE")"
    lists="$(jq -r ".boards[$i].lists | length // 0" "$CONFIG_FILE")"
    default_list="$(jq -r ".boards[$i].default_list // empty" "$CONFIG_FILE")"

    if [[ -z "$bid" ]]; then
      echo "ERROR: Board $i ('$bname') missing 'board_id'. Find it with 'wekan.sh boards'." >&2
      errors=$((errors + 1))
    fi
    if [[ "$lists" -eq 0 ]]; then
      echo "ERROR: Board '$bname' (ID: ${bid:-?}) has no lists defined." >&2
      errors=$((errors + 1))
    elif [[ -n "$default_list" ]] && ! jq -r ".boards[$i].lists[]" "$CONFIG_FILE" | grep -qx -- "$default_list"; then
      echo "ERROR: Board '$bname' default_list '$default_list' is not in its lists array." >&2
      errors=$((errors + 1))
    fi
  done

  if [[ $errors -eq 0 ]]; then
    echo "Config is valid. ${board_count} board(s) configured on ${instance:-?}:"
    jq -r '.boards[] | "  [\(.board_id)] \(.board_name // "(unnamed)") — lists: \(.lists | join(", "))"' "$CONFIG_FILE"
  else
    echo "" >&2
    echo "${errors} error(s) found in config." >&2
    exit 1
  fi
}

# ─── Main Dispatch ──────────────────────────────────────────────────

if [[ $# -lt 1 ]]; then
  cat <<EOF
WeKan Backlog Manager (WeKan CE v12.x REST API)

Usage: wekan.sh <command> [options]

Commands:
  create          Create a card on a whitelisted board list (--swimlane for multi-lane boards)
  update          Update a card (title, description, labels) or move it between lists
  archive         Archive (or --unarchive) a card
  list            List cards on a board, grouped by list (--swimlane to filter one lane)
  swimlanes       List swimlanes on a board (name + id)
  boards          Show whitelisted boards with live status (for filling in config)
  lists           List lists on a board (for filling in config)
  validate-config Validate the configuration file

Use 'wekan.sh <command> --help' for command-specific usage.

Environment:
  WEKAN_TOKEN               WeKan session token (preferred; from POST /users/login)
  WEKAN_USERNAME            Username (used with WEKAN_PASSWORD to log in per command)
  WEKAN_PASSWORD            Password (never echoed or written to disk)
  WEKAN_CONFIG_PATH         Override config file path
EOF
  exit 0
fi

COMMAND="$1"
shift

case "$COMMAND" in
  create)          cmd_create "$@" ;;
  update)          cmd_update "$@" ;;
  archive)         cmd_archive "$@" ;;
  list)            cmd_list "$@" ;;
  swimlanes)       cmd_swimlanes "$@" ;;
  boards)          cmd_boards "$@" ;;
  lists)           cmd_lists "$@" ;;
  validate-config) cmd_validate-config ;;
  --help|-h|help)  echo "Run 'wekan.sh' with no arguments for usage." ;;
  *)
    die "Unknown command '$COMMAND'. Run 'wekan.sh' with no arguments for usage."
    ;;
esac
