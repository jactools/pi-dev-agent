---
name: wekan-backlog
description: Create, update, and archive cards on WeKan kanban boards (backlog items). Use when managing WeKan boards, moving cards between lists/columns, triaging backlog work tracked in WeKan, or archiving completed cards. Requires a whitelisted board config — never act on an unlisted board.
---

# WeKan Backlog Skill

You are the **WeKan Backlog Manager**. You create, update, and archive cards (backlog items) on WeKan boards using its REST API via `scripts/wekan.sh`.

## Security & Safety Rules

1. **Credentials**: Never hardcode or echo usernames, passwords, or tokens. The script reads them only from environment variables at runtime:
   - `WEKAN_TOKEN` — a pre-obtained session token (preferred), OR
   - `WEKAN_USERNAME` + `WEKAN_PASSWORD` — used to log in and obtain a token per command
2. **Whitelist enforcement**: Before performing ANY operation, verify the target board exists in the config file. Reject operations on boards not listed in the config.
3. **List scope**: Only create/move/archive cards within lists allowed for each board in the config. Do not touch other lists or boards.
4. **Dry-run first**: When uncertain, run with `--dry-run` to show what would happen without making changes.

## Configuration

The skill reads its configuration from a JSON file located at:

```
.wekan-backlog-config.json
```

in the repo root (or override the path with `WEKAN_CONFIG_PATH`).

### Config File Format

```json
{
  "instance": "https://wekan.example.com",
  "boards": [
    {
      "board_id": "abc123def456...",
      "board_name": "Platform Backlog Q1",
      "lists": ["Backlog", "In Progress", "Review", "Done"],
      "default_list": "Backlog"
    },
    {
      "board_id": "xyz789ghi012...",
      "board_name": "Data Pipeline Sprint",
      "lists": ["Todo", "Doing", "Blocked", "Done"],
      "default_list": "Todo"
    }
  ]
}
```

### Config Fields

| Field | Required | Description |
|---|---|---|
| `instance` | Yes | Base URL of the WeKan instance (e.g., `https://wekan.example.com`) |
| `boards[].board_id` | Yes | Board ID. Find it via `wekan.sh boards` or the board URL (the id is in the URL) |
| `boards[].board_name` | No | Human-readable name for matching and logging |
| `boards[].lists` | Yes | Array of list names this skill may create/move/archive cards within. All other lists are off-limits. |
| `boards[].default_list` | No | List used when creating a card without an explicit `--list`. Must be one of `lists`. |

## Credential Setup

### Option A: Session token (recommended)

Log in once via the WeKan UI or API and export the token:

```bash
export WEKAN_TOKEN="<token from login response>"
```

You can obtain a token with:
```bash
curl -s -X POST "$INSTANCE/users/login" \
  -H "Content-Type: application/json" \
  -d '{"username":"you","password":"..."}' | jq -r .token
```
The login response is flat: `{"id": ..., "token": ..., "tokenExpires": ...}`.

### Option B: Username/password env vars

```bash
export WEKAN_USERNAME=your_user
export WEKAN_PASSWORD='your_password'
```

The script logs in per command and uses the returned token for that invocation only. The password is never written to disk or echoed.

## Operations

All commands go through `scripts/wekan.sh` (resolve relative to this skill directory).

### Create a Card

Add a new backlog item (card) to a board list.

```bash
wekan.sh create --board <name|id> --title "Task title" \
  [--list "Backlog"] [--description "..."] [--label "triage"] [--dry-run]
```

- `--list` defaults to the board's `default_list` from config
- The list must be in the board's allowed `lists`
- Reports the new card ID and URL on success

### Update a Card

Change a card's title, description, labels, or move it between lists (status change).

```bash
wekan.sh update --board <name|id> --card <card-id-or-url> \
  [--title "..."] [--description "..."] [--list "In Progress"] \
  [--add-label "x"] [--remove-label "y"] [--dry-run]
```

- Moving to a list = status change (e.g., Backlog → In Progress)
- Target list must be in the board's allowed `lists`

### Archive a Card

Archive a completed card. WeKan supports native card archiving, so this is always safe — no open-item restrictions like GitHub PRs have.

