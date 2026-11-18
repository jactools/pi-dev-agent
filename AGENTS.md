# AI Agent Instructions

This repository follows specific rules that all AI agents must adhere to when making changes.

## Git Rules

### Only `git status` — NO OTHER GIT COMMANDS
Agents are **FORBIDDEN** to run any `git` command except `git status`.

**Allowed:**
- `git status` (the only permitted git command)

**Explicitly forbidden (all other git commands):**
- `git add` / `git reset` (staging/unstaging)
- `git diff` / `git diff --cached` (inspecting)
- `git log` / `git show` (reading history)
- `git commit`
- `git revert`
- `git reset --hard`
- `git merge`
- `git push`
- `git checkout`
- `git restore`
- **Any other `git` command**

**Rationale:** The user controls all git operations. Agents must never stage, inspect diffs, read history, or modify commit history. Use the `read` tool and `bash` to inspect files instead of `git diff`/`git show`.

### No Secrets/Certs/CAs in Git
Agents are **FORBIDDEN** to commit secrets, certificates, CA bundles, passwords, API keys, tokens, or any sensitive material to git.

**Allowed:**
- File references and placeholders where real values are injected at deploy time
- `.gitignore` entries that exclude sensitive files

**Explicitly forbidden:**
- Inline certificates (PEM blocks) in any file tracked by git
- Inline passwords, API keys, tokens, or secrets in any file tracked by git
- Embedding generated values (certs, keys, passwords) in version-controlled files

**Patterns to follow:**
- Store sensitive files outside git (e.g., `.env.*.local`) and reference them at deploy time
- Use environment variable injection at build/deploy time

## TypeScript / React Rules

### 1. Component Structure
- One component per file
- Co-locate styles, types, and small helpers with the component
- Extract shared logic into custom hooks (`use*.ts`)
- Extract shared types into `types/` directory

### 2. Naming Conventions
- Components: `PascalCase` (e.g., `DeliveryTable.tsx`)
- Hooks: `use*` camelCase (e.g., `useDeliveryStatus.ts`)
- Utilities: `camelCase` (e.g., `formatDate.ts`)
- Types/Interfaces: `PascalCase` (e.g., `DeliveryStatus`)
- Constants: `UPPER_SNAKE_CASE`

### 3. API Communication
- All API calls go through a centralized API client (`src/api/`)
- Use `snake_case` for all API request/response field names (matches backend)
- The React UI may display camelCase labels but must send/receive snake_case
- Never hardcode API URLs — use environment configuration

### 4. Testing
- Use Vitest for unit tests
- Use Playwright for E2E/UI tests
- Every significant UI change must have automated tests
- Test files co-located: `Component.test.tsx` next to `Component.tsx`

### 5. Styling
- Tailwind CSS for all styling
- No CSS modules or styled-components
- Use the design system components in `src/components/shared/`

## General Guidelines

### Environment
- Use `npx` or local `node_modules/.bin/` for all Node commands
- All paths are relative to the repository root
- Source environment from `.env.<env>.local` (sourced by build scripts)

### Dependencies — Never copy `node_modules` across platforms
- `node_modules/` is **platform-specific** (native optional deps such as `@esbuild/*` and `@rollup/rollup-*`) and must never be copied, synced, or baked between machines or into images/volumes. Always regenerate it on the target platform with `npm ci` so it stays reproducible from `package-lock.json`.
- A mismatched `node_modules` fails deep inside vite/vitest with cryptic "installed for another platform" errors. The guardrail in `scripts/check-native-deps.mjs` (wired into `pretest`, `predev`, and `prebuild`) detects this and fails fast — if it fires, run `rm -rf node_modules && npm ci` on the target machine.
- Do not commit or sync OS junk such as `.DS_Store`; these are gitignored.

### Shell Scripts — Bash 3.2 / POSIX Compatibility
Shell scripts must run on macOS's default `/bin/bash` (Bash 3.2) as well as Linux bash. Avoid features introduced in Bash 4.0+:

- `${var^^}` / `${var,,}` case conversion (use `tr '[:lower:]' '[:upper:]'`)
- associative arrays (`declare -A`)
- `readarray` / `mapfile`
- the `|&` redirection
- `**` globbing (globstar)
- `wait -n`, `coproc`

Bash 3.2 pitfalls that break at runtime (not caught by `bash -n`):

