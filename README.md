# ClaudeSound

Kleine macOS-Menüleisten-App rund um [Claude Code](https://docs.claude.com/en/docs/claude-code). Spielt Sounds bei Rückfragen und Antwortende, zeigt Live-Status aller laufenden Claude-Sitzungen als schwebende Zahnräder, und updated sich selbst von GitHub.

![platform](https://img.shields.io/badge/platform-macOS%2011%2B-lightgrey) ![lang](https://img.shields.io/badge/swift-Cocoa-orange) [![release](https://img.shields.io/github/v/release/fr-io/ClaudeSound)](https://github.com/fr-io/ClaudeSound/releases)

## Features

**Audio + visuelle Benachrichtigung**
- Eigener Sound für „Rückfrage" und „fertig" — beliebige `*.aiff` aus `/System/Library/Sounds/`
- Optionaler Claude-Logo-Popup oben rechts auf **allen** angeschlossenen Bildschirmen
- Optionale **macOS-Banner-Notification** wenn eine Session fertig wird (mit Working-Directory im Body)

**Sitzungs-Overlay**
- Pro laufender Claude-Sitzung ein schwebendes Zahnrad mit Kurzlabel (`agent` / `cli` / `code` / `desktop`)
- Bildschirm und Ecke (oben links / oben rechts) frei wählbar
- **Zahnrad dreht sich**, solange die Sitzung gerade arbeitet (zwischen `UserPromptSubmit` und `Stop`)
- Klick auf ein Zahnrad fokussiert das zugehörige Fenster (Terminal-Session, Claude.app, …) — geht über die Parent-PID-Kette bis zur nächsten GUI-App

**Selbst-Updater**
- Prüft beim Start und stündlich `releases/latest` auf GitHub
- Bei neuer Version: Banner im Menü + „Jetzt aktualisieren"-Button
- Lädt die DMG, ersetzt das Bundle, startet neu — alles ohne Zutun
- Manueller Trigger: „Nach Updates suchen"

**Sonstiges**
- Autostart beim Login via LaunchAgent (im Menü an-/abschaltbar)
- Übersicht aller aktuell laufenden Claude-Prozesse mit Klick → CWD im Finder
- App registriert sich beim ersten Start selbst in `~/.claude/settings.json` (additiv, ältere Hook-Formate werden auf den Stand gebracht)

## Install

**Für Endbenutzer:** DMG vom [neuesten Release](https://github.com/fr-io/ClaudeSound/releases/latest) herunterladen, `ClaudeSound.app` in den Applications-Ordner ziehen, starten.

**Aus dem Source:**
```bash
git clone https://github.com/fr-io/ClaudeSound.git
cd ClaudeSound
./install.sh
```

Voraussetzung: Xcode Command Line Tools (`xcode-select --install`).

Der Installer kompiliert mit `swiftc`, generiert das `.icns`-Icon, ad-hoc-signiert das Bundle, patcht die Claude-Hooks und startet die App. Re-run jederzeit zum Neubauen.

## DMG bauen

```bash
./install.sh      # build first
./make-dmg.sh     # erzeugt ClaudeSound-<version>.dmg im Ordner
```

Die DMG enthält die App, einen `/Applications`-Symlink zum Draggen und einen doppelklickbaren `.command`-Helper, der das macOS-Quarantine-Attribut entfernt (siehe unten).

## „ClaudeSound ist beschädigt" auf macOS Sequoia

Sequoia/Sonoma zeigen das für unsignierte Apps, die mit Quarantine-Attribut ankommen (Teams, Mail, Browser setzen das). Fix:

```bash
xattr -cr /Applications/ClaudeSound.app
open  /Applications/ClaudeSound.app
```

Oder die mitgelieferte `Falls App nicht öffnet — Doppelklick.command` aus der DMG starten.

Bei der schwächeren Meldung „**nicht verifizierter Entwickler**" reicht: Systemeinstellungen → Datenschutz & Sicherheit → „Trotzdem öffnen". Permanent sauber wäre nur eine Signierung mit Apple Developer ID + Notarisierung.

## Hooks-Schema

Die App registriert beim ersten Start (idempotent, additiv):

```json
{
  "hooks": {
    "Notification":     [{"matcher": "", "hooks": [{"type": "command",
      "command": "echo \"notify $PPID\" >> \"$HOME/Library/Application Support/ClaudeSound/trigger.log\""}]}],
    "Stop":             [{"matcher": "", "hooks": [{"type": "command",
      "command": "echo \"done $PPID\" >> \"$HOME/Library/Application Support/ClaudeSound/trigger.log\""}]}],
    "UserPromptSubmit": [{"matcher": "", "hooks": [{"type": "command",
      "command": "echo \"answered $PPID\" >> \"$HOME/Library/Application Support/ClaudeSound/trigger.log\""}]}]
  }
}
```

`$PPID` ist die PID des aufrufenden Claude-Prozesses — so weiß die App, *welche* Sitzung gerade etwas tut. Die App watcht `trigger.log` per `DispatchSource` und reagiert auf neue Zeilen. Beim Upgrade von älteren Versionen werden Hooks mit veraltetem Command-Format automatisch ersetzt.

State-Machine pro Session-PID:
| Event | Sound | Working |
|---|---|---|
| `notify` (Notification) | „Rückfrage" | unverändert |
| `answered` (UserPromptSubmit) | — | **on** |
| `done` (Stop) | „fertig" | off |

→ `Working` rotiert das Zahnrad.

## Dateien

| Datei | Zweck |
|---|---|
| `ClaudeSound.swift` | Die App: Menüleiste, Overlay, Trigger-Watcher, Visual-FX, Autostart, Hook-Self-Install, Self-Updater |
| `MakeIcon.swift` | Generiert das `AppIcon.iconset` programmatisch (Asterisk + Mund + Note) |
| `install.sh` | Build + Icon + Ad-hoc-Signing + Hook-Patch + Launch |
| `make-dmg.sh` | Packt das gebaute Bundle in ein verteilbares `.dmg` mit Quarantine-Helper |

## Deinstallation

```bash
rm -rf /Applications/ClaudeSound.app
rm -rf "$HOME/Library/Application Support/ClaudeSound"
rm  -f "$HOME/Library/LaunchAgents/com.flomeinigg.claudesound.plist"
```

Plus die `Notification`-, `Stop`- und `UserPromptSubmit`-Einträge mit `command`, der auf `ClaudeSound/trigger.log` zeigt, aus `~/.claude/settings.json` entfernen.

## Lizenz

MIT — siehe [LICENSE](LICENSE).
