#!/bin/sh
# Builds the Rust bridge (bridge/) for macOS, iOS devices and the iOS simulator.
# Usage: scripts/build-bridge.sh [release|debug]   (default release)
set -e
cd "$(dirname "$0")/../bridge"
PROFILE="${1:-release}"
FLAG=""
[ "$PROFILE" = "release" ] && FLAG="--release"
export IPHONEOS_DEPLOYMENT_TARGET=17.0 MACOSX_DEPLOYMENT_TARGET=14.0
for target in aarch64-apple-darwin aarch64-apple-ios aarch64-apple-ios-sim; do
    echo "== $target"
    cargo build $FLAG --target "$target"
done
