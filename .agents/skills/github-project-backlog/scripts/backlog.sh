#!/usr/bin/env bash
#
# GitHub Project Backlog Manager
# Usage: backlog.sh <command> [options]
#
# Commands: create, update, archive, list, validate-config, discover-fields
#
# Security: Reads GITHUB_TOKEN from environment. Never echoes or logs it.
# Config validation: Only operates on whitelisted projects/repos.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── Token Resolution (deferred — only called when GitHub API is needed) ──
resolve_token() {
  # Prefer gh CLI auth; fall back to GITHUB_TOKEN env var
  if command -v gh &>/dev/null && gh auth status &>/dev/null 2>&1; then
    echo "gh-cli-auth"
    return 0
  elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
    echo "env-var"
    return 0
  else
    echo "ERROR: No GitHub authentication found. Run 'gh auth login' or set GITHUB_TOKEN." >&2
    exit 1
  fi
}

# Check auth only when needed (not for validate-config, etc.)
require_auth() {
  if [[ -z "${AUTH_METHOD:-}" ]]; then
    AUTH_METHOD="$(resolve_token)"
  fi
}

# ─── Config Discovery ────────────────────────────────────────────────
discover_config() {
  # Priority order:
  # 1. $GITHUB_PROJECT_CONFIG_PATH env var (explicit config file path)
  # 2. <repo-root>/.github-project-backlog-config.json
  # 3. ~/.config/github-project-backlog/config.json
  # 4. Skill directory template (fallback — warn if used as live config)

  local candidate=""

  # Check explicit env var override first (can be a full path or repo root)
  if [[ -n "${GITHUB_PROJECT_CONFIG_PATH:-}" ]]; then
    if [[ -f "$GITHUB_PROJECT_CONFIG_PATH" ]]; then
      candidate="$GITHUB_PROJECT_CONFIG_PATH"
    elif [[ -f "${GITHUB_PROJECT_CONFIG_PATH}/.github-project-backlog-config.json" ]]; then
      candidate="${GITHUB_PROJECT_CONFIG_PATH}/.github-project-backlog-config.json"
    fi
  fi

  # If no env var match, try repo root
  if [[ -z "$candidate" ]]; then
    local repo_root
    repo_root="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
    if [[ -n "$repo_root" && -f "${repo_root}/.github-project-backlog-config.json" ]]; then
      candidate="${repo_root}/.github-project-backlog-config.json"
    fi
  fi

  # Check user-level global config
  if [[ -z "$candidate" && -f ~/.config/github-project-backlog/config.json ]]; then
    candidate=~/.config/github-project-backlog/config.json
  fi

  # Fallback to template (warn)
  if [[ -z "$candidate" ]]; then
    echo "WARNING: No live config found. Using template at $SKILL_DIR/config.example.json — this is for reference only." >&2
    candidate="$SKILL_DIR/config.example.json"
  fi

  if [[ -z "$candidate" || ! -f "$candidate" ]]; then
    echo "ERROR: No configuration file found. Create one at:" >&2
    echo "  <repo-root>/.github-project-backlog-config.json" >&2
    echo "" >&2
    echo "See config.example.json for the required format." >&2
    exit 1
  fi

  echo "$candidate"
}

CONFIG_FILE="$(discover_config)"

# ─── Config Validation Helpers ──────────────────────────────────────

# Convert string to lowercase (bash 3.2 compatible — no ${var,,})
to_lower() {
  echo "$1" | tr '[:upper:]' '[:lower:]'
}

