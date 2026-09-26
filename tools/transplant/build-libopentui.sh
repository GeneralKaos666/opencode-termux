#!/usr/bin/env bash
#
# build-libopentui.sh — reproducible bionic build of libopentui.so
#
# Context: MiMo/opencode embed a glibc-built libopentui.so. On Android (bionic)
# that library cannot dlopen, so the main TUI hangs. This script rebuilds a
# *bionic* libopentui.so from OpenTUI source.
#
# Two source profiles:
#   native (canonical, w7b recipe — task-w7b-build.log): OpenTUI w7b tree
#     (packages/native, vendored zig-deps), zig 0.16.0 native aarch64 binary,
#     `zig build -Dlibrary-target=aarch64-linux-android` + BIONIC_* env +
#     runtime-generated libc.txt (hdrfix-merge include dir + bionic crt dir)
#     + LD_PRELOAD w7b-shim.so (hardlink EPERM under Android SELinux ->
#     copy fallback). Output: lib/aarch64-android/libopentui.so.
#   core (legacy 0.1.101): packages/core/src/zig layout, glibc-hosted zig
#     0.15.2 via the glibc loader, uucode prebuilt tables. Kept for history;
#     its export surface (~249 dynsyms) does NOT satisfy the 1.18.x host
#     (createEventSink et al), so do not use it for opencode swaps.
#
# Hard-won requirements (do not "simplify" these away):
#   1. The OpenTUI build.zig must call `lib.linkLibC()` on the `addLibrary`
#      step AND the libc spec must define lib_dir + dynamic_linker. Without
#      these Zig emits an unresolved `getauxval`, and the .so fails to dlopen
#      on bionic (TUI still hangs).
#   2. uucode's host table-generator breaks under a global `--libc`, so the
#      prebuilt tables.zig (generated once without --libc) is reused via the
#      UUCODE_USE_PREBUILT_TABLES env switch (see build.zig patch).
#   3. Guard v2 (task-tui-common-fix, root cause: batch builds swapped a
#      pre-fix libopentui.so because the patch was never applied at the
#      common build layer): ALL patches under patches/opentui/*.patch are
#      applied to the source tree BEFORE building (idempotently), and the
#      built .so is SELF-VERIFIED — bufferDrawChar must contain the FFI
#      negative-coordinate guard pattern (@min 0x7fffffff clamp + saturating
#      add). A build without the guard fails loudly.
#
# Modes:
#   build-libopentui.sh              apply patches + build + verify + install
#   build-libopentui.sh --check <so> only verify the guard pattern in <so>
#                                    (exit 0 = guarded, 1 = missing/unguarded)
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# --- configurable locations (override via env) ---------------------------------
# Default tree = the v2 OpenTUI fork's prepared work tree (upstream 0.5.11 +
# patches/series). Its Zig sources live in packages/native (termux-native
# profile). Legacy w7b/core trees can be selected via OPENTUI_ZIG_DIR.
OPENTUI_ZIG_DIR="${OPENTUI_ZIG_DIR:-$HOME/opentui/.work/opentui/packages/native}"
PATCH_DIR="${PATCH_DIR:-$REPO_ROOT/patches/opentui}"
INSTALL_PATH="${INSTALL_PATH:-$REPO_ROOT/artifacts/transplant/opentui-bionic/libopentui.so}"
GLIBC_LD="${GLIBC_LD:-/data/data/com.termux/files/usr/glibc/lib/ld-linux-aarch64.so.1}"
GLIBC_LIB="${GLIBC_LIB:-/data/data/com.termux/files/usr/glibc/lib}"
# Native profile toolchain: Zig 0.16.0 native aarch64 build (installed under
# $HOME on Termux). Also on PATH as `zig`; env-overridable.
ZIG_BIN="${ZIG_BIN:-$HOME/zig-aarch64-linux-0.16.0/zig}"
BIONIC_SYSROOT="${BIONIC_SYSROOT:-/data/data/com.termux/files/usr}"
BIONIC_HDRFIX="${BIONIC_HDRFIX:-${TMPDIR:-/tmp}/w7b-hdrfix}"
BIONIC_LIBM="${BIONIC_LIBM:-/system/lib64/libm.so}"
HDRFIX_MERGE_DIR="${HDRFIX_MERGE_DIR:-${TMPDIR:-/tmp}/w7b-hdrfix-merge}"
BIONIC_CRT_DIR="${BIONIC_CRT_DIR:-${TMPDIR:-/tmp}/w7b-bionic-lib}"
SYS_INCLUDE_DIR="${SYS_INCLUDE_DIR:-/data/data/com.termux/files/usr/include}"
SHIM_SO="${SHIM_SO:-$REPO_ROOT/tools/transplant/toolchain/w7b-shim.so}"
# Legacy core-profile knobs (0.1.101 + glibc-hosted zig 0.15.2).
CORE_ZIG_BIN="${CORE_ZIG_BIN:-/data/data/com.termux/files/usr/tmp/zig-0.15.2/zig-aarch64-linux-0.15.2/zig}"
CORE_LIBC_SPEC="${CORE_LIBC_SPEC:-/data/data/com.termux/files/usr/tmp/w7b-libc.txt}"
# termux-native profile knobs (packages/native, vendored zig-deps): API level,
# and the uv-independent cache dirs kept out of the source tree.
ANDROID_API_LEVEL="${ANDROID_API_LEVEL:-24}"
TERMUX_PREFIX="${TERMUX_PREFIX:-/data/data/com.termux/files/usr}"
CACHE_DIR="${ZIG_GLOBAL_CACHE_DIR:-$HOME/.cache/zig}"
# termux-native build caches (fresh per run to avoid stale-output reuse).
NATIVE_ZIG_LOCAL_CACHE="${NATIVE_ZIG_LOCAL_CACHE:-${TMPDIR:-/tmp}/opentui-zig-local-cache}"
NATIVE_ZIG_GLOBAL_CACHE="${NATIVE_ZIG_GLOBAL_CACHE:-${TMPDIR:-/tmp}/opentui-zig-global-cache}"
# MiMo embedded slot — incoming lib must be <= this after stripping.
MAX_SLOT="${MAX_SLOT:-4567704}"

