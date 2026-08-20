#!/usr/bin/env swift
//
// Generates VelaChat.icns from the same marque the app draws in-app
// (`VelaMark` in Views/Components.swift): the hand-tuned seafoam family's
// dark teal ground, a seafoam `sailboat.fill`, and the small coral
// waterline. Colors are copied from Theme.swift / AccentPreset.teal so the
// dock icon and the in-app mark cannot drift apart.
//
// Run:  swift Scripts/make-icon.swift
// Then: Scripts/build-app.sh copies the result into the bundle.
//
// A squircle rather than VelaMark's circle: macOS icons since Big Sur sit
// on the system's rounded-rect grid, and a bare circle reads as a foreign
// object in the dock next to every other app.

import AppKit
import Foundation

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha
    )
}

// Theme.swift — AccentPreset.teal
let markBackground = color(0x173333)   // handTunedFamily.mark
let accent = color(0x8DDECE)           // baseHex
let accentStrong = color(0x52B9A8)     // handTunedFamily.strong
let coral = color(0xF0A58D)

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    guard let context = NSGraphicsContext.current else { image.unlockFocus(); return image }
    context.imageInterpolation = .high

    // Apple's icon grid leaves the artwork inset from the canvas so the
    // shadow and neighbouring icons have room.
    let inset = size * 0.0586
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = rect.width * 0.2237   // the Big Sur continuous-corner ratio
    let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    // Ground: a slight vertical lift keeps a very dark fill from reading
    // as a flat black tile at small sizes.
    let ground = NSGradient(
        colors: [
            markBackground.blended(withFraction: 0.16, of: accentStrong) ?? markBackground,
            markBackground
        ],
        atLocations: [0, 1],
        colorSpace: .sRGB
    )
    ground?.draw(in: squircle, angle: -90)

    // Inner hairline, the same idea as `.velaBorder` in the app.
    squircle.lineWidth = max(1, size * 0.006)
    accent.withAlphaComponent(0.16).setStroke()
    squircle.stroke()

    // The sailboat, tinted seafoam. Drawn from the SF Symbol so the dock
    // icon is literally the same glyph the app shows.
    let symbolPointSize = size * 0.42
    let configuration = NSImage.SymbolConfiguration(pointSize: symbolPointSize, weight: .medium)
    if let symbol = NSImage(systemSymbolName: "sailboat.fill", accessibilityDescription: "VelaChat")?
        .withSymbolConfiguration(configuration) {
        let tinted = NSImage(size: symbol.size)
        tinted.lockFocus()
        accent.set()
        NSRect(origin: .zero, size: symbol.size).fill(using: .sourceOver)
        symbol.draw(at: .zero, from: NSRect(origin: .zero, size: symbol.size), operation: .destinationIn, fraction: 1)
        tinted.unlockFocus()

        let target = NSRect(
            x: (size - tinted.size.width) / 2,
            y: (size - tinted.size.height) / 2 + size * 0.075,
            width: tinted.size.width,
            height: tinted.size.height
        )
        tinted.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1)
    }

    // The coral waterline — VelaMark's rotated capsule, kept because it is
    // the one warm note in the whole identity.
    //
    // Two departures from VelaMark, both forced by scale. It sits BELOW
    // the symbol's waves rather than across them (at 30pt in the sidebar
    // the overlap reads as a tiny accent; at 512 it reads as a mistake
    // drawn through the hull), and it is centred rather than offset right,
    // where at 32px it read as a stray speck in the corner instead of part
    // of the mark.
    //
    // Below 32px it is dropped entirely: three coral pixels in the corner
    // are noise, not identity.
    if size >= 32 {
        let lineWidth = size * 0.26
        let lineHeight = max(1, size * 0.052)
        let line = NSRect(
            x: size * 0.5 - lineWidth * 0.5,
            y: size * 0.185,
            width: lineWidth,
            height: lineHeight
        )
        context.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: line.midX, yBy: line.midY)
        transform.rotate(byDegrees: -8)
        transform.translateX(by: -line.midX, yBy: -line.midY)
        transform.concat()
        coral.setFill()
        NSBezierPath(roundedRect: line, xRadius: lineHeight / 2, yRadius: lineHeight / 2).fill()
        context.restoreGraphicsState()
    }

    image.unlockFocus()
    return image
}

func png(_ image: NSImage, size: CGFloat) -> Data? {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(size), pixelsHigh: Int(size),
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

// Output path is explicit when given, because build-app.sh invokes this
// from whatever directory the user happened to run it from — relying on
// the working directory silently wrote the iconset somewhere else.
let iconset: URL
if CommandLine.arguments.count > 1 {
    iconset = URL(fileURLWithPath: CommandLine.arguments[1])
} else {
    iconset = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent("build/AppIcon.iconset")
}
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(String, CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]

for (name, size) in variants {
    let image = drawIcon(size: size)
    guard let data = png(image, size: size) else {
        FileHandle.standardError.write("failed to render \(name)\n".data(using: .utf8)!)
        exit(1)
    }
    try data.write(to: iconset.appendingPathComponent("\(name).png"))
}

print("✅ Wrote \(variants.count) images to \(iconset.path)")
