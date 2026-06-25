import AppKit

// MARK: - MenuBarIcon
//
// Draws the status-item image for the three icon modes. `text` reuses an SF Symbol
// template glyph (auto-tinted by AppKit) and lets the controller set the "42%" title;
// `donut` and `bars` are drawn with Core Graphics. The drawn images use the system
// blue/orange usage hues for the fill (vivid on light and dark menu bars) and resolve
// dynamic colors against the passed appearance, so the controller re-renders them when
// the system theme changes.

enum MenuBarIcon {
    /// Usage hue: calm blue with headroom, orange once mostly spent (matches UsageHeat).
    static func heatColor(_ percent: Double) -> NSColor {
        percent < 75 ? .systemBlue : .systemOrange
    }

    /// A small filled circle in a fixed color (non-template), e.g. the yellow dot shown
    /// while Claude Code is awaiting permission.
    static func coloredDot(_ color: NSColor, diameter: CGFloat = 9) -> NSImage {
        let size = NSSize(width: diameter, height: diameter)
        let image = NSImage(size: size)
        image.lockFocus()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    /// A template SF Symbol image sized for the menu bar (AppKit tints it for the bar).
    static func glyph(_ symbol: String, pointSize: CGFloat = 12, weight: NSFont.Weight = .semibold) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)
        image?.isTemplate = true
        return image
    }

    /// An SF Symbol rendered in a fixed color (non-template), e.g. the green checkmark on
    /// the "Done" flash. Draws the template glyph then tints it with a source-atop fill.
    static func tintedGlyph(_ symbol: String, color: NSColor, pointSize: CGFloat = 12) -> NSImage? {
        guard let base = glyph(symbol, pointSize: pointSize) else { return nil }
        let size = base.size
        let image = NSImage(size: size)
        image.lockFocus()
        base.draw(in: NSRect(origin: .zero, size: size))
        color.set()
        NSRect(origin: .zero, size: size).fill(using: .sourceAtop)
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    /// The percent string for one window (display-mode aware), or "--%" when unknown.
    private static func percentText(_ percent: Double?, mode: UsageDisplayMode) -> String {
        guard let percent else { return "--%" }
        return UsageDisplay.barLabel(percent, mode: mode)
    }

    /// Color for a percent number: orange once mostly spent, label color otherwise.
    private static func numberColor(_ percent: Double?) -> NSColor {
        guard let percent else { return .secondaryLabelColor }
        return percent >= 75 ? .systemOrange : .labelColor
    }

    /// Glyph + two small stacked percentages (Session over Weekly), like a compact
    /// dual-metric readout. Drawn so the numbers can carry the usage hue.
    static func both(session: Double?, weekly: Double?, mode: UsageDisplayMode, appearance: NSAppearance) -> NSImage {
        let font = NSFont.systemFont(ofSize: 9, weight: .semibold)
        let topStr = percentText(session, mode: mode)
        let botStr = percentText(weekly, mode: mode)
        let topSize = (topStr as NSString).size(withAttributes: [.font: font])
        let botSize = (botStr as NSString).size(withAttributes: [.font: font])
        let overlap: CGFloat = 2
        let textW = ceil(max(topSize.width, botSize.width))
        let blockH = topSize.height + botSize.height - overlap

        let glyphImg = glyph("sparkle", pointSize: 11)
        let glyphSize = glyphImg?.size ?? NSSize(width: 12, height: 12)
        let gap: CGFloat = 3
        let height = ceil(max(blockH, glyphSize.height, 15))
        let width = ceil(glyphSize.width + gap + textW)

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        appearance.performAsCurrentDrawingAppearance {
            // Glyph, vertically centered + tinted to the label color.
            if let glyphImg {
                let rect = NSRect(x: 0, y: (height - glyphSize.height) / 2,
                                  width: glyphSize.width, height: glyphSize.height)
                glyphImg.draw(in: rect)
                NSColor.labelColor.set()
                rect.fill(using: .sourceAtop)
            }
            // Two stacked, trailing-aligned percentages (top = Session, bottom = Weekly).
            let colX = glyphSize.width + gap
            let blockTopY = (height + blockH) / 2
            let topY = blockTopY - topSize.height
            let botY = topY - botSize.height + overlap
            (topStr as NSString).draw(at: NSPoint(x: colX + (textW - ceil(topSize.width)), y: topY),
                                      withAttributes: [.font: font, .foregroundColor: numberColor(session)])
            (botStr as NSString).draw(at: NSPoint(x: colX + (textW - ceil(botSize.width)), y: botY),
                                      withAttributes: [.font: font, .foregroundColor: numberColor(weekly)])
        }
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    /// A progress ring filled clockwise from the top to the usage fraction.
    static func donut(percent: Double, appearance: NSAppearance) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        appearance.performAsCurrentDrawingAppearance {
            let lineWidth: CGFloat = 2.5
            let inset = lineWidth / 2 + 1
            let center = NSPoint(x: size.width / 2, y: size.height / 2)
            let radius = (size.width - inset * 2) / 2

            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = lineWidth
            NSColor.tertiaryLabelColor.setStroke()
            track.stroke()

            let frac = max(0, min(1, percent / 100))
            if frac > 0 {
                let start: CGFloat = 90
                let end = start - 360 * frac
                let arc = NSBezierPath()
                arc.appendArc(withCenter: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
                arc.lineWidth = lineWidth
                arc.lineCapStyle = .round
                heatColor(percent).setStroke()
                arc.stroke()
            }
        }
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    /// Two stacked bars (Session on top, Weekly below), each filled to its fraction.
    static func bars(session: Double?, weekly: Double?, appearance: NSAppearance) -> NSImage {
        let size = NSSize(width: 17, height: 16)
        let image = NSImage(size: size)
        image.lockFocus()
        appearance.performAsCurrentDrawingAppearance {
            let barHeight: CGFloat = 5
            let gap: CGFloat = 3
            let width = size.width
            var y = size.height - barHeight - 1 // top bar first
            for value in [session, weekly] {
                let trackRect = NSRect(x: 0, y: y, width: width, height: barHeight)
                let track = NSBezierPath(roundedRect: trackRect, xRadius: barHeight / 2, yRadius: barHeight / 2)
                NSColor.tertiaryLabelColor.setFill()
                track.fill()
                if let value, value > 0 {
                    let fillWidth = max(barHeight, width * CGFloat(min(1, value / 100)))
                    let fillRect = NSRect(x: 0, y: y, width: fillWidth, height: barHeight)
                    let fill = NSBezierPath(roundedRect: fillRect, xRadius: barHeight / 2, yRadius: barHeight / 2)
                    heatColor(value).setFill()
                    fill.fill()
                }
                y -= (barHeight + gap)
            }
        }
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}