# --- guard-pattern verification ------------------------------------------------
# The guard (patches/opentui/fix-drawchar-negative-coords.patch) compiles the
# @min(w/h, 0x7FFFFFFF) clamps + saturating adds inside isPointInScissor into:
#   mov wN, #0x7fffffff            (movn encoding)
#   csel wX, ..., vs               (saturating-add overflow select)
# inside the (inlined) bufferDrawChar text range. The unguarded build has
# neither (verified differentially on 1.18.27 batch vs crashfix v2 .so).
find_tool() {
	command -v "$1" >/dev/null 2>&1 && {
		echo "$1"
		return 0
	}
	command -v "$2" >/dev/null 2>&1 && {
		echo "$2"
		return 0
	}
	return 1
}

# Guard verification (task-tui-common-fix), single source of truth = the
# symbol-range scanner in swap_tui.py (inlining-agnostic: pattern location
# varies between inlined-into-bufferDrawChar and out-of-line builds; scanning
# all guard-owner symbol ranges discriminates guarded vs unguarded builds
# differentially: crashfix v2 clamp=4/csel=8, 1.18.27 batch 0/0).
guard_check() {
	local so="$1"
	python3 -c 'import sys; sys.path.insert(0, sys.argv[2] + "/tools/transplant"); from swap_tui import has_ffi_guard; sys.exit(0 if has_ffi_guard(open(sys.argv[1], "rb").read()) else 1)' "$so" "$REPO_ROOT"
}

# Behavioral gate: dlopen the built .so and hammer the guarded FFI
# entrypoints with hostile coords; a guarded .so survives, an unguarded one
# aborts with the production panic ("integer does not fit in destination
# type in lib.bufferDrawChar").
harness_check() {
	local so="$1"
	command -v clang >/dev/null 2>&1 || {
		echo ">> harness: clang not found, skipping behavioral gate (pattern scan already passed)" >&2
		return 0
	}
	local bin="$CACHE_DIR/ffi_guard_harness"
	if [ ! -x "$bin" ] || [ "$REPO_ROOT/tools/transplant/ffi_guard_harness.c" -nt "$bin" ]; then
		clang -O2 -o "$bin" "$REPO_ROOT/tools/transplant/ffi_guard_harness.c" -ldl ||
			{
				echo "GUARD-HARNESS ERROR: compile failed" >&2
				return 1
			}
	fi
	"$bin" "$so" || {
		echo "GUARD-HARNESS FAILED: hostile FFI cases killed the .so" >&2
		return 1
	}
	return 0
}

