# ClaudeSound

Kleine macOS-Menüleisten-App, die einen Sound spielt und ein Claude-Logo
oben rechts einblendet, sobald Claude Code eine Rückfrage stellt oder
eine Antwort beendet.

![menubar](https://img.shields.io/badge/platform-macOS%2011%2B-lightgrey) ![lang](https://img.shields.io/badge/swift-Cocoa-orange)

## Was es macht

Hängt sich an die [Claude Code Hooks](https://docs.claude.com/en/docs/claude-code/hooks):
- **`Notification`** → Sound „Rückfrage" + optional Logo-Popup
- **`Stop`** → Sound „fertig" + optional Logo-Popup

Im Menüleisten-Icon (singender Mund 🎵):
- Beim Login starten (Autostart via LaunchAgent)
- Visueller Effekt: Claude-Logo kurz oben rechts auf **allen** Bildschirmen
- Beliebigen `*.aiff` aus `/System/Library/Sounds/` wählen — getrennt für „fertig" und „Rückfrage"
- Test-Buttons für sofortige Vorschau
- Übersicht aller laufenden `claude`-CLI- und Claude-Desktop-Plugin-Prozesse, Klick öffnet das CWD im Finder

## Build & Install

Voraussetzung: Xcode Command Line Tools (`xcode-select --install`).

```bash
git clone https://github.com/fr-io/ClaudeSound.git
cd ClaudeSound
./install.sh
```

Der Installer:
1. Kompiliert die App mit `swiftc` und packt sie als `~/Applications/ClaudeSound.app`
2. Generiert das `.icns`-Icon
3. Signiert ad-hoc (`codesign --sign -`)
4. Patcht `~/.claude/settings.json` und legt die beiden Hooks an
5. Startet die App

Re-run jederzeit zum Neubauen.

## DMG für Kollegen bauen

```bash
./install.sh      # build first
./make-dmg.sh     # creates ClaudeSound-1.0.dmg
```

Die DMG enthält die App, einen `/Applications`-Symlink zum Drag-and-Drop und
eine doppelklickbare `.command`-Datei, die das macOS-Quarantine-Attribut
entfernt (siehe unten).

## „ClaudeSound ist beschädigt" auf macOS Sequoia

Sequoia zeigt diese Meldung für unsignierte Apps, die mit Quarantine-Attribut
ankommen (Teams, Mail, Browser setzen das). Fix:

```bash
xattr -cr /Applications/ClaudeSound.app
open  /Applications/ClaudeSound.app
```

Oder die mitgelieferte `Falls App nicht öffnet — Doppelklick.command` aus
der DMG starten — die macht genau das.

Für eine permanent saubere Lösung müsste die App mit Apple Developer ID
signiert und notarisiert werden.

## Dateien

| Datei | Zweck |
|---|---|
| `ClaudeSound.swift` | Die App: Menüleisten-UI, Trigger-Watcher, Visual-FX, Autostart, Hook-Self-Install |
| `MakeIcon.swift` | Generiert das `AppIcon.iconset` programmatisch (Asterisk + Mund + Note) |
| `install.sh` | Build + Icon + Ad-hoc-Signing + Hook-Patch + Launch |
| `make-dmg.sh` | Packt das fertige Bundle in ein verteilbares `.dmg` |

## Hooks-Schema

Beim ersten Start trägt die App folgende Hooks (additiv) ein:

```json
{
  "hooks": {
    "Notification": [{"matcher": "", "hooks": [{"type": "command",
      "command": "echo notify >> \"$HOME/Library/Application Support/ClaudeSound/trigger.log\""}]}],
    "Stop":         [{"matcher": "", "hooks": [{"type": "command",
      "command": "echo done   >> \"$HOME/Library/Application Support/ClaudeSound/trigger.log\""}]}]
  }
}
```

Die App watcht `trigger.log` via `DispatchSource` und reagiert auf neue Zeilen.

## Deinstallation

```bash
rm -rf /Applications/ClaudeSound.app
rm -rf "$HOME/Library/Application Support/ClaudeSound"
rm  -f "$HOME/Library/LaunchAgents/com.flomeinigg.claudesound.plist"
```

Plus die `Notification`/`Stop`-Einträge aus `~/.claude/settings.json` entfernen.

## Lizenz

MIT — siehe [LICENSE](LICENSE).
