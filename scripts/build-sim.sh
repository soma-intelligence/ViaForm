#!/bin/sh
# Bundles the shared TypeScript simulation (electron/src/shared/sim) behind apple/Sim/entry.ts
# into one script for JavaScriptCore, at apple/Resources/viaform-sim.js. Xcode runs this before
# each build; it needs `npm ci` in electron/ once, for esbuild.
set -e
cd "$(dirname "$0")/.."
ESBUILD=electron/node_modules/.bin/esbuild
if [ ! -x "$ESBUILD" ]; then
    echo "error: $ESBUILD is missing; run npm ci in electron/" >&2
    exit 1
fi
mkdir -p apple/Resources
"$ESBUILD" apple/Sim/entry.ts --bundle --format=iife --target=es2020 --log-level=warning \
    --outfile=apple/Resources/viaform-sim.js