# --- mode dispatch --------------------------------------------------------------
if [ "${1:-}" = "--check" ]; then
	[ -n "${2:-}" ] || {
		echo "usage: $0 --check <libopentui.so>" >&2
		exit 1
	}
	[ -f "$2" ] || {
		echo "GUARD-CHECK FAILED: $2 not found" >&2
		exit 1
	}
	guard_check "$2"
	exit $?
fi

command -v llvm-strip >/dev/null 2>&1 || {
	echo "llvm-strip not found" >&2
	exit 1
}

# Profile detection:
#   termux-native = upstream >=0.5.6 layout: Zig sources in packages/native with
#     vendored zig-deps.tar.gz (native Termux recipe; v2 B-line).
#   native (w7b)  = legacy w7b tree (packages/native, hdrfix sysroot recipe).
#   core          = legacy 0.1.101 layout (packages/core/src/zig).
if [ -f "$OPENTUI_ZIG_DIR/build.zig" ] && [ -f "$OPENTUI_ZIG_DIR/src/vendor/zig-deps.tar.gz" ]; then
	PROFILE=termux-native
elif [ -f "$OPENTUI_ZIG_DIR/build.zig" ]; then
	PROFILE=native
else
	PROFILE=core
fi
echo ">> OpenTUI zig dir : $OPENTUI_ZIG_DIR (profile=$PROFILE)"
echo ">> patch dir       : $PATCH_DIR"

if [ "$PROFILE" = core ]; then
	ZIG="$CORE_ZIG_BIN"
	LIBC_SPEC="$CORE_LIBC_SPEC"
	OUT_DIR="${OUT_DIR:-$OPENTUI_ZIG_DIR/lib/aarch64-linux-android}"
	echo ">> glibc loader    : $GLIBC_LD"
	echo ">> zig binary      : $ZIG"
	echo ">> libc spec       : $LIBC_SPEC"
	[ -x "$GLIBC_LD" ] || {
		echo "glibc loader missing: $GLIBC_LD" >&2
		exit 1
	}
	[ -f "$LIBC_SPEC" ] || {
		echo "libc spec missing: $LIBC_SPEC" >&2
		exit 1
	}
elif [ "$PROFILE" = termux-native ]; then
	ZIG="$ZIG_BIN"
	OUT_DIR="${OUT_DIR:-$OPENTUI_ZIG_DIR/lib/aarch64-android}"
	DEPS_ARCHIVE="$OPENTUI_ZIG_DIR/src/vendor/zig-deps.tar.gz"
	echo ">> zig binary      : $ZIG"
	echo ">> termux prefix   : $TERMUX_PREFIX"
	echo ">> deps archive    : $DEPS_ARCHIVE"
	echo ">> shim            : $SHIM_SO"
	[ -x "$ZIG" ] || {
		echo "zig 0.16 binary missing: $ZIG" >&2
		exit 1
	}
	[ -f "$DEPS_ARCHIVE" ] || {
		echo "vendored zig-deps missing: $DEPS_ARCHIVE" >&2
		exit 1
	}
	[ -d "$TERMUX_PREFIX/include/aarch64-linux-android/asm" ] || {
		echo "arch asm headers missing (pkg install ndk-sysroot)" >&2
		exit 1
	}
	[ -f "$TERMUX_PREFIX/lib/libc++_shared.so" ] || {
		echo "libc++_shared.so missing (pkg install libc++)" >&2
		exit 1
	}
	[ -f "$TERMUX_PREFIX/lib/libunwind.a" ] || {
		echo "libunwind.a missing" >&2
		exit 1
	}
	[ -f "$SHIM_SO" ] || {
		echo "LD_PRELOAD shim missing: $SHIM_SO" >&2
		exit 1
	}

	# The fork's translate-c compat shim carries a placeholder for the real
	# Bionic sys/time.h (nullable fixed-size array workaround). Substitute it in
	# place; idempotent because the placeholder is gone after the first run.
	TRANSLATE_COMPAT_HEADER="$OPENTUI_ZIG_DIR/src/android-translate-compat/sys/time.h"
	if [ -f "$TRANSLATE_COMPAT_HEADER" ] && grep -q '@ANDROIDTUI_SYS_TIME_HEADER@' "$TRANSLATE_COMPAT_HEADER"; then
		sed -i "s,@ANDROIDTUI_SYS_TIME_HEADER@,$TERMUX_PREFIX/include/sys/time.h,g" "$TRANSLATE_COMPAT_HEADER"
		echo ">>   substituted sys/time.h placeholder in translate-compat header"
	fi
