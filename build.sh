#!/bin/bash
# Compile Cockpit et assemble le bundle Cockpit.app (Apple Silicon, arm64).
set -euo pipefail
cd "$(dirname "$0")"

APP="Cockpit.app"
BUNDLE_ID="com.cockpit.dashboard"
VERSION="0.10"
CONFIG="${CONFIG:-release}"

echo "▸ Compilation ($CONFIG, arm64)…"
swift build -c "$CONFIG" --arch arm64
BIN="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)/Cockpit"

echo "▸ Assemblage du bundle…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Cockpit"
[ -f icon/AppIcon.icns ] && cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Cockpit</string>
    <key>CFBundleDisplayName</key><string>Cockpit</string>
    <key>CFBundleExecutable</key><string>Cockpit</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIconName</key><string>AppIcon</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>CFBundleDevelopmentRegion</key><string>fr</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSAppTransportSecurity</key>
    <dict>
        <key>NSAllowsLocalNetworking</key><true/>
    </dict>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
    <key>NSHumanReadableCopyright</key><string>Tableau de bord personnel.</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key><string>com.cockpit.dashboard.auth</string>
            <key>CFBundleURLSchemes</key><array><string>cockpit</string></array>
        </dict>
    </array>
    <key>NSCalendarsFullAccessUsageDescription</key>
    <string>Cockpit affiche vos événements du jour dans le module Agenda.</string>
    <key>NSRemindersFullAccessUsageDescription</key>
    <string>Cockpit affiche et coche vos rappels dans les modules Agenda et À faire.</string>
    <key>NSAppleEventsUsageDescription</key>
    <string>Cockpit lit et contrôle la lecture en cours dans Musique et Spotify.</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>Cockpit lit le fichier markdown de tâches que vous choisissez.</string>
    <key>NSLocationUsageDescription</key>
    <string>Cockpit utilise votre position pour la météo locale.</string>
    <key>NSContactsUsageDescription</key>
    <string>Cockpit lit votre carnet d'adresses pour repérer les mails importants venant de personnes que vous connaissez.</string>
</dict>
</plist>
PLIST

echo "▸ Signature ad hoc (requirement figé sur l'identifiant)…"
xattr -cr "$APP" 2>/dev/null || true
codesign --force --sign - --timestamp=none \
         -r="designated => identifier \"$BUNDLE_ID\"" "$APP"

echo "✓ $APP prêt ($(du -sh "$APP" | cut -f1))"