# Validate that a project is whitelisted. Returns the project JSON on success.
validate_project() {
  local query="$1"  # Can be: org/project_name, project_id number, or partial name match

  if [[ ! -s "$CONFIG_FILE" ]]; then
    echo "ERROR: Config file is empty." >&2
    exit 1
  fi

  local result=""

  # Try matching by numeric project_id
  if [[ "$query" =~ ^[0-9]+$ ]]; then
    result="$(jq -r --argjson pid "$query" '.projects[] | select(.project_id == $pid)' "$CONFIG_FILE")"
  else
    # Match by org + name (case-insensitive partial match on project_name)
    local query_org=""
    local query_name="$query"

    if [[ "$query" == */* ]]; then
      query_org="${query%%/*}"
      query_name="${query#*/}"
    fi

    local query_org_lower
    local query_name_lower
    query_org_lower="$(to_lower "$query_org")"
    query_name_lower="$(to_lower "$query_name")"

    result="$(jq -r --arg org "$query_org_lower" --arg name "$query_name_lower" \
      '.projects[] | select((.org // "" | ascii_downcase) == $org and ((.project_name // "") | ascii_downcase | contains($name)))' \
      "$CONFIG_FILE")"

    # If no org specified, try matching by name alone across all projects
    if [[ -z "$result" && -z "$query_org" ]]; then
      result="$(jq -r --arg name "$query_name_lower" \
        '.projects[] | select((.project_name // "") | ascii_downcase | contains($name))' \
        "$CONFIG_FILE")"
    fi
  fi

  if [[ -z "$result" || "$result" == "null" ]]; then
    echo "ERROR: Project '$query' not found in config." >&2
    echo "" >&2
    echo "Available projects:" >&2
    jq -r '.projects[] | "  - ID: \(.project_id) | Name: \(.project_name) | Org: \(.org)"' "$CONFIG_FILE" >&2
    exit 1
  fi

  echo "$result"
}

# Validate that a repo is allowed for the given project.
validate_repo() {
  local project_json="$1"
  local repo="$2"

  local allowed_repos
  allowed_repos="$(echo "$project_json" | jq -r '.repos[]')"

  if ! echo "$allowed_repos" | grep -qx "$repo"; then
    echo "ERROR: Repo '$repo' is not in the allowed repos for this project." >&2
    echo "" >&2
    echo "Allowed repos:" >&2
    echo "$allowed_repos" | sed 's/^/  - /' >&2
    exit 1
  fi
}

# ─── Field Discovery & Caching ──────────────────────────────────────

CACHE_FILE="${GITHUB_PROJECT_CACHE_PATH:-${HOME}/.cache/github-project-backlog-cache.json}"

discover_and_cache_fields() {
  local project_json="$1"
  local project_id
  project_id="$(echo "$project_json" | jq -r '.project_id')"

  # Check cache first
  if [[ -f "$CACHE_FILE" ]]; then
    local cached
    cached="$(jq -r --arg pid "$project_id" '.projects[$pid // empty]' "$CACHE_FILE" 2>/dev/null || echo "")"
    if [[ -n "$cached" && "$cached" != "null" ]]; then
      echo "$cached"
      return 0
    fi
  fi

  # Discover via gh CLI
  local fields_json
  fields_json="$(gh project view-fields "$project_id" --json id,name,settings 2>/dev/null || echo "")"

  if [[ -z "$fields_json" ]]; then
    echo "WARNING: Could not discover fields for project $project_id. Proceeding without field caching." >&2
    return 1
  fi

  # Ensure cache directory exists
  mkdir -p "$(dirname "$CACHE_FILE")"

  # Merge into existing cache or create new one
  if [[ -f "$CACHE_FILE" ]]; then
    local tmp
    tmp="$(mktemp)"
    jq --arg pid "$project_id" --argjson fields "$fields_json" \
      '.projects[$pid] = $fields // .projects' "$CACHE_FILE" > "$tmp" && mv "$tmp" "$CACHE_FILE"
  else
    echo "{\"projects\": {\"$project_id\": $fields_json}}" > "$CACHE_FILE"
  fi

  echo "$fields_json"
}

# ─── Commands ────────────────────────────────────────────────────────

cmd_create() {
  require_auth
  local project_query="" item_type="issue" title="" body="" repo="" labels="" status="" dry_run=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project|-p) project_query="$2"; shift 2 ;;
      --type|-t) item_type="$2"; shift 2 ;;
      --title) title="$2"; shift 2 ;;
      --body) body="$2"; shift 2 ;;
      --repo) repo="$2"; shift 2 ;;
      --labels) labels="$2"; shift 2 ;;
      --status) status="$2"; shift 2 ;;
      --dry-run|-n) dry_run=true; shift ;;
      *) echo "ERROR: Unknown option '$1'" >&2; exit 1 ;;
    esac
  done

  if [[ -z "$project_query" || -z "$title" ]]; then
    echo "Usage: backlog.sh create --project <name|id> --type issue|pr|note --title <title> [--repo <repo>] [--labels ...] [--status <status>] [--dry-run]" >&2
    exit 1
  fi

  local project_json
  project_json="$(validate_project "$project_query")"

  if [[ -n "$repo" ]]; then
    validate_repo "$project_json" "$repo"
  fi

  local org project_id project_name
  org="$(echo "$project_json" | jq -r '.org')"
  project_id="$(echo "$project_json" | jq -r '.project_id')"
  project_name="$(echo "$project_json" | jq -r '.project_name // "unknown"')"

  if $dry_run; then
    echo "[DRY RUN] Would create $item_type in project '$project_name' (ID: $project_id):"
    echo "  Title:   $title"
    [[ -n "$body" ]] && echo "  Body:    $(echo "$body" | head -1)..."
    [[ -n "$repo" ]] && echo "  Repo:    $org/$repo"
    [[ -n "$labels" ]] && echo "  Labels:  $labels"
    [[ -n "$status" ]] && echo "  Status:  $status"
    return 0
  fi

  local item_id="" item_url=""

  case "$item_type" in
    issue)
      if [[ -z "$repo" ]]; then
        # Use first repo from config as default
        repo="$(echo "$project_json" | jq -r '.repos[0]')"
      fi
      echo "Creating issue in $org/$repo..."
      local create_args=(--repo "$org/$repo" --title "$title")
      [[ -n "$body" ]] && create_args+=(--body "$body")
      [[ -n "$labels" ]] && create_args+=(--label "$labels")

      # Capture issue number from output
      local output
      output="$(gh issue create "${create_args[@]}" 2>&1)" || {
        echo "ERROR: Failed to create issue. Output:" >&2
        echo "$output" >&2
        exit 1
      }
      item_id="$(echo "$output" | grep -oP '#\K[0-9]+' | head -1)"
      if [[ -z "$item_id" ]]; then
        # Try parsing URL from output
        item_url="$(echo "$output" | grep -oP 'https://github\.com/\S+' | head -1)"
        item_id="${item_url##*/}"
      fi

      echo "Created issue #$item_id: $title"
      ;;
    pr)
      if [[ -z "$repo" ]]; then
        repo="$(echo "$project_json" | jq -r '.repos[0]')"
      fi
      echo "Creating PR in $org/$repo..."
      # PRs require a branch — this is informational only; user must create the branch first
      echo "[INFO] Create a branch and push it, then run:" >&2
      echo "  gh pr create --repo $org/$repo --title '$title' --body '$body'" >&2
      return 0
      ;;
    note)
      # Notes are added directly to the project without a repo
      item_type="note"
      ;;
    *)
      echo "ERROR: Unknown item type '$item_type'. Use issue, pr, or note." >&2
      exit 1
      ;;
  esac

  # Add item to project (for issues and notes)
  if [[ "$item_type" != "pr" ]]; then
    local node_id=""

    if [[ -n "$item_id" && "$item_type" == "issue" ]]; then
      echo "Fetching node ID for issue #$item_id..."
      node_id="$(gh api "repos/$org/$repo/issues/$item_id" --jq '.node_id' 2>/dev/null)" || {
        echo "WARNING: Could not fetch node ID. Item may not be added to project automatically." >&2
      }
    fi

    if [[ -n "$node_id" ]]; then
      echo "Adding item to project $project_name..."
      gh project item-add "$project_id" --item-id "$node_id" 2>/dev/null || {
        echo "WARNING: Could not add item to project. It may have been added automatically by --project flag." >&2
      }

      # Set status if provided
      if [[ -n "$status" ]]; then
        local field_id=""
        local config_field_id
        config_field_id="$(echo "$project_json" | jq -r '.status_field_id // empty')"

        if [[ -z "$config_field_id" ]]; then
          # Discover fields
          discover_and_cache_fields "$project_json" >/dev/null 2>&1 || true
          field_id=""  # Will need manual lookup
        else
          field_id="$config_field_id"
        fi

        if [[ -n "$field_id" ]]; then
          echo "Setting status to '$status'..."
          gh project item-update \
            --project-id "$project_id" \
            --item-id "$node_id" \
            --field-values "${field_id}=${status}" 2>/dev/null || {
              echo "WARNING: Could not set status. Check field configuration." >&2
            }
        fi
      fi

      item_url="https://github.com/$org/$repo/issues/$item_id"
    fi

    if [[ -n "$item_url" ]]; then
      echo "Done! Item created and added to project: $item_url"
    else
      echo "Done! Item created in project '$project_name' (ID: $project_id)."
    fi
  fi
}

