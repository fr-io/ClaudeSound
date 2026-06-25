import Cocoa

let APP_SUPPORT = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/ClaudeSound", isDirectory: true)
let CONFIG_URL  = APP_SUPPORT.appendingPathComponent("config.json")
let TRIGGER_URL = APP_SUPPORT.appendingPathComponent("trigger.log")
let LAUNCH_AGENT_URL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/LaunchAgents/com.flomeinigg.claudesound.plist")
let SOUNDS_DIR = "/System/Library/Sounds"
let CLAUDE_ORANGE = NSColor(calibratedRed: 0.80, green: 0.46, blue: 0.35, alpha: 1.0)

// MARK: - Config

struct Config: Codable {
    var notifySound: String = "Funk"
    var doneSound:   String = "Glass"
    var visualEffect: Bool  = false
}

enum ConfigStore {
    static var current: Config = load()
    static func load() -> Config {
        try? FileManager.default.createDirectory(at: APP_SUPPORT, withIntermediateDirectories: true)
        guard let data = try? Data(contentsOf: CONFIG_URL),
              let cfg = try? JSONDecoder().decode(Config.self, from: data) else { return Config() }
        return cfg
    }
    static func save() {
        let enc = JSONEncoder(); enc.outputFormatting = .prettyPrinted
        if let data = try? enc.encode(current) { try? data.write(to: CONFIG_URL) }
    }
}

// MARK: - Autostart (LaunchAgent)

enum AutostartManager {
    static var isEnabled: Bool { FileManager.default.fileExists(atPath: LAUNCH_AGENT_URL.path) }

