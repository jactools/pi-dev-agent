# WeKan Backlog Skill

Manage cards (backlog items) on WeKan boards — create, update, move between lists, and archive.

## Quick Start

### 1. Set Credentials

**Option A: Session token (recommended)**
```bash
export WEKAN_TOKEN="<token>"
```

Get a token by logging in via the API:
```bash
curl -s -X POST "https://wekan.example.com/users/login" \
  -H "Content-Type: application/json" \
  -d '{"username":"you","password":"..."}' | jq -r .token
```

**Option B: Username/password env vars** (script logs in per command)
```bash
export WEKAN_USERNAME=your_user
export WEKAN_PASSWORD='your_password'
```

### 2. Create a Config File

```bash
cp .agents/skills/wekan-backlog/config.example.json .wekan-backlog-config.json
```

Edit `.wekan-backlog-config.json`:
```json
{
  "instance": "https://wekan.example.com",
  "boards": [
    {
      "board_id": "<17-char-board-id>",
      "board_name": "Platform Backlog Q1",
      "lists": ["Backlog", "In Progress", "Review", "Done"],
      "default_list": "Backlog"
    }
  ]
}
```

### 3. Find Board & List IDs

```bash
# List boards you have access to (board_id is in the output)
.agents/skills/wekan-backlog/scripts/wekan.sh boards

# List lists on a board
.agents/skills/wekan-backlog/scripts/wekan.sh lists --board "Platform Backlog Q1"
```

Board IDs also appear in the WeKan URL: `https://wekan.example.com/boards/<boardId>`.

## Usage with Pi Agent

Once configured, ask the pi agent:

- **"Add this task to our WeKan Q1 backlog"** — creates a card in the default list
- **"Move the auth refactor card to In Progress"** — moves it between lists (status change)
- **"Archive all done cards on the pipeline board"** — archives each card natively
- **"What's on our WeKan board?"** — lists cards grouped by list

## Config File Reference

| Field | Required | Description |
|---|---|---|
| `instance` | Yes | Base URL of the WeKan instance |
| `boards[].board_id` | Yes | 17-char board ID (from `wekan.sh boards` or the URL) |
| `boards[].board_name` | No | Human-readable name for matching and logging |
| `boards[].lists` | Yes | List names this skill may touch. All other lists are off-limits. |
| `boards[].default_list` | No | List used when creating a card without `--list`. Must be in `lists`. |

## Security

- **Credentials**: Never hardcoded or echoed. Read from `WEKAN_TOKEN`, or `WEKAN_USERNAME`/`WEKAN_PASSWORD` (login happens per command; password is never written to disk).
- **Whitelist**: Only boards and lists listed in config are accessible. All operations on unlisted boards/lists are rejected.
- **Dry-run**: Use `--dry-run` to preview changes without executing them.

## File Structure

```
.wekan-backlog-config.json          ← Live config (create this)
config.example.json                 ← Template
scripts/wekan.sh                    ← CLI tool
SKILL.md                            ← Pi skill instructions
README.md                           ← This file
```
