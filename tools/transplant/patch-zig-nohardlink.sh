#!/data/data/com.termux/files/usr/bin/bash
#
# patch-zig-nohardlink.sh — disable Zig 0.16's O_TMPFILE fast path in the local
# Zig std library so `File.Atomic.link` uses the named-temp + renameat2 path.
#
# Why: Android SELinux denies hardlink()/linkat() under /data (EACCES). Zig's
# O_TMPFILE path opens the temp file unnamed via openat(O_TMPFILE) — which
# "succeeds" on bionic — then materializes it with linkat(AT_EMPTY_PATH), which
# is denied. The named-temp fallback uses renameat2(RENAME_NOREPLACE), which
# works, so forcing that path unblocks the native build.
#
# Idempotent: detects the patched condition and is a no-op on re-run. Keeps a
# one-time .orig backup. Restore with --restore.
#
# Usage:
#   patch-zig-nohardlink.sh [ZIG_LIB_DIR]
#   patch-zig-nohardlink.sh --restore [ZIG_LIB_DIR]
set -euo pipefail

ZIG_BIN="${ZIG_BIN:-$HOME/zig-aarch64-linux-0.16.0/zig}"
RESTORE=0
if [ "${1:-}" = "--restore" ]; then
	RESTORE=1
	shift
fi
ZIG_LIB_DIR="${1:-$(dirname "$ZIG_BIN")/lib}"

TARGET="$ZIG_LIB_DIR/std/Io/Threaded.zig"
[ -f "$TARGET" ] || {
	echo "ERROR: $TARGET not found (set ZIG_BIN or pass ZIG_LIB_DIR)" >&2
	exit 1
}

ORIG="$TARGET.nohardlink.orig"
UNPATCHED='if (native_os == .linux and !options.replace) tmpfile: {'
PATCHED='if (false and native_os == .linux and !options.replace) tmpfile: { // Android/Termux: no hardlinks under /data (SELinux EACCES); use named-temp + renameat2 instead.'

if [ "$RESTORE" -eq 1 ]; then
	if [ -f "$ORIG" ]; then
		cp -f "$ORIG" "$TARGET"
		rm -f "$ORIG"
		echo ">> restored $TARGET from backup"
	else
		echo ">> no backup at $ORIG; nothing to restore"
	fi
	exit 0
fi

if grep -qF "$PATCHED" "$TARGET"; then
	echo ">> zig O_TMPFILE fast path already disabled"
	exit 0
fi
grep -qF "$UNPATCHED" "$TARGET" || {
	echo "ERROR: expected O_TMPFILE guard not found in $TARGET — zig layout changed" >&2
	exit 1
}
[ -f "$ORIG" ] || cp -p "$TARGET" "$ORIG"
# Force the condition to always fall through to the named-temp path.
sed -i 's|if (native_os == .linux and !options.replace) tmpfile: {|if (false and native_os == .linux and !options.replace) tmpfile: { // Android/Termux: no hardlinks under /data (SELinux EACCES); use named-temp + renameat2 instead.|' "$TARGET"
grep -qF "$PATCHED" "$TARGET" || {
	echo "ERROR: patch did not apply" >&2
	exit 1
}
echo ">> disabled zig O_TMPFILE fast path in $TARGET (backup: $ORIG)"
