#!/bin/bash
# Construit Cockpit.app, le DMG, et le paquet à déposer sur le serveur
# (relais PHP + PWA + landing + version.json + DMG).
set -euo pipefail
cd "$(dirname "$0")"

VERSION="$(grep -m1 '^VERSION=' build.sh | cut -d'"' -f2)"
DMG="Cockpit-$VERSION.dmg"
STAGE="$(mktemp -d)/Cockpit"
NOTES="${1:-}"

./build.sh

echo "▸ Fabrication du DMG…"
mkdir -p "$STAGE"
cp -R Cockpit.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Cockpit" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$(dirname "$STAGE")"
echo "✓ $DMG prêt ($(du -sh "$DMG" | cut -f1))"

echo "▸ Paquet serveur (cockpit-deploy.zip)…"
# La landing propose toujours "Cockpit.dmg" (nom stable) + version.json pour la
# détection de mise à jour côté app et PWA.
cp "$DMG" web/Cockpit.dmg
printf '{"version":"%s","url":"Cockpit.dmg","notes":%s}\n' \
  "$VERSION" "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$NOTES")" \
  > web/version.json
# La version PWA suit celle de build.sh.
/usr/bin/sed -i '' "s/const COCKPIT_VERSION = \"[^\"]*\"/const COCKPIT_VERSION = \"$VERSION\"/" web/index.html

# Paquet FTP pour le tout premier déploiement (ensuite : git via deploy.php).
PKG="$(mktemp -d)/cockpit"
mkdir -p "$PKG"
cp -R web/. "$PKG/"
rm -rf "$PKG/config.php" "$PKG/deploy.config.php" "$PKG"/data/*.json
rm -f cockpit-deploy.zip
( cd "$(dirname "$PKG")" && zip -qr "$OLDPWD/cockpit-deploy.zip" cockpit )
rm -rf "$(dirname "$PKG")"
echo "✓ cockpit-deploy.zip prêt ($(du -sh cockpit-deploy.zip | cut -f1))"

echo
echo "DMG : envoie Cockpit-$VERSION.dmg (au 1er lancement : clic droit → Ouvrir)."
echo "Serveur : soit git (init.php une fois puis deploy.php), soit FTP du zip."
echo "Pense à committer web/version.json après un bump de VERSION."
