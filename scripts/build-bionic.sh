#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

# build-bionic.sh — v2 Native B-line builder (android-bun source compile).
#
# Compiles the opencode v2 source tree with the android (bionic) Bun into a
# zero-glibc native ELF, then normalizes the product to the packaging contract
# names so the v1 native/compressed package scripts can be reused verbatim:
#
#   artifacts/build/<ver>/opencode-native-revived      (deb-native/pacman-native)
#   artifacts/build/<ver>/opencode-native-revived-upx  (deb-compressed/pacman-compressed)
#
# Command chain, in order:
#   1. opentui runtime check   — the grafted bionic libopentui.so in the .bun
#      store must export the 9 v2 FFI symbols + pthread_tryjoin_np stanza;
#      rebuild via tools/transplant/build-libopentui.sh when missing.
#   2. platform patch          — tools/build-bionic/apply-platform-patch.sh
#      (idempotent; forces process.platform="linux" so the loader picks the
#      bionic linux-arm64 libopentui.so).
#   3. bundler compile         — bun script/build.ts --target=opencode-linux-arm64
#      (android bun; openat2_shim LD_PRELOAD for install-only paths; no shim
#      needed at runtime).
#   4. normalize               — copy dist output to contract names + write
#      build.json (sha256 + provenance).
#
# Environment:
#   VER                version tag for the build (default: 2.0.0)
#   V2_SRC             v2 monorepo root (contains packages/cli/script/build.ts)
#                      default: $HOME/develop/opencode-src/opencode-<VER> or
#                      $(TMPDIR)/v2probe/opencode-src/opencode-<VER>
#   ANDROID_BUN        android bun binary (default: artifacts/transplant/android-bun/bun-1.4.2/bun;
#                      auto-falls back to $PREFIX/bin/bun when the cached one
#                      does not match the source's required bun version)
#   OPENAT2_SHIM       openat2/fchmodat2 LD_PRELOAD shim (default: tools/transplant/toolchain/openat2_shim.so)
#   OPENTUI_REBUILD    1 = force rebuild of the bionic libopentui.so (default 0 = only when broken)
#   OPENCODE_VERSION   version string embedded in the binary (default: VER)
#   BUILD_ROOT         output root (default: artifacts/build)
#   UPX                set to 1 to also produce the -upx variant
#   UPX_OPTS           upx flags (default: --best)

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VER="${VER:-2.0.0}"

# ── resolve v2 source tree ─────────────────────────────────────────────
if [[ -n "${V2_SRC:-}" ]]; then
	SRC_DIR="$V2_SRC"
else
	for cand in \
		"$HOME/develop/opencode-src/opencode-$VER" \
		"${TMPDIR:-/data/data/com.termux/files/usr/tmp}/v2probe/opencode-src/opencode-$VER"; do
		if [[ -d "$cand/packages/cli" ]]; then
			SRC_DIR="$cand"
			break
		fi
	done
fi
[[ -n "${SRC_DIR:-}" && -f "$SRC_DIR/packages/cli/script/build.ts" ]] || {
	echo "==> v2 source tree not found for $VER, downloading from GitHub..." >&2
	DL_DIR="${TMPDIR:-/data/data/com.termux/files/usr/tmp}/v2src"
	mkdir -p "$DL_DIR"
	EXTRACT_DIR="$DL_DIR/opencode-${VER}"
	if [[ ! -f "$EXTRACT_DIR/packages/cli/script/build.ts" ]]; then
		TGZ="$DL_DIR/opencode-${VER}-src.tar.gz"
		if [[ ! -f "$TGZ" ]]; then
			curl -fsSL "https://codeload.github.com/anomalyco/opencode/tar.gz/v${VER}" -o "$TGZ" || {
				echo "Error: failed to download source for v${VER} from GitHub" >&2
				exit 1
			}
		fi
		mkdir -p "$EXTRACT_DIR"
		tar xzf "$TGZ" -C "$EXTRACT_DIR" --strip-components=1 2>/dev/null || {
			echo "Error: failed to extract source tarball" >&2
			exit 1
		}
	fi
	[[ -f "$EXTRACT_DIR/packages/cli/script/build.ts" ]] || {
		echo "Error: extracted source has no packages/cli/script/build.ts" >&2
		exit 1
	}
	SRC_DIR="$EXTRACT_DIR"
}

