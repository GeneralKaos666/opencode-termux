[English](./README.md) | [简体中文](./README.zh.md)

# opencode-termux

OpenCode on Termux. **Mainline = native bionic direct-run line**: a single zero-glibc
Android ELF produced by the transplant revive pipeline, shipped as formal releases
under the plain `opencode` package name. The wrapper line (inherited from the
former `pure-android` line) is kept as appendix maintenance. Current branch:
`native-android` (default mainline).

---

## Native line (mainline): zero-glibc single-ELF runtime

The official prebuilt Android Bun serves as the base. We graft opencode's module graph
into the same ELF, run the revive surgery, and produce a single Bionic executable that
can be execve'd directly. Zero glibc dependencies, requires Android API >= 28.

### v2.0.0 port status (current)

> **opencode 2.0.0 GA** has been transplanted to a native bionic ELF (bun 1.4.2 base)
> and packaged as `opencode 2.0.0`. Packages: `opencode_2.0.0_aarch64.deb` /
> `opencode-2.0.0-1-aarch64.pkg.tar.xz` (Package=`opencode`, zero glibc Depends).
>
> **Known limitation**: the TUI crashes in the revived binary — bun `getenv_z`
> segfault in the HTTP-client DNS path (`Segmentation fault at address 0x40`,
> bun.report signature Aa1744846…). **Headless paths work**: `--version`, `serve`,
> `run --standalone`, `--help`. The v2 binary is NOT seccomp-hardened (no
> `libopencode-crhandler.so`).
>
> **v1.18.x line retained** for rollback (cached debs available).

> **opencode 2.0.0 GA** has been transplanted to a native bionic ELF (bun 1.4.2 base)
> and packaged as `opencode 2.0.0`. Packages: `opencode_2.0.0_aarch64.deb` /
> `opencode-2.0.0-1-aarch64.pkg.tar.xz` (Package=`opencode`, zero glibc Depends).
>
> **Known limitation**: the TUI crashes in the revived binary — bun `getenv_z`
> segfault in the HTTP-client DNS path (`Segmentation fault at address 0x40`,
> bun.report signature Aa1744846…). **Headless paths work**: `--version`, `serve`,
> `run --standalone`, `--help`. The v2 binary is NOT seccomp-hardened (no
> `libopencode-crhandler.so`).
>
> **v1.18.x line retained** for rollback (cached debs available).

### Highlights

- ✅ **Zero glibc**: no glibc-repo / openssl-glibc needed. The earlier "zero glibc is
  impossible" conclusion was overturned by the revive surgery — the real cause was that
  assemble never patched `BUN_COMPILED.size` in the `.bun` section. See
  `docs/transplant.md` §0.1/§0.2.
- ✅ **Fully working TUI** (v1.18.x): a self-built bionic `libopentui.so` (NDK) is swapped in at
  equal length via `tools/transplant/swap_tui.py`. W10a deep smoke passed 5/5 (real
  chat round trip / resize / clean exit / 5min soak with RSS actually dropping). **⚠️ v2.0.0 TUI is broken** — see port status above.
- ✅ **Native watcher**: `tools/watcher/` provides a standalone daemon module
  (`watcher.c`, NDK inotify recursive watching) plus a plugin-side shim (`shim.js`).
  Fixes the total lack of file watching caused by upstream `@parcel/watcher` failing to
  load on Termux. E2E all three event types <100ms, kill -9 self-heal ≤612ms.
- ✅ **bin-direct packaging**: `bin/opencode` inside the package is a real executable
  ELF, no bash launcher wrapper.
