#!/bin/bash
# Compila Upgrady e crea build/Upgrady.app (con Sparkle.framework incorporato).
# Requisiti: Xcode (Swift 5.9+), macOS 14+.
#
# Uso: ./build_app.sh            → build/Upgrady.app
#      ./build_app.sh --install  → anche installata in /Applications e avviata
#      ./build_app.sh --zip      → anche dist/Upgrady_v<versione>.zip per la release
#
# Con BETA=1 l'app si chiama "Upgrady Beta" con un identificativo separato, così convive con la versione in uso.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"
BUILD="$ROOT/build"
VERSION="2.0.0"
BUILD_NUMBER="1"
BETA="${BETA:-0}"
if [ "$BETA" = "1" ]; then
    NAME="Upgrady Beta"; BUNDLE_ID="com.github.gionnio.Upgrady.beta"
else
    NAME="Upgrady"; BUNDLE_ID="com.github.gionnio.Upgrady"
fi
APP="$BUILD/$NAME.app"

# Sparkle (MIT): versione fissa, scaricata dalla release ufficiale e verificata con il checksum pubblicato.
SPARKLE_VERSION="2.10.0"
SPARKLE_SHA256="17e28312b8e18ab7cdbbe09a6fb28cc55a5479ec6c371dbc07cdecd2a14fd959"
if [ ! -d "$ROOT/Vendor/Sparkle.xcframework" ]; then
    echo "▸ Scarico Sparkle $SPARKLE_VERSION"
    mkdir -p "$ROOT/Vendor"
    ZIP="$(mktemp -d)/sparkle.zip"
    curl -fsSL -o "$ZIP" "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-for-Swift-Package-Manager.zip"
    echo "$SPARKLE_SHA256  $ZIP" | shasum -a 256 -c - >/dev/null
    ditto -x -k "$ZIP" "$ROOT/Vendor/sparkle-tmp"
    mv "$ROOT/Vendor/sparkle-tmp/Sparkle.xcframework" "$ROOT/Vendor/"
    cp "$ROOT/Vendor/sparkle-tmp/LICENSE" "$ROOT/Vendor/Sparkle-LICENSE"
    rm -rf "$ROOT/Vendor/sparkle-tmp"
fi

echo "▸ Compilo"
swift build -c release --arch arm64 --arch x86_64
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"

echo "▸ Bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/Upgrady" "$APP/Contents/MacOS/Upgrady"
cp -R "$ROOT/Resources/"*.lproj "$APP/Contents/Resources/"
cp "$ROOT/Vendor/Sparkle-LICENSE" "$APP/Contents/Resources/Sparkle-LICENSE.txt"

# Sparkle: il framework universale scaricato da Swift Package Manager.
SPARKLE="$(find "$ROOT/Vendor/Sparkle.xcframework" -maxdepth 2 -path '*/macos-*/Sparkle.framework' | head -1)"
[ -n "$SPARKLE" ] || { echo "Sparkle.framework non trovato"; exit 1; }
ditto "$SPARKLE" "$APP/Contents/Frameworks/Sparkle.framework"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Upgrady" 2>/dev/null || true

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>${NAME}</string>
    <key>CFBundleDisplayName</key><string>${NAME}</string>
    <key>CFBundleIdentifier</key><string>${BUNDLE_ID}</string>
    <key>CFBundleExecutable</key><string>Upgrady</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>${VERSION}</string>
    <key>CFBundleVersion</key><string>${BUILD_NUMBER}</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>it</string></array>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Copyright © 2026 Gionnio. MIT License.</string>
</dict>
</plist>
PLIST

if [ -d "$ROOT/icon/AppIcon.iconset" ]; then
    iconutil -c icns "$ROOT/icon/AppIcon.iconset" -o "$BUILD/AppIcon.icns"
    cp "$BUILD/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist"
fi

# Firma ad-hoc di tutto il pacchetto (Sparkle e i suoi helper compresi), poi l'app con il suo identificativo.
# Niente runtime protetto: con firme ad-hoc impedirebbe all'app di caricare Sparkle (serve solo per la notarizzazione).
codesign --force --deep --sign - "$APP"
codesign --force --identifier "$BUNDLE_ID" --sign - "$APP"
touch "$APP"
echo "✅ $APP"

if [ "${1:-}" = "--install" ]; then
    echo "▸ Installo in /Applications"
    osascript -e "quit app \"$NAME\"" 2>/dev/null || true
    sleep 1
    rm -rf "/Applications/$NAME.app"
    ditto "$APP" "/Applications/$NAME.app"
    open "/Applications/$NAME.app"
    echo "✓ $NAME installata. Dopo una reinstallazione macOS può chiedere di nuovo i permessi (Gestione app, notifiche)."
fi

if [ "${1:-}" = "--zip" ]; then
    mkdir -p "$ROOT/dist"
    ZIP_OUT="$ROOT/dist/${NAME// /_}_v$VERSION.zip"
    rm -f "$ZIP_OUT"
    ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP_OUT"
    echo "📦 $ZIP_OUT"
    shasum -a 256 "$ZIP_OUT"
fi