cmd_update() {
  require_auth
  local project_query="" item_ref="" status="" labels_add="" labels_remove="" title="" body="" dry_run=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project|-p) project_query="$2"; shift 2 ;;
      --item|-i) item_ref="$2"; shift 2 ;;
      --status) status="$2"; shift 2 ;;
      --add-label) labels_add="$2"; shift 2 ;;
      --remove-label) labels_remove="$2"; shift 2 ;;
      --title) title="$2"; shift 2 ;;
      --body) body="$2"; shift 2 ;;
      --dry-run|-n) dry_run=true; shift ;;
      *) echo "ERROR: Unknown option '$1'" >&2; exit 1 ;;
    esac
  done

  if [[ -z "$project_query" || -z "$item_ref" ]]; then
    echo "Usage: backlog.sh update --project <name|id> --item <issue#|URL> [--status <s>] [--add-label <l>] [--remove-label <l>] [--title <t>] [--body <b>] [--dry-run]" >&2
    exit 1
  fi

  local project_json
  project_json="$(validate_project "$project_query")"

  local org repo project_id
  org="$(echo "$project_json" | jq -r '.org')"
  project_id="$(echo "$project_json" | jq -r '.project_id')"

  # Extract issue/PR number from reference
  local item_number=""
  if [[ "$item_ref" =~ ^[0-9]+$ ]]; then
    item_number="$item_ref"
  elif [[ "$item_ref" =~ issues/[0-9]+ ]]; then
    item_number="${item_ref##*issues/}"
  elif [[ "$item_ref" =~ pull/[0-9]+ ]]; then
    item_number="${item_ref##*pull/}"
  fi

  if [[ -z "$item_number" ]]; then
    echo "ERROR: Could not parse item number from '$item_ref'. Use a number, 'issues/<n>', or 'pull/<n>'." >&2
    exit 1
  fi

  # Determine repo (use first allowed repo as default)
  repo="$(echo "$project_json" | jq -r '.repos[0]')"

  if $dry_run; then
    echo "[DRY RUN] Would update item #$item_number in project '$(echo "$project_json" | jq -r '.project_name // "unknown"')':"
    [[ -n "$status" ]] && echo "  Status:     -> $status"
    [[ -n "$labels_add" ]] && echo "  Add labels: $labels_add"
    [[ -n "$labels_remove" ]] && echo "  Remove labels: $labels_remove"
    [[ -n "$title" ]] && echo "  Title:      -> $title"
    return 0
  fi

  # Update issue/PR metadata
  if [[ -n "$title" || -n "$body" || -n "$labels_add" || -n "$labels_remove" ]]; then
    local edit_args=(--repo "$org/$repo")
    [[ -n "$title" ]] && edit_args+=(--title "$title")
    [[ -n "$body" ]] && edit_args+=(--body "$body")
    [[ -n "$labels_add" ]] && edit_args+=(--add-label "$labels_add")
    [[ -n "$labels_remove" ]] && edit_args+=(--remove-label "$labels_remove")

    echo "Updating issue #$item_number..."
    gh issue edit "$item_number" "${edit_args[@]}" 2>/dev/null || {
      echo "WARNING: Could not update issue metadata." >&2
    }
  fi

  # Update project status field
  if [[ -n "$status" ]]; then
    local config_field_id
    config_field_id="$(echo "$project_json" | jq -r '.status_field_id // empty')"

    if [[ -z "$config_field_id" ]]; then
      echo "WARNING: No status_field_id in config. Cannot update status." >&2
      return 0
    fi

    # Get the node ID for this item
    local node_id
    node_id="$(gh api "repos/$org/$repo/issues/$item_number" --jq '.node_id' 2>/dev/null)" || {
      echo "WARNING: Could not fetch node ID." >&2
      return 0
    }

    echo "Setting status to '$status'..."
    gh project item-update \
      --project-id "$project_id" \
      --item-id "$node_id" \
      --field-values "${config_field_id}=${status}" 2>/dev/null || {
        echo "WARNING: Could not update status field." >&2
      }
  fi

  echo "Done! Item #$item_number updated in project '$(echo "$project_json" | jq -r '.project_name // "unknown"')'."
}

