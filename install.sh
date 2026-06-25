#!/bin/bash
# ClaudeSound installer.
# Builds the menubar app, places it under ~/Applications, wires up the
# Claude Code Notification/Stop hooks, and launches it.
# Re-run any time to rebuild and re-wire.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_NAME="ClaudeSound"
APP_DIR="$HOME/Applications/$APP_NAME.app"
SUPPORT="$HOME/Library/Application Support/$APP_NAME"
TRIGGER="$SUPPORT/trigger.log"
SETTINGS="$HOME/.claude/settings.json"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "swiftc not found. Run: xcode-select --install" >&2
  exit 1
fi

echo "==> Stopping any running instance..."
killall "$APP_NAME" 2>/dev/null || true
sleep 0.3

echo "==> Building $APP_NAME.app..."
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources" "$SUPPORT"
touch "$TRIGGER"

cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>ClaudeSound</string>
  <key>CFBundleIdentifier</key><string>com.flomeinigg.claudesound</string>
  <key>CFBundleName</key><string>ClaudeSound</string>
  <key>CFBundleDisplayName</key><string>ClaudeSound</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleVersion</key><string>1.6</string>
  <key>CFBundleShortVersionString</key><string>1.6</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSUIElement</key><true/>
  <key>LSMinimumSystemVersion</key><string>11.0</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

swiftc -O -o "$APP_DIR/Contents/MacOS/$APP_NAME" \
  "$SCRIPT_DIR/ClaudeSound.swift" \
  -framework Cocoa

echo "==> Generating app icon..."
ICONSET_DIR="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET_DIR"
ICONGEN_BIN="$(mktemp -d)/makeicon"
swiftc -O -o "$ICONGEN_BIN" "$SCRIPT_DIR/MakeIcon.swift" -framework Cocoa
"$ICONGEN_BIN" "$ICONSET_DIR" >/dev/null
iconutil -c icns "$ICONSET_DIR" -o "$APP_DIR/Contents/Resources/AppIcon.icns"

echo "==> Ad-hoc signing..."
# Without ANY signature, macOS Sequoia shows the misleading "is damaged"
# Gatekeeper error after the bundle picks up a quarantine attribute. An
# ad-hoc signature gives the binary an internally-consistent hash so the
# OS treats it as a normal unsigned app (recipient still has to strip the
# quarantine attr — see make-dmg.sh and LIESMICH).
codesign --force --deep --sign - "$APP_DIR" 2>/dev/null || true

# Force Finder/Dock to drop their cached icon for this bundle.
touch "$APP_DIR"

echo "==> Patching Claude Code hooks in $SETTINGS..."
mkdir -p "$(dirname "$SETTINGS")"
[ -f "$SETTINGS" ] || echo "{}" > "$SETTINGS"

python3 - "$SETTINGS" "$TRIGGER" <<'PY'
import json, sys, pathlib
settings_path = pathlib.Path(sys.argv[1])
trigger = sys.argv[2]
data = json.loads(settings_path.read_text() or "{}")
notify_cmd   = 'echo "notify $PPID" >> '   + json.dumps(trigger)
done_cmd     = 'echo "done $PPID" >> '     + json.dumps(trigger)
answered_cmd = 'echo "answered $PPID" >> ' + json.dumps(trigger)
data.setdefault("hooks", {})
data["hooks"]["Notification"]     = [{"matcher": "", "hooks": [{"type": "command", "command": notify_cmd}]}]
data["hooks"]["Stop"]             = [{"matcher": "", "hooks": [{"type": "command", "command": done_cmd}]}]
data["hooks"]["UserPromptSubmit"] = [{"matcher": "", "hooks": [{"type": "command", "command": answered_cmd}]}]
settings_path.write_text(json.dumps(data, indent=2) + "\n")
PY

echo "==> Launching $APP_NAME..."
open "$APP_DIR"

cat <<EOF

Installation abgeschlossen.

  App:         $APP_DIR
  Config:      $SUPPORT/config.json
  Trigger:     $TRIGGER
  Hooks:       $SETTINGS

In der Menüleiste erscheint ein Asterisk-Symbol — dort:
  • Beim Login starten          (Autostart via LaunchAgent)
  • Visueller Effekt            (Claude-Logo-Popup rechts oben auf allen Bildschirmen)
  • Sound: fertig / Rückfrage   (alle macOS-System-Sounds wählbar)
  • Test: fertig / Rückfrage    (sofortige Vorschau)

Die Hooks lösen ab der nächsten frisch gestarteten Claude-Session aus.
EOF
