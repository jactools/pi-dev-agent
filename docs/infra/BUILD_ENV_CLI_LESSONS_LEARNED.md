# Lessons Learned: Build/Env CLI Simplification (2026-11-12)

Retrospective on the work that started as a two-line bug report (`pi_dev_agent.sh build`
errors) and ended as a cross-repo rename of env files, flags, tests, and docs.
The expectation was "fix two errors"; the reality touched 15+ files. This document
records what happened, why it took longer than expected, and the rules to apply next time.

## What actually happened (three phases)

### Phase 1 — The reported bug

`./scripts/pi_dev_agent.sh build` failed with "Must specify --local or --corporate",
and `build --local` failed with "Unknown argument: --local".

Root cause: the wrapper's parser accepted exactly one positional command and rejected
everything after it, while delegating builds to a script that *requires* options.
The wrapper was a dead end for its own subcommand — there was no way to pass the mode through.

### Phase 2 — Fixing forwarding (and finding a latent bug)

While adding argument forwarding, testing revealed `build_pi_dev_images.sh` had never
supported value options: `--image base`, `--tag X`, and `--agent-version Y` all failed
with "Unknown option: <value>" because the parse loop consumed only the flag and let the
bare value hit the catch-all. A second parse loop that was supposed to handle values
referenced `$2` from a context with no positional parameters — it could never have worked.
Worse, `--tag`/`--agent-version` were parsed but silently never applied, even though the
usage text promised they would.

These options were documented in `IMPROVED_WORKFLOW.md` examples that had never been run.

### Phase 3 — The simplification (the expensive part)

The actual requirement turned out to be: "I only ever use `--env dev|test|prod` and
`--local/--corporate`; drop everything else." That is a *shrink*, not an extension — but it
cost more than Phase 1+2 combined, because the env-file naming was load-bearing:

- Renaming `.env.pi-dev.{local,corporate}(.example)` to `.env.{dev,test,prod}` touched
  `.gitignore` patterns, three templates (two renamed, one new), and the user's live file.
- Four test suites referenced the old filenames/flags in fixtures and assertions.
- ~6 docs plus hint strings inside *unrelated* scripts (`pi_multi_agent.sh`,
  `setup_multi_agent.sh`) printed the old invocations.
- A pre-existing, locale-dependent failure in `test_pi_dev_env_templates.sh` surfaced only
  after the refactor (see Lesson 5) and had to be triaged as "not my change".

## Why it was harder than expected

1. **The fix grew before the requirement shrank.** Phase 2 built forwarding for five
   options (`--local/--corporate`, `--image`, `--tag`, `--agent-version`) plus tests —
   all of which Phase 3 deleted. The generic plumbing was never used by anyone.
2. **A rename's blast radius is its references, not the file.** Every echo string, doc
   example, gitignore pattern, and test fixture that mentioned the old name had to be found
   and updated; several lived in files nobody would think to check.
3. **Latent bugs masqueraded as working features.** Documented examples were untested, so
   "it's documented" was mistaken for "it works".
4. **Green assumptions hid a red baseline.** One test suite had been failing on this machine
   all along (locale), which threatened to be misattributed to the refactor.

## Lessons and rules for next time

### 1. Ask what is actually run before building generic plumbing

The whole CLI surface in use was two flags. If "which invocations do you actually type?"
had been asked first, Phases 2's forwarding logic and its tests would not have existed to be
deleted an hour later. **Rule: implement to observed usage; treat every extra option as a
liability that must justify itself.**

### 2. A wrapper must decide up front whether it forwards or re-declares options

`pi_dev_agent.sh` accepted one positional and rejected the rest, then delegated to a script
with its own required flags — an impossible composition. **Rule: when wrapping a script with
its own CLI, either forward unknown args explicitly (and test the forwarding) or re-declare
the options in the wrapper; never silently drop them.**

### 3. Every documented example is a test case

