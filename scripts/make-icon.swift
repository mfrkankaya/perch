// Renders the Perch app icon (1024 px master) and builds Resources/AppIcon.icns.
// Usage: swift scripts/make-icon.swift
import AppKit

let S: CGFloat = 1024

func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

func gradient(_ c: [CGColor], _ locs: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: c as CFArray, locations: locs)!
}

func render(size px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    let g = ctx.cgContext
    g.scaleBy(x: CGFloat(px) / S, y: CGFloat(px) / S)

    // Tile (macOS grid: 824 px body, 100 px margin) with soft drop shadow.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
    g.saveGState()
    g.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: color(0x000000, 0.35))
    g.addPath(tilePath); g.setFillColor(color(0x1B1F4B)); g.fillPath()
    g.restoreGState()

    g.saveGState()
    g.addPath(tilePath); g.clip()
    // Dusk sky
    g.drawLinearGradient(gradient([color(0x23265E), color(0x3B3A8F), color(0x0E8C95)], [0, 0.45, 1]),
                         start: CGPoint(x: 200, y: 924), end: CGPoint(x: 824, y: 100), options: [])
    // Moon glow
    g.drawRadialGradient(gradient([color(0xFFE7A8, 0.55), color(0xFFE7A8, 0)]),
                         startCenter: CGPoint(x: 735, y: 760), startRadius: 0,
                         endCenter: CGPoint(x: 735, y: 760), endRadius: 260, options: [])
    g.setFillColor(color(0xFFF1C9)); g.fillEllipse(in: CGRect(x: 690, y: 715, width: 90, height: 90))
    // Stars
    for (x, y, r) in [(260.0, 800.0, 7.0), (340.0, 860.0, 5.0), (470.0, 815.0, 4.0), (580.0, 870.0, 6.0), (215.0, 690.0, 4.0)] {
        g.setFillColor(color(0xFFFFFF, 0.8)); g.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
    }
    // Top sheen
    g.drawLinearGradient(gradient([color(0xFFFFFF, 0.14), color(0xFFFFFF, 0)]),
                         start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 640), options: [])
    g.restoreGState()

    // Perch (branch / menu bar) crossing the whole tile
    g.saveGState()
    g.addPath(tilePath); g.clip()
    g.setShadow(offset: CGSize(width: 0, height: -6), blur: 12, color: color(0x000000, 0.3))
    let bar = CGPath(roundedRect: CGRect(x: 60, y: 300, width: 904, height: 44), cornerWidth: 22, cornerHeight: 22, transform: nil)
    g.addPath(bar); g.setFillColor(color(0xF6EBDD)); g.fillPath()
    g.restoreGState()

    // Bird
    g.saveGState()
    g.setShadow(offset: CGSize(width: 0, height: -10), blur: 22, color: color(0x000000, 0.35))
    let body = CGMutablePath()
    body.move(to: CGPoint(x: 330, y: 470))                         // tail tip join
    body.addCurve(to: CGPoint(x: 560, y: 360), control1: CGPoint(x: 380, y: 380), control2: CGPoint(x: 470, y: 352))
    body.addCurve(to: CGPoint(x: 700, y: 520), control1: CGPoint(x: 650, y: 368), control2: CGPoint(x: 705, y: 440))
    body.addCurve(to: CGPoint(x: 640, y: 690), control1: CGPoint(x: 712, y: 600), control2: CGPoint(x: 700, y: 670))
    body.addCurve(to: CGPoint(x: 500, y: 640), control1: CGPoint(x: 580, y: 712), control2: CGPoint(x: 520, y: 690))
    body.addCurve(to: CGPoint(x: 330, y: 470), control1: CGPoint(x: 470, y: 570), control2: CGPoint(x: 400, y: 510))
    body.closeSubpath()
    // tail
    let tail = CGMutablePath()
    tail.move(to: CGPoint(x: 420, y: 440))
    tail.addLine(to: CGPoint(x: 215, y: 420))
    tail.addQuadCurve(to: CGPoint(x: 260, y: 505), control: CGPoint(x: 220, y: 470))
    tail.addLine(to: CGPoint(x: 450, y: 540))
    tail.closeSubpath()
    g.setFillColor(color(0xFF9A3C))
    g.addPath(tail); g.fillPath()
    g.addPath(body); g.fillPath()
    g.restoreGState()

    // Body gradient fill
    let bodyGradient = gradient([color(0xFFD45C), color(0xFF9F3F), color(0xF2672E)], [0, 0.55, 1])
    g.saveGState()
    g.addPath(tail); g.clip()
    g.drawLinearGradient(bodyGradient, start: CGPoint(x: 620, y: 700), end: CGPoint(x: 330, y: 380),
                         options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    g.restoreGState()
    g.saveGState()
    g.addPath(body); g.clip()
    g.drawLinearGradient(gradient([color(0xFFD45C), color(0xFF9F3F), color(0xF2672E)], [0, 0.55, 1]),
                         start: CGPoint(x: 620, y: 700), end: CGPoint(x: 330, y: 380), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    // Belly highlight
    g.setFillColor(color(0xFFF0C2, 0.55))
    g.fillEllipse(in: CGRect(x: 545, y: 390, width: 150, height: 170))
    g.restoreGState()

    // Wing
    let wing = CGMutablePath()
    wing.move(to: CGPoint(x: 400, y: 500))
    wing.addCurve(to: CGPoint(x: 590, y: 560), control1: CGPoint(x: 470, y: 560), control2: CGPoint(x: 540, y: 585))
    wing.addCurve(to: CGPoint(x: 520, y: 430), control1: CGPoint(x: 620, y: 520), control2: CGPoint(x: 590, y: 445))
    wing.addCurve(to: CGPoint(x: 400, y: 500), control1: CGPoint(x: 470, y: 420), control2: CGPoint(x: 430, y: 455))
    wing.closeSubpath()
    g.saveGState()
    g.addPath(wing); g.clip()
    g.drawLinearGradient(gradient([color(0xE65A26), color(0xC8441C)]),
                         start: CGPoint(x: 560, y: 570), end: CGPoint(x: 420, y: 440), options: [])
    g.restoreGState()

    // Beak
    let beak = CGMutablePath()
    beak.move(to: CGPoint(x: 690, y: 625))
    beak.addLine(to: CGPoint(x: 775, y: 598))
    beak.addLine(to: CGPoint(x: 688, y: 572))
    beak.closeSubpath()
    g.addPath(beak); g.setFillColor(color(0x3A2A6E)); g.fillPath()

    // Eye
    g.setFillColor(color(0xFFFFFF)); g.fillEllipse(in: CGRect(x: 612, y: 606, width: 50, height: 50))
    g.setFillColor(color(0x1E1B3F)); g.fillEllipse(in: CGRect(x: 628, y: 616, width: 28, height: 28))
    g.setFillColor(color(0xFFFFFF)); g.fillEllipse(in: CGRect(x: 641, y: 632, width: 9, height: 9))

    // Feet gripping the perch
    g.setStrokeColor(color(0x3A2A6E)); g.setLineWidth(16); g.setLineCap(.round)
    for x in [500.0, 575.0] {
        g.move(to: CGPoint(x: x, y: 385)); g.addLine(to: CGPoint(x: x, y: 336))
        g.move(to: CGPoint(x: x - 18, y: 336)); g.addLine(to: CGPoint(x: x + 18, y: 336))
    }
    g.strokePath()

    // Subtle inner border
    g.addPath(CGPath(roundedRect: tile.insetBy(dx: 2, dy: 2), cornerWidth: 184, cornerHeight: 184, transform: nil))
    g.setStrokeColor(color(0xFFFFFF, 0.12)); g.setLineWidth(4); g.strokePath()

    ctx.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : FileManager.default.currentDirectoryPath)
let iconset = root.appendingPathComponent("build/AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try render(size: 1024).write(to: root.appendingPathComponent("Resources/AppIcon-1024.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "AppIcon.icns written" : "iconutil failed")
