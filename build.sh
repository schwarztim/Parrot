#!/bin/bash
set -euo pipefail

# Parrot: Build, Bundle, Sign, and Launch
#
# Installs to /Applications/Parrot.app for stable TCC permissions.
# Uses a self-signed certificate ("Parrot Dev Signing") for hardened runtime.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/.build/debug"
APP_DIR="/Applications/Parrot.app"
BINARY_NAME="Parrot"
BUNDLE_ID="com.parrot.dev"
ENTITLEMENTS="$SCRIPT_DIR/Parrot/Parrot.entitlements"
APP_ICON="$SCRIPT_DIR/icon/AppIcon.icns"

# Ensure /Applications exists (should always exist)
mkdir -p "/Applications"

# Detect signing identity
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep "Parrot Dev Signing" | head -1 | awk -F'"' '{print $2}')
if [ -z "$IDENTITY" ]; then
    echo "⚠ No 'Parrot Dev Signing' certificate found. Using ad-hoc signing."
    echo "  TCC permissions may not persist across rebuilds."
    IDENTITY="-"
    SIGN_OPTS=""
else
    echo "✓ Signing with: $IDENTITY"
    SIGN_OPTS="--options runtime"
fi

# Build
echo "Building..."
swift build -c debug 2>&1 | grep -E "^(Building|Build|error:)" || true

if [ ! -f "$BUILD_DIR/$BINARY_NAME" ] || [ ! -f "$BUILD_DIR/parrot-agent-hook" ]; then
    echo "✗ Build failed"
    exit 1
fi

# Kill running instance
pkill -f "Parrot.app/Contents/MacOS/Parrot" 2>/dev/null || true
sleep 0.3

# Assemble .app bundle in ~/Applications
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BUILD_DIR/$BINARY_NAME" "$APP_DIR/Contents/MacOS/$BINARY_NAME"
# The agent hook helper ships next to the app binary; AgentInstaller looks there.
cp "$BUILD_DIR/parrot-agent-hook" "$APP_DIR/Contents/MacOS/parrot-agent-hook"

# App icon
if [ -f "$APP_ICON" ]; then
    cp "$APP_ICON" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

cat > "$APP_DIR/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$BINARY_NAME</string>
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>
    <string>$BINARY_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>LSUIElement</key>
    <false/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Parrot needs microphone access to record your voice for transcription.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Parrot uses Apple Events to pause Music and Spotify while you dictate and to run the scripts you attach to modes.</string>
    <key>NSContactsUsageDescription</key>
    <string>Parrot can include your name, email and phone from your Contacts card when a mode asks for it, so the AI can sign messages for you.</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>com.parrot.dev.url</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>parrot</string>
            </array>
        </dict>
    </array>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Audio Files</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.audio</string>
            </array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Video Files</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.movie</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST

# Sign. No nested frameworks, so --deep (deprecated) is unnecessary: sign the
# agent hook helper first (no entitlements), then the bundle.
echo "Signing..."
HOOK="$APP_DIR/Contents/MacOS/parrot-agent-hook"
if [ "$IDENTITY" = "-" ]; then
    codesign --force --sign - --identifier "$BUNDLE_ID.agent-hook" "$HOOK"
    codesign --force --sign - --identifier "$BUNDLE_ID" \
        --entitlements "$ENTITLEMENTS" "$APP_DIR"
else
    codesign --force --sign "$IDENTITY" $SIGN_OPTS --identifier "$BUNDLE_ID.agent-hook" "$HOOK"
    codesign --force --sign "$IDENTITY" $SIGN_OPTS \
        --entitlements "$ENTITLEMENTS" "$APP_DIR"
fi

echo "✓ Installed: $APP_DIR"

# Launch
if [ "${1:-}" = "--no-run" ]; then
    echo "Skipping launch (--no-run)"
else
    echo "Launching..."
    open "$APP_DIR"
fi
