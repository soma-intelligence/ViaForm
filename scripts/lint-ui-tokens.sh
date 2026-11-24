#!/usr/bin/env bash
# UI token lint (UI-UX-AUDIT P1-6, P1-7): Swift UI code under apple/ takes its type and colours
# from the design system in apple/Shared/UI/Theme. Fails when a file outside that folder uses
#   .system(size:     a hard-coded font size (use VFFont, VFFont.glyph or VFFont.icon)
#   Color(red:        a literal colour, SwiftUI or platform (use a theme token; any *Color(red:
#                     matches, so NSColor, UIColor, MTLClearColor and typealiases count too)
# and, outside comments, a literal ` mm"` (a length built by hand: show lengths through VFFormat,
# which follows the reader's display units, UI-UX-AUDIT P2-23).
# Justified exceptions go in scripts/lint-ui-tokens.allow, one per line:
#   <path relative to the repo root>    # why
#   units: <path>                       # why (exempts the file from the mm rule only)
# A path ending in / exempts the whole folder. Blank lines and lines starting with # are ignored.
#
# Usage: scripts/lint-ui-tokens.sh            (exit 0 clean, 1 with findings)
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
allow_file="scripts/lint-ui-tokens.allow"
theme_dir="apple/Shared/UI/Theme/"

allowed=()
units_allowed=()
if [ -f "$allow_file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        line="$(printf '%s' "$line" | sed -e 's/[[:space:]]*$//' -e 's/^[[:space:]]*//')"
        case "$line" in
            "") ;;
            units:*) units_allowed+=("$(printf '%s' "${line#units:}" | sed -e 's/^[[:space:]]*//')") ;;
            *) allowed+=("$line") ;;
        esac
    done < "$allow_file"
fi

# in_list <file> <entries...>: the file is listed, or sits in a listed folder (ending in /).
in_list() {
    local f="$1" a
    shift
    for a in "$@"; do
        case "$a" in
            */) case "$f" in "$a"*) return 0 ;; esac ;;
            *) [ "$f" = "$a" ] && return 0 ;;
        esac
    done
    return 1
}

is_allowed() {
    case "$1" in "$theme_dir"*) return 0 ;; esac
    in_list "$1" "${allowed[@]+"${allowed[@]}"}"
}

findings=0
while IFS= read -r -d '' f; do
    f="${f#./}"
    if ! in_list "$f" "${units_allowed[@]+"${units_allowed[@]}"}"; then
        # A hand-built length: ` mm"` on a line that is not a comment.
        if hits="$(grep -nF ' mm"' "$f" | grep -vE '^[0-9]+:[[:space:]]*//')"; then
            while IFS= read -r h; do
                echo "$f:$h  (show lengths through VFFormat)"
                findings=$((findings + 1))
            done <<< "$hits"
        fi
    fi
    is_allowed "$f" && continue
    # -F: the patterns are fixed strings, so the dots and parentheses are literal.
    if hits="$(grep -nF -e '.system(size:' -e 'Color(red:' "$f")"; then
        while IFS= read -r h; do
            echo "$f:$h"
            findings=$((findings + 1))
        done <<< "$hits"
    fi
done < <(find apple -name '*.swift' -not -path '*/build/*' -not -path '*/.build/*' -print0 | sort -z)

if [ "$findings" -gt 0 ]; then
    echo
    echo "lint-ui-tokens: $findings hard-coded font size(s), colour(s) or mm length(s) outside $theme_dir."
    echo "Use VFFont / theme colours / VFFormat, or add a justified entry to $allow_file."
    exit 1
fi
echo "lint-ui-tokens: clean (no .system(size: or Color(red: outside $theme_dir, no hand-built mm length)."
