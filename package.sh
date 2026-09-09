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
# La landing propose "Cockpit.dmg" (nom stable) ; version.json pilote la
# détection de mise à jour (app + PWA).
cp "$DMG" Cockpit.dmg
printf '{"version":"%s","url":"Cockpit.dmg","notes":%s}\n' \
  "$VERSION" "$(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$NOTES")" \
  > version.json
# La version PWA suit celle de build.sh.
/usr/bin/sed -i '' "s/const COCKPIT_VERSION = \"[^\"]*\"/const COCKPIT_VERSION = \"$VERSION\"/" index.html

# Paquet FTP pour le tout premier déploiement (ensuite : git via deploy.php).
PKG="$(mktemp -d)/cockpit"
mkdir -p "$PKG/data"
cp index.html relay.php sw.js manifest.webmanifest version.json .htaccess \
   deploy.php init.sample.php config.sample.php Cockpit.dmg "$PKG/"
[ -f Prisme.dmg ]          && cp Prisme.dmg "$PKG/"
[ -f prisme-version.json ] && cp prisme-version.json "$PKG/"
cp -R icons "$PKG/"
cp data/.htaccess "$PKG/data/"
rm -f cockpit-deploy.zip
( cd "$(dirname "$PKG")" && zip -qr "$OLDPWD/cockpit-deploy.zip" cockpit )
rm -rf "$(dirname "$PKG")"
echo "✓ cockpit-deploy.zip prêt ($(du -sh cockpit-deploy.zip | cut -f1))"

echo
echo "Pour publier :"
echo "  git add -A && git commit -m \"v$VERSION\" && git push"
echo "→ la CI appelle deploy.php ; Cockpit.dmg + version.json partent avec (versionnés)."
echo "Rien à faire en FTP. (Cockpit-$VERSION.dmg garde le numéro pour tes archives.)"
