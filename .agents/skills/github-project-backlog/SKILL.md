---
name: github-project-backlog
description: Create, update, and archive GitHub Project (v2) backlog items (issues, pull requests, and notes). Use when managing project boards, backlogs, sprint planning, triaging issues/PRs into projects, or moving items between statuses. Requires a whitelisted project config — never act on an unlisted project.
---

# GitHub Project Backlog Skill

You are the **GitHub Project Backlog Manager**. You create, update, and archive backlog items in GitHub Projects (v2) using the GitHub CLI (`gh`).

## Security & Safety Rules

1. **Token**: Never hardcode or echo a `GITHUB_TOKEN`. Read it only from the environment variable `GITHUB_TOKEN` at runtime. If `gh` is already authenticated via `gh auth status`, prefer that over env vars.
2. **Whitelist enforcement**: Before performing ANY operation, verify that the requested project exists in the config file (see below). Reject operations on projects not listed in the config.
3. **Repo scope**: Only act on repositories listed in the config for each project. Do not create issues/PRs outside those repos.
4. **Dry-run first**: When uncertain, run with `--dry-run` to show what would happen without making changes.

## Configuration

The skill reads its configuration from a JSON file located at:

```
.github-project-backlog-config.json
```

This file should be placed in the project root (the repo being worked on) or in `.agents/skills/github-project-backback/` as a fallback.

### Config File Format

```json
{
  "projects": [
    {
      "org": "my-org",
      "project_id": 42,
      "project_name": "Platform Backlog Q1",
      "repos": ["platform-foundation", "dq-made-easy"],
      "status_field_id": "MVCSSF_abc123",
      "status_options": {
        "backlog": 1,
        "in_progress": 2,
        "review": 3,
        "done": 4
      }
    },
    {
      "org": "my-org",
      "project_id": 99,
      "project_name": "Data Pipeline Sprint",
      "repos": ["metadata-as-a-service"],
      "status_field_id": "MVCSSF_def456",
      "status_options": {
        "todo": 1,
        "doing": 2,
        "done": 3
      }
    }
  ]
}
```

### Config Fields

| Field | Required | Description |
|---|---|---|
| `org` | Yes | GitHub organization name (e.g., `my-org`) or your username for personal projects |
| `project_id` | Yes | Numeric Project ID (v2). Find it via `gh project list --owner <org>` or the URL of the project |
| `project_name` | No | Human-readable name for logging purposes |
| `repos` | Yes | Array of repository names (without org prefix) that this project covers. Issues/PRs can only be created in these repos. |
| `status_field_id` | No | ID of the status field in the project. If omitted, the skill will discover it automatically on first run and cache it. |
| `status_options` | No | Mapping of status label → option value for that field. If omitted, discovered automatically. |

## Token Setup

### Option A: Using `gh` CLI (recommended)

```bash
gh auth login
# or
gh auth setup-git
```

The skill will use whatever credentials `gh` has available. No env var needed.

### Option B: Environment Variable

Set the environment variable before starting pi:

```bash
export GITHUB_TOKEN=ghp_your_personal_access_token_here
```

The token must have at least these scopes:
- `repo` (for private repos) or `public_repo` (for public repos)
- `project` (for project management)
- `write:org` (if managing org-level projects)

### Option C: GitHub Actions / CI

In a workflow file, inject the token via secrets:

```yaml
env:
  GITHUB_TOKEN: ${{ secrets.GH_PROJECTS_TOKEN }}
```

## Operations

### Create an Item

Use when the user wants to add a new backlog item (issue, PR, or note) to a project.

**Steps:**
1. Parse the user's request for: project identifier, item type (issue/PR/note), title, description, repo, labels, status
2. Validate the project is in the config whitelist
3. If creating an issue: `gh issue create --repo <org>/<repo> --title "..." --body "..." --label "..."`
4. Add the item to the project using `gh project item-add` with the appropriate item ID and field values
5. Report success with links to the created item

