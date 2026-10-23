#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Lanebay"
APP_VERSION="${APP_VERSION:-0.1.0}"
BUNDLE_ID="${BUNDLE_ID:-com.lanebay.app}"
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-https://example.invalid/appcast.xml}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-YOUR_EDDSA_PUBLIC_KEY}"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lanebay-package.XXXXXX")"

cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

cd "$ROOT_DIR"
swift build -c release
mkdir -p "$DIST_DIR"
rm -rf "$APP_BUNDLE" "$DIST_DIR/$APP_NAME.dmg"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources" "$FRAMEWORKS_DIR"
cp "$ROOT_DIR/.build/release/$APP_NAME" "$CONTENTS_DIR/MacOS/$APP_NAME"

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>Lanebay</string>
  <key>CFBundleIdentifier</key><string>com.lanebay.app</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Lanebay</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Lanebay uses the microphone for local push-to-talk dictation that never leaves your Mac.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Lanebay uses on-device speech recognition so you can draft commands with push-to-talk.</string>
  <key>SUFeedURL</key><string>https://example.invalid/appcast.xml</string>
  <key>SUPublicEDKey</key><string>YOUR_EDDSA_PUBLIC_KEY</string>
  <key>SUEnableAutomaticChecks</key><false/>
  <key>SUAutomaticallyUpdate</key><false/>
</dict>
</plist>
PLIST

/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $APP_VERSION" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :SUFeedURL $SPARKLE_FEED_URL" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :SUPublicEDKey $SPARKLE_PUBLIC_ED_KEY" "$CONTENTS_DIR/Info.plist"

ICON_PATH="$(find "$ROOT_DIR" -path "$ROOT_DIR/.build" -prune -o -name '*.icns' -print -quit)"
if [[ -n "$ICON_PATH" ]]; then
  cp "$ICON_PATH" "$CONTENTS_DIR/Resources/Lanebay.icns"
  /usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string Lanebay' "$CONTENTS_DIR/Info.plist"
fi

SPARKLE_FRAMEWORK="$(find "$ROOT_DIR/.build" -name Sparkle.framework -type d -print -quit)"
if [[ -z "$SPARKLE_FRAMEWORK" ]]; then
  printf 'error: Sparkle.framework is missing from the SwiftPM build artifacts\n' >&2
  exit 1
fi
ditto "$SPARKLE_FRAMEWORK" "$FRAMEWORKS_DIR/Sparkle.framework"
cp "$ROOT_DIR/Vendor/Sparkle/LICENSE" "$CONTENTS_DIR/Resources/Sparkle-LICENSE.txt"
install_name_tool -add_rpath '@executable_path/../Frameworks' "$CONTENTS_DIR/MacOS/$APP_NAME"
codesign --force --deep -s - "$FRAMEWORKS_DIR/Sparkle.framework"

codesign --force --deep -s - "$APP_BUNDLE"

ln -s /Applications "$STAGING_DIR/Applications"
ditto "$APP_BUNDLE" "$STAGING_DIR/$APP_NAME.app"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DIST_DIR/$APP_NAME.dmg"

printf 'Created %s\n' "$DIST_DIR/$APP_NAME.dmg"
