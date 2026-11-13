#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Build the public Vue frontend and its matching Tauri host from the same revision.
set -eu
root=$(pwd)
build=$(realpath -m "${1:?build directory}")
revision=5410f6d30e1061607c8ccbbca7c6c7f1cc474951
mkdir -p "$build"
source=${SAYALL_PUBLIC_CHECKOUT:-"$build/public.git"}
if [ ! -d "$source" ]; then git init --bare "$source"; fi
if ! git -C "$source" cat-file -e "$revision^{commit}" 2>/dev/null; then
    git -C "$source" fetch --depth 1 https://github.com/GetSayAll/remote-mic-app-windows.git "$revision"
fi
stage=$(mktemp -d "$build/desktop.XXXXXX")
trap 'rm -rf "$stage"' EXIT
git -C "$source" archive "$revision" | tar x -C "$stage"
patch --batch --fuzz=0 -d "$stage" -p1 < "$root/packaging/ubuntu/desktop.patch"
cp "$root"/Apps/Ubuntu/desktop/*.rs "$stage/crates/sayall-windows/src/"
mv "$stage/crates/sayall-windows/src/ubuntu_capture.rs" "$stage/src-tauri/src/"
cp "$root/Apps/Ubuntu/desktop/ubuntu-messages.ts" "$stage/src/lib/"
cp "$root/Tests/Ubuntu/desktop.test.ts" "$stage/src/lib/ubuntu-desktop.test.ts"
cp "$root/packaging/ubuntu/tauri.linux.conf.json" "$stage/src-tauri/"
/usr/bin/python3 "$root/packaging/ubuntu/icons.py" "$stage"
cd "$stage"
pnpm install --frozen-lockfile --ignore-scripts
if [ "${SAYALL_TEST_FRONTEND:-0}" = 1 ]; then pnpm exec vitest run --maxWorkers=2; fi
pnpm run build
export CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$build/cargo-target}"
export SAYALL_SOURCE_REVISION="$revision"
cargo build --locked --release --features tauri/custom-protocol -p sayall-windows-app -p sayall-mcp
install -m755 "$CARGO_TARGET_DIR/release/sayall-windows-app" "$build/sayall-desktop"
install -m755 "$CARGO_TARGET_DIR/release/sayall-mcp" "$build/sayall-mcp"
strip --strip-unneeded "$build/sayall-desktop" "$build/sayall-mcp"
install -m644 src-tauri/icons/icon.png "$build/sayall.png"
install -m644 public/fonts/OFL.txt "$build/desktop-font-OFL.txt"
for notice in LICENSE ATTRIBUTION.md THIRD_PARTY_NOTICES.md; do install -m644 "$notice" "$build/desktop-$notice"; done