cmd_archive() {
  require_auth
  local project_query="" item_ref="" action="close" dry_run=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project|-p) project_query="$2"; shift 2 ;;
      --item|-i) item_ref="$2"; shift 2 ;;
      --action) action="$2"; shift 2 ;;
      --dry-run|-n) dry_run=true; shift ;;
      *) echo "ERROR: Unknown option '$1'" >&2; exit 1 ;;
    esac
  done

  if [[ -z "$project_query" || -z "$item_ref" ]]; then
    echo "Usage: backlog.sh archive --project <name|id> --item <issue#|URL> [--action close|remove-from-project] [--dry-run]" >&2
    exit 1
  fi

  local project_json
  project_json="$(validate_project "$project_query")"

  local org repo project_id project_name
  org="$(echo "$project_json" | jq -r '.org')"
  project_id="$(echo "$project_json" | jq -r '.project_id')"
  project_name="$(echo "$project_json" | jq -r '.project_name // "unknown"')"

  # Extract item number
  local item_number=""
  if [[ "$item_ref" =~ ^[0-9]+$ ]]; then
    item_number="$item_ref"
  elif [[ "$item_ref" =~ issues/[0-9]+ ]]; then
    item_number="${item_ref##*issues/}"
  elif [[ "$item_ref" =~ pull/[0-9]+ ]]; then
    item_number="${item_ref##*pull/}"
  fi

  if [[ -z "$item_number" ]]; then
    echo "ERROR: Could not parse item number from '$item_ref'." >&2
    exit 1
  fi

  repo="$(echo "$project_json" | jq -r '.repos[0]')"

  # Determine item type (issue vs PR) by querying the GitHub API
  local item_type="issue"
  local item_state="open"
  local api_response
  api_response="$(gh api "repos/$org/$repo/issues/$item_number" --jq '{type: .pull_request // empty, state: .state}' 2>/dev/null || echo '{}')"

  if [[ "$api_response" != '{}' && -n "$(echo "$api_response" | jq -r '.type // empty')" ]]; then
    item_type="pr"
    item_state="$(echo "$api_response" | jq -r '.state')"
  else
    item_state="$(echo "$api_response" | jq -r '.state // "unknown"')"
  fi

  # If it's an open PR, archiving is not allowed (PR must be merged separately)
  if [[ "$item_type" == "pr" && "$item_state" == "open" ]]; then
    echo "ERROR: Cannot archive open PR #$item_number. Merge the PR first before archiving." >&2
    exit 1
  fi

  # Confirm destructive action
  if $dry_run; then
    echo "[DRY RUN] Would archive item #$item_number ($item_type, state: $item_state) in project '$project_name':"
    case "$action" in
      close)
        if [[ "$item_type" == "pr" ]]; then
          echo "  Action: Remove closed/merged PR from project board"
        else
          echo "  Action: Close issue and remove from project board"
        fi
        ;;
      remove-from-project) echo "  Action: Remove from project board only (item stays open)" ;;
      *) echo "  Unknown action: $action" ;;
    esac
    return 0
  fi

  case "$action" in
    close)
      if [[ "$item_type" == "pr" ]]; then
        # PR is already closed/merged (open PRs were rejected above).
        # Archiving a PR means removing it from the project board.
        echo "PR #$item_number is closed. Removing from project board..."
      else
        echo "Closing issue #$item_number..."
        gh issue close "$item_number" --repo "$org/$repo" 2>/dev/null || {
          echo "WARNING: Could not close issue." >&2
        }
      fi
      # Remove the item from the project board
      local node_id
      node_id="$(gh api "repos/$org/$repo/issues/$item_number" --jq '.node_id' 2>/dev/null)"
      if [[ -n "$node_id" ]]; then
        echo "Removing item from project '$project_name'..."
        gh project item-delete --project-id "$project_id" --item-id "$node_id" 2>/dev/null || {
          echo "WARNING: Could not remove item from project board." >&2
        }
      fi
      ;;
    remove-from-project)
      # Get node ID and remove from project only
      local node_id
      node_id="$(gh api "repos/$org/$repo/issues/$item_number" --jq '.node_id' 2>/dev/null)" || {
        echo "ERROR: Could not fetch node ID for item #$item_number." >&2
        exit 1
      }
      echo "Removing item from project '$project_name'..."
      gh project item-delete --project-id "$project_id" --item-id "$node_id" 2>/dev/null || {
        echo "WARNING: Could not remove item from project." >&2
      }
      ;;
    *)
      echo "ERROR: Unknown action '$action'. Use close or remove-from-project." >&2
      exit 1
      ;;
  esac

  echo "Done! Item #$item_number archived in project '$project_name'."
}