ANDROID_BUN="${ANDROID_BUN:-$ROOT_DIR/artifacts/transplant/android-bun/bun-1.4.2/bun}"
# The v2 build.ts enforces ^<packageManager version> (bun@1.4.2) and aborts on
# mismatch. Prefer a bionic bun 1.4.2 when the cached tree holds a stale/wrong
# build (the artifacts/ cache has been observed holding 1.4.0 in a 1.4.2 dir).
BUILD_BUN_VERSION="$(grep -o '"packageManager"[^,]*' "$SRC_DIR/package.json" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)"
if [[ -n "$BUILD_BUN_VERSION" && -x "$ANDROID_BUN" ]]; then
	have="$("$ANDROID_BUN" --version 2>/dev/null || true)"
	if [[ "$have" != "$BUILD_BUN_VERSION" ]]; then
		for cand in "${TERMUX_PREFIX:-/data/data/com.termux/files/usr}/bin/bun" "$HOME/bun"; do
			if [[ -x "$cand" && "$("$cand" --version 2>/dev/null || true)" == "$BUILD_BUN_VERSION" ]]; then
				echo "    (ANDROID_BUN $have != required $BUILD_BUN_VERSION; using $cand)" >&2
				ANDROID_BUN="$cand"
				break
			fi
		done
	fi
fi
OPENAT2_SHIM="${OPENAT2_SHIM:-$ROOT_DIR/tools/transplant/toolchain/openat2_shim.so}"
BUILD_ROOT="${BUILD_ROOT:-$ROOT_DIR/artifacts/build}"
OUT_DIR="$BUILD_ROOT/$VER"
OPENCODE_VERSION="${OPENCODE_VERSION:-$VER}"
ULW_PATCH="$ROOT_DIR/tools/build-bionic/apply-platform-patch.sh"

[[ -x "$ANDROID_BUN" ]] || {
	echo "Error: ANDROID_BUN not found: $ANDROID_BUN" >&2
	exit 1
}
[[ -f "$OPENAT2_SHIM" ]] || {
	echo "Error: OPENAT2_SHIM not found: $OPENAT2_SHIM (build via tools/transplant/toolchain/)" >&2
	exit 1
}
# Fail fast (with the actual vs required version) instead of letting build.ts
# throw a semver error deep into the compile.
if [[ -n "${BUILD_BUN_VERSION:-}" ]]; then
	bun_have="$("$ANDROID_BUN" --version 2>/dev/null || echo unknown)"
	[[ "$bun_have" == "$BUILD_BUN_VERSION" ]] || {
		echo "Error: source requires bun@$BUILD_BUN_VERSION but ANDROID_BUN=$ANDROID_BUN reports $bun_have" >&2
		echo "       set ANDROID_BUN=<bionic bun $BUILD_BUN_VERSION> (e.g. \$PREFIX/bin/bun)" >&2
		exit 1
	}
fi

echo "==> build-bionic VER=$VER"
echo "    src = $SRC_DIR"
echo "    bun = $ANDROID_BUN ($("$ANDROID_BUN" --version 2>/dev/null || echo '?'))"

# ── 1. opentui bionic runtime check ────────────────────────────────────
STORE="$SRC_DIR/node_modules/.bun"
# ── 0.5 install dependencies (required for store/opentui check) ────────
echo "==> installing dependencies (bun install --force --ignore-scripts + shim)..."
cd "$SRC_DIR/packages/cli"
LD_PRELOAD="$OPENAT2_SHIM" "$ANDROID_BUN" install --force --ignore-scripts 2>&1 | tail -3 || {
	echo "WARN: bun install failed; continuing without store" >&2
}
cd "$ROOT_DIR"
cd "$ROOT_DIR"