else
	ZIG="$ZIG_BIN"
	OUT_DIR="${OUT_DIR:-$OPENTUI_ZIG_DIR/lib/aarch64-android}"
	echo ">> zig binary      : $ZIG"
	echo ">> bionic sysroot  : $BIONIC_SYSROOT"
	echo ">> hdrfix          : $BIONIC_HDRFIX"
	echo ">> shim            : $SHIM_SO"
	[ -x "$ZIG" ] || {
		echo "zig 0.16 binary missing: $ZIG" >&2
		exit 1
	}
	[ -d "$BIONIC_HDRFIX" ] || {
		echo "hdrfix dir missing: $BIONIC_HDRFIX" >&2
		exit 1
	}
	[ -d "$HDRFIX_MERGE_DIR" ] || {
		echo "hdrfix-merge dir missing: $HDRFIX_MERGE_DIR" >&2
		exit 1
	}
	[ -d "$BIONIC_CRT_DIR" ] || {
		echo "bionic crt dir missing: $BIONIC_CRT_DIR" >&2
		exit 1
	}
	[ -f "$SHIM_SO" ] || {
		echo "LD_PRELOAD shim missing: $SHIM_SO" >&2
		exit 1
	}
fi
[ -x "$ZIG" ] || {
	echo "zig binary missing: $ZIG" >&2
	exit 1
}

