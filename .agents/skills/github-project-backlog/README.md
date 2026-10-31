# GitHub Project Backlog Skill

Manage GitHub Projects (v2) backlog items — create, update, and archive issues, PRs, and notes.

## Quick Start

### 1. Authenticate with GitHub

**Option A: `gh` CLI (recommended)**
```bash
gh auth login
```

**Option B: Environment variable**
```bash
export GITHUB_TOKEN=ghp_your_personal_access_token_here
```

The token needs these scopes: `repo`, `project`. For org projects, add `write:org`.

### 2. Create a Config File

Copy the example and fill in your details:

```bash
cp .agents/skills/github-project-backlog/config.example.json \
   .github-project-backlog-config.json
```

Edit `.github-project-backlog-config.json`:

```json
{
  "projects": [
    {
      "org": "my-org",
      "project_id": 42,
      "project_name": "Platform Backlog Q1",
      "repos": ["platform-foundation", "dq-made-easy"],
      "status_field_id": "",
      "status_options": {}
    }
  ]
}
```

### 3. Find Your Project ID

```bash
gh project list --owner my-org
# or for personal projects:
gh project list
```

### 4. Discover Field IDs (Optional)

The skill can auto-discover status field IDs, or you can set them manually:

```bash
# Run from within the repo that has the config file
.github-project-backlog/scripts/backlog.sh discover-fields "Platform Backlog Q1"
```

This writes discovered fields to `~/.cache/github-project-backlog-cache.json`.

## Usage with Pi Agent

Once configured, simply ask the pi agent:

- **"Add this task to our Q1 backlog"** — creates an issue and adds it to the project
- **"Move ticket #42 to in-progress"** — updates status field
- **"What's on the data pipeline board?"** — lists items by status
- **"Archive all done items from sprint 5"** — closes closed issues and removes merged PRs from the board (open PRs are rejected until merged)

## Config File Reference

| Field | Required | Description |
|---|---|---|
| `org` | Yes | GitHub org name or username |
| `project_id` | Yes | Numeric Project ID (v2) |
| `project_name` | No | Human-readable label for logging |
| `repos` | Yes | Array of repo names this project covers |
| `status_field_id` | No | ID of the status field; auto-discovered if empty |
| `status_options` | No | Label → value mapping for statuses |

## Security

- **Token**: Never hardcoded. Read from `GITHUB_TOKEN` env var or `gh` CLI auth.
- **Whitelist**: Only projects/repos listed in config are accessible. All operations on unlisted projects are rejected.
- **Dry-run**: Use `--dry-run` flag to preview changes without executing them.

## File Structure

```
.github-project-backlog-config.json   ← Live config (create this)
config.example.json                   ← Template
scripts/backlog.sh                    ← CLI tool
SKILL.md                              ← Pi skill instructions
README.md                             ← This file
```
