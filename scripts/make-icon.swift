#!/usr/bin/env swift
import AppKit

// Uygulama ikonu: krem zemin, koyu "editör" kartı, gül rengi bir prompt işareti.
// Tasarımdaki paletin birebir aynısı — ikon da arayüzün parçası.

let sizes: [(name: String, px: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

func color(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

let cream = color(0xF6F0E6)
let ink = color(0x2A1F1A)
let blush = color(0xE8C9C0)
let gold = color(0xC9A961)

func draw(_ px: Int) -> NSImage {
    let size = CGFloat(px)
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let scale = size / 1024

    // Yuvarlatılmış krem zemin (macOS ikon silueti).
    let plate = NSBezierPath(roundedRect: NSRect(x: 100 * scale, y: 100 * scale,
                                                 width: 824 * scale, height: 824 * scale),
                             xRadius: 185 * scale, yRadius: 185 * scale)
    cream.setFill()
    plate.fill()

    // Koyu editör kartı.
    let card = NSBezierPath(roundedRect: NSRect(x: 214 * scale, y: 306 * scale,
                                                width: 596 * scale, height: 412 * scale),
                            xRadius: 64 * scale, yRadius: 64 * scale)
    ink.setFill()
    card.fill()

    // Prompt işareti  ›
    let chevron = NSBezierPath()
    chevron.move(to: NSPoint(x: 344 * scale, y: 570 * scale))
    chevron.line(to: NSPoint(x: 436 * scale, y: 496 * scale))
    chevron.line(to: NSPoint(x: 344 * scale, y: 422 * scale))
    chevron.lineWidth = 46 * scale
    chevron.lineCapStyle = .round
    chevron.lineJoinStyle = .round
    blush.setStroke()
    chevron.stroke()

    // İmleç satırı.
    let caret = NSBezierPath(roundedRect: NSRect(x: 486 * scale, y: 400 * scale,
                                                 width: 200 * scale, height: 44 * scale),
                             xRadius: 22 * scale, yRadius: 22 * scale)
    gold.setFill()
    caret.fill()

    image.unlockFocus()
    return image
}

let fm = FileManager.default
let dir = "AppIcon.iconset"
try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

for (name, px) in sizes {
    let image = draw(px)
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else { continue }
    try? png.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
}

print("✓ \(dir) üretildi")
