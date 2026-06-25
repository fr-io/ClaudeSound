// Generates AppIcon.iconset for ClaudeSound: a Claude-orange asterisk with
// a singing mouth + eighth note overlaid in front. Renders at all sizes
// macOS expects so `iconutil` can pack the .icns.
//
// Usage: swift MakeIcon.swift /path/to/AppIcon.iconset

import Cocoa

// Palette
let CREAM  = NSColor(srgbRed: 0.96, green: 0.94, blue: 0.91, alpha: 1.0)
let ORANGE = NSColor(srgbRed: 0.85, green: 0.46, blue: 0.34, alpha: 1.0)
let DARK   = NSColor(srgbRed: 0.18, green: 0.12, blue: 0.10, alpha: 1.0)
let WHITE  = NSColor.white

func drawIcon(canvas s: CGFloat) {
    let r = s * 0.225  // squircle radius, matches Big Sur+ app-icon shape

    // Background rounded square
    let bg = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: s, height: s),
                          xRadius: r, yRadius: r)
    CREAM.setFill()
    bg.fill()

    // Claude asterisk (8 rays, slightly offset up-left so the mouth fits bottom-right)
    drawAsterisk(center: NSPoint(x: s*0.46, y: s*0.56),
                 outer: s*0.34, rays: 8, color: ORANGE)

    // Singing-mouth pill, anchored lower-right, overlapping the asterisk
    let mouthCenter = NSPoint(x: s*0.55, y: s*0.36)
    let mouthW = s * 0.45
    let mouthH = s * 0.22
    drawMouth(center: mouthCenter, width: mouthW, height: mouthH,
              fill: WHITE, stroke: DARK, strokeWidth: s*0.018)

    // Eighth note to the right of the mouth
    drawEighthNote(headCenter: NSPoint(x: s*0.78, y: s*0.50),
                   scale: s*0.085, color: DARK)
}

func drawAsterisk(center c: NSPoint, outer: CGFloat, rays: Int, color: NSColor) {
    color.setFill()
    let inner = outer * 0.13
    for i in 0..<rays {
        let a = (Double(i) / Double(rays)) * .pi * 2
        let dx  = CGFloat(cos(a)), dy  = CGFloat(sin(a))
        let pdx = CGFloat(-sin(a)), pdy = CGFloat(cos(a))
        let p = NSBezierPath()
        p.move(to: NSPoint(x: c.x + pdx*inner, y: c.y + pdy*inner))
        p.line(to: NSPoint(x: c.x + dx*outer + pdx*inner*0.22,
                           y: c.y + dy*outer + pdy*inner*0.22))
        p.line(to: NSPoint(x: c.x + dx*outer - pdx*inner*0.22,
                           y: c.y + dy*outer - pdy*inner*0.22))
        p.line(to: NSPoint(x: c.x - pdx*inner, y: c.y - pdy*inner))
        p.close()
        p.fill()
    }
}

func drawMouth(center c: NSPoint, width w: CGFloat, height h: CGFloat,
               fill: NSColor, stroke: NSColor, strokeWidth sw: CGFloat) {
    let rect = NSRect(x: c.x - w/2, y: c.y - h/2, width: w, height: h)
    let outer = NSBezierPath(roundedRect: rect, xRadius: h/2, yRadius: h/2)
    fill.setFill(); outer.fill()
    stroke.setStroke(); outer.lineWidth = sw; outer.stroke()

    // Lip line — gentle smile across the middle
    let line = NSBezierPath()
    line.move(to: NSPoint(x: rect.minX + h*0.55, y: c.y))
    line.curve(to: NSPoint(x: rect.maxX - h*0.55, y: c.y),
               controlPoint1: NSPoint(x: c.x - w*0.18, y: c.y - h*0.18),
               controlPoint2: NSPoint(x: c.x + w*0.18, y: c.y - h*0.18))
    line.lineWidth = sw * 0.85
    line.lineCapStyle = .round
    stroke.setStroke()
    line.stroke()
}

func drawEighthNote(headCenter h: NSPoint, scale s: CGFloat, color: NSColor) {
    color.setFill(); color.setStroke()

    // Slanted note head
    NSGraphicsContext.current?.saveGraphicsState()
    let xf = NSAffineTransform()
    xf.translateX(by: h.x, yBy: h.y)
    xf.rotate(byDegrees: -22)
    xf.concat()
    let head = NSBezierPath(ovalIn: NSRect(
        x: -s*1.05, y: -s*0.70, width: s*2.1, height: s*1.4))
    head.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    // Stem
    let stemX = h.x + s*0.95
    let stemTop = h.y + s*3.4
    let stem = NSBezierPath()
    stem.move(to: NSPoint(x: stemX, y: h.y + s*0.2))
    stem.line(to: NSPoint(x: stemX, y: stemTop))
    stem.lineWidth = s * 0.40
    stem.lineCapStyle = .round
    stem.stroke()

    // Flag
    let flag = NSBezierPath()
    flag.move(to: NSPoint(x: stemX, y: stemTop))
    flag.curve(to: NSPoint(x: stemX + s*1.55, y: stemTop - s*2.1),
               controlPoint1: NSPoint(x: stemX + s*2.0, y: stemTop - s*0.3),
               controlPoint2: NSPoint(x: stemX + s*1.85, y: stemTop - s*1.4))
    flag.lineWidth = s * 0.45
    flag.lineCapStyle = .round
    flag.lineJoinStyle = .round
    flag.stroke()
}

func renderPNG(size px: Int) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
    else { return nil }
    rep.size = NSSize(width: px, height: px)

    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)
    ctx?.imageInterpolation = .high
    NSGraphicsContext.current = ctx
    drawIcon(canvas: CGFloat(px))
    NSGraphicsContext.restoreGraphicsState()

    return rep.representation(using: .png, properties: [:])
}

// MARK: - Main

_ = NSApplication.shared  // initialize AppKit color machinery

let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "./AppIcon.iconset"
try? FileManager.default.createDirectory(
    atPath: outDir, withIntermediateDirectories: true)

let entries: [(String, Int)] = [
    ("icon_16x16.png",      16),
    ("icon_16x16@2x.png",   32),
    ("icon_32x32.png",      32),
    ("icon_32x32@2x.png",   64),
    ("icon_128x128.png",    128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png",    256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png",    512),
    ("icon_512x512@2x.png", 1024),
]

for (name, px) in entries {
    guard let data = renderPNG(size: px) else {
        FileHandle.standardError.write("failed: \(name)\n".data(using: .utf8)!)
        exit(1)
    }
    let url = URL(fileURLWithPath: outDir).appendingPathComponent(name)
    try? data.write(to: url)
    print("  \(name) (\(px)×\(px))")
}
print("Wrote \(entries.count) PNGs to \(outDir)")
