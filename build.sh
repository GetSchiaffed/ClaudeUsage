#!/bin/bash
# build.sh — Builds ClaudeUsage.app from ClaudeUsage.swift
#
# Usage:
#   chmod +x build.sh
#   ./build.sh
#
# Then run with:
#   open ClaudeUsage.app
#
# To stop and rebuild:
#   pkill ClaudeUsage; ./build.sh && open ClaudeUsage.app

set -euo pipefail

APP_NAME="ClaudeUsage"
SWIFT_FILE="ClaudeUsage.swift"
BUNDLE_ID="com.claudeusage.app"

# Verify source file exists
if [[ ! -f "$SWIFT_FILE" ]]; then
    echo "Error: $SWIFT_FILE not found in current directory."
    echo "Run this script from the directory containing $SWIFT_FILE."
    exit 1
fi

# Verify Xcode command-line tools are available
if ! command -v swiftc &>/dev/null; then
    echo "Error: swiftc not found. Install Xcode Command Line Tools:"
    echo "  xcode-select --install"
    exit 1
fi

SDK=$(xcrun --sdk macosx --show-sdk-path 2>/dev/null)
if [[ -z "$SDK" ]]; then
    echo "Error: Could not find macOS SDK. Is Xcode installed?"
    exit 1
fi

# ── Step 1: Create .app bundle directory structure ──────────────────────────
APP_DIR="${APP_NAME}.app"
CONTENTS="${APP_DIR}/Contents"
MACOS="${CONTENTS}/MacOS"
RESOURCES="${CONTENTS}/Resources"

echo "Creating app bundle structure..."
rm -rf "${APP_DIR}"
mkdir -p "${MACOS}" "${RESOURCES}"

# ── Step 2: Write Info.plist ─────────────────────────────────────────────────
cat > "${CONTENTS}/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundleDisplayName</key>
    <string>Claude Usage</string>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>12.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHumanReadableCopyright</key>
    <string>Claude Usage Monitor</string>
    <key>NSAppleScriptEnabled</key>
    <true/>
</dict>
</plist>
EOF

echo "Info.plist written."

# ── Step 3: Detect architecture and compile ──────────────────────────────────
ARCH=$(uname -m)

if [[ "$ARCH" == "arm64" ]]; then
    TARGET="arm64-apple-macosx12.0"
else
    TARGET="x86_64-apple-macosx12.0"
fi

echo "Compiling ${SWIFT_FILE} for ${TARGET}..."

swiftc "${SWIFT_FILE}" \
    -o "${MACOS}/${APP_NAME}" \
    -sdk "${SDK}" \
    -target "${TARGET}" \
    -O \
    -suppress-warnings

echo ""
echo "✓ Build succeeded: ${APP_DIR}"
echo ""
echo "Run with:"
echo "  open ${APP_DIR}"
echo ""
echo "Stop with:"
echo "  pkill ${APP_NAME}"
echo ""
echo "Rebuild and restart:"
echo "  pkill ${APP_NAME} 2>/dev/null; ./build.sh && open ${APP_DIR}"