cmd_list() {
  require_auth
  local project_query="" status_filter="" show_all=false

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --project|-p) project_query="$2"; shift 2 ;;
      --status) status_filter="$2"; shift 2 ;;
      --all|--show-all) show_all=true; shift ;;
      *) echo "ERROR: Unknown option '$1'" >&2; exit 1 ;;
    esac
  done

  if [[ -z "$project_query" ]]; then
    echo "Usage: backlog.sh list --project <name|id> [--status <filter>] [--all]" >&2
    exit 1
  fi

  local project_json
  project_json="$(validate_project "$project_query")"

  local org project_id project_name
  org="$(echo "$project_json" | jq -r '.org')"
  project_id="$(echo "$project_json" | jq -r '.project_id')"
  project_name="$(echo "$project_json" | jq -r '.project_name // "unknown"')"

  echo "=== Project: $project_name (ID: $project_id) ==="
  echo ""

  # List items using gh CLI
  if command -v gh &>/dev/null; then
    local query_args=()
    [[ -n "$status_filter" ]] && query_args+=(--filter "status:$status_filter")

    gh project view "$project_id" --json title,number,state,labels,assignees,status 2>/dev/null | \
      jq -r '.items[]? | "- #\(.content?.number // "?"): \(.content?.title // "(note)") [\(.content?.labels.nodes[].name // "no labels")]"' 2>/dev/null || {
        echo "(Could not retrieve items. Try running 'gh auth login' first.)" >&2
      }
  else
    # Fallback: list issues from repos in the project
    local repos
    repos="$(echo "$project_json" | jq -r '.repos[]')"

    while IFS= read -r r; do
      echo "--- $org/$r ---"
      gh issue list --repo "$org/$r" --state open 2>/dev/null || echo "(Could not list issues)"
      echo ""
    done <<< "$repos"
  fi
}