- ✅ **UPX compressed variant**: the same native ELF packed with UPX `--best`, shipped
  as the `opencode-compressed` package family — 71.14% smaller at a measured startup
  cost. See [Compressed variant](#compressed-variant-opencode-compressed-native--upx).

> **Naming legacy note — the `glibc` suffix is historical, NOT a current dependency**
>
> The `*-glibc` package names (e.g. `opencode-glibc`) are **legacy naming kept for
> convenience**: renaming would break existing installs, scripts, and the mirror
> history. They date from the early node era, when the transplanted node assets
> genuinely linked against glibc. Since the **revive surgery**, all glibc calls and
> dependencies have been **completely removed** — current builds are zero-glibc at
> **both runtime and compile time**, across the wrapper (`*-glibc`), the native
> mainline (`opencode`, zero-glibc), and the UPX-compressed (`opencode-compressed`)
> families. "glibc" in a package name today means nothing about runtime linkage;
> it is purely a frozen historical identifier.

### How it works

```
official android bun ELF          opencode module graph
        │                                │
        └───────────────┬────────────────┘
                        ▼
     tools/transplant/transplant.py  (graft + patch)
                        ▼
        revive surgery  (BUN_COMPILED.size fix)
                        ▼
   swap_tui.py: bionic libopentui.so equal-length swap
                        ▼
      single execve-able opencode ELF (~180MB)
```

### Install (mainline package: `opencode`)

The native mainline has inherited the plain `opencode` package name (the wrapper
line was renamed `opencode-wrapper` — see the [coexistence matrix](#package-coexistence-matrix)):

```bash
# Download from https://github.com/Hope2333/opencode-termux/releases
# ELF asset names look like opencode-2.0.0-aarch64-android-native (or opencode-1.18.21-... for rollback)
dpkg -i opencode_<version>_aarch64.deb
# or
pacman -U opencode-<version>-1-aarch64.pkg.tar.xz
```

**From the hope2333 software source (recommended)**:

```bash
curl -fsSL https://hope2333.github.io/repo/install.sh | sh -s -- --install opencode   # configure + install
pacman -Syu   # upgrade later
```

See [Software source](#software-source) and the
[wiki install guide](https://hope2333.github.io/wiki/guides/install.html).

```bash
opencode --version   # -> 2.0.0 (v1.18.x also available for rollback)
opencode run "hi"
opencode             # TUI
```

### Compressed variant: `opencode-compressed` (native + UPX)

The same revived native ELF, additionally packed with UPX `--best` and shipped as the
`opencode-compressed` package family (command entry is still `opencode`):

| Stage | Size | Note |
|---|---|---|
| Unpacked native ELF | 179,807,785 B | sha256 `02609002…` (native-beta-260826 build) |
| UPX `--best` | 51,891,796 B | **-71.14%**, sha256 `30c074ab…` |
| + `xz -9` upload layer | 50,362,704 B | sha256 `42a0ef39…`; xz gains only ~3% because UPX output is already high-entropy |

- **Startup tradeoff (measured)**: UPX decompression adds ~0.7–1.1s (1.9–2.3s total vs
  ~1.1s unpacked). Choose `opencode-compressed` for download size, plain `opencode`
  for startup latency.
- **Fingerprint chain**: unpacked `02609002…` → UPX `30c074ab…` → xz `42a0ef39…`
  (sha256 prefixes; full hashes in the release notes and `SHA256SUMS.txt`).
- **AV false-positive notice**: UPX-packed executables are a known antivirus
  false-positive trigger. Verify downloads against `SHA256SUMS.txt` before use.
- First shipped together in the **Push260828** release (four package families'
  first co-appearance): ELF assets `opencode-1.18.21-aarch64-android-native-tui-upx`
  (+ `.xz`), packages `opencode-compressed_1.18.21_aarch64.deb` /
  `opencode-compressed-1.18.21-1-aarch64.pkg.tar.xz`, plus `SHA256SUMS.txt`.

```bash
dpkg -i opencode-compressed_<version>_aarch64.deb
# or
pacman -U opencode-compressed-<version>-1-aarch64.pkg.tar.xz
```

### Package coexistence matrix

| Package | Line | Command entry | Coexistence |
|---|---|---|---|
| `opencode` | native bionic (mainline) | `opencode` | mutually exclusive with `opencode-wrapper` and `opencode-compressed` |
| `opencode-compressed` | native bionic + UPX | `opencode` | mutually exclusive with `opencode` and `opencode-wrapper` |
| `opencode-wrapper` | wrapper (appendix) | `opencode` | mutually exclusive with `opencode` and `opencode-compressed` |
| `opencode-wrapper-standalone` | wrapper, frozen single version | `opencode-wrapper` | **coexists with `opencode`**; rollback only |

The three `opencode`-entry packages replace each other via the package manager's
conflict mechanism; the standalone package uses an independent lib path and a distinct
command name so it can sit alongside the native mainline as a frozen rollback.

### Build

One-shot pipeline:

```bash
make transplant VER=1.18.21
# extract -> detect -> convert -> patch -> assemble -> revive -> verify
# Produces a runnable opencode-native-revived directly
```

Key points:

- **All-version coverage**: 1.2.x through latest all work. Old trailer format and the
  new `.bun` section format (opencode >= 1.18, proven on 1.18.21) are auto-detected.
- **Auto revive size mode**: bases <= 1.3.x use reloc relocation writes, >= 1.4.x use
  plain-offset direct writes (auto-decided by base version since b09c28c); override
  explicitly with `--size-mode reloc|plain-offset`. Graphs in the new section format
  must use a >= 1.4 base (see `tools/transplant/config/bun-bind.json`, target=1.4.0).
- **TUI injection**: the pipeline includes a swap_tui step that swaps in the bionic
  libopentui.so at equal length.
- **Golden regression**: `make transplant-check` (golden-file regression; fixtures
  need `scripts/fetch-fixtures.sh` pre-downloaded first).

### Dependencies

| Tool | Required? | Purpose |
|---|---|---|
| python3 | ✅ | Pipeline itself, runs on stdlib alone |
| NDK | Only for self-built components | Building bionic libopentui.so / watcher.c |
| gh / npm / curl | ✅ | Fetching the Bun base, opencode packages and fixtures |

### CI and verification boundary

`.github/workflows/build-native-android.yml` (workflow_dispatch manual trigger):
runs the full revive flow and golden regression on an x86 runner; artifacts are
evidence-only (CI does not execute them). **CI green ≠ runnable**: final acceptance
requires on-device verification on a real machine. Also note: isolated-HOME testing
needs a warm cache mirror, otherwise the binary hangs at startup.

### Release policy (honest notes)

> The native line is the stable mainline release channel. Performance reality
> (measured, not marketing): startup ~1s magnitude (`--version` first try 1965ms =
> Phase B bootstrap ~220ms + Phase C JS evaluation ~820ms; the <300ms goal needs
> upstream Bun changes and is unreachable today), size ~180MB unpacked / ~50MB
> UPX-packed.

For the full surgery principles, config schema, failure playbooks and FAQ see
`docs/transplant.md`; for a comparison of the runtime lines see
`docs/comparison-runtime-lines.md`.

---

## Branch topology

| Branch | Role |
|---|---|
| `native-android` | **Default mainline** — native bionic line (this branch) |
| `wrapper` | wrapper line, appendix maintenance (renamed from `pure-android`) |
| `archive/wrapper-classic` | legacy wrapper line, archived |

---

## Make system

The Make system is the highest-priority entry for all build and package operations.
Individual tools are help-first: run `--help` before reading source. Read or modify
project source only when something actually breaks.

```bash
# Package all families for a version
make family=wrapper,native,compressed VER=1.18.27

# Per-family targets
make deb-native VER=1.18.27
make pacman-native VER=1.18.27

# Native transplant
make transplant VER=1.18.27

# Validation
make selfcheck
make matrix VERS='1.18.[15-27]' TARGET_HOST=<host> TARGET_USER=<user>
```

For maintainer operations (upload, fleet push, cache cleanup), see
`docs/make-maintainer.md` and `tools/maintain.sh --help`.

---

## Software source

Packages are distributed through two channels:

**Pacman** (per-repo db): `https://hope2333.github.io/repo/Termux/pacman/<repo>.db.tar.gz`
— the `opencode-termux` db carries all three families (`opencode` / `opencode-compressed`
/ `opencode-wrapper`, all at 1.18.27-1).

**Apt flat index**: `https://github.com/Hope2333/opencode-termux/releases/latest/download/Packages.gz`
(40 entries: 13 native + 13 compressed + 13 wrapper + 1 standalone).

Default install priority: per-repo mirrorlist servers (release CDN) first, Pages-hosted
source as fallback.

**One-line configure + install**:

```bash
curl -fsSL https://hope2333.github.io/repo/install.sh | sh -s -- --install opencode
```

Upgrades: `pacman -Syu` (pacman) / `apt update && apt upgrade` (apt) — details in the
[wiki install guide](https://hope2333.github.io/wiki/guides/install.html).

---

## Plugin management

The recommended way to manage plugins is the built-in `opencode plugin` command:

```bash
opencode plugin install <plugin>
opencode plugin list
opencode plugin remove <plugin>
```

The `file://` registration path remains valid for snapshot/rollback scenarios.
Bare-name plugin entries in `opencode.json` are legacy (1.2.x-era). See
`docs/plugin-management.md` for the full reference.

---

## Appendix: wrapper line (inherited from the pure-android line)

The bun-termux-loader wrapping approach: upstream `opencode-linux-arm64` is a
glibc-linked Bun single-file app (Bun runtime + JS compiled into one ELF). The loader
prepends a ~12KB Bionic wrapper ELF: it reads `/proc/self/exe` to locate BUNWRAP1
metadata, extracts the embedded opencode binary, then mmaps glibc's ld.so and jumps to
its entry (userland exec, no execve), keeping `/proc/self/exe` pointing at itself so
Bun's JS location stays intact.

The `opencode-wrapper` package is **self-contained**: it runs on bare Termux without
the Termux `glibc` or `ca-certificates-glibc` packages. Packaging is bin-only (single
binary at `usr/bin/opencode`), with no postinst/prerm/postrm hooks and no full-prefix
copy. Working TUI via bionic libopentui.so swap (docs/tui-common-fix.md).

### Dependencies

| Package | Required? | Why |
|---|---|---|
| `bash` | ✅ Yes | Launcher script |
| `ncurses` | ✅ Yes | TUI support |

### Install

```bash
# Path A: apt/pkg
dpkg -i opencode-wrapper_<version>_aarch64.deb

# Path B: pacman
pacman -U opencode-wrapper-<version>-1-aarch64.pkg.tar.xz
```

Rollback package (coexists with the native `opencode`, command entry `opencode-wrapper`,
single frozen version):

```bash
dpkg -i opencode-wrapper-standalone_<version>_aarch64.deb
# or
pacman -U opencode-wrapper-standalone-<version>-1-aarch64.pkg.tar.xz
```

### Build

```bash
# Single version
make all VER=1.17.3 PKG=both

# Batch build
make batch VERS='1.17.[0-3]' PKG=both ODIR=~/oct-out MIX=1

# Flow: clean -> runtime(produce-local.sh: npm download + loader wrap)
#      -> stage(scripts/build.sh) -> deb -> pacman
```

### CI

`.github/workflows/build-pure-android.yml`: workflow_dispatch manual trigger,
QEMU aarch64 binary handling, npm download of opencode-linux-arm64 wrapped with the
prebuilt wrapper+shim (`tools/prebuilt/`), artifact upload plus status JSON.

> amd64 (x64) + Android + Termux has almost no real users; this project ships no x64
> assets. armv7's 32-bit dependency chain is badly broken with prohibitive fix costs;
> that experiment is abandoned.

### Launcher safeguards

- TTY cleanup on exit (soft/hard depending on exit code)
- Stale lock cleanup (`*.lock` under `$XDG_STATE_HOME`)
- `OPENCODE_DISABLE_DEFAULT_PLUGINS=1` by default

---

## Repository layout

```
.github/workflows/
  build-native-android.yml    Native line CI (evidence-only artifact)
  build-pure-android.yml      wrapper line CI (aarch64)
tools/
  transplant/                 Native revive pipeline (transplant.py / revive_patch.py /
                              swap_tui.py / config/bun-bind.json)
  watcher/                    Native inotify watcher daemon + shim plugin bridge
  produce-local.sh            wrapper line: npm download + loader wrap
  prebuilt/                   Prebuilt aarch64 wrapper+shim for wrapper line CI
scripts/
  fetch-fixtures.sh           transplant-check golden fixtures pre-download
  build.sh                    Stage prefix (wrapper line; STANDALONE=1 for rollback pkg)
  launcher.sh                 Runtime dispatcher (cleanup + exec)
  package/package_deb.sh      DEB builder (opencode-wrapper)
  package/package_pacman.sh   Pacman builder (opencode-wrapper)
  package/package_deb_native.sh        DEB builder (native opencode)
  package/package_pacman_native.sh     Pacman builder (native opencode)
  package/package_deb_compressed.sh    DEB builder (opencode-compressed)
  package/package_pacman_compressed.sh Pacman builder (opencode-compressed)
  package/package_deb_standalone.sh    DEB builder (opencode-wrapper-standalone)
  package/package_pacman_standalone.sh Pacman builder (opencode-wrapper-standalone)
  hooks/run-system-skills.sh  Post-install/upgrade hooks
patches/
  0001-android-support.patch  Upstream OpenCode Android patches (WIP)
docs/
  transplant.md               Authoritative native-line surgery doc
  comparison-runtime-lines.md Comparison of the runtime lines
  dual-track-install.md       Provider choice across the package families
  make-maintainer.md          Maintainer build/upload/cache operations
  native-android-research.md  Zero-glibc research history
```

## Related

- OpenCode upstream: <https://github.com/anomalyco/opencode>
- bun-termux-loader: <https://github.com/Hope2333/bun-termux-loader>
- Android-native Bun: <https://github.com/Hope2333/bun-termux>
- Upstream Bun (Android builds): <https://github.com/oven-sh/bun>
- Releases: <https://github.com/Hope2333/opencode-termux/releases>

## Metadata

Maintainer: `Hope2333(幽零小喵) <u0catmiao@proton.me>`
