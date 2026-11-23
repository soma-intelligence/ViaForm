#!/usr/bin/env bash
# UI token lint (UI-UX-AUDIT P1-6, P1-7): Swift UI code under apple/ takes its type and colours
# from the design system in apple/Shared/UI/Theme. Fails when a file outside that folder uses
#   .system(size:     a hard-coded font size (use VFFont, VFFont.glyph or VFFont.icon)
#   Color(red:        a literal colour, SwiftUI or platform (use a theme token; any *Color(red:
#                     matches, so NSColor, UIColor, MTLClearColor and typealiases count too)
# Justified exceptions go in scripts/lint-ui-tokens.allow, one per line:
#   <path relative to the repo root>    # why
# A path ending in / exempts the whole folder. Blank lines and lines starting with # are ignored.
#
# Usage: scripts/lint-ui-tokens.sh            (exit 0 clean, 1 with findings)
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"
allow_file="scripts/lint-ui-tokens.allow"
theme_dir="apple/Shared/UI/Theme/"

allowed=()
if [ -f "$allow_file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"
        line="$(printf '%s' "$line" | sed -e 's/[[:space:]]*$//' -e 's/^[[:space:]]*//')"
        [ -n "$line" ] && allowed+=("$line")
    done < "$allow_file"
fi

is_allowed() {
    local f="$1" a
    case "$f" in "$theme_dir"*) return 0 ;; esac
    for a in "${allowed[@]+"${allowed[@]}"}"; do
        case "$a" in
            */) case "$f" in "$a"*) return 0 ;; esac ;;
            *) [ "$f" = "$a" ] && return 0 ;;
        esac
    done
    return 1
}

findings=0
while IFS= read -r -d '' f; do
    f="${f#./}"
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
    echo "lint-ui-tokens: $findings hard-coded font size(s) or colour(s) outside $theme_dir."
    echo "Use VFFont / theme colours, or add a justified entry to $allow_file."
    exit 1
fi
echo "lint-ui-tokens: clean (no .system(size: or Color(red: outside $theme_dir)."