# ── 0.6 install platform-specific packages (android reports platform=android) ─
# Install each package separately: one nonexistent package (@opentui/solid-linux-arm64
# is not published) must not abort the batch and leave a nondeterministic store
# layout — that was the trigger for the glibc libopentui embed (regression 2.0.12).
echo "==> installing platform packages (pty, watcher, fonts)..."
cd "$SRC_DIR/packages/cli"
for _pkg in \
	"@opencode-ai/pty-linux-arm64-gnu@0.1.13" \
	"@parcel/watcher-linux-arm64-glibc@2.5.1" \
	"@opentui/core-linux-arm64@0.5.10" \
	"@opentui/core-linux-arm64-musl@0.5.10"; do
	if ! LD_PRELOAD="$OPENAT2_SHIM" "$ANDROID_BUN" install --force --ignore-scripts --os=linux --cpu=arm64 "$_pkg" 2>&1 | tail -1; then
		echo "WARN: platform package install failed: $_pkg" >&2
	fi
done
cd "$ROOT_DIR"
NEEDED_SYMS=(cancelKittyImageTransport editBufferSetTabWidth getBufferWidthMethod
	getKittyImageTransport imageCreateFromPixels imageUpdatePixels pollKittyImageTransport
	processKittyImageReply setKittyImageTransport)

