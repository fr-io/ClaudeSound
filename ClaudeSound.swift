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
    var overlayEnabled: Bool = false
    var overlayScreenIndex: Int = 0      // index into NSScreen.screens
    var overlayCorner: String = "topRight"   // "topRight" | "topLeft"
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
    let label: String       // friendly menu label
    var shortKind: String { // short tag used in the floating overlay
        switch label {
        case "Claude CLI":             return "cli"
        case "Claude Code":            return "code"
        case "Claude Agent (Desktop)": return "agent"
        case "Claude Desktop":         return "desktop"
        default:                       return "claude"
        }
    }
}

/// Walks up the parent-PID chain until we hit a regular GUI app (Terminal,
/// iTerm, Claude.app, VS Code, …). Returns nil if nothing GUI is found.
func findGUIAncestorApp(forPID pid: Int) -> NSRunningApplication? {
    var current = pid_t(pid)
    for _ in 0..<16 {
        if current <= 1 { break }
        if let app = NSRunningApplication(processIdentifier: current),
           app.activationPolicy == .regular {
            return app
        }
        current = parentPID(of: current)
    }
    return nil
}

func parentPID(of pid: pid_t) -> pid_t {
    let out = runCapturingStdout("/bin/ps", ["-p", "\(pid)", "-o", "ppid="])
    return pid_t(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
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
        let cmd = String(line[line.index(after: sep)...])
            .trimmingCharacters(in: .whitespaces)
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

// MARK: - Floating session overlay

func makeGearIcon(diameter d: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: d, height: d))
    img.lockFocus()

    // White circle background for contrast against any wallpaper
    NSColor.white.withAlphaComponent(0.94).setFill()
    let bg = NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: d - 2, height: d - 2))
    bg.fill()
    NSColor.black.withAlphaComponent(0.18).setStroke()
    bg.lineWidth = 0.7
    bg.stroke()

    // Hand-drawn gear: 8 teeth, dark grey
    let center = NSPoint(x: d/2, y: d/2)
    let outerR = d * 0.36
    let baseR  = d * 0.26
    let holeR  = d * 0.10
    let teeth  = 8
    let segs   = teeth * 2  // alternating outer/base
    let path = NSBezierPath()
    for i in 0..<segs {
        let a = (Double(i) / Double(segs)) * .pi * 2 - .pi/2
        let r = (i % 2 == 0) ? outerR : baseR
        let dx = CGFloat(cos(a)), dy = CGFloat(sin(a))
        let pt = NSPoint(x: center.x + dx * r, y: center.y + dy * r)
        if i == 0 { path.move(to: pt) } else { path.line(to: pt) }
    }
    path.close()
    NSColor(white: 0.22, alpha: 1.0).setFill()
    path.fill()
    // Center hole — fill with the same colour as the background to fake a cut-out
    NSColor.white.withAlphaComponent(0.94).setFill()
    NSBezierPath(ovalIn: NSRect(
        x: center.x - holeR, y: center.y - holeR,
        width: holeR*2, height: holeR*2)).fill()

    img.unlockFocus()
    return img
}

func makeExclamationBadge(diameter d: CGFloat) -> NSImage {
    let img = NSImage(size: NSSize(width: d, height: d))
    img.lockFocus()
    // Red filled circle with subtle white outline for contrast
    NSColor.white.setStroke()
    NSColor.systemRed.setFill()
    let outer = NSBezierPath(ovalIn: NSRect(x: 0.5, y: 0.5, width: d - 1, height: d - 1))
    outer.fill()
    outer.lineWidth = 1.0
    outer.stroke()
    // White "!" centered
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: d * 0.72, weight: .heavy),
        .foregroundColor: NSColor.white,
    ]
    let str = NSAttributedString(string: "!", attributes: attrs)
    let sz = str.size()
    str.draw(at: NSPoint(x: (d - sz.width) / 2,
                         y: (d - sz.height) / 2 - d * 0.04))
    img.unlockFocus()
    return img
}

/// Clickable view that hosts the gear icon in a sublayer so we can attach a
/// rotation animation independently of the surrounding NSView geometry.
/// A second sublayer shows a red "!" badge in the top-right when the
/// matching Claude session is asking the user a question.
final class GearView: NSView {
    private let imageLayer = CALayer()
    private let badgeLayer = CALayer()
    private var spinning = false
    private var asking   = false
    private let onClick: () -> Void

