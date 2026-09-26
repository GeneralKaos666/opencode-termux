# TUI Crash Fix: Process and Technical Overview

> This document records the complete technical history of the OpenCode-on-Termux native-line TUI render layer (`libopentui.so`) from its first crash to the root-cause fix at the common layer. It covers commits `342d68d` (crashfix v2), `17b51a4` / `10afa28` / `faf1334` (the common-layer root-fix trilogy), and the patches `patches/opentui/fix-drawchar-negative-coords.patch` and `ffi-int-truncation-guards.patch`.

---

## TL;DR

On 2026-08-25 alpha-package users reported a probabilistic SIGABRT when clicking to expand the thinking block in the TUI. The root cause had two layers: (1) negative coordinates/sizes from the JS side crossed the FFI boundary as two's-complement values into Zig, becoming huge u32 values, and the `@intCast(u32->i32)` safety check inside `bufferDrawChar` panicked; (2) the build pipeline's common layer `libopentui.so` never had the patches applied, causing a full regression across all 13 versions. The fix had two layers: (1) `fix-drawchar-negative-coords.patch` inserts bit31 early-returns at 8 sites, `@min(w/h, 0x7FFFFFFF)` saturating clamps, and saturating addition; (2) `build-libopentui.sh` was rewritten as a five-step pipeline (apply all patches -> zig build -> objdump guard self-check -> hostile FFI harness -> install into slot), `swap_tui.py` rejects unguarded `.so` files, and `tui_smoke.py` pty smoke test became part of the standing matrix. Final result: all 13 versions fully rebuilt, 12/12 guard verifications passed, 1.18.21 rebuilt fresh via `make transplant` then smoke PASS, 4/4 golden regressions passed.

---

## Timeline

| Date | Event | Key commit / hash |
|------|-------|-------------------|
| 2026-08-25 | Alpha user reports TUI SIGABRT: clicking to expand the thinking block -> `integer does not fit in destination type` in `lib.bufferDrawChar` | crash report |
| 2026-08-25 | DIAG1: extract `bun-10258.so` (fd29387d, 13,995,736B) from the crashed process, confirmed as the OpenTUI bionic lib (SONAME=libopentui.so) | DIAG1 done |
| 2026-08-26 | DIAG2: disassembly locates 4 `@intCast` failure branches inside `bufferDrawChar@0x2ad104` (+0x12c/0x130/0x154/0x178), pinning down `buffer.zig:925` and `:322-324` | DIAG2 done |
| 2026-08-26 | v1 guard (coords only): `if (x >= 0x80000000 or y >= 0x80000000) return;` inserted at `buffer.zig:925` | Rebuild FFI stress test: coordinate stress PASS, scissor-residual FAIL |
| 2026-08-26 | v2 guard (coords + scissor): `@min(scissor.width, 0x7FFFFFFF)` clamp + `+|` saturating add written into `isPointInScissor` | **342d68d** `fix(opentui): guard negative FFI coords in bufferDrawChar` |
| 2026-08-27 | Beta release 1.18.21, includes seccomp shim + TUI guard v2; `tui_probe` only tests `--version` | `956515a` beta channel marker |
| 2026-08-30~09-03 | Push260903 preparation: 13-version wrapper + native batch build; swap-in via `transplant.py` equal-length replacement | batch build logs |
| 2026-09-03 | Found that the 1.18.27 batch package embedded an unguarded `libopentui.so`; `build-libopentui.sh` (UNTRACKED) did not apply `patches/opentui/*` | `task-tui-common-fix.log` P2 |
| 2026-09-04 | P3: `build-libopentui.sh` rewritten as a five-step pipeline; `swap_tui.py` gains `has_ffi_guard` rejection logic; canonical .so 917,832B | **17b51a4** `fix(transplant): common-layer libopentui guard` |
| 2026-09-04 | P4: patch extended to cover the `packages/native` tree (`ffi-int-truncation-guards.patch`); differential FFI proof: new build exit=0, old .so exit=134 | **10afa28** `fix(transplant): wire libopentui common layer` |
| 2026-09-04 | P5: full rebuild of 13 versions + 12/12 guards passed + 4/4 golden + attach smoke render=yes panic=no | **faf1334** `feat(transplant): P5 hardening` |

---