# ── ALWAYS deploy the verified bionic .so to EVERY store copy ──────────
# bun bundles the file the JS resolves: "@opentui/core-linux-arm64/libopentui.so".
# A single-target fallback glob previously missed that path and left the glibc
# prebuilt embedded, which dies at runtime with "libm.so.6 not found".
BUILTIN="$ROOT_DIR/artifacts/transplant/opentui-bionic/libopentui.so"
[[ -f "$BUILTIN" ]] || {
	echo "Error: bionic libopentui.so missing: $BUILTIN (run: make libopentui)" >&2
	exit 1
}
mapfile -t TUI_COPIES < <(find "$SRC_DIR/node_modules" -name libopentui.so -type f 2>/dev/null)
[[ ${#TUI_COPIES[@]} -gt 0 ]] || {
	echo "Error: no libopentui.so under $SRC_DIR/node_modules (bun install failed?)" >&2
	exit 1
}
for _so in "${TUI_COPIES[@]}"; do
	cp -p "$BUILTIN" "$_so"
	echo "    deployed verified bionic libopentui.so -> $_so"
done
TUI_SO="$(ls "$SRC_DIR"/node_modules/@opentui/core-linux-arm64/libopentui.so 2>/dev/null | head -n1 || true)"
[[ -n "$TUI_SO" ]] || TUI_SO="${TUI_COPIES[0]}"

# ── Verify FFI symbols ──
# v2 requires the 9 OpenTUI FFI exports. pthread_tryjoin_np is glibc-only and
# must be ABSENT from a correct bionic build: the Android clipboard patch
# (opentui patches/0007) replaces it with thread.join(), and bionic has no such
# symbol, so an undefined import would fail dlopen at runtime.
TUI_OK=0
if [[ -n "$TUI_SO" && -f "$TUI_SO" ]]; then
	TUI_SYMS="$(nm -D "$TUI_SO" 2>/dev/null || true)"
	missing=0
	for s in "${NEEDED_SYMS[@]}"; do
		grep -qw "$s" <<<"$TUI_SYMS" || {
			echo "    missing symbol: $s"
			missing=1
		}
	done
	if grep -qw "pthread_tryjoin_np" <<<"$TUI_SYMS"; then
		echo "    unexpected symbol: pthread_tryjoin_np (bionic has no such symbol; patch 0007 not applied?)"
		missing=1
	fi
	# Guard gate: an unguarded .so crashes on negative FFI coords (task-tui-common-fix).
	if [[ $missing -eq 0 ]] && ! bash "$ROOT_DIR/tools/transplant/build-libopentui.sh" --check "$TUI_SO" >/dev/null 2>&1; then
		echo "    opentui .so failed the FFI guard self-check (unguarded build)"
		missing=1
	fi
	[[ $missing -eq 0 ]] && TUI_OK=1
fi

if [[ "$TUI_OK" -eq 1 && "${OPENTUI_REBUILD:-0}" != "1" ]]; then
	echo "    opentui bionic runtime OK: $TUI_SO"
elif [[ "${OPENTUI_REBUILD:-0}" == "1" ]]; then
	echo "==> rebuilding bionic libopentui.so (OPENTUI_REBUILD=1)"
	bash "$ROOT_DIR/tools/transplant/build-libopentui.sh"
	TUI_DIR="$(dirname "$TUI_SO")"
	mkdir -p "$TUI_DIR"
	cp -f "$ROOT_DIR/artifacts/transplant/opentui-bionic/libopentui.so" "$TUI_DIR/libopentui.so"
else
	echo "==> opentui bionic runtime stale/broken (missing FFI symbols or unguarded)"
	echo "    TUI_SO=$TUI_SO"
	echo "    rebuild with: OPENTUI_REBUILD=1 $0 $VER  OR  make libopentui"
	exit 1
fi

# ── 1b. install linux platform packages (android bun reports platform=android) ──
echo "==> installing linux platform packages (pty, watcher)..."
cd "$SRC_DIR"
for pkg in "@opencode-ai/pty@0.1.13" "@parcel/watcher-linux-arm64-glibc@2.5.1"; do
	pkg_name="${pkg%%@*}"
	pkg_short="${pkg_name##*/}"
	# Check if already installed in store (any platform variant)
	if ls "$STORE"/${pkg_name//\//+}@*/node_modules/$pkg_name/package.json &>/dev/null; then
		echo "    $pkg_short already in store"
	else
		echo "    installing $pkg..."
		LD_PRELOAD="$OPENAT2_SHIM" "$ANDROID_BUN" install --force --ignore-scripts --os=linux --cpu=arm64 "$pkg" 2>&1 | tail -1 || true
	fi
	# Ensure platform-specific binary is in node_modules (store may use platform-agnostic key)
	PTY_BIN="$(find "$STORE" -path "*/$pkg_name/bin/opencode-pty" -type f 2>/dev/null | head -n1 || true)"
	if [[ -z "$PTY_BIN" ]]; then
		# Fallback: try platform-specific store key
		PTY_BIN="$(find "$STORE" -path "*/${pkg_name}-linux-arm64-gnu/bin/opencode-pty" -type f 2>/dev/null | head -n1 || true)"
	fi
	if [[ -n "$PTY_BIN" ]]; then
		# Create symlink in node_modules/@opencode-ai/pty-linux-arm64-gnu/bin/ if missing
		DEST_DIR="$SRC_DIR/node_modules/${pkg_name}-linux-arm64-gnu/bin"
		if [[ ! -f "$DEST_DIR/opencode-pty" && -n "$PTY_BIN" ]]; then
			mkdir -p "$DEST_DIR"
			cp -p "$PTY_BIN" "$DEST_DIR/opencode-pty" 2>/dev/null || true
		fi
	fi
done
cd "$SRC_DIR/packages/cli"

# ── 1c. re-deploy + HARD assertion (1b's `bun install --force` may have
# re-extracted the glibc @opentui platform package). The .so bun will embed
# MUST be bionic: a glibc embed dlopens "libm.so.6" at runtime and dies.
mapfile -t TUI_COPIES < <(find "$SRC_DIR/node_modules" -name libopentui.so -type f 2>/dev/null)
for _so in "${TUI_COPIES[@]}"; do
	cp -p "$BUILTIN" "$_so"
done
EMBED_SO="$SRC_DIR/node_modules/@opentui/core-linux-arm64/libopentui.so"
[[ -f "$EMBED_SO" ]] || EMBED_SO="$(find "$SRC_DIR/node_modules" -path '*core-linux-arm64*/libopentui.so' -type f 2>/dev/null | head -n1 || true)"
[[ -n "$EMBED_SO" && -f "$EMBED_SO" ]] || {
	echo "Error: cannot locate @opentui/core-linux-arm64/libopentui.so under $SRC_DIR/node_modules" >&2
	exit 1
}
EMBED_NEEDED="$(readelf -d "$EMBED_SO" 2>/dev/null || true)"
if grep -q 'libm\.so\.6' <<<"$EMBED_NEEDED"; then
	echo "Error: glibc libopentui.so would be embedded: $EMBED_SO (NEEDED libm.so.6)" >&2
	exit 1
fi
grep -q 'libm\.so\]' <<<"$EMBED_NEEDED" || {
	echo "Error: $EMBED_SO is not a bionic libopentui.so (no libm.so NEEDED)" >&2
	exit 1
}
bash "$ROOT_DIR/tools/transplant/build-libopentui.sh" --check "$EMBED_SO" >/dev/null 2>&1 || {
	echo "Error: $EMBED_SO failed the FFI guard self-check" >&2
	exit 1
}
echo "    embed assertion OK: $EMBED_SO is bionic + guard-verified"

# ── 2. platform patch (idempotent) ─────────────────────────────────────
CHUNK="$(ls -d "$STORE"/@opentui+core@*/ 2>/dev/null | head -n1 || true)"
: "${CHUNK:?Error: @opentui+core store chunk not found — run 'bun install --force --ignore-scripts' in $SRC_DIR}"
"$ULW_PATCH" "${CHUNK%/}"

# ── 3. bundler compile ─────────────────────────────────────────────────
cd "$SRC_DIR/packages/cli"
echo "==> compiling (android bun, target=opencode-linux-arm64)"
LD_PRELOAD="$OPENAT2_SHIM" OPENCODE_VERSION="$OPENCODE_VERSION" \
	"$ANDROID_BUN" script/build.ts --target=opencode-linux-arm64 --skip-install --skip-web-ui
DIST_BIN="$SRC_DIR/packages/cli/dist/cli-linux-arm64/bin/opencode"
[[ -x "$DIST_BIN" ]] || {
	echo "Error: build output missing: $DIST_BIN" >&2
	exit 1
}

# ── 4. normalize to packaging contract names ───────────────────────────
mkdir -p "$OUT_DIR"
mv -f "$DIST_BIN" "$OUT_DIR/opencode-native-revived"
sha256sum "$OUT_DIR/opencode-native-revived" | awk '{print $1}' >"$OUT_DIR/build.sha256"
echo "==> normalized: $OUT_DIR/opencode-native-revived ($(stat -c%s "$OUT_DIR/opencode-native-revived") B)"
echo "    sha256: $(cat "$OUT_DIR/build.sha256")"

# ── 4a. HARD post-compile assertion: embedded libopentui.so MUST be bionic ──
# Scans every embedded 64-bit LE ELF for SONAME=libopentui.so and rejects a
# glibc one (NEEDED libm.so.6). This is the regression gate for the 2.0.12 bug
# where bun embedded the glibc prebuilt and the product died at dlopen time.
python3 - "$OUT_DIR/opencode-native-revived" <<'PYEOF'
import struct, sys

path = sys.argv[1]
d = open(path, "rb").read()
start = 0
found = 0
bad = 0
while True:
    i = d.find(b"\x7fELF", start)
    if i < 0:
        break
    start = i + 1
    if i + 0x40 > len(d):
        continue
    if d[i + 4] != 2 or d[i + 5] != 1 or d[i + 6] != 1:
        continue  # not 64-bit little-endian
    try:
        e_phoff = struct.unpack_from("<Q", d, i + 0x20)[0]
        e_phentsize = struct.unpack_from("<H", d, i + 0x36)[0]
        e_phnum = struct.unpack_from("<H", d, i + 0x38)[0]
    except struct.error:
        continue
    if not e_phoff or not e_phentsize or not e_phnum:
        continue
    if i + e_phoff + e_phnum * e_phentsize > len(d):
        continue
    loads, dyn = [], None
    for k in range(e_phnum):
        p = i + e_phoff + k * e_phentsize
        t = struct.unpack_from("<I", d, p)[0]
        off = struct.unpack_from("<Q", d, p + 8)[0]
        va = struct.unpack_from("<Q", d, p + 16)[0]
        fsz = struct.unpack_from("<Q", d, p + 32)[0]
        if t == 1:
            loads.append((off, va, fsz))
        elif t == 2:
            dyn = (off, struct.unpack_from("<Q", d, p + 32)[0])
    if not dyn or not loads:
        continue
    do, ds = dyn
    if i + do + ds > len(d):
        continue
    def v2o(v):
        for off, va, fsz in loads:
            if va <= v < va + fsz:
                return i + off + (v - va)
        return None
    strtab, needed, soname = None, [], None
    for j in range(0, ds, 16):
        tag, val = struct.unpack_from("<QQ", d, i + do + j)
        if tag == 0:
            break
        if tag == 5:
            strtab = v2o(val)
        elif tag == 1:
            needed.append(val)
        elif tag == 14:
            soname = val
    if strtab is None:
        continue
    def s(n):
        e = d.find(b"\x00", strtab + n)
        return d[strtab + n:e].decode("latin1")
    son = s(soname) if soname is not None else None
    if son != "libopentui.so":
        continue
    found += 1
    names = [s(n) for n in needed]
    if any(x == "libm.so.6" for x in names):
        bad += 1
        print(f"Error: embedded libopentui.so at offset {i} is glibc (NEEDED {names})", file=sys.stderr)

if not found:
    print("Error: no embedded libopentui.so (SONAME) found in product", file=sys.stderr)
    sys.exit(1)
if bad:
    print("Error: product embeds a glibc libopentui.so; bionic embed required", file=sys.stderr)
    sys.exit(1)
print(f"    embed assertion OK: product embeds a bionic libopentui.so ({found} copy)")
PYEOF

# ── 4b. cleanup node_modules (save disk for batch builds) ──
echo "==> cleaning source tree node_modules to save disk..."
rm -rf "$SRC_DIR/node_modules" 2>/dev/null || true
rm -rf "$SRC_DIR/packages/cli/node_modules" 2>/dev/null || true

# ── 5. optional UPX variant ────────────────────────────────────────────
if [[ "${UPX:-0}" == "1" ]]; then
	if command -v upx >/dev/null 2>&1; then
		echo "==> UPX compressing (${UPX_OPTS:---best})"
		cp -p "$OUT_DIR/opencode-native-revived" "$OUT_DIR/opencode-native-revived-upx"
		upx ${UPX_OPTS:---best} --no-color "$OUT_DIR/opencode-native-revived-upx"
		sha256sum "$OUT_DIR/opencode-native-revived-upx" | awk '{print $1}' >"$OUT_DIR/build-upx.sha256"
		echo "    upx: $(stat -c%s "$OUT_DIR/opencode-native-revived-upx") B"
	else
		echo "WARN: upx not found; -upx variant skipped (set UPX=0 or install upx)" >&2
	fi
fi

# ── 6. provenance ──────────────────────────────────────────────────────
python3 - "$OUT_DIR" "$VER" "$SRC_DIR" "$ANDROID_BUN" <<'PYEOF'
import json, hashlib, os, sys
out_dir, ver, src, bun = sys.argv[1:5]
rec = {
  "version": ver,
  "kind": "native-b-line",
  "source": src,
  "android_bun": bun,
  "note": "compiled on android bun (bionic); TUI via grafted bionic libopentui.so; headless-channel reserve (A+/A-line) documented separately",
}
for name in ("opencode-native-revived", "opencode-native-revived-upx"):
    p = os.path.join(out_dir, name)
    if os.path.isfile(p):
        rec[name] = {
            "size": os.path.getsize(p),
            "sha256": hashlib.sha256(open(p, "rb").read()).hexdigest(),
        }
with open(os.path.join(out_dir, "build.json"), "w") as f:
    json.dump(rec, f, indent=2, ensure_ascii=False)
print("    wrote build.json")
PYEOF
echo "==> build-bionic done: $OUT_DIR"