    init(diameter d: CGFloat, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: NSRect(x: 0, y: 0, width: d, height: d))
        wantsLayer = true

        imageLayer.frame = bounds
        imageLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        imageLayer.position    = CGPoint(x: bounds.midX, y: bounds.midY)
        imageLayer.contentsGravity = .resizeAspect
        imageLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        let gear = makeGearIcon(diameter: d)
        var pr = NSRect(origin: .zero, size: gear.size)
        if let cg = gear.cgImage(forProposedRect: &pr, context: nil, hints: nil) {
            imageLayer.contents = cg
        } else {
            imageLayer.contents = gear
        }
        layer?.addSublayer(imageLayer)

        // "!" badge — pinned to the top-right corner of the gear, sits on top
        // of the rotating layer so it doesn't spin with the gear.
        let badgeD: CGFloat = d * 0.48
        badgeLayer.frame = NSRect(x: bounds.maxX - badgeD,
                                  y: bounds.maxY - badgeD,
                                  width: badgeD, height: badgeD)
        badgeLayer.contentsGravity = .resizeAspect
        badgeLayer.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
        let badge = makeExclamationBadge(diameter: badgeD)
        var br = NSRect(origin: .zero, size: badge.size)
        if let cg = badge.cgImage(forProposedRect: &br, context: nil, hints: nil) {
            badgeLayer.contents = cg
        } else {
            badgeLayer.contents = badge
        }
        badgeLayer.isHidden = true
        layer?.addSublayer(badgeLayer)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) { onClick() }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    func setSpinning(_ active: Bool) {
        if active == spinning { return }
        spinning = active
        if active {
            let r = CABasicAnimation(keyPath: "transform.rotation.z")
            r.fromValue = 0
            r.toValue   = -CGFloat.pi * 2   // negative → clockwise on screen
            r.duration  = 1.6
            r.repeatCount = .infinity
            r.isRemovedOnCompletion = false
            imageLayer.add(r, forKey: "spin")
        } else {
            imageLayer.removeAnimation(forKey: "spin")
        }
    }

    func setAsking(_ a: Bool) {
        if a == asking { return }
        asking = a
        badgeLayer.isHidden = !a
    }
}

final class ProcessItemView: NSView {
    let pid: Int
    private let gear: GearView

    init(proc: ClaudeProc, width: CGFloat, onClick: @escaping () -> Void) {
        self.pid = proc.pid
        let iconSize: CGFloat = 38
        let labelGap: CGFloat = 4
        let labelHeight: CGFloat = 16
        self.gear = GearView(diameter: iconSize, onClick: onClick)

        super.init(frame: NSRect(x: 0, y: 0, width: width,
                                 height: iconSize + labelGap + labelHeight))
        wantsLayer = true

        gear.frame = NSRect(x: (width - iconSize) / 2,
                            y: labelGap + labelHeight,
                            width: iconSize, height: iconSize)
        gear.toolTip = "\(proc.label) — PID \(proc.pid)"
        addSubview(gear)

        let label = NSTextField(labelWithString: proc.shortKind)
        label.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        label.alignment = .center
        label.textColor = .white
        label.backgroundColor = NSColor.black.withAlphaComponent(0.72)
        label.drawsBackground = true
        label.isBordered = false
        label.wantsLayer = true
        label.layer?.cornerRadius = 5
        label.layer?.masksToBounds = true
        let intrinsic = label.intrinsicContentSize
        let lblW = min(intrinsic.width + 10, width)
        label.frame = NSRect(
            x: (width - lblW) / 2, y: 0,
            width: lblW, height: labelHeight)
        addSubview(label)
    }
    required init?(coder: NSCoder) { fatalError() }
    func setActive(_ a: Bool) { gear.setSpinning(a) }
    func setAsking(_ a: Bool) { gear.setAsking(a) }
}

final class OverlayController {
    private var window: NSWindow?
    private var container: NSView?
    private var itemsByPID: [Int: ProcessItemView] = [:]
    private var lastFrameSize: NSSize = .zero
    private weak var delegate: AppDelegate?
    private let itemWidth: CGFloat = 84
    private let itemSpacing: CGFloat = 10
    private let padding: CGFloat = 10
    private let maxItems = 8

