// swift tools/make-icon.swift <out.iconset>  — draws the Powvy Note icon at all iconset sizes.
import AppKit

func draw(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect { NSRect(x: x * s, y: y * s, width: w * s, height: h * s) }

    // macOS squircle-ish tile, dark gradient
    let tile = NSBezierPath(roundedRect: r(100, 100, 824, 824), xRadius: 185 * s, yRadius: 185 * s)
    NSGradient(starting: NSColor(calibratedWhite: 0.20, alpha: 1), ending: NSColor(calibratedWhite: 0.05, alpha: 1))!.draw(in: tile, angle: -90)

    // sticky note hanging from the notch
    let note = NSBezierPath(roundedRect: r(250, 210, 524, 560), xRadius: 40 * s, yRadius: 40 * s)
    NSColor(calibratedRed: 1.0, green: 0.84, blue: 0.30, alpha: 1).setFill()
    note.fill()

    // the notch
    let notch = NSBezierPath(roundedRect: r(372, 740, 280, 110), xRadius: 50 * s, yRadius: 50 * s)
    NSColor.black.setFill()
    notch.fill()
    NSBezierPath(rect: r(372, 800, 280, 124)).fill()

    // markdown lines: heading + checkbox rows
    let ink = NSColor(calibratedRed: 0.30, green: 0.22, blue: 0.05, alpha: 1)
    ink.setFill()
    NSBezierPath(roundedRect: r(310, 610, 300, 46), xRadius: 23 * s, yRadius: 23 * s).fill()
    for (i, y) in [CGFloat(500), 400, 300].enumerated() {
        ink.setStroke()
        let box = NSBezierPath(roundedRect: r(310, y, 54, 54), xRadius: 12 * s, yRadius: 12 * s)
        box.lineWidth = 12 * s
        box.stroke()
        if i == 0 {
            let tick = NSBezierPath()
            tick.move(to: NSPoint(x: 322 * s, y: (y + 28) * s))
            tick.line(to: NSPoint(x: 338 * s, y: (y + 12) * s))
            tick.line(to: NSPoint(x: 370 * s, y: (y + 60) * s))
            tick.lineWidth = 14 * s
            tick.lineCapStyle = .round
            tick.stroke()
        }
        NSBezierPath(roundedRect: r(394, y + 10, i == 2 ? 200 : 300, 34), xRadius: 17 * s, yRadius: 17 * s).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try draw(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try draw(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