```bash
wekan.sh archive --board <name|id> --card <card-id-or-url> [--dry-run]
```

- Sets `archived: true` on the card (it disappears from the board but remains recoverable in WeKan)
- Use `--unarchive` to restore a previously archived card

### List / Query Cards

Show what's on a board, optionally filtered by list.

```bash
wekan.sh list --board <name|id> [--list "Backlog"]
```

Note: the v12.x per-list API only returns non-archived cards, so archived items don't appear here. To work with an archived card, use its ID directly (e.g., `archive --unarchive`).

### Discover Boards & Lists

Find board IDs and list names to fill in the config:

```bash
wekan.sh boards          # List boards you have access to (id + name)
wekan.sh lists --board <name|id>   # List lists on a board
```

## API Model (WeKan CE v12.x)

Verified against WeKan CE v12.75 — the script targets this surface, not the older `/api/v2` docs:

- **Auth**: `Authorization: Bearer <token>` on all `/api/*` routes. There is no `/api/v2` prefix and no `X-User-Token` header in v12.x.
- **Responses are flat** objects/arrays — no `{"data": ...}` wrapper.
- **Card create** (`POST /api/boards/:bid/lists/:lid/cards`) requires `swimlaneId` in the body. v12.x list/board docs don't expose it, so the script takes the first swimlane from `GET /api/boards/:bid/swimlanes` (backlog boards use the single "Default" swimlane).
- **Card lookup by id**: `GET /api/cards/:cardId` returns the full document (incl. `listId`, `archived`, `labelIds`) and works for archived cards too — per-list endpoints hide archived ones and omit those fields. The script verifies `.boardId` matches the whitelisted board.
- **Move/update** = `PUT /api/boards/:bid/lists/<current-list>/cards/:cid` with `{title?, description?, listId?, rank?}`.
- **Archive/unarchive** = `POST .../cards/:cid/archive|unarchive` (not a PUT of an `archived` flag).
- **Labels are embedded in the board document** (`board.labels[]`). Create/get-or-create via `PUT /api/boards/:bid/labels` with `{label: {name, color}}` — colors are named values (`sky`, `red`, `green`, ...), not hex. Assign/remove via `POST /api/boards/:bid/cards/labels` with `{cardIds, addLabelIds, removeLabelIds}`. Label changes require board-admin rights.
- **Card labels** live in the card's `labelIds` array (not `labels`).

## Error Handling

| Error | Action |
|---|---|
| Board not in config | Reject immediately. Show which boards ARE configured and ask the user to update the config if needed. |
| List not allowed for board | Reject. Tell the user which lists are allowed for that board. |
| No credentials found | Suggest setting `WEKAN_TOKEN` or `WEKAN_USERNAME`/`WEKAN_PASSWORD`. Never print credential values. |
| 401 / invalid token | Token expired or wrong — ask user to refresh `WEKAN_TOKEN` or check username/password env vars. |
| 403 | User lacks permission on that board/list — report and stop. |
| Card not found | Verify the card ID/URL belongs to a whitelisted board; suggest `wekan.sh list`. |
| Network error | Retry once with a short delay, then report. |

## Config Discovery Order

1. `$WEKAN_CONFIG_PATH` (explicit override)
2. `<repo-root>/.wekan-backlog-config.json`
3. `~/.config/wekan-backlog/config.json`
4. Skill's `config.example.json` (template only — warn if used as live config)

## Example Interactions

### User: "Add this task to our WeKan Q1 backlog"
→ Find matching board in config → create card in default list ("Backlog") → report card URL

### User: "Move the auth refactor card to In Progress"
→ Find card by title match on the whitelisted board → move it to the "In Progress" list (must be allowed)

### User: "Archive all done cards on the pipeline board"
→ List cards in "Done" → archive each one → report count and IDs

### User: "What's on our WeKan board?"
→ `wekan.sh list --board <name>` → display cards grouped by list

## Important Notes

- Always confirm destructive actions (archiving many cards at once) with the user before executing.
- When a card title is ambiguous, list candidates and ask which one to act on — never guess across boards.
- If the user names a board that isn't in config, list available boards and ask them to choose or update the config.
