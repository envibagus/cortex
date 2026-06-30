// Renders the Cortex DMG "Drag to Install" background to the path given as arg 1.
// Uses the system font (SF). Run by scripts/make-dmg-styled.sh.
//
// Usage: swift scripts/dmg-background.swift out.png
import AppKit

let w: CGFloat = 660, h: CGFloat = 400
let img = NSImage(size: NSSize(width: w, height: h))
img.lockFocus()

// Soft top-to-bottom light gradient.
NSGradient(colors: [NSColor(white: 0.99, alpha: 1), NSColor(white: 0.945, alpha: 1)])!
    .draw(in: NSRect(x: 0, y: 0, width: w, height: h), angle: -90)

func centered() -> NSMutableParagraphStyle {
    let p = NSMutableParagraphStyle(); p.alignment = .center; return p
}

// Title near the top (AppKit origin is bottom-left, so high y is the top).
let title = "Drag to Install"
(title as NSString).draw(
    in: NSRect(x: 0, y: h - 92, width: w, height: 60),
    withAttributes: [
        .font: NSFont.systemFont(ofSize: 44, weight: .semibold),
        .foregroundColor: NSColor(white: 0.12, alpha: 1),
        .paragraphStyle: centered(),
    ])

// Chevrons across the middle, between where the two icons sit.
let chevrons = "\u{203A}   \u{203A}   \u{203A}"
(chevrons as NSString).draw(
    in: NSRect(x: w / 2 - 70, y: h - 235, width: 140, height: 46),
    withAttributes: [
        .font: NSFont.systemFont(ofSize: 38, weight: .semibold),
        .foregroundColor: NSColor(white: 0.62, alpha: 1),
        .paragraphStyle: centered(),
    ])

img.unlockFocus()

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "dmg-background.png"
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