`--local --image base` was in the docs and broken for as long as the parse loop existed.
**Rule: if an invocation appears in usage text or docs, a regression test must execute it —
preferably against fakes, so it runs everywhere.** (The fake-`docker` fixture pattern made
this cheap; use it.)

### 4. Grep for all references *before* renaming anything user-facing

The rename touched `.gitignore`, templates, four test suites, six docs, and hint strings in
two unrelated scripts. **Rule: before any rename of a file/flag/env var, run one repo-wide
grep for the old name (including `--`-prefixed forms) and treat the hit list as the work
estimate.** Hint messages inside `echo` statements are the classic long tail.

### 5. Establish a test baseline *before* starting; pin locales in tests

`test_pi_dev_env_templates.sh` failed on this machine before any change because `comm` used
the ambient locale (`en_NZ.UTF-8`) while its inputs were sorted with `LC_ALL=C`. It only
surfaced after the refactor and had to be proven pre-existing via `git stash`. **Rules: run
all related suites first and record failures; in any test that sorts or compares text, pin
`LC_ALL=C` on *both* the sort and the comparison.**

### 6. Copy error-message assertions verbatim

Two new assertions failed on first run because `assert_line` is an exact full-line match and
the expected strings omitted the `ERROR:` prefix / trailing detail. **Rule: when asserting
error output, copy the exact line from the script (or use substring matching for long messages).**

### 7. For large multi-line doc edits, verify text programmatically

Two edit attempts failed on invisible line-wrap differences in heredoc-style blocks; a small
Python replacement that asserts each old string occurs exactly once was faster and safer.
**Rule: for big prose blocks, extract the exact region first (or script the replacement with
occurrence-count assertions) instead of retyping it from memory.**

### 8. `git stash`/`pop` can split index state; verify after

Using `git stash` to test a baseline left staged renames half-restored (new files staged as
adds, deletions unstaged), breaking rename detection until re-`git add`. **Rule: after any
stash/pop cycle, check `git status --short`; for baseline comparisons prefer `git worktree`
or reading the committed version directly.**

### 9. Keep orthogonal axes orthogonal

The old design conflated source policy (`--local`/`--corporate`) with file selection (the
mode *implied* which env file). Separating them — mode = registry/source defaults, `--env` =
which machine's values — removed the implicit coupling at the cost of one more required flag.
**Rule: when a flag silently selects two things (policy + data source), split it; explicit is
cheaper than surprising.**

### 10. Keep validation in one place, but validate what you need locally

The wrapper forwards mode flags to the build script instead of re-validating them (single
source of error messages), while validating `--env` itself because compose commands also need
the file — then passes its validated value down. **Rule: forward what a callee already
validates; only validate in the caller what the caller itself consumes.**

## What worked well

- **Fake-binary fixtures** (fake `docker`, fake build script) let every suite run without
  Docker, credentials, or network — including exact argument-forwarding assertions.
- The existing test structure (`assert_line`, per-case fixture dirs, `bash -n` gates) was
  easy to extend; the new forwarding suite followed it directly.
- Making both flags **required with no defaults** (matching the repo's existing "no defaults
  allowed" stance for build mode) removed an entire class of "which file did I load?" bugs.

## Open items / known gaps

- `.env.dev` (renamed from `.env.pi-dev.local`) still lacks `GITREPOS_HOST_PATH`, so
  compose commands (`start`, `config`, ...) will fail with "Set GITREPOS_HOST_PATH" until it
  is added. Pre-existing, not introduced by this change.
- Historical docs intentionally left stale: `docker/pi-dev-base/MIGRATION_SUMMARY.md`,
  `PHASE_3_RESULTS.md`, and `doc/migrate-to-pi-dev-core-base.md` still reference the old
  filenames/flags as point-in-time records.
- `.env.test.example` is currently a copy of the prod (corporate) template; adjust its
  contents if the test environment's registry policy differs.
