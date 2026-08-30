#!/usr/bin/env bash
# make-app.sh — construit le bundle `MlxTranslate.app` (GUI) à partir du target
# SwiftPM `MlxTranslateApp`, avec un Info.plist (CFBundleIdentifier stable) pour une
# identité TCC (« Enregistrement de l'écran ») stable. Usage : ./make-app.sh [debug|release]
set -euo pipefail

CONFIG="${1:-debug}"
cd "$(dirname "$0")"

echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG" --product mlxtranslateapp

BIN=".build/$CONFIG/mlxtranslateapp"
APP="build/MlxTranslate.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/mlxtranslateapp"

# Icone (facultatif) : si icône fournie, on l'emploie.
ICON="build/appicon.icns"
[ -f "$ICON" ] && cp "$ICON" "$APP/Contents/Resources/appicon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleExecutable</key><string>mlxtranslateapp</string>
    <key>CFBundleIdentifier</key><string>com.apoze.mlxtranslate</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleName</key><string>MlxTranslate</string>
    <key>CFBundleDisplayName</key><string>MlxTranslate</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> codesign (ad-hoc)"
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "   (codesign ad-hoc : $APP)"

echo "==> OK : $APP"
echo "    Lancer : open $APP"