    init(delegate: AppDelegate) { self.delegate = delegate }

    /// Diff-based update: existing item views are reused (so the spin
    /// animation isn't restarted on every refresh); we only build a new
    /// view when a PID first appears, and only recreate the container when
    /// the overall frame size changes.
    func update(procs: [ClaudeProc], cfg: Config,
                active: Set<Int> = [], asking: Set<Int> = []) {
        let visibleProcs = Array(procs.prefix(maxItems))
        if !cfg.overlayEnabled || visibleProcs.isEmpty {
            close()
            return
        }
        let screens = NSScreen.screens
        guard !screens.isEmpty else { close(); return }
        let screenIdx = min(max(0, cfg.overlayScreenIndex), screens.count - 1)
        let screen = screens[screenIdx]
        let visible = screen.visibleFrame

        let itemH: CGFloat = 38 + 4 + 16
        let totalH = CGFloat(visibleProcs.count) * itemH
                   + CGFloat(max(0, visibleProcs.count - 1)) * itemSpacing
                   + padding * 2
        let totalW = itemWidth + padding * 2
        let margin: CGFloat = 14
        let x: CGFloat = (cfg.overlayCorner == "topLeft")
            ? visible.minX + margin
            : visible.maxX - totalW - margin
        let y = visible.maxY - totalH - margin
        let frame = NSRect(x: x, y: y, width: totalW, height: totalH)

        // Ensure window exists
        let w: NSWindow
        if let existing = window {
            w = existing
        } else {
            w = NSWindow(contentRect: frame, styleMask: .borderless,
                         backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.level = .statusBar
            w.backgroundColor = .clear
            w.isOpaque = false
            w.hasShadow = false
            w.ignoresMouseEvents = false
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            window = w
        }
        w.setFrame(frame, display: false)

        // Ensure container; rebuild it (and start fresh) if the geometry changed
        let frameSize = frame.size
        let geometryChanged = (lastFrameSize != frameSize)
        let needsNewContainer = container == nil || geometryChanged
        if needsNewContainer {
            let c = NSView(frame: NSRect(origin: .zero, size: frameSize))
            c.wantsLayer = true
            c.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.18).cgColor
            c.layer?.cornerRadius = 10
            c.layer?.masksToBounds = true
            // Re-attach existing items to the new container
            for view in itemsByPID.values { c.addSubview(view) }
            container = c
            w.contentView = c
            lastFrameSize = frameSize
        }
        guard let cont = container else { return }

        // Diff PIDs
        let newPIDs = Set(visibleProcs.map { $0.pid })
        for (pid, view) in itemsByPID where !newPIDs.contains(pid) {
            view.removeFromSuperview()
            itemsByPID.removeValue(forKey: pid)
        }

        // Update existing + create new, then position
        var yOff = totalH - padding - itemH
        for p in visibleProcs {
            let item: ProcessItemView
            let isActive = active.contains(p.pid)
            let isAsking = asking.contains(p.pid)
            if let existing = itemsByPID[p.pid] {
                item = existing
                item.setActive(isActive)
                item.setAsking(isAsking)
            } else {
                let pidCopy = p.pid
                item = ProcessItemView(proc: p, width: itemWidth) { [weak self] in
                    self?.delegate?.focusPID(pidCopy)
                }
                item.setActive(isActive)
                item.setAsking(isAsking)
                cont.addSubview(item)
                itemsByPID[p.pid] = item
            }
            item.setFrameOrigin(NSPoint(x: padding, y: yOff))
            yOff -= (itemH + itemSpacing)
        }
        w.orderFrontRegardless()
    }

    func close() {
        window?.orderOut(nil)
        window?.close()
        window = nil
        container = nil
        itemsByPID.removeAll()
        lastFrameSize = .zero
    }
}

// MARK: - Updater (self-update from GitHub releases)

let UPDATE_REPO = "fr-io/ClaudeSound"

struct GitHubRelease: Codable {
    let tagName: String
    let name: String?
    let htmlUrl: String
    let assets: [Asset]
    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case htmlUrl = "html_url"
        case assets
    }
    struct Asset: Codable {
        let name: String
        let browserDownloadUrl: String
        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadUrl = "browser_download_url"
        }
    }
}

enum UpdateState {
    case idle
    case checking
    case available(version: String, dmgURL: URL)
    case downloading
    case applying
    case error(String)
}

