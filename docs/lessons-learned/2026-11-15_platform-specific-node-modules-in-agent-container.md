# Lessons Learned — Platform-Specific node_modules in Bind-Mounted Repos (Agent Container)

**Date**: 2026-11-15  
**Topic**: vite/vitest failing inside the linux/arm64 pi-dev-agent container because a bind-mounted repo's `node_modules` was installed on macOS; and how to fix it without breaking host development  
**Related**: `docker/pi-dev-agent/Dockerfile.pi-dev-agent`, `docker/pi-dev-agent/entrypoint.sh`, `scripts/build_pi_dev_images.sh`, `dq-made-easy-ui/scripts/check-native-deps.mjs`

## What Happened (Symptom)

Running vitest for `dq-made-easy-ui` inside the pi-dev-agent container failed. The repo's
own guardrail (`pretest` → `node scripts/check-native-deps.mjs`) caught it and exited 1:

```
✖ node_modules was installed for a different platform than this one.
  @esbuild: expected @esbuild/linux-arm64
    found:      darwin-arm64
  @rollup:  expected @rollup/rollup-linux-arm64-gnu or -musl
    found:      rollup-darwin-arm64
```

Without the guardrail, the failure would have surfaced deep inside vite/vitest as a cryptic
"was installed for another platform" stack trace. The container could not simply run
`npm ci`: it has no package manager (purged on purpose) and egress to `.npmjs.org` is
blocked by the squid sidecar — only `jacloud.site` is reachable, and that registry is
private-only.

## Root Cause

`node_modules/` is platform-specific: native optional deps (`@esbuild/*`,
`@rollup/rollup-*`, `lightningcss-*`, `@tailwindcss/oxide-*`, `@parcel/watcher-*`) are
installed per OS/arch via npm's optionalDependencies. The agent container bind-mounts the
host checkout, so it inherits whatever platform installed that tree — darwin-arm64 on the
Mac, useless in a linux/arm64 image.

The tempting quick fixes were both wrong:

- **Copy the macOS `node_modules` into the image/container** — violates the AGENTS.md rule
  (never copy node_modules across platforms; regenerate with `npm ci`) and bakes host state
  into an artifact, so it silently rots on every dependency change.
- **Replace the mounted tree in-container** — "fixes" the container but breaks development
  on the Mac until someone re-runs `npm ci` there (and a crash mid-swap leaves the repo in
  a worse state).

## Resolution

Regenerate on the target platform at **image build time**, then merge additively at runtime:

1. The build script stages only `package.json` + `package-lock.json` from the host checkout;
   the Dockerfile runs `npm ci` inside the build, so every binary matches the image's own
   architecture (330 packages for linux/arm64). Manifests are inputs; no node_modules is
   ever copied.
2. The entrypoint merges whatever is missing from that baked tree into each mounted repo's
   `node_modules` — **additively only**: it never deletes or overwrites host files, so both
   platforms' optional deps coexist and each tool loads only its own at runtime. Host dev
   keeps working unchanged.

Design details that mattered:

- **Ownership on bind mounts.** Files copied into a bind mount run as root are root-owned
  *on the host*; later `rm -rf node_modules` / `npm ci` from the Mac would then fail with
  EACCES inside root-owned subdirectories. The entrypoint chowns everything it adds to the
  repo directory's uid/gid (501:20 here). Rule: anything a container writes into a bind
  mount must preserve host ownership.
- **Staleness guard.** The baked bundle carries the lockfile it was built from; the
  entrypoint compares sha256 and skips with a loud warning on mismatch instead of silently
  installing packages for an outdated tree.
- **Don't hardcode package lists.** npm's libc-aware optional-dep resolution installed only
  the `-gnu` variants on this glibc system (not `-musl`). Letting `npm ci` decide — and
  merging "whatever is missing" generically — stays correct as deps change.
- **Verify corepack behavior before relying on it.** The repo pins `"packageManager":
  "npm@11.14.1"`; in this image stack the global npm (12.x) is not hijacked by that field,
  so a plain `npm ci` is deterministic across local/corporate builds.

## Prevention / Takeaway

- **"Regenerate on the target platform" means running `npm ci` inside an image build for
  that architecture** — with manifests as the only input from the host. That satisfies both
  reproducibility (lockfile-driven) and correctness (native binaries match).
- **When two platforms share state through a bind mount, prefer additive over destructive.**
  Replacement fixes one side by breaking the other; coexisting platform-specific optional
  deps are harmless because each runtime loads only its own.
- **Cheap read-only guardrails pay for themselves.** `check-native-deps.mjs` (wired into
  `pretest`/`predev`/`prebuild`) turned a deep, cryptic vite failure into an immediate,
  actionable error — and it is what told us the fix worked (`OK (linux-arm64)` in-container,
  `OK (darwin-arm64)` on the Mac).
- **Unit-test shell functions against simulated trees before shipping them.** A pre-build
  test of `sync_repo_node_modules()` caught a real bug: the scoped-package branch tested
  `-d "$entry"` with a bare name instead of the absolute path, which would have silently
  skipped *every* `@scoped` package (exactly the platform-specific ones) in production.
  `bash -n` and ShellCheck never catch that class of error.
