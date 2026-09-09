#!/usr/bin/env swift
// Génère l'icône de Cockpit (jauge de cockpit) puis assemble icon/AppIcon.icns.
// Usage : swift tools/make_icon.swift
import AppKit

func draw(_ size: CGFloat) -> NSBitmapImageRep {
    let px = Int(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let s = size

    // Fond : squircle dégradé anthracite.
    let inset = s * 0.055
    let rect = CGRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let squircle = CGPath(roundedRect: rect, cornerWidth: s * 0.225, cornerHeight: s * 0.225, transform: nil)
    ctx.saveGState()
    ctx.addPath(squircle); ctx.clip()
    let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                        colors: [NSColor(red: 0.13, green: 0.16, blue: 0.20, alpha: 1).cgColor,
                                 NSColor(red: 0.06, green: 0.08, blue: 0.11, alpha: 1).cgColor] as CFArray,
                        locations: [0, 1])!
    ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])

    let c = CGPoint(x: s / 2, y: s / 2 - s * 0.02)
    let r = s * 0.30
    let lw = s * 0.085
    let start = CGFloat.pi * 1.35   // ~ -135° visuel
    let end = CGFloat.pi * -0.35

    // Rail de la jauge.
    ctx.setLineCap(.round)
    ctx.setLineWidth(lw)
    ctx.setStrokeColor(NSColor(red: 1, green: 1, blue: 1, alpha: 0.10).cgColor)
    ctx.addArc(center: c, radius: r, startAngle: start, endAngle: end, clockwise: true)
    ctx.strokePath()

    // Arc actif (dégradé vert).
    ctx.saveGState()
    let arc = CGMutablePath()
    arc.addArc(center: c, radius: r, startAngle: start, endAngle: CGFloat.pi * 0.25, clockwise: true)
    ctx.addPath(arc.copy(strokingWithWidth: lw, lineCap: .round, lineJoin: .round, miterLimit: 10))
    ctx.clip()
    let green = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [NSColor(red: 0.02, green: 0.60, blue: 0.42, alpha: 1).cgColor,
                                    NSColor(red: 0.35, green: 0.86, blue: 0.55, alpha: 1).cgColor] as CFArray,
                           locations: [0, 1])!
    ctx.drawLinearGradient(green, start: CGPoint(x: c.x - r, y: c.y - r),
                           end: CGPoint(x: c.x + r, y: c.y + r), options: [])
    ctx.restoreGState()

    // Graduations, juste à l'extérieur du rail.
    ctx.setStrokeColor(NSColor(white: 1, alpha: 0.16).cgColor)
    ctx.setLineWidth(s * 0.013)
    ctx.setLineCap(.round)
    for i in 0...6 {
        let t = start + (end - start) * CGFloat(i) / 6
        let inner = r + lw * 0.75, outer = r + lw * 1.35
        ctx.move(to: CGPoint(x: c.x + cos(t) * inner, y: c.y + sin(t) * inner))
        ctx.addLine(to: CGPoint(x: c.x + cos(t) * outer, y: c.y + sin(t) * outer))
    }
    ctx.strokePath()

    // Aiguille vers le haut-droite.
    let needle = CGFloat.pi * 0.16
    let nlen = r * 0.98
    ctx.setLineCap(.round)
    ctx.setLineWidth(s * 0.030)
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.move(to: CGPoint(x: c.x - cos(needle) * s * 0.05, y: c.y - sin(needle) * s * 0.05))
    ctx.addLine(to: CGPoint(x: c.x + cos(needle) * nlen, y: c.y + sin(needle) * nlen))
    ctx.strokePath()

    // Moyeu.
    ctx.setFillColor(NSColor(red: 0.35, green: 0.86, blue: 0.55, alpha: 1).cgColor)
    ctx.fillEllipse(in: CGRect(x: c.x - s * 0.055, y: c.y - s * 0.055, width: s * 0.11, height: s * 0.11))
    ctx.setFillColor(NSColor(white: 0.10, alpha: 1).cgColor)
    ctx.fillEllipse(in: CGRect(x: c.x - s * 0.022, y: c.y - s * 0.022, width: s * 0.044, height: s * 0.044))

    ctx.restoreGState()

    // Liséré subtil.
    ctx.addPath(squircle)
    ctx.setStrokeColor(NSColor(white: 1, alpha: 0.06).cgColor)
    ctx.setLineWidth(s * 0.006)
    ctx.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let fm = FileManager.default
let root = URL(fileURLWithPath: CommandLine.arguments.first ?? ".")
    .deletingLastPathComponent().deletingLastPathComponent()
let iconset = root.appendingPathComponent("icon/AppIcon.iconset")
try? fm.removeItem(at: iconset)
try! fm.createDirectory(at: iconset, withIntermediateDirectories: true)

let specs: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in specs {
    let rep = draw(px)
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: iconset.appendingPathComponent("\(name).png"))
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("icon/AppIcon.icns").path]
try! task.run(); task.waitUntilExit()
try? fm.removeItem(at: iconset)
print(task.terminationStatus == 0 ? "✓ icon/AppIcon.icns" : "✗ iconutil a échoué")