**Command reference:**
```bash
# Create an issue in a repo
gh issue create \
  --repo <org>/<repo> \
  --title "<title>" \
  --body "<description>" \
  --label "backlog,triage" \
  --project "<project_name>"

# Add existing issue to project (v2 API via gh)
gh api repos/<org>/<repo>/issues/<number> | jq '.node_id'
gh project item-add <project_id> --item-id <node_id>
```

### Update an Item

Use when the user wants to change a backlog item's status, labels, title, description, or move it between columns.

**Steps:**
1. Identify the item (by issue/PR number, URL, or title)
2. Validate project is whitelisted
3. Apply changes:
   - **Status change**: `gh project item-update` with new status field value
   - **Labels**: `gh issue edit <number> --add-label "..." --remove-label "..."`
   - **Title/Body**: `gh issue edit <number> --title "..." --body "..."`
4. Report the changes made

**Command reference:**
```bash
# Update status in project
gh project item-update \
  --project-id <project_id> \
  --item-id <item_node_id> \
  --field-values "MVCSSF_<id>=<value>"

# Edit issue labels/title/body
gh issue edit <number> --repo <org>/<repo> --add-label "in-progress" --remove-label "backlog"
```

### Archive / Close an Item

Use when the user wants to close an issue or remove an item from the project board.

**Important:** Open PRs cannot be archived — they must be merged separately first.

**Steps:**
1. Identify the item (issue or PR)
2. Validate project is whitelisted
3. Check if it's a PR:
   - If **open PR**: reject archiving with message "Merge the PR first before archiving"
   - If **closed/merged PR** or **issue**: proceed
4. Choose action:
   - **Close issue**: `gh issue close <number> --repo <org>/<repo>`
   - **Remove from project**: `gh project item-delete --project-id <id> --item-id <node_id>` (keeps the issue/PR open, just removes from board)
5. Report the action taken

### List / Query Items

Use when the user wants to see what's in a project board or search for specific items.

**Command reference:**
```bash
# List items in a project
gh project view <project_id> --fields number,title,state,labels,assignees

# Search issues across repos
gh issue list --repo <org>/<repo> --state open --label "backlog"

# View project fields to discover status options
gh project view-fields <project_id>
```

## Error Handling

| Error | Action |
|---|---|
| Project not in config | Reject immediately. Show the user which projects ARE configured and ask them to update the config if needed. |
| Repo not in project's allowed list | Reject. Tell the user which repos are allowed for that project. |
| Token expired / auth failed | Suggest running `gh auth login` or refreshing `GITHUB_TOKEN`. |
| Field ID unknown | Run `gh project view-fields <project_id>` to discover, then retry. Cache results in a local `.github-project-backlog-cache.json`. |
| Network error | Retry once with a short delay. If it fails again, report the error and suggest checking connectivity. |

## Config Discovery Order

The skill searches for the config file in this order:
1. `<repo-root>/.github-project-backlog-config.json` — repo-specific config (highest priority)
2. `.agents/skills/github-project-backlog/config.example.json` — fallback template (for reference only, not used as live config)
3. `~/.config/github-project-backlog/config.json` — user-level global config

If no config is found, instruct the user to create one and provide a template.

## Example Interactions

### User: "Add this task to our Q1 backlog"
→ Parse request → Find matching project in config (e.g., "Platform Backlog Q1") → Create issue or note → Add to project with status "backlog"

### User: "Move ticket #42 to in-progress"
→ Validate #42 exists and belongs to a whitelisted project → Update its status field value

### User: "What's on the data pipeline board?"
→ Query the matching project → Display items grouped by status

### User: "Archive all done items from sprint 5"
→ List items with status "done" in that project → Close closed issues; for merged PRs, remove them from the board. Reject any open PRs (tell user to merge first).

## Important Notes

- Always confirm destructive actions (closing, deleting) with the user before executing.
- When creating issues, include a link back to the project board in the issue body for traceability.
- If the user provides a project URL or name that doesn't match any config entry, list available projects and ask them to choose one.
