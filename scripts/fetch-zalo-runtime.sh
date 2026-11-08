#!/bin/zsh
# Prepares the official Zalo runtime for the iOS build, on your Mac.
#
# iOS cannot open a DMG or check a macOS code signature, so this is done once on the Mac that builds the app:
#   1. downloads the Zalo PC DMG pinned in ZaloRuntimeInstaller.swift from VNG (or uses ZALO_DMG=/path/to.dmg),
#   2. checks its SHA-256 against the pin,
#   3. mounts it and checks VNG's code signature on Zalo.app (same requirement as the macOS installer),
#   4. copies only Contents/Info.plist and Contents/Resources/app.asar into iOS/ZaloRuntime/ (gitignored).
#
# The iOS target bundles iOS/ZaloRuntime as a folder resource. Nothing from VNG is committed to the repository, and
# the resulting app is for your own devices only.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="Sources/Olaz/ZaloRuntime/ZaloRuntimeInstaller.swift"
VERSION=$(grep -A3 'static let pinned = Release(' "$SRC" | sed -nE 's/.*version: "([0-9.]+)".*/\1/p')
URL=$(grep -A3 'static let pinned = Release(' "$SRC" | sed -nE 's/.*URL\(string: "([^"]+)"\).*/\1/p')
SHA=$(grep -A3 'static let pinned = Release(' "$SRC" | sed -nE 's/.*sha256: "([0-9a-f]+)".*/\1/p')
REQUIREMENT='anchor apple generic and identifier "com.vng.zalo" and certificate leaf[subject.OU] = "CVB6BX97VM"'
OUT="iOS/ZaloRuntime"
WORK=$(mktemp -d)
MOUNT="$WORK/mnt"
trap 'hdiutil detach "$MOUNT" -force >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT

if [[ -f "$OUT/Contents/Resources/app.asar" ]] && \
   [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$OUT/Contents/Info.plist" 2>/dev/null)" == "$VERSION" ]]; then
    echo "Zalo runtime $VERSION already in $OUT"
    exit 0
fi

DMG="${ZALO_DMG:-}"
if [[ -z "$DMG" ]]; then
    DMG="$WORK/zalo.dmg"
    echo "Downloading Zalo PC $VERSION from VNG…"
    curl -fL --progress-bar -A "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)" -o "$DMG" "$URL"
fi

echo "Checking SHA-256…"
ACTUAL=$(shasum -a 256 "$DMG" | awk '{print $1}')
if [[ -n "$SHA" && "$ACTUAL" != "$SHA" ]]; then
    echo "error: SHA-256 mismatch for $DMG (expected $SHA, got $ACTUAL)" >&2
    exit 1
fi

mkdir -p "$MOUNT"
hdiutil attach -nobrowse -readonly -noautoopen -mountpoint "$MOUNT" "$DMG" >/dev/null
APP=$(find "$MOUNT" -maxdepth 2 -name "Zalo.app" -type d | head -1)
[[ -n "$APP" ]] || { echo "error: Zalo.app not found in the DMG" >&2; exit 1; }

echo "Checking VNG's code signature…"
codesign --verify --deep --strict -R="$REQUIREMENT" "$APP"

rm -rf "$OUT"
mkdir -p "$OUT/Contents/Resources"
cp "$APP/Contents/Info.plist" "$OUT/Contents/Info.plist"
cp "$APP/Contents/Resources/app.asar" "$OUT/Contents/Resources/app.asar"
echo "Zalo runtime $VERSION ready in $OUT ($(du -sh "$OUT" | awk '{print $1}'))"