cmd_validate-config() {
  if [[ ! -s "$CONFIG_FILE" ]]; then
    echo "ERROR: Config file '$CONFIG_FILE' is empty or missing." >&2
    exit 1
  fi

  local errors=0

  # Validate JSON syntax
  if ! jq empty "$CONFIG_FILE" 2>/dev/null; then
    echo "ERROR: Invalid JSON in config file." >&2
    exit 1
  fi

  # Check required fields
  local project_count
  project_count="$(jq '.projects | length' "$CONFIG_FILE")"

  if [[ "$project_count" -eq 0 ]]; then
    echo "WARNING: No projects defined in config." >&2
    errors=$((errors + 1))
  fi

  for i in $(seq 0 $((project_count - 1))); do
    local org pid repos
    org="$(jq -r ".projects[$i].org // empty" "$CONFIG_FILE")"
    pid="$(jq -r ".projects[$i].project_id // empty" "$CONFIG_FILE")"
    repos="$(jq -r ".projects[$i].repos | length" "$CONFIG_FILE")"

    if [[ -z "$org" ]]; then
      echo "ERROR: Project $i missing 'org' field." >&2
      errors=$((errors + 1))
    fi

    if [[ -z "$pid" || "$pid" == "0" ]]; then
      echo "WARNING: Project '$org' has project_id=0 or unset. Find the real ID with 'gh project list --owner $org'." >&2
    fi

    if [[ "$repos" -eq 0 ]]; then
      echo "ERROR: Project '$org' (ID: $pid) has no repos defined." >&2
      errors=$((errors + 1))
    fi
  done

  if [[ $errors -eq 0 ]]; then
    echo "Config is valid. ${project_count} project(s) configured."
    jq -r '.projects[] | "  [\(.project_id)] \(.org)/\(.project_name // "(unnamed)") — repos: \(.repos | join(", "))"' "$CONFIG_FILE"
  else
    echo "" >&2
    echo "${errors} error(s) found in config." >&2
    exit 1
  fi
}