func currentAppVersion() -> String {
    (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0"
}

func versionTuple(_ s: String) -> [Int] {
    s.trimmingCharacters(in: CharacterSet(charactersIn: "v "))
     .split(separator: ".")
     .compactMap { Int($0) }
}

func isVersion(_ remote: String, newerThan local: String) -> Bool {
    let r = versionTuple(remote), l = versionTuple(local)
    let n = max(r.count, l.count)
    for i in 0..<n {
        let a = i < r.count ? r[i] : 0
        let b = i < l.count ? l[i] : 0
        if a != b { return a > b }
    }
    return false
}

func fetchLatestRelease(completion: @escaping (Result<GitHubRelease, Error>) -> Void) {
    guard let url = URL(string: "https://api.github.com/repos/\(UPDATE_REPO)/releases/latest") else {
        completion(.failure(NSError(domain: "ClaudeSound", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "invalid URL"])))
        return
    }
    var req = URLRequest(url: url)
    req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
    req.timeoutInterval = 10
    URLSession.shared.dataTask(with: req) { data, _, err in
        if let err = err { completion(.failure(err)); return }
        guard let data = data else {
            completion(.failure(NSError(domain: "ClaudeSound", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "no data"])))
            return
        }
        do {
            let dec = JSONDecoder()
            let r = try dec.decode(GitHubRelease.self, from: data)
            completion(.success(r))
        } catch {
            completion(.failure(error))
        }
    }.resume()
}

// Embedded updater shell script. Runs after our app quits, mounts the
// downloaded DMG, swaps the bundle on disk, unmounts, and re-launches.
let UPDATER_SCRIPT = #"""
#!/bin/bash
APP_PID="$1"
DMG="$2"
APP_DIR="$3"

# Wait for the calling app to exit (max ~12 s)
for i in $(seq 1 48); do
  if ! kill -0 "$APP_PID" 2>/dev/null; then break; fi
  sleep 0.25
done

MOUNT_OUTPUT=$(hdiutil attach -nobrowse -noverify "$DMG" 2>/dev/null)
MOUNT_DIR=$(echo "$MOUNT_OUTPUT" | grep -oE '/Volumes/[^[:cntrl:]]+' | tail -1)
NEW_APP="$MOUNT_DIR/ClaudeSound.app"

if [ -n "$MOUNT_DIR" ] && [ -d "$NEW_APP" ]; then
  rm -rf "$APP_DIR"
  cp -R "$NEW_APP" "$APP_DIR"
  xattr -cr "$APP_DIR" 2>/dev/null || true
  hdiutil detach "$MOUNT_DIR" -quiet 2>/dev/null || true
  open "$APP_DIR"
else
  [ -n "$MOUNT_DIR" ] && hdiutil detach "$MOUNT_DIR" -quiet 2>/dev/null || true
  /usr/bin/osascript -e 'display alert "ClaudeSound Update fehlgeschlagen" message "Die neue Version konnte nicht installiert werden. Die alte Version bleibt funktionsfähig."'
  open "$APP_DIR"
