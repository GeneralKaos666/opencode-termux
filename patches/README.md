# Patches for OpenCode Android support

> NOTE (deprecated appendix): the `build-pure-android.yml` glibc-wrapper line is
> deprecated. Mainline is the native transplant pipeline
> (`.github/workflows/build-native-android.yml`, `make transplant VER=...`,
> see `docs/transplant.md`). This directory now only carries the active
> `opentui/` patches. The legacy top-level `0001/0002` patches were removed
> (failing Job: corrupt/truncated + wrong target repo, see below).

These patches modified the upstream OpenCode source (`github.com/anomalyco/opencode`)
to support Android/Termux as a build target.

## Patch files

- `opentui/` — active bionic TUI/FFI guard patches for the transplant pipeline.

### Removed legacy patches (do not restore)

- `0001-android-support.patch` (removed) — targeted `package.json` `"os"` field
  and `postinstall.mjs`. Both are gone upstream: current `dev` package.json has
  no `"os"` field (`"name": "opencode"`), and `postinstall.mjs` returns 404.
  The file was also truncated mid-hunk, so `git apply` failed with
  `No such file or directory`.
- `0002-bun-termux-cwd-fix.patch` (removed) — targeted Bun source
  `src/runtime/cli/run_command.zig`, which never exists in an
  `anomalyco/opencode` checkout. It also had a placeholder
  `index abcdef1..1234567` header and a truncated hunk
  (`corrupt patch at :54`). The Termux CWD fallback lives in
  `Hope2333/bun-termux` (android-termux branch, commit `767462f`), not here.

## Applying (deprecated line: builds stock upstream, no patches)

```bash
# Deprecated glibc-wrapper line builds stock upstream with no top-level patches:
git clone --depth 1 --branch dev https://github.com/anomalyco/opencode.git opencode-source
cd opencode-source
bun install
bun run build --target=linux-arm64  # produces opencode-linux-arm64
```

## Building for Termux

The patches produce a standard `bun build --compile` output. The binary is then
wrapped for Android using bun-termux-loader (in CI or locally).
