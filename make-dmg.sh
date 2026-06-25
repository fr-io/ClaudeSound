#!/bin/bash
# Packages the already-built ClaudeSound.app into a distributable .dmg.
# Run install.sh first so $APP_DIR exists and contains the icon.

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="ClaudeSound"
APP_DIR="$HOME/Applications/$APP_NAME.app"
VERSION="1.4"
DMG_OUT="$SCRIPT_DIR/$APP_NAME-$VERSION.dmg"

if [ ! -d "$APP_DIR" ]; then
  echo "Build first: $SCRIPT_DIR/install.sh" >&2
  exit 1
fi

STAGING="$(mktemp -d)/$APP_NAME"
mkdir -p "$STAGING"
cp -R "$APP_DIR" "$STAGING/$APP_NAME.app"
# Clear quarantine + any extended attrs from the staged copy so the contents
# inside the DMG are clean. (The recipient's browser/Teams may still mark the
# DMG itself as quarantined on download — see fix-gatekeeper.command.)
xattr -cr "$STAGING/$APP_NAME.app" 2>/dev/null || true
ln -s /Applications "$STAGING/Applications"

# Double-clickable Gatekeeper repair for macOS Sequoia: strips the quarantine
# attribute that causes "ClaudeSound ist beschädigt" on newer macOS versions.
cat > "$STAGING/Falls App nicht öffnet — Doppelklick.command" <<'CMD'
#!/bin/bash
APP="/Applications/ClaudeSound.app"
if [ ! -d "$APP" ]; then
  echo "Bitte erst ClaudeSound.app nach /Applications kopieren."
  echo ""
  read -p "Mit Enter schließen…" _
  exit 1
fi
echo "Entferne Quarantine-Attribut von $APP …"
xattr -cr "$APP"
echo "Starte ClaudeSound…"
open "$APP"
echo ""
echo "Fertig. Du kannst dieses Fenster schließen."
read -p "Mit Enter schließen…" _
CMD
chmod +x "$STAGING/Falls App nicht öffnet — Doppelklick.command"

cat > "$STAGING/LIESMICH.txt" <<'EOF'
ClaudeSound — Sound + visuelle Benachrichtigung für Claude Code
================================================================

INSTALLATION
1. ClaudeSound.app in den "Applications"-Ordner ziehen.
2. App starten via Spotlight (⌘+Space → "ClaudeSound").

FALLS DIE APP "BESCHÄDIGT" GEMELDET WIRD (macOS Sequoia/Sonoma)
   Das passiert bei unsignierten Apps, die per Teams/Mail/Browser
   ankommen — macOS markiert sie als Quarantäne. Lösung:
   → Doppelklick auf "Falls App nicht öffnet — Doppelklick.command"
   in diesem DMG. Das räumt das Quarantäne-Flag weg und startet die App.

   Manuelle Alternative im Terminal:
     xattr -cr /Applications/ClaudeSound.app && open /Applications/ClaudeSound.app

Die App registriert sich beim ersten Start selbständig in den
Claude-Code-Hooks (~/.claude/settings.json). Ab der nächsten neu
gestarteten Claude-Session spielt sie Sounds.

KONFIGURATION
In der Menüleiste erscheint ein Mund-Icon. Im Menü:
  • Beim Login starten         Autostart per LaunchAgent
  • Visueller Effekt           Claude-Logo kurz oben rechts auf
                               allen Bildschirmen einblenden
  • Sound: fertig / Rückfrage  beliebigen macOS-Systemsound wählen
  • Test                       sofortige Vorschau
  • Laufende Claude-Sitzungen  Übersicht + Klick öffnet das CWD im Finder

DEINSTALLATION
1. ClaudeSound.app aus /Applications löschen.
2. Diese Pfade entfernen (Terminal):
     rm -rf ~/Library/Application\ Support/ClaudeSound
     rm  -f ~/Library/LaunchAgents/com.flomeinigg.claudesound.plist
3. In ~/.claude/settings.json die Hooks-Einträge entfernen, deren
   "command" auf "ClaudeSound/trigger.log" zeigt.
EOF

rm -f "$DMG_OUT"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$DMG_OUT" >/dev/null

rm -rf "$(dirname "$STAGING")"

echo "DMG erstellt:"
ls -lh "$DMG_OUT"