## Crash Mechanism

### Trigger Path

```
JS Renderable._screenX/_screenY (can be negative; thinking block top goes beyond the viewport)
  -> buffer.ts:613 drawChar (no clamp, passes straight to lib.bufferDrawChar)
    -> FFI boundary: lib.zig:3207 export fn bufferDrawChar(buffer_handle, char:u32, x:u32, y:u32, ...)
      -> JS negative number (-1) becomes u32 0xFFFFFFFF via two's complement (bit31 set)
        -> @intCast(u32->i32) safety check inside bufferDrawChar
          -> panic: "integer does not fit in destination type"
            -> SIGABRT (rc=134)
```

### Disassembly Localization Record

Disassembling `bufferDrawChar@vaddr 0x2ad104` from the un-stripped crashed .so (fd29387d):

- `+0x12c` (`0x2ad230`): `tbnz w0, #31, fail` -- `@intCast(x)` failure branch
- `+0x130` (`0x2ad234`): `tbnz w0, #31, fail` -- `@intCast(y)` failure branch
- `+0x154` (`0x2ad258`): `tbnz w0, #31, fail` -- `@intCast(scissor.width)` failure branch
- `+0x178` (`0x2ad27c`): `tbnz w0, #31, fail` -- `@intCast(scissor.height)` failure branch

All 4 fail branches jump to `0x2ad610`, which references `defaultPanic.integerOutOfBounds` (vaddr `0x3509a4`); the panic string `"integer does not fit in destination type"` lives at `0x4074a`.

`validateAndIndex@0x2aea54` confirms the struct layout: `width@[0x118]`, `height@[0x11c]`, `scissor_stack@[0xd0/0xd8]`.

### Exposure Scenario

`Renderable.ts:1521`'s `_screenX` / `_screenY` take negative values when the expanded thinking block's top goes beyond the viewport or the scroll clipping boundary. Via `Renderable.ts:1424-1434`'s `pushScissorRect` they enter `scissor_stack`, producing negative derived scissor sizes. Clicking to expand the thinking block is a probabilistic trigger, depending on scroll position, content width, and click timing.

---

## Fix Evolution

### v1: Coordinate Guard Only

```zig
// buffer.zig:925 setVisibleCellWithAlphaBlending
if (x >= 0x80000000 or y >= 0x80000000) return;  // added: bit31 early return
if (!self.isPointInScissor(@intCast(x), @intCast(y))) return;
```

Effect: FFI coordinate stress test PASS over 2000 iterations, but **scissor-residual stress test FAILED** -- `@intCast(scissor.width)` / `@intCast(scissor.height)` inside `isPointInScissor` still panicked (rc=134).

Lesson: guarding only the coordinate entry point is not enough; scissor sizes come from the JS side's `pushScissorRect` and can likewise carry negative derived values across the FFI boundary.

### v2: Saturating Clamp Inside isPointInScissor (342d68d)

```zig
// buffer.zig:297-303 isPointInScissor
pub fn isPointInScissor(self: *const OptimizedBuffer, x: i32, y: i32) bool {
    const scissor = self.getCurrentScissorRect() orelse return true;
    // FFI negative-coordinate defense: clamp u32 scissor sizes before @intCast
    const w = @as(i32, @intCast(@min(scissor.width, 0x7FFFFFFF)));
    const h = @as(i32, @intCast(@min(scissor.height, 0x7FFFFFFF)));
    return x >= scissor.x and x < scissor.x +| w and
        y >= scissor.y and y < scissor.y +| h;
}
```

Key design choices:

| Guard strategy | Applicable scenario | Implementation |
|----------|---------|------|
| bit31 early return | FFI entry coordinates (x/y u32) | `if (x >= 0x80000000) return;` |
| `@min(w/h, 0x7FFFFFFF)` clamp | scissor sizes (width/height u32) | safe conversion via `@intCast` after clamping |
| Saturating addition `+\|` | endpoint coordinate calculation | `x +| w` does not overflow; out-of-bounds gets truncated by `@min` |
| `<= -0x40000000` early return | `drawTextBufferInternal` etc. `@intCast(-y)` | prevents `INT32_MIN` negation overflow |

