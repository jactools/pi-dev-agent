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
  "instance": "https://wekan.dev.jac.dot:10443",
  "ca_cert": "../platform-foundation/certs/dev/platform-dev-rootCA.pem",
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
| `instance` | Yes | Base URL of the WeKan instance (e.g., `https://wekan.dev.jac.dot:10443`) |
| `ca_cert` | No | PEM bundle for a private CA, used as curl `--cacert`. Relative paths resolve against the config file's directory. Required when the instance uses a self-signed/local-CA cert (e.g., Platform Dev Root CA). |
| `boards[].board_id` | Yes | Board ID. Find it via `wekan.sh boards` or the board URL (the id is in the URL) |
| `boards[].board_name` | No | Human-readable name for matching and logging |
| `boards[].lists` | Yes | Array of list names this skill may create/move/archive cards within. All other lists are off-limits. |
| `boards[].default_list` | No | List used when creating a card without an explicit `--list`. Must be one of `lists`. |

## Connectivity from Inside the pi-dev-agent Container

WeKan runs in the **kind dev cluster** behind ingress-nginx. It is NOT reachable via cluster DNS (`wekan:8080`) and NOT on `127.0.0.1`/localhost — those only work *inside* the cluster or on the host machine. Do not "fix" the instance URL to either of those.

The working path (already wired up in this repo) — WeKan goes **through squid**, not direct:

```
pi-dev-agent container ──HTTPS_PROXY──> squid (172.31.0.2:3128)
                                         │  squid.conf allows EXACTLY wekan.dev.jac.dot:10443
                                         │  (extra_hosts on the proxy service maps the FQDN to
                                         │   host-gateway for squid's own resolution)
                                         ▼
                                       kind node — published port 10443 -> ingress-nginx :443
                                         │  SNI/Host wekan.dev.jac.dot routes to platform-wekan/wekan:8080
                                         ▼
                                       WeKan pod
```

- **Egress (squid-routed, on purpose)**: The container enforces strict egress (default-DROP iptables); the only outbound paths are squid plus a few direct exceptions (`PI_DEV_AGENT_DIRECT_ALLOW_HOSTS`). WeKan is deliberately NOT in that list — a direct rule for the kind node's published port 10443 would reach **every** ingress frontend on the cluster, not just WeKan. Instead, `.dev.jac.dot` is absent from NO_PROXY so curl sends WeKan through squid, where an exact host:port ACL (`wekan_host wekan_port`) permits only `wekan.dev.jac.dot:10443`. TLS stays end-to-end (CONNECT tunnel, no MITM).
- **DNS**: Resolution happens inside the **squid** container, which has `extra_hosts: - wekan.dev.jac.dot:host-gateway` (Docker Desktop otherwise syncs the host `/etc/hosts` entry where the FQDN maps to 127.0.0.1). If WeKan suddenly fails with a DNS error in the proxy log (`docker logs pi-dev-agent-pi-dev-agent-proxy-1`), check that entry on the proxy service.
- **TLS**: The instance cert is signed by *Platform Dev Root CA*. `wekan.sh` reads the config's `ca_cert` field and passes it to curl as `--cacert`. On SSL verify errors: check that `ca_cert` exists (relative paths resolve against the config file's directory). Canonical copy: `platform-foundation/certs/dev/platform-dev-rootCA.pem`; in-cluster source of truth: `kubectl get cm -n platform-tls platform-root-ca -o jsonpath='{.data.rootCA\.pem}'`.
- **Credentials**: `WEKAN_TOKEN` lives in `docker-wekan/.env.dev.local`. Run `wekan.sh` from that repo (or any CWD whose git root contains the file) and it is loaded automatically. Never echo token values.

Quick connectivity check after startup:

```bash
wekan.sh boards   # "Metadata Management" should show as live, not NOT FOUND/Forbidden
```

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

## Swimlanes

Boards can be split into multiple **swimlanes** — horizontal lanes that each get their own copy of the columns. The `Metadata Management` board uses one lane per repo (`WeKan`, `dq-made-easy`, `metadata-as-a-service`, ...), so *which lane a card lands in matters* as much as which list it does.

- **Discover lanes**: `wekan.sh swimlanes --board <name|id>` — prints each lane's name and 17-char id.
- **Create into a specific lane**: pass `--swimlane <name|id>` to `create`. On multi-lane boards this is **required** — the script refuses to guess (it lists the available lanes) instead of silently filing the card in the wrong repo's lane. Single-lane boards default to their only lane.
- **List a whole board**: plain `wekan.sh list --board <name|id>` on a multi-lane board prints one section **per lane** — never loop over lanes yourself, and never assume all cards live in one column set.
- **Filter a listing by lane**: pass `--swimlane <name|id>` to `list` to see one lane only.

### Why lane handling is non-trivial (read before debugging)

Multi-lane boards keep **their own copy of every column per lane** — a 7-lane board with 5 columns has 35 lists, and the API's list documents do NOT say which copy belongs to which lane (`GET /api/boards/:id/lists` returns only `_id/title/modifiedAt/cardsModifiedAt`, in consecutive runs grouped by lane). The script reconstructs the mapping: any non-empty list anchors its whole run to a lane via the cards' `swimlaneId`. Consequences:

- A lane with **zero cards anywhere** cannot be anchored; it still lists correctly (all columns show 0), and `create` into such a lane works by elimination when unambiguous — otherwise it fails loudly rather than guessing. If you hit that error, create the lane's first card via the WeKan UI.
- Card title search (`update --card <title>`, `archive --card <title>`) searches **all lanes' copies** of every column.

