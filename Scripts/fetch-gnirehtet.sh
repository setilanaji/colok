#!/bin/bash
# gnirehtet ships prebuilt binaries for Linux and Windows only, so on Apple
# Silicon we build the Rust relay from source and take the APK from the release.
# Everything lands in ~/.colok, which is where Colok looks first.
set -euo pipefail

VERSION="${GNIREHTET_VERSION:-2.5.1}"
DEST="$HOME/.colok"
WORK="$(mktemp -d)"
mkdir -p "$DEST"

echo "==> fetching gnirehtet $VERSION"
curl -fsSL -o "$WORK/rel.zip" \
  "https://github.com/Genymobile/gnirehtet/releases/download/v${VERSION}/gnirehtet-rust-linux64-v${VERSION}.zip"
unzip -qo "$WORK/rel.zip" -d "$WORK"
APK="$(find "$WORK" -name 'gnirehtet.apk' | head -1)"
[[ -n "$APK" ]] || { echo "gnirehtet.apk not found in release archive" >&2; exit 1; }
cp "$APK" "$DEST/gnirehtet.apk"
echo "==> gnirehtet.apk -> $DEST/gnirehtet.apk"

if ! command -v cargo >/dev/null 2>&1; then
  echo "cargo not found - install Rust (https://rustup.rs) then re-run" >&2
  exit 1
fi

echo "==> building the relay for $(uname -m) (this takes a minute)"
git clone --depth 1 --branch "v${VERSION}" https://github.com/Genymobile/gnirehtet.git "$WORK/src" 2>/dev/null \
  || git clone --depth 1 https://github.com/Genymobile/gnirehtet.git "$WORK/src"
cd "$WORK/src/relay-rust"
cargo build --release
cp target/release/gnirehtet "$DEST/gnirehtet"
chmod +x "$DEST/gnirehtet"

echo "==> gnirehtet relay -> $DEST/gnirehtet"
rm -rf "$WORK"
echo "done. verify with: colok doctor"
