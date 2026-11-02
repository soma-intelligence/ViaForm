#!/bin/sh
# Moves each engine submodule to the tip of its upstream default branch and prints what changed.
# Exit 0 with "changed=true" in $GITHUB_OUTPUT (when set) if anything moved.
# Usage: scripts/engine-sync.sh            (run from anywhere in the repo)
set -e
cd "$(dirname "$0")/.."
changed=false
summary=""
for engine in solidcraft pcbcraft; do
    dir="engines/$engine"
    git -C "$dir" fetch --quiet --tags origin
    branch=$(git -C "$dir" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)
    old=$(git -C "$dir" rev-parse HEAD)
    new=$(git -C "$dir" rev-parse "$branch")
    if [ "$old" != "$new" ]; then
        git -C "$dir" checkout --quiet "$new"
        tag=$(git -C "$dir" describe --tags --abbrev=0 "$new" 2>/dev/null || echo "no tag")
        count=$(git -C "$dir" rev-list --count "$old..$new")
        summary="$summary- **$engine**: ${old%"${old#???????}"}..${new%"${new#???????}"} ($count commits, latest tag $tag)
"
        changed=true
    fi
done
printf '%s' "$summary"
if [ -n "$GITHUB_OUTPUT" ]; then
    echo "changed=$changed" >> "$GITHUB_OUTPUT"
    { echo "summary<<EOF_SUMMARY"; printf '%s' "$summary"; echo "EOF_SUMMARY"; } >> "$GITHUB_OUTPUT"
fi
