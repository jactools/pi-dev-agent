# Implementation Summary: Repo Dependency Bundles (target-platform node_modules for bind-mounted repos)

**Date**: 2026-11-15  
**Status**: Complete — verified in the live agent container

## Objective and Scope

Make the `platform-pi-dev-agent` image able to run Node tooling (vitest/vite/eslint) inside
bind-mounted repositories whose `node_modules` was installed on the host's platform.
First target: `dq-made-easy-ui`, where vitest failed in the linux/arm64 container because
the mounted tree only contained darwin-arm64 native optional deps.

Constraints that shaped the design:

- **AGENTS.md rule (dq-made-easy-ui)** — never copy/sync/bake a host `node_modules` across
  platforms; always regenerate it on the target platform with `npm ci` so it stays
  reproducible from `package-lock.json`.
- The agent container has **no runtime package installation** (`apt`/`dpkg` purged) and
  restricted egress (squid blocks `.npmjs.org`; only `jacloud.site` is allowed), so an
  in-container `npm ci` against the public registry is not possible.
- The host Mac must keep working: whatever the container does to a bind-mounted repo must
  not break local `npm run dev` / vitest on macOS.

## Results

| Scenario | Before | After |
|---|---|---|
| `node scripts/check-native-deps.mjs` in container | exit 1 (`found: rollup-darwin-arm64`) | `OK (linux-arm64)` |
| `npx vitest run` (3 files, dq-made-easy-ui) in live container | blocked by platform mismatch | **3 files passed, 40/40 tests passed** (~700 ms) |
| Host Mac dev after container start | — | unaffected: darwin + linux optional deps coexist; `check-native-deps` still `OK (darwin-arm64)` |
| Root-owned files on host bind mount | n/a | none — added packages chowned to the host repo owner (501:20) |

The runtime merge is additive and idempotent: the first start copied exactly 5 packages
(`@esbuild/linux-arm64`, `@parcel/watcher-linux-arm64-glibc`, `@rollup/rollup-linux-arm64-gnu`,
`@tailwindcss/oxide-linux-arm64-gnu`, `lightningcss-linux-arm64-gnu`); subsequent starts log
"already complete for this platform; nothing to add".

## Changes (all in the pi-dev-agent repo)

### `scripts/build_pi_dev_images.sh`

New `stage_repo_dep_manifests()` step, run before the agent image build: copies only
`package.json` + `package-lock.json` from `$GITREPOS_HOST_PATH/dq-made-easy-ui` into
`docker/pi-dev-agent/repo-deps/dq-made-easy-ui/`. Fails fast with actionable errors when
`GITREPOS_HOST_PATH` is unset, the checkout is missing, or either manifest is absent.

### `docker/pi-dev-agent/Dockerfile.pi-dev-agent`

New **Repo dependency bundles** section (placed after all heavy install layers so editing it
never invalidates the npm/playwright cache):

- `COPY` of the two staged manifests into `/usr/local/pi-dev/repo-deps/dq-made-easy-ui/`
- `RUN --mount=type=secret,id=npmrc,required=false … && npm ci --no-audit --no-fund` —
  installs all 330 packages **for the image's own architecture** (linux/arm64 in local
  builds), reproducibly from the lockfile. The secret is only used as a scoped
  `NPM_CONFIG_USERCONFIG` for that one RUN; it is never copied into an image layer, so no
  credentials are baked in. Local builds use the default registry; corporate builds resolve
  through the existing `npmrc` BuildKit secret (jacloud.site).

### `docker/pi-dev-agent/entrypoint.sh`

New `sync_repo_node_modules()` function, called after shared-venv population:

- Iterates every bundle under `/usr/local/pi-dev/repo-deps/*/` (overridable via
  `PI_DEV_AGENT_REPO_DEPS_DIR` for testing) — new repos need no entrypoint changes.
- **Staleness guard**: compares sha256 of the baked `package-lock.json` with the mounted
  repo's; on mismatch it warns and skips (rebuild the image, or `npm ci` in-container when
  registry access exists).
- If the repo has no `node_modules`: copies the full baked tree. Otherwise **additive merge**:
  only top-level entries (and `@scope/*` children) missing from the mounted tree are copied —
  never deletes or overwrites host files, so both platforms' optional deps coexist and each
  tool loads only its own at runtime.
- Added packages are chowned to match the host repo's uid/gid (`stat -c '%u %g'`), so later
  host-side `npm ci` / `rm -rf` is not blocked by root-owned files on the bind mount.

### `.gitignore`

Ignores `docker/pi-dev-agent/repo-deps/` — staged manifests are build inputs, never committed.

### `docs/infra/PI_DEV_AGENT_IMAGE.md`

New "Repo dependency bundles" section documenting build-time staging, runtime merge
semantics, staleness behavior, and how to bake another repo; image-contract bullet added.

## New Files Created

- `docs/implementation/summaries/2026-11-15_repo-dependency-bundles-for-vitest.md` (this file)
- `docs/lessons-learned/2026-11-15_platform-specific-node-modules-in-agent-container.md`
- `docker/pi-dev-agent/repo-deps/dq-made-easy-ui/{package.json,package-lock.json}` — staged at
  build time only; gitignored

## Known Issues / Remaining Work

- **Corporate builds**: jacloud.site verdaccio is private-only (no npmjs proxying), so the
  full dq-made-easy-ui dependency tree must be published internally before a `--corporate`
  agent build can complete. Local mode uses the public registry and works as-is.
- **Staleness is manual**: after any dependency change in dq-made-easy-ui, the image must be
  rebuilt (the entrypoint warns loudly but does not auto-install).
- Only `dq-made-easy-ui` is baked today; other repos with platform-specific native deps are
  not yet covered.

## Next Steps

- Bake additional repos when they need in-container Node tooling (one staging call + one
  COPY/`npm ci` pair each — see the doc section "Extending").
- Publish the dq-made-easy-ui dependency tree to jacloud.site verdaccio for corporate parity.
- Consider a build-time check that fails fast if a staged manifest is older than the repo's
  HEAD (today the runtime staleness warning covers this).