Effect: FFI differential stress test (including a `pushScissorRect` toggle loop) over 2000 iterations, old vs new .so -- new .so all PASS (rc=0), old .so SIGABRT (rc=134). TUI smoke passed.

---

## Regression and Root Cause (1.18.27 Batch Package)

### Facts

Found 2026-09-03: the `libopentui.so` embedded in the 1.18.27 pacman package had **no guards at all**, `objdump` guard pattern count = 0, attach SIGABRT persisted. All 13 versions were like this.

### Root Cause Chain

```
build-libopentui.sh (UNTRACKED file, not committed to git)
  -> does not apply patches/opentui/* patches
    -> the built .so is the original unguarded version

transplant.py:1410
  -> hardcodes bionic_lib = artifacts/transplant/opentui-bionic/libopentui.so
    -> that file's mtime is Aug 24, earlier than fix commit 342d68d (Aug 26)
      -> permanently the old unguarded .so

transplant.py equal-length swap-in
  -> all versions' .bun slots replace the same old .so
    -> all 13 versions inherit the defect
```

### Incidental Discovery

The old 1.18.21 host bun lacked `bun:ffi` dlopen (TinyCC disabled), so `libopentui.so` was never usable. `tui_probe` only tested `--version` (process surviving = PASS), **not the render layer**, masking the problem.

### General Lessons

- **Reusing stale common-layer artifacts = entire batch inherits the defect**: one stale .so pollutes all versions via equal-length swap-in
- **UNTRACKED build scripts = invisible regressions**: `build-libopentui.sh` was not committed to git, so the lost patch-application step went unnoticed
- **Probes must test the render layer**: `--version` passing does not mean the TUI works; pty smoke + panic scanning is required

---

## Common-Layer Root-Fix Architecture

### Canonical Build Five Steps (build-libopentui.sh)

```
Step 1: Apply all patches
  -> reverse-first: reverse first, then git apply patches/opentui/*.patch
  -> ensure idempotence: clean when unpatched, no duplication when patched

Step 2: zig 0.16 bionic build
  -> zig build -Dlibrary-target=aarch64-linux-android -Doptimize=ReleaseSafe
  -> NDK bionic sysroot + libm

Step 3: objdump guard self-check (fail-loudly)
  -> scan the compiled guard pattern inside guard-owning symbols
  -> no clamp/csel instructions detected = build failure

Step 4: ffi_guard_harness.c (hostile FFI harness)
  -> dlopen + dlsym all FFI entry points
  -> inject bit31 coordinates drawChar + INT32_MIN grayscale + huge fill/scissor
  -> only release if exit=0; exit=134 (SIGABRT) = build failure

Step 5: Install into slot
  -> llvm-strip -> cp -> clean build artifacts
```

### swap_tui.py Guard Verification