# --- phase 0: apply ALL patches/opentui/*.patch (idempotent, fail on reject) ----
# tree root = the directory CONTAINING packages/ (handles both layouts:
# packages/native and packages/core/src/zig)
OPENTUI_TREE="$(cd "$OPENTUI_ZIG_DIR" && while [ "$(basename "$PWD")" != "packages" ] && [ "$PWD" != "/" ]; do cd ..; done && cd .. && pwd)"
command -v patch >/dev/null 2>&1 || {
	echo "patch(1) not found" >&2
	exit 1
}
shopt -s nullglob
PATCHES=("$PATCH_DIR"/*.patch)
shopt -u nullglob
for p in "${PATCHES[@]}"; do
	echo ">> patch: $p"
	# reverse-check FIRST: patch(1) -N --forward silently skips a mixed-state
	# file ("Reversed (or previously applied) patch detected", exit 0), which
	# would leave half-applied guards in the tree unnoticed.
	if patch -d "$OPENTUI_TREE" -p1 -R --dry-run <"$p" >/dev/null 2>&1; then
		echo ">>   already applied, skipping"
	elif patch -d "$OPENTUI_TREE" -p1 -N --forward --dry-run <"$p" >/dev/null 2>&1; then
		patch -d "$OPENTUI_TREE" -p1 -N --forward <"$p"
	else
		# Drift (e.g. tree already carries an equivalent guard with local comment
		# variants). NOT fatal: the semantic post-check below gates the build on
		# actual guard presence, so a genuinely unguarded tree still aborts.
		echo "WARN: patch drift on $OPENTUI_TREE — relying on semantic guard verification"
	fi
done

# Semantic post-check: regardless of what patch(1) decided, the tree MUST end
# up with the full guard set. Fail loudly if anything is absent.
BUF="$(find "$OPENTUI_TREE/packages" -maxdepth 3 -name buffer.zig | head -1)"
RND="$(find "$OPENTUI_TREE/packages" -maxdepth 3 -name renderer.zig | head -1)"
[ -n "$BUF" ] && [ -n "$RND" ] || {
	echo "ERROR: buffer.zig/renderer.zig not found under $OPENTUI_TREE/packages" >&2
	exit 1
}
sem_fail=0
sem() { grep -qF "$2" "$1" || {
	echo "ERROR: guard missing in $1: $2" >&2
	sem_fail=1
}; }
sem "$BUF" '@min(scissor.width, 0x7FFFFFFF)'
sem "$BUF" 'if (x >= 0x80000000 or y >= 0x80000000) return;'
sem "$BUF" 'if (posX < -0x40000000 or posY < -0x40000000) return;'
sem "$BUF" 'if (y <= -0x40000000) return;'
sem "$RND" '@min(width, 0x7FFFFFFF)'
[ "$sem_fail" -eq 0 ] || exit 1
echo ">> semantic patch verification: OK"

cd "$OPENTUI_ZIG_DIR"
export ZIG_GLOBAL_CACHE_DIR="$CACHE_DIR"

if [ "$PROFILE" = core ]; then
	# If the prebuilt tables.zig is absent, generate it first WITHOUT --libc (the
	# only step that needs the host toolchain), then the real build reuses it.
	if [ ! -f "zig-pkg/uucode-0.1.0-"*"/prebuilt_tables.zig" ]; then
		echo ">> phase 1: generate uucode tables.zig (no --libc)"
		UUCODE_USE_PREBUILT_TABLES= \
			"$GLIBC_LD" --library-path "$GLIBC_LIB" "$ZIG" build \
			-Dtarget=aarch64-linux-android -Doptimize=ReleaseSafe
	fi

	echo ">> phase 2: build bionic libopentui.so (with --libc)"
	export UUCODE_USE_PREBUILT_TABLES=1
	"$GLIBC_LD" --library-path "$GLIBC_LIB" "$ZIG" build \
		-Dtarget=aarch64-linux-android -Doptimize=ReleaseSafe \
		--libc "$LIBC_SPEC"
elif [ "$PROFILE" = termux-native ]; then
	# Native Termux recipe (upstream packages/native + vendored zig-deps):
	#   1. extract zig-deps without a hardlink mutex (Android SELinux denies
	#      hardlinks under /data, which deadlocks upstream's prepare script)
	#   2. generate a disposable linker sysroot + libc spec pointing at Termux's
	#      real Bionic headers/libs, and expose it via ZIG_LIBC +
	#      ANDROIDTUI_ANDROID_* (consumed by the tree's build.zig android branch)
	#   3. zig build -Dlibrary-target (NOT -Dtarget: that retargets the exported
	#      "opentui" module and would build the host library instead)
	# LD_PRELOAD shim survives the same SELinux hardlink ban inside zig's cache.
	DEPS_DIR="$OPENTUI_ZIG_DIR/zig-deps"
	DEPS_ID="$(cksum "$DEPS_ARCHIVE")"
	if [ "$(cat "$DEPS_DIR/.ready" 2>/dev/null)" = "$DEPS_ID" ]; then
		echo ">>   zig-deps already extracted"
	else
		rm -rf "$OPENTUI_ZIG_DIR/.zig-deps.lock" "$OPENTUI_ZIG_DIR"/.zig-deps.*.owner "$OPENTUI_ZIG_DIR"/.zig-deps.*.tmp
		DEPS_TMP="$OPENTUI_ZIG_DIR/.zig-deps.$$.tmp"
		mkdir -p "$DEPS_TMP"
		tar -xzf "$DEPS_ARCHIVE" -C "$DEPS_TMP"
		printf '%s\n' "$DEPS_ID" >"$DEPS_TMP/.ready"
		rm -rf "$DEPS_DIR"
		mv "$DEPS_TMP" "$DEPS_DIR"
		echo ">>   zig-deps extracted: $DEPS_DIR"
	fi

	# Disposable linker sysroot (crt objects + resolved Bionic libc/libm/libdl).
	LINKER_STUBS_DIR="$OPENTUI_TREE/.zig-linker-stubs"
	mkdir -p "$LINKER_STUBS_DIR"
	CRT_MATCH="$(find "$TERMUX_PREFIX/lib" "$TERMUX_PREFIX/lib64" -name 'crtbegin_so.o' 2>/dev/null | head -1)"
	[ -n "$CRT_MATCH" ] || {
		echo "crtbegin_so.o not found under $TERMUX_PREFIX (pkg install ndk-sysroot clang)" >&2
		exit 1
	}
	SYSTEM_LIBDIR=""
	if [ -f "/apex/com.android.runtime/lib64/bionic/libc.so" ]; then
		SYSTEM_LIBDIR="/apex/com.android.runtime/lib64/bionic"
	elif [ -f "/system/lib64/libc.so" ]; then
		SYSTEM_LIBDIR="/system/lib64"
	elif [ -f "$TERMUX_PREFIX/aarch64-linux-android/lib/libc.so" ]; then
		SYSTEM_LIBDIR="$TERMUX_PREFIX/aarch64-linux-android/lib"
	else
		echo "cannot find Bionic libc.so (checked APEX, /system/lib64, Termux prefix)" >&2
		exit 1
	fi
	cp "$(dirname "$CRT_MATCH")/crtbegin_so.o" "$LINKER_STUBS_DIR/crtbegin_so.o"
	cp "$(dirname "$CRT_MATCH")/crtend_so.o" "$LINKER_STUBS_DIR/crtend_so.o"
	for lib in libc libm libdl; do
		src="$SYSTEM_LIBDIR/$lib.so"
		[ -f "$src" ] || {
			echo "$lib.so not found at $src" >&2
			exit 1
		}
		cp "$(readlink -f "$src" 2>/dev/null || echo "$src")" "$LINKER_STUBS_DIR/$lib.so"
	done

	# Zig libc spec: real Termux includes, disposable crt dir.
	LIBC_SPEC="$(mktemp "${TMPDIR:-/tmp}/opentui-native-libc.XXXXXX.txt")"
	{
		echo "include_dir=$TERMUX_PREFIX/include"
		echo "sys_include_dir=$TERMUX_PREFIX/include"
		echo "crt_dir=$LINKER_STUBS_DIR"
		echo "msvc_lib_dir="
		echo "kernel32_lib_dir="
		echo "gcc_dir="
	} >"$LIBC_SPEC"

	# libc++ headers (Yoga C++): find the v1 include dir.
	LIBCXX_INCLUDE=""
	for candidate in "$TERMUX_PREFIX/include/c++/v1" "$TERMUX_PREFIX/include/c++"/*/v1 "$TERMUX_PREFIX/include"/*/c++/v1; do
		if [ -f "$candidate/type_traits" ] 2>/dev/null; then
			LIBCXX_INCLUDE="$candidate"
			break
		fi
	done
	[ -n "$LIBCXX_INCLUDE" ] || {
		echo "libc++ headers (type_traits) not found (apt install --reinstall libc++)" >&2
		exit 1
	}

	# Android SELinux denies hardlinks under /data; disable zig's O_TMPFILE
	# fast path so Atomic.link uses renameat2(RENAME_NOREPLACE) instead.
	bash "$REPO_ROOT/tools/transplant/patch-zig-nohardlink.sh" "$(dirname "$ZIG")/lib"

	rm -rf "$OPENTUI_ZIG_DIR/zig-out" "$OPENTUI_ZIG_DIR/.zig-cache" "$OPENTUI_ZIG_DIR/lib" 2>/dev/null || true
	rm -rf "$NATIVE_ZIG_LOCAL_CACHE" "$NATIVE_ZIG_GLOBAL_CACHE"
	mkdir -p "$NATIVE_ZIG_LOCAL_CACHE" "$NATIVE_ZIG_GLOBAL_CACHE"

	echo ">> phase 2: build bionic libopentui.so (native zig 0.16, termux recipe)"
	ANDROID_API_LEVEL="$ANDROID_API_LEVEL" \
		ZIG_LIBC="$LIBC_SPEC" \
		ZIG_LOCAL_CACHE_DIR="$NATIVE_ZIG_LOCAL_CACHE" \
		ZIG_GLOBAL_CACHE_DIR="$NATIVE_ZIG_GLOBAL_CACHE" \
		ANDROIDTUI_ANDROID_ASM_INCLUDE="$TERMUX_PREFIX/include/aarch64-linux-android" \
		ANDROIDTUI_ANDROID_LIB_PATH="$TERMUX_PREFIX/lib" \
		ANDROIDTUI_ANDROID_LIB_SEARCH_PATHS="$TERMUX_PREFIX/lib:$LINKER_STUBS_DIR" \
		ANDROIDTUI_ANDROID_LIBCXX_PATH="$TERMUX_PREFIX/lib/libc++_shared.so" \
		ANDROIDTUI_ANDROID_LIBCXX_INCLUDE="$LIBCXX_INCLUDE" \
		ANDROIDTUI_ANDROID_LIBCXX_INCLUDE2="$(dirname "$LIBCXX_INCLUDE")" \
		ANDROIDTUI_ANDROID_LIBUNWIND_PATH="$TERMUX_PREFIX/lib/libunwind.a" \
		LD_PRELOAD="$SHIM_SO" \
		"$ZIG" build \
		-Dlibrary-target="aarch64-linux-android.${ANDROID_API_LEVEL}" \
		-Doptimize=ReleaseSafe
else
	# w7b recipe: runtime-generated libc.txt (absolute paths from env knobs),
	# BIONIC_* env consumed by the tree's build.zig android branch, and the
	# LD_PRELOAD shim to survive Android SELinux's hardlink ban in zig's cache.
	LIBC_SPEC="$(mktemp "${TMPDIR:-/tmp}/opentui-libc.XXXXXX.txt")"
	{
		echo "include_dir=$HDRFIX_MERGE_DIR"
		echo "sys_include_dir=$SYS_INCLUDE_DIR"
		echo "crt_dir=$BIONIC_CRT_DIR"
		echo "msvc_lib_dir="
		echo "kernel32_lib_dir="
		echo "gcc_dir="
	} >"$LIBC_SPEC"

	echo ">> phase 2: build bionic libopentui.so (native zig 0.16, w7b recipe)"
	LD_PRELOAD="$SHIM_SO" \
		BIONIC_SYSROOT="$BIONIC_SYSROOT" \
		BIONIC_HDRFIX="$BIONIC_HDRFIX" \
		BIONIC_LIBM="$BIONIC_LIBM" \
		"$ZIG" build \
		-Dlibrary-target=aarch64-linux-android -Doptimize=ReleaseSafe \
		--libc "$LIBC_SPEC"
fi

SO="$OUT_DIR/libopentui.so"
if [ ! -f "$SO" ]; then
	echo "build did not produce $SO; searching tree..." >&2
	FOUND="$(find "$OPENTUI_ZIG_DIR" "$OPENTUI_ZIG_DIR/zig-out" -name 'libopentui.so' 2>/dev/null | head -1)"
	[ -n "$FOUND" ] && SO="$FOUND"
fi
[ -f "$SO" ] || {
	echo "build did not produce any libopentui.so" >&2
	exit 1
}

echo ">> strip debug info"
llvm-strip --strip-debug "$SO"

SIZE=$(stat -c '%s' "$SO")
echo ">> size: $SIZE bytes (slot limit $MAX_SLOT)"
if [ "$SIZE" -gt "$MAX_SLOT" ]; then
	echo "WARN: $SO ($SIZE) exceeds advisory slot $MAX_SLOT (authoritative per-binary slot check is swap_tui.py)" >&2
fi

echo ">> verify NEEDED libc (getauxval must resolve on bionic)"
if ! llvm-readelf -d "$SO" 2>/dev/null | grep -q 'NEEDED.*libc.so'; then
	echo "ERROR: libc.so not in NEEDED — linkLibC missing, dlopen will fail on bionic" >&2
	exit 1
fi

echo ">> phase 3: self-verify FFI guard (task-tui-common-fix)"
guard_check "$SO"
harness_check "$SO"

INSTALL_DIR="$(dirname "$INSTALL_PATH")"
mkdir -p "$INSTALL_DIR"
cp -f "$SO" "$INSTALL_PATH"
echo ">> installed: $INSTALL_PATH ($SIZE bytes)"

echo ">> OK: $INSTALL_PATH is a bionic-loadable, guard-verified libopentui.so"
