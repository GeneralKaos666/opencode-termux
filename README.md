[English](./README.md) | [简体中文](./README.zh.md)

# opencode-termux

OpenCode on Termux. AI-powered coding assistant, native bionic runtime, zero glibc dependencies.

![opencode v2 TUI](./assets/screenshots/opencode-v2-tui.webp)

## Quick install

```bash
curl -fsSL https://opencode.ai/install.sh | bash
```

This installs the `opencode` command. After installation, upgrade via package manager:

```bash
# Termux (default)
pkg upgrade opencode

# pacman (if initialized)
pacman -Syu opencode
```

## What is this

[OpenCode](https://opencode.ai) is an AI-powered terminal coding assistant. This project packages it for [Termux](https://termux.dev) on Android, providing native bionic binaries with zero glibc dependencies.

Three runtime variants are available:

| Package | Runtime | Size | TUI | Notes |
|---------|---------|------|-----|-------|
| `opencode` | Native bionic | ~66 MB (UPX) | Full | Mainline, recommended |
| `opencode-compressed` | Native bionic (UPX) | ~66 MB | Full | Alias for `opencode` |
| `opencode-wrapper` | Bun-termux-loader | ~193 MB | Full | Glibc wrapper, legacy |

**Mainline** = native bionic (`opencode`). Zero glibc, Android API >= 28, full TUI via bionic libopentui.so.

## Install via pacman (optional)

Termux uses `apt` by default. If you prefer `pacman`:

```bash
curl -fsSL https://opencode.ai/install-pacman.sh | bash
```

Then install:

```bash
pacman -S opencode
```

## Upgrade

```bash
# apt (default)
pkg upgrade opencode

# pacman
pacman -Syu opencode
```

## Requirements

- Android API >= 28 (Android 9.0+)
- Termux (F-Droid or GitHub release)
- ~200 MB free storage

## Packages

### Stable releases

Packages are published on [GitHub Releases](https://github.com/Hope2333/opencode-termux/releases) under rolling tags:

- `Push260912` -- v1.18.30 / v1.18.31 (last v1 release)
- `Push260921` -- v2.0.0 GA (current mainline)

### Package formats

- **deb**: `opencode_<ver>_aarch64.deb` (Termux apt)
- **pacman**: `opencode-<ver>-1-aarch64.pkg.tar.xz` (Termux pacman)
- **native UPX**: `opencode-native-<ver>-upx.xz` (binary only, ~66 MB)

## Building from source

Requires `make`, `python3`, `clang`, and `upx` (optional).

```bash
# Build native bionic binary
make build-native VER=2.0.0

# Build compressed (UPX) variant
make build-native-upx VER=2.0.0

# Build deb package
make deb-native VER=2.0.0

# Build pacman package
make pacman-native VER=2.0.0
```

See [docs/make-maintainer.md](./docs/make-maintainer.md) for full build reference.

## v1 to v2 migration

v2.0.0 is the current mainline. v1.18.x packages are retained for rollback.

If you have v1 installed:

```bash
# v2 replaces v1 automatically (Conflicts/Replaces in control)
pkg upgrade opencode
```

Package name changed from `opencode-glibc` (v1) to `opencode-wrapper` (v2 wrapper variant).

## Technical documentation

- [docs/transplant.md](./docs/transplant.md) -- Runtime transplant pipeline
- [docs/comparison-runtime-lines.md](./docs/comparison-runtime-lines.md) -- Runtime line comparison
- [docs/dual-track-install.md](./docs/dual-track-install.md) -- Dual-track install guide
- [docs/make-maintainer.md](./docs/make-maintainer.md) -- Makefile reference

## License

OpenCode is open source. This packaging project follows the same license.