`has_ffi_guard()` scans the code sections of guard-owning symbols (e.g. `bufferDrawChar`, `isPointInScissor`) within the ELF, detecting the compiled guard pattern:
- `mov wN, #0x7fffffff` clamp instruction (MOVN #0x8000, LSL#16)
- `csel ..., vs` saturating-add branch

If the guard pattern is not detected -> reject that .so, `swap_tui.py` exits with code 5.

### tui_smoke.py pty Smoke Test

```
1. Open a pty, launch the opencode process
2. Wait for TUI rendering (detect ANSI sequences)
3. Perform interactive actions (open session, click thinking block)
4. Scan stderr/process output for panic keywords
5. Extract the embedded .so at runtime (from /proc/<pid>/maps + dd)
6. Run has_ffi_guard verification on the extracted .so
```

---

## Patch Coverage List

### fix-drawchar-negative-coords.patch (buffer.zig + renderer.zig, packages/core)

| # | File:location | Guard type | Input form defended against |
|---|----------|---------|--------------|
| 1 | `buffer.zig:297-303` `isPointInScissor` | `@min(w/h, 0x7FFFFFFF)` + `+\|` saturating add | negative derived scissor size crossing FFI as u32 |
| 2 | `buffer.zig:320-324` `clipRectToScissor` | same as above | same as above (clipRect endpoint calculation) |
| 3 | `buffer.zig:807` `setVisibleCellWithAlphaBlending` | `if (x >= 0x80000000 or y >= 0x80000000) return;` | FFI coordinate bit31 set |
| 4 | `buffer.zig:838` `setCellWithAlphaBlendingRaw` | same as above | same as above |
| 5 | `buffer.zig:1248` `drawTextBufferInternal` | `if (y <= -0x40000000) return;` | `INT32_MIN` negation overflow |
| 6 | `buffer.zig:2131` `drawGrayscaleBuffer` | `if (posX < -0x40000000 or posY < -0x40000000) return;` | same as above (grayscale buffer) |
| 7 | `buffer.zig:2200` `drawGrayscaleBufferSupersampled` | same as above | same as above (supersampled grayscale) |
| 8 | `renderer.zig:936/995/1000` hit-grid scissor | `@min(clipped.w/h, 0x7FFFFFFF)` + `+\|` | renderer hit-grid scissor |

### ffi-int-truncation-guards.patch (packages/native)

Covers the functions in `packages/native/src/buffer.zig` and `renderer.zig` isomorphic to the core tree: `setCellWithAlphaBlendingCellWithoutImages` (:908), `setCellWithAlphaBlendingRawCell` (:964), `drawTextBufferInternal` (:1661), `drawGrayscaleBuffer` (:2828), `drawGrayscaleBufferSupersampled` (:2897), `renderer` hit-scissor (:2824/2885/2959). The guard pattern is fully identical to the core tree.

### SAFE: Not-Changed List

| Location | Reason |
|------|------|
| `setCell` (non-Blending variant) | does not go through `@intCast` to i32; used directly as u32 index |
| `OptimizedBuffer.set` / `get` | all internal u32 arithmetic, no signed conversion involved |
| `blendCells` | pure u32 arithmetic, no `@intCast` |
| `getCurrentScissorRect` return value | returns `?ClipRect`; clipping decision handled by caller `isPointInScissor` |
| `pushScissorRect` call side | negative values are legal (means outside viewport), absorbed by the scissor guard side |

---

## Verification Matrix

### 13-Version Rebuild Results

| Version | Guard verification (guard_check) | smoke (render) | Version match (tar) | SHA ok |
|------|----------------------|----------------|----------------|--------|
| 1.18.15 | PASS | PASS | PASS | PASS |
| 1.18.16 | PASS | PASS | PASS | PASS |
| 1.18.17 | PASS | PASS | PASS | PASS |
| 1.18.18 | PASS | PASS | PASS | PASS |
| 1.18.19 | PASS | PASS | PASS | PASS |
| 1.18.20 | PASS | PASS | PASS | PASS |
| 1.18.21 | PASS | PASS (rebuild) | PASS | PASS |
| 1.18.22 | PASS | PASS | PASS | PASS |
| 1.18.23 | PASS | PASS | PASS | PASS |
| 1.18.24 | PASS | PASS | PASS | PASS |
| 1.18.25 | PASS | PASS | PASS | PASS |
| 1.18.26 | PASS | PASS | PASS | PASS |
| 1.18.27 | PASS | PASS | PASS | PASS |

Note: 1.18.21 initially failed smoke (render=NO, guard=no-so), cause: old host bun lacked `bun:ffi` dlopen. PASS after a fresh rebuild via `make transplant VER=1.18.21`.

### Golden Regression

| golden | Status |
|--------|------|
| 1.2.9 | PASS |
| 1.3.11 | PASS |
| 1.3.13 | PASS |
| synth-36b | PASS |

### Attach Smoke

```
opencode attach localhost:4097 -s ses_f94b5affcffe0qtniR5tEoeXKT
-> render=yes, panic=no, exit=0
```

### Differential FFI Stress Test

| .so | Coordinate stress 2000 iter | scissor-residual 2000 iter |
|-----|---------------------|---------------------------|
| New build (guard=OK) | PASS (rc=0) | PASS (rc=0) |
| Old crashed .so (fd29387d) | SIGABRT (rc=134) | SIGABRT (rc=134) |

---

## Residual Risks

1. **Guard machine-code pattern depends on the compiler**: `has_ffi_guard()` scans for the `mov wN, #0x7fffffff` and `csel ..., vs` instruction patterns. zig 0.16 + NDK r29 aarch64 currently emits these patterns, but a zig version upgrade or NDK change could alter compiler output, causing a guard-scan false negative. Must re-verify when zig/NDK is upgraded.

2. **crhandler per-version ABI not audited**: the seccomp SIGSYS shim (`libopencode-crhandler.so`) is injected as `DT_NEEDED` into every version's binary. So far only existence and dlopen success have been verified; ABI compatibility has not been audited per version.

3. **tui_smoke warm-cache dependency**: the pty smoke test depends on the bun compile cache (`$HOME/.bun/install/cache`). In a cold-cache environment the first start may time out, causing a false smoke FAIL.

4. **0.1.101 profile deprecation warning**: the zig 0.16 build emits `warning: ...deprecated in newer Zig versions` (profile `aarch64-linux-android`); it does not affect compilation but may become a hard error in zig 0.17+.

---

## 2026-09-22 regression: glibc libopentui.so embedded in the v2 B-line

**Symptom** — `opencode-native-revived` (2.0.0/2.0.12) started but the TUI aborted:

```
Error: Failed to initialize OpenTUI render library: Failed to open library
".../$TMPDIR/.bun-<pid>-<hash>.so": dlopen failed: library "libm.so.6" not found
```

`--version` worked (it never loads the TUI lib).

**Root cause** — `scripts/build-bionic.sh` deployed the bionic `.so` to a single
node_modules location chosen by a fallback glob
(`@opentui+core-linux-arm64@*` else `@opentui+core@*`). When the first glob
missed, the file bun actually bundles — `@opentui/core-linux-arm64/libopentui.so`
— stayed the glibc prebuilt (NEEDED `libm.so.6`, 5,867,248 B). The miss was
triggered by the step-0.6 batch `bun install` aborting on the nonexistent
`@opentui/solid-linux-arm64@0.5.10` (404). Post-hoc `swap_tui.py` cannot fix it:
the bionic `.so` (6,004,328 B) is larger than the embedded glibc slot.

**Fix** — in `scripts/build-bionic.sh`:

1. step 0.6 installs each platform package separately (drops the unpublished `@opentui/solid-linux-arm64`), so one 404 can't abort the batch;
2. every `libopentui.so` under `node_modules` is overwritten with the bionic build, **after** the pty/watcher install (which `bun install --force` re-extracts);
3. a **pre-compile hard assertion** rejects a glibc `@opentui/core-linux-arm64/libopentui.so`;
4. a **post-compile hard assertion** scans the product for embedded `SONAME=libopentui.so` ELFs and rejects any with NEEDED `libm.so.6`.

**Verification** — rebuilt 2.0.12: both assertions pass; TUI renders (model
selector + prompt + `2.0.12` status bar); `opencode_2.0.12_aarch64.deb` builds.

---

## Index

### Commit Chain

| commit | Date | Description |
|--------|------|------|
| `342d68d` | 2026-08-26 | crashfix v2: guard negative FFI coords in bufferDrawChar |
| `17b51a4` | 2026-09-04 | common-layer root fix: common-layer libopentui guard, reject unguarded swap |
| `10afa28` | 2026-09-04 | common-layer extension: wire libopentui common layer + extend guard patch |
| `faf1334` | 2026-09-04 | P5 hardening: w7b native recipe, pty smoke gate, truncation guard |

### Patch Files

| Path | Target tree | Guard sites |
|------|--------|---------|
| `patches/opentui/fix-drawchar-negative-coords.patch` | packages/core/src/zig | 8 |
| `patches/opentui/ffi-int-truncation-guards.patch` | packages/native/src | 8 |

### Scripts

| Path | Function |
|------|------|
| `tools/transplant/build-libopentui.sh` | canonical five-step build pipeline |
| `tools/transplant/swap_tui.py` | equal-length slot swap + `has_ffi_guard` rejection |
| `tools/transplant/tui_smoke.py` | pty smoke: render + panic scan + runtime .so extraction |

### Evidence Logs

| Path | Content |
|------|------|
| `.omo/evidence/task-crash-alpha260825.log` | original DIAG1/DIAG2 crash diagnosis chain |
| `.omo/evidence/task-tui-common-fix.log` | common-layer root fix five phases (T1-T2, P3-P5) |
| `.omo/evidence/task-w10a-tui-deep-smoke.log` | W10a deep TUI smoke |
| `.omo/evidence/task-w7b-opentui-bionic.log` | W7b opentui bionic build |