cmd_discover-fields() {
  require_auth
  local project_query="${1:-}"

  if [[ -z "$project_query" ]]; then
    echo "Usage: backlog.sh discover-fields <project-name-or-id>" >&2
    exit 1
  fi

  local project_json
  project_json="$(validate_project "$project_query")"

  local project_id
  project_id="$(echo "$project_json" | jq -r '.project_id')"

  echo "Discovering fields for project ID: $project_id..."
  discover_and_cache_fields "$project_json" || {
    echo "Could not discover fields via gh CLI." >&2
    exit 1
  }

  echo ""
  echo "Fields discovered and cached to: $CACHE_FILE"
}

# ─── Main Dispatch ──────────────────────────────────────────────────

if [[ $# -lt 1 ]]; then
  cat <<EOF
GitHub Project Backlog Manager

Usage: backlog.sh <command> [options]

Commands:
  create          Create a new issue/PR/note in a project
  update          Update an existing item (status, labels, title, body)
  archive         Close an issue or remove an item from the project (open PRs are rejected)
  list            List items in a project board
  validate-config Validate the configuration file
  discover-fields Discover and cache project field IDs

Use 'backlog.sh <command> --help' for command-specific usage.

Environment:
  GITHUB_TOKEN              GitHub personal access token (scopes: repo, project)
  GH_PROJECT_CONFIG_PATH    Override config file path
  GH_PROJECT_CACHE_PATH     Override cache file path

Authentication:
  The tool prefers 'gh' CLI auth if available, falling back to GITHUB_TOKEN.
EOF
  exit 0
fi

COMMAND="$1"
shift

case "$COMMAND" in
  create)       cmd_create "$@" ;;
  update)       cmd_update "$@" ;;
  archive)      cmd_archive "$@" ;;
  list)         cmd_list "$@" ;;
  validate-config) cmd_validate-config ;;
  discover-fields) cmd_discover-fields "$@" ;;
  --help|-h|help) echo "Use 'backlog.sh' with no arguments for usage." ;;
  *)
    echo "ERROR: Unknown command '$COMMAND'" >&2
    echo "Run 'backlog.sh' with no arguments for usage." >&2
    exit 1
    ;;
esac
