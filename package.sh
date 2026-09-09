#!/bin/bash
# Construit Cockpit.app puis l'empaquette dans un DMG prêt à envoyer.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="0.1"
DMG="Cockpit-$VERSION.dmg"
STAGE="$(mktemp -d)/Cockpit"

./build.sh

echo "▸ Fabrication du DMG…"
mkdir -p "$STAGE"
cp -R Cockpit.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create -volname "Cockpit" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$(dirname "$STAGE")"

echo "✓ $DMG prêt ($(du -sh "$DMG" | cut -f1))"
echo
echo "Sur l'autre Mac : glisser Cockpit dans Applications, puis au 1er lancement"
echo "clic droit → Ouvrir (signature ad hoc). Si besoin :"
echo "  xattr -dr com.apple.quarantine /Applications/Cockpit.app"