fi
rm -f "$DMG"
"""#

func shellQuote(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
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

    private lazy var overlay = OverlayController(delegate: self)
    private var overlayTimer: Timer?
    // PIDs of Claude sessions currently waiting on the user (Notification
    // fired, no Stop yet).
    private var askingPIDs: Set<Int> = []
    // PIDs currently doing work (UserPromptSubmit fired, no Stop yet).
    // Hook-derived rather than CPU-derived — accurate even when the local
    // process is mostly waiting on the model server.
    private var workingPIDs: Set<Int> = []

    private var updateState: UpdateState = .idle
    private var updateTimer: Timer?

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
        startOverlayTimer()
        scheduleUpdateChecks()

        watcher = TriggerWatcher(url: TRIGGER_URL) { [weak self] ev in
            self?.handleEvent(ev)
        }
        watcher.start()
    }

    // MARK: Update checking

    private func scheduleUpdateChecks() {
        // First check 5 s after launch (don't slow startup), then hourly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.checkForUpdates()
        }
        updateTimer?.invalidate()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            self?.checkForUpdates()
        }
    }

    @objc private func checkForUpdates() {
        // Don't re-enter while a check / download is in flight.
        switch updateState {
        case .checking, .downloading, .applying: return
        default: break
        }
        updateState = .checking
        rebuildMenuIfPresent()
        fetchLatestRelease { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .failure(let err):
                    self.updateState = .error(err.localizedDescription)
                case .success(let release):
                    let local = currentAppVersion()
                    if isVersion(release.tagName, newerThan: local),
                       let asset = release.assets.first(where: { $0.name.hasSuffix(".dmg") }),
                       let dmg = URL(string: asset.browserDownloadUrl) {
                        let cleanVersion = release.tagName
                            .trimmingCharacters(in: CharacterSet(charactersIn: "v "))
                        self.updateState = .available(version: cleanVersion, dmgURL: dmg)
                    } else {
                        self.updateState = .idle
                    }
                }
                self.rebuildMenuIfPresent()
            }
        }
    }

    @objc private func applyUpdate() {
        guard case .available(_, let dmgURL) = updateState else { return }
        updateState = .downloading
        rebuildMenuIfPresent()

        let tmpDMG = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ClaudeSound-update-\(UUID().uuidString).dmg")

        URLSession.shared.downloadTask(with: dmgURL) { [weak self] tmpURL, _, err in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let err = err {
                    self.updateState = .error("Download fehlgeschlagen: \(err.localizedDescription)")
                    self.rebuildMenuIfPresent()
                    return
                }
                guard let tmpURL = tmpURL else {
                    self.updateState = .error("Kein Download-Ziel.")
                    self.rebuildMenuIfPresent()
                    return
                }
                do {
                    try? FileManager.default.removeItem(at: tmpDMG)
                    try FileManager.default.moveItem(at: tmpURL, to: tmpDMG)
                } catch {
                    self.updateState = .error("DMG konnte nicht abgelegt werden: \(error.localizedDescription)")
                    self.rebuildMenuIfPresent()
                    return
                }
                self.updateState = .applying
                self.rebuildMenuIfPresent()
                self.spawnUpdater(dmgPath: tmpDMG.path)
            }
        }.resume()
    }

    private func spawnUpdater(dmgPath: String) {
        let scriptPath = NSTemporaryDirectory()
            + "claudesound-updater-\(UUID().uuidString).sh"
        do {
            try UPDATER_SCRIPT.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            _ = chmod(scriptPath, 0o755)
        } catch {
            updateState = .error("Updater-Script: \(error.localizedDescription)")
            rebuildMenuIfPresent()
            return
        }

        let pid = ProcessInfo.processInfo.processIdentifier
        let bundlePath = Bundle.main.bundlePath
        let cmd = "nohup bash \(shellQuote(scriptPath)) "
                + "\(shellQuote(String(pid))) "
                + "\(shellQuote(dmgPath)) "
                + "\(shellQuote(bundlePath)) "
                + ">/dev/null 2>&1 & disown"

        let p = Process()
        p.launchPath = "/bin/bash"
        p.arguments = ["-c", cmd]
        do {
            try p.run()
            p.waitUntilExit()  // bash -c returns immediately after backgrounding
        } catch {
            updateState = .error("Updater-Start: \(error.localizedDescription)")
            rebuildMenuIfPresent()
            return
        }

        // Give the detached script a moment to spin up, then quit so it can
        // swap the bundle on disk.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.terminate(nil)
        }
    }

    private func rebuildMenuIfPresent() {
        if let menu = statusItem?.menu { populateMenu(menu) }
    }

    /// Idempotently registers ClaudeSound's hooks in ~/.claude/settings.json.
    /// Each hook captures the bash subprocess's $PPID (= the Claude session
    /// process) so the receiving app can associate events with a specific
    /// running session. Older formats are migrated; other user hooks stay.
    private func ensureClaudeHooksInstalled() {
        let settingsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        let triggerPath = TRIGGER_URL.path

        // Each ClaudeSound hook keeps a stable shape so we can compare exactly.
        let wanted: [(event: String, cmd: String)] = [
            ("Notification",      "echo \"notify $PPID\" >> \"\(triggerPath)\""),
            ("Stop",              "echo \"done $PPID\" >> \"\(triggerPath)\""),
            ("UserPromptSubmit",  "echo \"answered $PPID\" >> \"\(triggerPath)\""),
        ]

        try? FileManager.default.createDirectory(at: APP_SUPPORT,
                                                 withIntermediateDirectories: true)

        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            settings = obj
        }
        var hooks = settings["hooks"] as? [String: Any] ?? [:]

        func hasExact(in eventName: String, cmd: String) -> Bool {
            guard let list = hooks[eventName] as? [[String: Any]] else { return false }
            for entry in list {
                guard let inner = entry["hooks"] as? [[String: Any]] else { continue }
                for hk in inner where (hk["command"] as? String) == cmd { return true }
            }
            return false
        }
        if wanted.allSatisfy({ hasExact(in: $0.event, cmd: $0.cmd) }) { return }

        // Strip any previous version of our hooks (anything pointing at our
        // trigger file) so duplicates don't pile up across upgrades.
        func purge(_ eventName: String) -> [[String: Any]] {
            let list = (hooks[eventName] as? [[String: Any]]) ?? []
            return list.filter { entry in
                guard let inner = entry["hooks"] as? [[String: Any]] else { return true }
                return !inner.contains {
                    ($0["command"] as? String)?.contains(triggerPath) == true
                }
            }
        }
        for (event, cmd) in wanted {
            var list = purge(event)
            list.append(["matcher": "",
                         "hooks": [["type": "command", "command": cmd]]])
            hooks[event] = list
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
                // Drop state for sessions that no longer exist
                let live = Set(procs.map { $0.pid })
                self.askingPIDs  = self.askingPIDs.intersection(live)
                self.workingPIDs = self.workingPIDs.intersection(live)
                self.refreshOverlay()
            }
        }
    }

    /// Single point that pushes the current overlay state.
    private func refreshOverlay() {
        overlay.update(procs: cachedProcs,
                       cfg: ConfigStore.current,
                       active: workingPIDs,
                       asking: askingPIDs)
    }

    private func startOverlayTimer() {
        overlayTimer?.invalidate()
        overlayTimer = nil
        guard ConfigStore.current.overlayEnabled else { return }
        overlayTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            self?.refreshProcsAsync()
        }
    }

    func focusProcess(_ proc: ClaudeProc) { focusPID(proc.pid) }

    func focusPID(_ pid: Int) {
        // Background-walk so a slow `ps` doesn't freeze the click feedback.
        procQueue.async {
            let target = autoreleasepool { findGUIAncestorApp(forPID: pid) }
            DispatchQueue.main.async {
                target?.activate(options: [.activateAllWindows])
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

        let header = NSMenuItem(title: "ClaudeSound v\(currentAppVersion())",
                                action: nil, keyEquivalent: "")
        header.isEnabled = false
        m.addItem(header)
        m.addItem(.separator())

        addUpdateSection(to: m)

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

        let ovr = NSMenuItem(title: "Sitzungs-Overlay (Zahnräder)",
                             action: #selector(toggleOverlay), keyEquivalent: "")
        ovr.state = ConfigStore.current.overlayEnabled ? .on : .off
        ovr.target = self
        m.addItem(ovr)

        let screensItem = NSMenuItem(title: "Overlay-Bildschirm", action: nil, keyEquivalent: "")
        screensItem.submenu = buildScreenSubmenu()
        m.addItem(screensItem)

        let cornerItem = NSMenuItem(title: "Overlay-Ecke", action: nil, keyEquivalent: "")
        cornerItem.submenu = buildCornerSubmenu()
        m.addItem(cornerItem)

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
        let checkUpd = NSMenuItem(title: "Nach Updates suchen",
                                  action: #selector(checkForUpdates),
                                  keyEquivalent: "")
        checkUpd.target = self
        m.addItem(checkUpd)
        m.addItem(NSMenuItem(title: "Beenden",
                             action: #selector(NSApplication.terminate(_:)),
                             keyEquivalent: "q"))
    }

    private func addUpdateSection(to m: NSMenu) {
        switch updateState {
        case .idle, .checking:
            return  // nothing shown at top
        case .available(let version, _):
            let banner = NSMenuItem(
                title: "🆙 Update verfügbar: v\(version)",
                action: nil, keyEquivalent: "")
            banner.isEnabled = false
            let attr = NSMutableAttributedString(string: banner.title)
            attr.addAttribute(.foregroundColor,
                              value: NSColor.systemBlue,
                              range: NSRange(location: 0, length: attr.length))
            attr.addAttribute(.font,
                              value: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize),
                              range: NSRange(location: 0, length: attr.length))
            banner.attributedTitle = attr
            m.addItem(banner)

            let apply = NSMenuItem(title: "    Jetzt aktualisieren",
                                   action: #selector(applyUpdate),
                                   keyEquivalent: "")
            apply.target = self
            m.addItem(apply)
            m.addItem(.separator())
        case .downloading:
            let it = NSMenuItem(title: "⏬ Update wird geladen…",
                                action: nil, keyEquivalent: "")
            it.isEnabled = false
            m.addItem(it)
            m.addItem(.separator())
        case .applying:
            let it = NSMenuItem(title: "🔄 Update wird angewendet — App startet neu…",
                                action: nil, keyEquivalent: "")
            it.isEnabled = false
            m.addItem(it)
            m.addItem(.separator())
        case .error(let msg):
            let it = NSMenuItem(title: "⚠️ Update-Fehler",
                                action: nil, keyEquivalent: "")
            it.isEnabled = false
            it.toolTip = msg
            m.addItem(it)
            m.addItem(.separator())
        }
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

    private func buildScreenSubmenu() -> NSMenu {
        let sub = NSMenu()
        let screens = NSScreen.screens
        let selected = ConfigStore.current.overlayScreenIndex
        for (i, screen) in screens.enumerated() {
            let name = screen.localizedName.isEmpty
                ? "Bildschirm \(i + 1)"
                : "\(screen.localizedName) (#\(i + 1))"
            let sizeStr = "\(Int(screen.frame.width))×\(Int(screen.frame.height))"
            let it = NSMenuItem(title: "\(name) — \(sizeStr)",
                                action: #selector(pickScreen(_:)), keyEquivalent: "")
            it.state = (i == selected) ? .on : .off
            it.target = self
            it.representedObject = i
            sub.addItem(it)
        }
        if screens.isEmpty {
            let it = NSMenuItem(title: "(keine Bildschirme gefunden)",
                                action: nil, keyEquivalent: "")
            it.isEnabled = false
            sub.addItem(it)
        }
        return sub
    }

    private func buildCornerSubmenu() -> NSMenu {
        let sub = NSMenu()
        let current = ConfigStore.current.overlayCorner
        for (title, key) in [("oben rechts", "topRight"), ("oben links", "topLeft")] {
            let it = NSMenuItem(title: title,
                                action: #selector(pickCorner(_:)), keyEquivalent: "")
            it.state = (key == current) ? .on : .off
            it.target = self
            it.representedObject = key
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

    @objc private func toggleOverlay() {
        ConfigStore.current.overlayEnabled.toggle()
        ConfigStore.save()
        startOverlayTimer()
        if ConfigStore.current.overlayEnabled {
            refreshProcsAsync()
        } else {
            overlay.close()
        }
    }

    @objc private func pickScreen(_ sender: NSMenuItem) {
        guard let idx = sender.representedObject as? Int else { return }
        ConfigStore.current.overlayScreenIndex = idx
        ConfigStore.save()
        refreshOverlay()
    }

    @objc private func pickCorner(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        ConfigStore.current.overlayCorner = key
        ConfigStore.save()
        refreshOverlay()
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
        // Event lines: "notify 12345" / "answered 12345" / "done 12345". PID
        // comes from the hook's shell $PPID. The state machine:
        //   notify   → asking on, working stays on
        //   answered → asking off, working on
        //   done     → asking off, working off
        let parts = event.split(separator: " ", maxSplits: 1)
        let kind = String(parts.first ?? "")
        let pid: Int? = (parts.count >= 2) ? Int(parts[1]) : nil
        let cfg = ConfigStore.current
        switch kind {
        case "notify":
            playSound(cfg.notifySound)
            if cfg.visualEffect { visual.show() }
            if let pid = pid {
                askingPIDs.insert(pid)
                refreshOverlay()
            }
        case "answered":
            // User submitted a prompt — Claude starts working, badge clears.
            if let pid = pid {
                askingPIDs.remove(pid)
                workingPIDs.insert(pid)
                refreshOverlay()
            }
        case "done":
            playSound(cfg.doneSound)
            if cfg.visualEffect { visual.show() }
            if let pid = pid {
                askingPIDs.remove(pid)
                workingPIDs.remove(pid)
                refreshOverlay()
            }
        default: break
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
