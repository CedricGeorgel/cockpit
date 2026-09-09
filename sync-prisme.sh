#!/bin/bash
# Reprend Prisme.app (build ad-hoc universel dans ~/Documents/Prisme) et le
# range dans ce dépôt : Prisme.dmg + prisme-version.json, servis par la landing
# et le bandeau de mise à jour de Cockpit.
#
# Usage :  ./sync-prisme.sh  ["notes de version"]
#   puis :  git add -A && git commit -m "prisme X.Y" && git push
set -euo pipefail
cd "$(dirname "$0")"

NOTES="${1:-Analyseur d'espace disque}"

# Où trouver Prisme.app (dernier build en date gagne).
CANDIDATES=(
  "$HOME/Documents/Prisme/Prisme.app"
  "$HOME/Applications/Prisme.app"
  "/Applications/Prisme.app"
)
PAPP=""
for c in "${CANDIDATES[@]}"; do
  [ -d "$c" ] && { [ -z "$PAPP" ] || [ "$c" -nt "$PAPP" ]; } && PAPP="$c"
done
[ -n "$PAPP" ] || { echo "Prisme.app introuvable. Build-le d'abord (UNIVERSAL=1 ./build.sh dans ~/Documents/Prisme)."; exit 1; }
echo "▸ Source : $PAPP"

PVER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PAPP/Contents/Info.plist")"
echo "▸ Version : $PVER"
codesign -dv "$PAPP" 2>&1 | grep -q 'adhoc' || echo "  ⚠️  pas signé ad-hoc : Gatekeeper râlera"

echo "▸ Fabrication de Prisme.dmg…"
STAGE="$(mktemp -d)/Prisme"
mkdir -p "$STAGE"
ditto "$PAPP" "$STAGE/Prisme.app"
xattr -cr "$STAGE/Prisme.app" 2>/dev/null || true
ln -s /Applications "$STAGE/Applications"
rm -f Prisme.dmg
hdiutil create -volname "Prisme" -srcfolder "$STAGE" -ov -format UDZO Prisme.dmg >/dev/null
rm -rf "$(dirname "$STAGE")"

python3 - "$PVER" "$NOTES" > prisme-version.json <<'PY'
import json, sys
print(json.dumps({"version": sys.argv[1], "url": "Prisme.dmg", "notes": sys.argv[2]}))
PY

echo "✓ Prisme.dmg ($(du -sh Prisme.dmg | cut -f1)) + prisme-version.json v$PVER"
echo "  git add -A && git commit -m \"prisme $PVER\" && git push"
