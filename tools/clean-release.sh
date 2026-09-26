#!/usr/bin/env bash
# clean-release.sh — Clean stale/garbage assets from a GitHub release
# Usage: ./tools/clean-release.sh --tag Push260912 [--dry-run] [--confirm]
set -uo pipefail

TAG="" DRY=0 CONFIRM=0 REPO_SLUG="Hope2333/opencode-termux"

while [ $# -gt 0 ]; do
    case "$1" in
        --tag) TAG="$2"; shift 2 ;;
        --dry-run) DRY=1; shift ;;
        --confirm) CONFIRM=1; shift ;;
        *) echo "Unknown: $1" >&2; exit 1 ;;
    esac
done

[ -z "$TAG" ] && { echo "Usage: $0 --tag TAG [--dry-run] [--confirm]"; exit 1; }

echo "=== clean-release $TAG ==="
echo ""

# Fetch release assets
ASSETS=$(GIT_SSL_NO_VERIFY=1 GH_INSECURE=1 gh api "repos/$REPO_SLUG/releases/tags/$TAG" \
    --jq '.assets[] | "\(.id)\t\(.name)"' 2>/dev/null) || { echo "Error: cannot fetch release"; exit 1; }

TOTAL=$(echo "$ASSETS" | grep -c . || true)
echo "Total assets: $TOTAL"
echo ""

# Identify garbage
GARBAGE_IDS=()
GARBAGE_NAMES=()

while IFS=$'\t' read -r id name; do
    [ -n "$id" ] || continue
    is_garbage=0

    # Pattern 1: daily mirrorlist snapshots (keep only -latest)
    case "$name" in
        hope2333-mirrorlist-1.0.*-*-any.pkg.tar.xz)
            case "$name" in
                *latest*) ;;  # keep
                *) is_garbage=1 ;;
            esac
            ;;
    esac

    # Pattern 2: old db files
    case "$name" in
        hope2333.db|hope2333.db.tar.gz|hope2333_final.db|hope2333_final.db.tar.gz)
            is_garbage=1 ;;
    esac

    # Pattern 3: duplicate SHA256SUMS
    case "$name" in
        SHA256SUMS-*.txt)
            is_garbage=1 ;;
    esac

    if [ "$is_garbage" -eq 1 ]; then
        GARBAGE_IDS+=("$id")
        GARBAGE_NAMES+=("$name")
    fi
done <<< "$ASSETS"

echo "Garbage to remove: ${#GARBAGE_NAMES[@]}"
for name in "${GARBAGE_NAMES[@]}"; do
    echo "  - $name"
done
echo ""

if [ "${#GARBAGE_NAMES[@]}" -eq 0 ]; then
    echo "Nothing to clean."
    exit 0
fi

# Execute cleanup
if [ "$DRY" -eq 1 ]; then
    echo "DRY-RUN: would delete ${#GARBAGE_NAMES[@]} assets"
    exit 0
fi

if [ "$CONFIRM" -ne 1 ]; then
    echo "Set --confirm to execute deletion."
    exit 0
fi

echo "Deleting ${#GARBAGE_NAMES[@]} garbage assets..."
for i in "${!GARBAGE_IDS[@]}"; do
    echo "  Deleting ${GARBAGE_NAMES[$i]}..."
    GIT_SSL_NO_VERIFY=1 GH_INSECURE=1 gh api \
        -X DELETE "repos/$REPO_SLUG/releases/assets/${GARBAGE_IDS[$i]}" 2>/dev/null || {
        echo "    Warning: failed to delete ${GARBAGE_NAMES[$i]}"
    }
done

echo "=== Done: cleaned ${#GARBAGE_NAMES[@]} assets from $TAG ==="