```bash
wekan.sh swimlanes --board "Metadata Management"
#   - ID: qAoDzgY7TFEyqGk5B | Name: WeKan
#   - ID: p7B3EfPmY3xVhtnrY | Name: metadata-as-a-service
#   ...

wekan.sh create --board "Metadata Management" --list "Planned" \
  --swimlane "metadata-as-a-service" --title "Add new endpoint"

wekan.sh list --board "Metadata Management"            # all lanes, one section each
wekan.sh list --board "Metadata Management" --swimlane platform-foundation   # one lane only
```

## Operations

All commands go through `scripts/wekan.sh` (resolve relative to this skill directory).

### Create a Card

Add a new backlog item (card) to a board list.

```bash
wekan.sh create --board <name|id> --title "Task title" \
  [--list "Backlog"] [--swimlane <name|id>] [--description "..."] [--label "triage"] [--dry-run]
```

- `--list` defaults to the board's `default_list` from config
- The list must be in the board's allowed `lists`
- On multi-lane boards, `--swimlane <name|id>` selects the lane (required — see [Swimlanes](#swimlanes))
- Reports the new card ID and URL on success

### Update a Card

Change a card's title, description, labels, or move it between lists (status change).

```bash
wekan.sh update --board <name|id> --card <card-id-or-url> \
  [--title "..."] [--description "..."] [--list "In Progress"] \
  [--swimlane <name|id>] [--add-label "x"] [--remove-label "y"] [--dry-run]
```

- Moving to a list = status change (e.g., Backlog → In Progress)
- Target list must be in the board's allowed `lists`
- On multi-lane boards, `--list` targets the copy of that column **in the card's own lane** by default; pass `--swimlane <name|id>` to move it cross-lane

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
wekan.sh list --board <name|id> [--list "Backlog"] [--swimlane <name|id>]
```

- On multi-lane boards without `--swimlane`, output is grouped **per lane** (one section per swimlane, columns in config order) — this is the correct way to get a board-wide overview.
- With `--swimlane <name|id>`, only that lane's cards are shown.
- Note: the v12.x per-list API only returns non-archived cards, so archived items don't appear here. To work with an archived card, use its ID directly (e.g., `archive --unarchive`).

### Show Card Details

Retrieve and display complete information about a specific card.

```bash
wekan.sh show --board <name|id> --card <id|url|title>
```

- `--card` accepts a WeKan card ID, full card URL, or (partial, case-insensitive) card title
- Returns the card's metadata:
  - **Title** and **description**
  - **Status** (which list the card is in)
  - **Swimlane** (on multi-lane boards)
  - **Labels** (assigned tags/categories)
  - **Archived** state
  - **Created/Modified** timestamps
- Works on both active and archived cards
- Board membership is verified — the card's `boardId` must match a whitelisted board

**Example:**

```bash
wekan.sh show --board "Platform Backlog Q1" --card abc123def456
```

### Discover Boards & Lists

Find board IDs and list names to fill in the config:

```bash
wekan.sh boards           # List boards you have access to (id + name)
wekan.sh lists --board <name|id>    # List lists on a board
wekan.sh swimlanes --board <name|id>  # List swimlanes on a board (name + id)
```

## API Model (WeKan CE v12.x)

Verified against WeKan CE v12.75 — the script targets this surface, not the older `/api/v2` docs:

- **Auth**: `Authorization: Bearer <token>` on all `/api/*` routes. There is no `/api/v2` prefix and no `X-User-Token` header in v12.x.
- **Responses are flat** objects/arrays — no `{"data": ...}` wrapper.
- **Swimlanes**: `GET /api/boards/:bid/swimlanes` returns a bare array of `{_id, title}`. Card creation REQUIRES `swimlaneId` in the body; card documents carry their own `swimlaneId`. Multi-lane boards keep **one copy of each column per lane** (N lanes × M columns = N×M lists), and list docs do NOT expose their lane — only cards do. The script reconstructs the list→lane mapping from `/lists` response order (consecutive runs per lane) anchored by card `swimlaneId`s, so every command operates on the correct lane's column copy. The script resolves `--swimlane <name|id>` against the board's lanes and refuses to guess on multi-lane boards.
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
| Swimlane not found / ambiguous | Show the available lanes (the script already lists them) and ask which one was meant — never guess on multi-lane boards. |
| Network error | Retry once with a short delay, then report. |

## Config Discovery Order

1. `$WEKAN_CONFIG_PATH` (explicit override)
2. `<repo-root>/.wekan-backlog-config.json` — git toplevel of the CWD; falls back to the CWD itself when git is not installed (it isn't in the pi-dev-agent container, so run `wekan.sh` from the repo that holds the config, e.g. `docker-wekan/`)
3. `~/.config/wekan-backlog/config.json`
4. Skill's `config.example.json` (template only — warn if used as live config)

## Example Interactions

### User: "Add this task to our WeKan Q1 backlog"
→ Find matching board in config → if the board has multiple swimlanes, ask which lane (or infer from context) → create card in default list with `--swimlane` → report card URL

### User: "Move the auth refactor card to In Progress"
→ Find card by title match on the whitelisted board → move it to the "In Progress" list (must be allowed)

### User: "Archive all done cards on the pipeline board"
→ List cards in "Done" → archive each one → report count and IDs

### User: "What's on our WeKan board?"
→ `wekan.sh list --board <name>` → display cards grouped by list

### User: "Show me the details of this card"
→ Resolve the card by ID or title → display title, description, list, swimlane, labels, timestamps, and archived state

## Important Notes

- Always confirm destructive actions (archiving many cards at once) with the user before executing.
- When a card title is ambiguous, list candidates and ask which one to act on — never guess across boards.
- If the user names a board that isn't in config, list available boards and ask them to choose or update the config.