- Under `set -u`, expanding an empty array as `"${arr[@]}"` is a fatal "unbound variable" error on bash < 4.4 — always guard: `${arr[@]+"${arr[@]}"}`
- The guarded form must NOT be used in assignments: `local -a x=${arr[@]+"${arr[@]}"}` collapses to `local -a x=` when empty, which bash treats as an array with ONE empty element (the caller then receives a spurious `""` argument). Build the array explicitly instead:
  ```bash
  local -a x=()
  if [ "${#arr[@]}" -gt 0 ]; then x+=("${arr[@]}"); fi
  ```

Prefer POSIX-compatible syntax where it is equally clear. Since Linux may not be available for testing, validate with `bash -n` and ShellCheck (`--shell=bash --external-sources`), and always test scripts on macOS before merging.

### Environment Files
- `.env.dev.example` — committed template (no secrets)
- `.env.dev.local` — local overrides (gitignored, contains real values)
- Build scripts source `.env.<env>.local` if present, fall back to `.env.<env>.example`

### Diagrams
- **Never use text/ASCII diagrams** in markdown files.
- **Always use Mermaid diagrams** for any visual representation.
- Store `.mmd` and `.svg` files alongside documents in `images/` subdirectories.

### Timestamps
All timestamps must be in UTC.

## Document Store — Platform Knowledge Base

The platform document store indexes all Markdown documents and is searchable via REST API.

**Document types**: `IMPLEMENTATION_SUMMARY`, `IMPLEMENTATION_PLAN`, `LESSONS_LEARNED`, `DESIGN_DOC`, `RELEASE_NOTES`

**Auto-upload rule**: After creating any implementation summary, lessons learned, or plan document, upload it to the document store.

## WeKan Backlog Configuration

The WeKan backlog config to use is:

```
/Users/jacbeekers/gitrepos/docker-wekan/.wekan-backlog-config.json
```

It whitelists board `E2d2SQ43BAqwKt72C` ("Metadata Management") on
`https://wekan.dev.jac.dot:10443` (lists: Planned, In Progress, In Review, Done, Blocked).

**Config discovery (wekan extension):** set `WEKAN_CONFIG_PATH` to that file in pi's
launch environment. If it is not set, the extension falls back to
`~/config/wekan-backlog/config.json` (note: **no leading dot** — the discovery code
uses `$HOME/config/...`, even though the error message says `~/.config/...`). A
cwd-independent copy is kept there so the tools work across sessions. The `ca_cert`
in the fallback copy is an absolute path to
`platform-foundation/certs/dev/platform-dev-rootCA.pem`.

**Credentials (never commit):** the tools need `WEKAN_TOKEN`, or
`WEKAN_USERNAME` + `WEKAN_PASSWORD`, exported in pi's environment. Without them,
boards resolve as "NOT FOUND on instance".

## Repository Structure

```
├── src/                    # React source code
│   ├── api/               # API client
│   ├── components/        # React components
│   │   ├── shared/        # Design system / shared components
│   │   └── features/      # Feature-specific components
│   ├── hooks/             # Custom React hooks
│   ├── pages/             # Route-level components
│   ├── types/             # TypeScript types
│   └── utils/             # Utility functions
├── public/                # Static assets
├── nginx/                 # Nginx configuration for container
├── docs-site/             # Docusaurus documentation site
├── docs/                  # Implementation docs, summaries, lessons learned
│   ├── implementation/
│   │   └── summaries/
│   ├── lessons-learned/
│   └── development/
├── scripts/               # Build and dev scripts
│   ├── build_dev_images.sh
│   ├── calculate_versions.sh
│   └── dev_images.sh
├── Dockerfile
├── package.json
├── vite.config.ts
├── tsconfig.json
├── VERSION_MANIFEST.json
└── .env.dev.example
```

## Implementation Summaries

**Every significant implementation effort must be documented as an implementation summary.**

### Rules
- **Location:** `docs/implementation/summaries/`
- **Format:** Markdown (`.md`)
- **Naming:** `YYYY-MM-DD_<functional-descriptive-name>.md`
- **Content:**
  - Date and status
  - Objective and scope
  - Results
  - New files created
  - Known issues or remaining work
  - Next steps

### When to Generate
- After completing a significant architectural change
- When a feature or epic is marked as done
- After executing a refactoring plan

### Index
Always update the index table in `docs/implementation/summaries/README.md` when adding a new summary.

## Lessons Learned

**Significant issues, bugs, or discoveries must be documented as lessons learned.**

### Rules
- **Location:** `docs/lessons-learned/`
- **Format:** Markdown (`.md`)
- **Naming:** `YYYY-MM-DD_<descriptive-name>.md`
- **Content:**
  - Date
  - What happened
  - Root cause
  - Resolution
  - Prevention / takeaway