    static func enable(appPath: String) {
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key><string>com.flomeinigg.claudesound</string>
            <key>ProgramArguments</key>
            <array>
                <string>/usr/bin/open</string>
                <string>\(appPath)</string>
            </array>
            <key>RunAtLoad</key><true/>
            <key>KeepAlive</key><false/>
        </dict>
        </plist>
        """
        try? FileManager.default.createDirectory(
            at: LAUNCH_AGENT_URL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try? plist.write(to: LAUNCH_AGENT_URL, atomically: true, encoding: .utf8)
        runLaunchctl(args: ["load", "-w", LAUNCH_AGENT_URL.path])
    }

    static func disable() {
        runLaunchctl(args: ["unload", LAUNCH_AGENT_URL.path])
        try? FileManager.default.removeItem(at: LAUNCH_AGENT_URL)
    }

    private static func runLaunchctl(args: [String]) {
        let p = Process()
        p.launchPath = "/bin/launchctl"
        p.arguments = args
        p.standardError = Pipe()
        p.standardOutput = Pipe()
        try? p.run()
        p.waitUntilExit()
    }
}

// MARK: - Sounds

func availableSounds() -> [String] {
    let files = (try? FileManager.default.contentsOfDirectory(atPath: SOUNDS_DIR)) ?? []
    return files
        .filter { $0.hasSuffix(".aiff") }
        .map { ($0 as NSString).deletingPathExtension }
        .sorted()
}

func playSound(_ name: String) {
    let path = "\(SOUNDS_DIR)/\(name).aiff"
    if let s = NSSound(contentsOfFile: path, byReference: true) { s.play() }
}

// MARK: - Claude process discovery

struct ClaudeProc {
    let pid: Int
    let cwd: String?
    let command: String
    let label: String   // friendly menu label
}

func runCapturingStdout(_ launch: String, _ args: [String]) -> String {
    // autoreleasepool: Process / Pipe / FileHandle on a background queue must
    // not leak autoreleased objects up to the main pool — that caused crashes.
    return autoreleasepool {
        let p = Process()
        p.launchPath = launch
        p.arguments = args
        let outPipe = Pipe()
        p.standardOutput = outPipe
        // Discard stderr without keeping a pipe — avoids any second-pipe deadlock.
        if let devnull = FileHandle(forWritingAtPath: "/dev/null") {
            p.standardError = devnull
        }
        do { try p.run() } catch { return "" }
        // Read FIRST, then wait: waiting before reading deadlocks when the
        // child writes more than the pipe buffer (≈64 KB).
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// Returns a friendly label if this command line represents a relevant Claude
/// process (CLI or desktop-app session), otherwise nil.
func classifyClaudeProcess(_ cmd: String) -> String? {
    if cmd.contains("ClaudeSound") || cmd.contains("claude-sound") { return nil }

    // Standalone Claude Code CLI
    let firstToken = cmd.split(separator: " ", maxSplits: 1).first.map(String.init) ?? cmd
    let base = (firstToken as NSString).lastPathComponent
    if base == "claude" { return "Claude CLI" }
    if cmd.contains("@anthropic-ai/claude-code") || cmd.contains("/claude-code/") {
        return "Claude Code"
    }

    // Claude Desktop — each Plugin Node service hosts an agent session
    if cmd.contains("Claude Helper (Plugin)") && cmd.contains("node.mojom.NodeService") {
        return "Claude Agent (Desktop)"
    }
    if cmd.contains("/Claude.app/Contents/MacOS/Claude") && !cmd.contains("Helper") {
        return "Claude Desktop"
    }
    return nil
}

func cwdsForPIDs(_ pids: [Int]) -> [Int: String] {
    guard !pids.isEmpty else { return [:] }
    let joined = pids.map(String.init).joined(separator: ",")
    let out = runCapturingStdout("/usr/sbin/lsof",
                                 ["-a", "-p", joined, "-d", "cwd", "-Fpn"])
    var result: [Int: String] = [:]
    var currentPID: Int?
    for raw in out.split(separator: "\n") {
        let line = String(raw)
        if line.hasPrefix("p") {
            currentPID = Int(line.dropFirst())
        } else if line.hasPrefix("n"), let pid = currentPID {
            result[pid] = String(line.dropFirst())
        }
    }
    return result
}

func listClaudeProcesses() -> [ClaudeProc] {
    let out = runCapturingStdout("/bin/ps", ["-axww", "-o", "pid=,command="])
    let myPID = Int(ProcessInfo.processInfo.processIdentifier)
    var matched: [(Int, String, String)] = []  // pid, cmd, label
    for raw in out.split(separator: "\n") {
        let line = String(raw).trimmingCharacters(in: .whitespaces)
        guard let sep = line.firstIndex(of: " ") else { continue }
        let pidStr = String(line[..<sep])
        guard let pid = Int(pidStr), pid != myPID else { continue }
        let cmd = String(line[line.index(after: sep)...]).trimmingCharacters(in: .whitespaces)
        if let label = classifyClaudeProcess(cmd) {
            matched.append((pid, cmd, label))
        }
    }
    let cwds = cwdsForPIDs(matched.map { $0.0 })
    return matched
        .map { ClaudeProc(pid: $0.0, cwd: cwds[$0.0], command: $0.1, label: $0.2) }
        .sorted { ($0.label, $0.pid) < ($1.label, $1.pid) }
}

/// Returns a folder name worth showing for a cwd. Skips system/app bundles
/// where the cwd carries no useful working-directory signal.
func userlandFolder(_ cwd: String?) -> String? {
    guard let cwd = cwd else { return nil }
    let skipPrefixes = ["/Applications/", "/System/", "/usr/", "/Library/"]
    if skipPrefixes.contains(where: { cwd.hasPrefix($0) }) { return nil }
    if cwd == "/" { return nil }
    return (cwd as NSString).lastPathComponent
}

// MARK: - Visual effect

final class LogoView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let inset = bounds.width * 0.04
        let rect = bounds.insetBy(dx: inset, dy: inset)

        NSColor.white.withAlphaComponent(0.96).setFill()
        NSBezierPath(ovalIn: rect).fill()

        let cx = rect.midX, cy = rect.midY
        let inner = rect.width * 0.07
        let outer = rect.width * 0.40
        CLAUDE_ORANGE.setFill()
        for i in 0..<8 {
            let a = (Double(i) / 8.0) * .pi * 2
            let dx  = CGFloat(cos(a)), dy  = CGFloat(sin(a))
            let pdx = CGFloat(-sin(a)), pdy = CGFloat(cos(a))
            let p = NSBezierPath()
            p.move(to: NSPoint(x: cx + pdx*inner, y: cy + pdy*inner))
            p.line(to: NSPoint(x: cx + dx*outer + pdx*inner*0.25,
                               y: cy + dy*outer + pdy*inner*0.25))
            p.line(to: NSPoint(x: cx + dx*outer - pdx*inner*0.25,
                               y: cy + dy*outer - pdy*inner*0.25))
            p.line(to: NSPoint(x: cx - pdx*inner, y: cy - pdy*inner))
            p.close()
            p.fill()
        }
    }
}

final class VisualEffectController {
    func show() {
        // Each invocation owns its own windows — no shared state survives between
        // calls, so a pending teardown can never touch windows from a later call.
        var windows: [NSWindow] = []
        for screen in NSScreen.screens {
            let size: CGFloat = 90
            let margin: CGFloat = 24
            let visible = screen.visibleFrame
            let frame = NSRect(
                x: visible.maxX - size - margin,
                y: visible.maxY - size - margin,
                width: size, height: size)
            let w = NSWindow(contentRect: frame, styleMask: .borderless,
                             backing: .buffered, defer: false)
            // Critical: keep AppKit from over-releasing on close().
            w.isReleasedWhenClosed = false
            w.level = .floating
            w.backgroundColor = .clear
            w.isOpaque = false
            w.ignoresMouseEvents = true
            w.hasShadow = false
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            let view = LogoView(frame: NSRect(origin: .zero, size: frame.size))
            view.wantsLayer = true
            w.contentView = view
            w.alphaValue = 0
            w.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                w.animator().alphaValue = 1.0
            }
            windows.append(w)
        }
        // The closure captures `windows` strongly, keeping the NSWindow objects
        // alive through the fade-out + close. Refs are released once it returns.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.85) {
            for w in windows {
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.35
                    w.animator().alphaValue = 0
                }, completionHandler: {
                    w.orderOut(nil)
                    w.close()
                })
            }
        }
    }
}

// MARK: - Trigger watcher

final class TriggerWatcher {
    private let url: URL
    private let handler: (String) -> Void
    private var source: DispatchSourceFileSystemObject?
    private var fd: Int32 = -1
    private var offset: UInt64 = 0

    init(url: URL, handler: @escaping (String) -> Void) {
        self.url = url
        self.handler = handler
    }

    func start() {
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        offset = currentSize()
        openWatch()
    }

    private func currentSize() -> UInt64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? UInt64) ?? 0
    }

    private func openWatch() {
        fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main)
        src.setEventHandler { [weak self] in
            guard let self = self else { return }
            let mask = src.data
            if mask.contains(.delete) || mask.contains(.rename) {
                src.cancel()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { self.start() }
                return
            }
            self.readNew()
        }
        let capturedFD = fd
        src.setCancelHandler { close(capturedFD) }
        src.resume()
        source = src
    }

    private func readNew() {
        let size = currentSize()
        if size < offset { offset = 0 }
        guard let fh = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? fh.close() }
        try? fh.seek(toOffset: offset)
        let data = fh.readDataToEndOfFile()
        offset = (try? fh.offset()) ?? offset
        guard let text = String(data: data, encoding: .utf8) else { return }
        for line in text.split(whereSeparator: { $0.isNewline }) {
            let ev = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            if !ev.isEmpty { handler(ev) }
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    let visual = VisualEffectController()
    var watcher: TriggerWatcher!

    // Process list is fetched off the main thread; the menu reads the cache so
    // opening it never blocks on `ps` / `lsof`.
    private var cachedProcs: [ClaudeProc] = []
    private var procsLoaded = false
    private var refreshing = false
    private let procQueue = DispatchQueue(
        label: "ch.flomeinigg.ClaudeSound.proc", qos: .userInitiated)

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button { b.image = makeMenubarIcon() }

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        populateMenu(menu)
        refreshProcsAsync()

        ensureClaudeHooksInstalled()

        watcher = TriggerWatcher(url: TRIGGER_URL) { [weak self] ev in
            self?.handleEvent(ev)
        }
        watcher.start()
    }

    /// Idempotently registers ClaudeSound's Notification/Stop hooks in
    /// ~/.claude/settings.json so a freshly-DMG'd install works without the
    /// user running any setup script. Leaves any other hooks the user has
    /// configured untouched.
    private func ensureClaudeHooksInstalled() {
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        let triggerPath = TRIGGER_URL.path

        try? FileManager.default.createDirectory(at: APP_SUPPORT,
                                                 withIntermediateDirectories: true)

        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = obj
        }
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        func hasOurHook(in eventName: String) -> Bool {
            guard let list = hooks[eventName] as? [[String: Any]] else { return false }
            for entry in list {
                guard let inner = entry["hooks"] as? [[String: Any]] else { continue }
                for hk in inner {
                    if let cmd = hk["command"] as? String, cmd.contains(triggerPath) {
                        return true
                    }
                }
            }
            return false
        }

        let alreadyOK = hasOurHook(in: "Notification") && hasOurHook(in: "Stop")
        if alreadyOK { return }

        func appendHook(_ eventName: String, command: String) {
            var list = hooks[eventName] as? [[String: Any]] ?? []
            list.append([
                "matcher": "",
                "hooks":   [["type": "command", "command": command]]
            ])
            hooks[eventName] = list
        }
        let q = "\""
        if !hasOurHook(in: "Notification") {
            appendHook("Notification", command: "echo notify >> \(q)\(triggerPath)\(q)")
        }
        if !hasOurHook(in: "Stop") {
            appendHook("Stop", command: "echo done >> \(q)\(triggerPath)\(q)")
        }
        settings["hooks"] = hooks

        try? FileManager.default.createDirectory(
            at: settingsURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        if let data = try? JSONSerialization.data(
            withJSONObject: settings, options: [.prettyPrinted]) {
            try? data.write(to: settingsURL)
        }
    }

    private func refreshProcsAsync() {
        if refreshing { return }
        refreshing = true
        procQueue.async { [weak self] in
            // autoreleasepool: see runCapturingStdout for rationale.
            let procs = autoreleasepool { listClaudeProcesses() }
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.cachedProcs = procs
                self.procsLoaded = true
                self.refreshing = false
            }
        }
    }

    // Singing mouth: open oval lips + eighth note
    private func makeMenubarIcon() -> NSImage {
        let size = NSSize(width: 22, height: 18)
        let img = NSImage(size: size)
        img.lockFocus()
        NSColor.labelColor.setStroke()
        NSColor.labelColor.setFill()

        // Lips: open oval (singing mouth)
        let mouth = NSBezierPath(ovalIn: NSRect(x: 1.5, y: 4.5, width: 11, height: 6.5))
        mouth.lineWidth = 1.6
        mouth.stroke()
        // Small tongue/inside hint — short horizontal line
        let inside = NSBezierPath()
        inside.move(to: NSPoint(x: 4.0, y: 7.7))
        inside.line(to: NSPoint(x: 10.0, y: 7.7))
        inside.lineWidth = 1.2
        inside.lineCapStyle = .round
        inside.stroke()

        // Eighth note — head
        let head = NSBezierPath(ovalIn: NSRect(x: 13.8, y: 4.6, width: 4.4, height: 3.2))
        head.fill()
        // Stem
        let stem = NSBezierPath()
        stem.move(to: NSPoint(x: 17.8, y: 6.0))
        stem.line(to: NSPoint(x: 17.8, y: 15.5))
        stem.lineWidth = 1.5
        stem.lineCapStyle = .round
        stem.stroke()
        // Flag
        let flag = NSBezierPath()
        flag.move(to: NSPoint(x: 17.8, y: 15.5))
        flag.curve(to: NSPoint(x: 20.6, y: 11.6),
                   controlPoint1: NSPoint(x: 21.0, y: 14.8),
                   controlPoint2: NSPoint(x: 20.6, y: 13.2))
        flag.lineWidth = 1.5
        flag.lineCapStyle = .round
        flag.stroke()

        img.unlockFocus()
        img.isTemplate = true
        return img
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        populateMenu(menu)
        refreshProcsAsync()  // fire-and-forget; next open shows fresh data
    }

    private func populateMenu(_ m: NSMenu) {
        m.removeAllItems()

        let header = NSMenuItem(title: "ClaudeSound", action: nil, keyEquivalent: "")
        header.isEnabled = false
        m.addItem(header)
        m.addItem(.separator())

        // Running Claude processes (uses cache; refreshed in background)
        let procs = cachedProcs
        let headerTitle: String
        if !procsLoaded {
            headerTitle = "Claude-Prozesse werden geladen…"
        } else if procs.isEmpty {
            headerTitle = "Keine laufenden Claude-Sitzungen"
        } else {
            headerTitle = "Laufende Claude-Sitzungen (\(procs.count)):"
        }
        let procHeader = NSMenuItem(title: headerTitle, action: nil, keyEquivalent: "")
        procHeader.isEnabled = false
        m.addItem(procHeader)

        for p in procs {
            let folder = userlandFolder(p.cwd)
            let title: String
            if let folder = folder {
                title = "  \(p.label) — \(folder) (PID \(p.pid))"
            } else {
                title = "  \(p.label) (PID \(p.pid))"
            }
            let it = NSMenuItem(title: title,
                                action: #selector(openProcessCwd(_:)),
                                keyEquivalent: "")
            it.target = self
            it.representedObject = (folder != nil) ? p.cwd : nil
            let cmdPreview = p.command.count > 200
                ? String(p.command.prefix(200)) + "…"
                : p.command
            it.toolTip = "\(p.cwd ?? "(kein Arbeitsverzeichnis)")\n\n\(cmdPreview)"
            if folder == nil { it.isEnabled = false }
            m.addItem(it)
        }
        m.addItem(.separator())

        // Settings
        let auto = NSMenuItem(title: "Beim Login starten",
                              action: #selector(toggleAutostart), keyEquivalent: "")
        auto.state = AutostartManager.isEnabled ? .on : .off
        auto.target = self
        m.addItem(auto)

        let vfx = NSMenuItem(title: "Visueller Effekt (Logo-Popup)",
                             action: #selector(toggleVisual), keyEquivalent: "")
        vfx.state = ConfigStore.current.visualEffect ? .on : .off
        vfx.target = self
        m.addItem(vfx)

        m.addItem(.separator())
        let sounds = availableSounds()

        let done = NSMenuItem(title: "Sound: fertig", action: nil, keyEquivalent: "")
        done.submenu = soundSubmenu(sounds: sounds,
                                    selected: ConfigStore.current.doneSound,
                                    action: #selector(pickDoneSound(_:)))
        m.addItem(done)

        let notify = NSMenuItem(title: "Sound: Rückfrage", action: nil, keyEquivalent: "")
        notify.submenu = soundSubmenu(sounds: sounds,
                                      selected: ConfigStore.current.notifySound,
                                      action: #selector(pickNotifySound(_:)))
        m.addItem(notify)

        m.addItem(.separator())
        let tD = NSMenuItem(title: "Test: fertig", action: #selector(testDone), keyEquivalent: "")
        tD.target = self; m.addItem(tD)
        let tN = NSMenuItem(title: "Test: Rückfrage", action: #selector(testNotify), keyEquivalent: "")
        tN.target = self; m.addItem(tN)

        m.addItem(.separator())
        m.addItem(NSMenuItem(title: "Beenden",
                             action: #selector(NSApplication.terminate(_:)),
                             keyEquivalent: "q"))
    }

    private func soundSubmenu(sounds: [String], selected: String, action: Selector) -> NSMenu {
        let sub = NSMenu()
        for s in sounds {
            let it = NSMenuItem(title: s, action: action, keyEquivalent: "")
            it.state = (s == selected) ? .on : .off
            it.target = self
            it.representedObject = s
            sub.addItem(it)
        }
        return sub
    }

    // MARK: Actions

    @objc private func openProcessCwd(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func toggleAutostart() {
        if AutostartManager.isEnabled {
            AutostartManager.disable()
        } else {
            AutostartManager.enable(appPath: Bundle.main.bundlePath)
        }
    }

    @objc private func toggleVisual() {
        ConfigStore.current.visualEffect.toggle()
        ConfigStore.save()
        if ConfigStore.current.visualEffect { visual.show() }
    }

    @objc private func pickDoneSound(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String else { return }
        ConfigStore.current.doneSound = s
        ConfigStore.save()
        playSound(s)
    }

    @objc private func pickNotifySound(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? String else { return }
        ConfigStore.current.notifySound = s
        ConfigStore.save()
        playSound(s)
    }

    @objc private func testDone()   { handleEvent("done") }
    @objc private func testNotify() { handleEvent("notify") }

    private func handleEvent(_ event: String) {
        let cfg = ConfigStore.current
        switch event {
        case "notify":
            playSound(cfg.notifySound)
            if cfg.visualEffect { visual.show() }
        case "done":
            playSound(cfg.doneSound)
            if cfg.visualEffect { visual.show() }
        default: break
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
