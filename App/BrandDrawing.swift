import AppKit

/// Window and menu bar artwork shared by the app and its asset generator.
enum QbarBrand {
    static let appImage = NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { bounds in
        drawAppIcon(in: bounds)
        return true
    }

    static let menuImage: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.setStroke()
            let frame = NSBezierPath(roundedRect: NSRect(x: 1.5, y: 3, width: 15, height: 12), xRadius: 2.5, yRadius: 2.5)
            frame.lineWidth = 1.5
            frame.stroke()
            let divider = NSBezierPath()
            divider.move(to: NSPoint(x: 2, y: 10.5))
            divider.line(to: NSPoint(x: 16, y: 10.5))
            divider.lineWidth = 1.3
            divider.stroke()
            NSColor.black.setFill()
            for x in [9.0, 11.5, 14.0] {
                NSBezierPath(ovalIn: NSRect(x: x, y: 12, width: 1.2, height: 1.2)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Qbar"
        return image
    }()

    static func drawAppIcon(in bounds: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let transform = NSAffineTransform()
        transform.translateX(by: bounds.minX, yBy: bounds.minY)
        transform.scaleX(by: bounds.width / 1024, yBy: bounds.height / 1024)
        transform.concat()

        // Two short status bars express Qbar's overflow area. Keep the app
        // artwork separate from the actual menu bar glyph above.
        let tile = NSBezierPath(roundedRect: NSRect(x: 64, y: 64, width: 896, height: 896), xRadius: 202, yRadius: 202)
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor(calibratedRed: 0.07, green: 0.05, blue: 0.20, alpha: 0.35)
        shadow.shadowBlurRadius = 32
        shadow.shadowOffset = NSSize(width: 0, height: -16)
        shadow.set()
        NSColor(calibratedRed: 0.21, green: 0.17, blue: 0.46, alpha: 1).setFill()
        tile.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(colorsAndLocations:
            (NSColor(calibratedRed: 0.16, green: 0.14, blue: 0.35, alpha: 1), 0),
            (NSColor(calibratedRed: 0.28, green: 0.25, blue: 0.57, alpha: 1), 0.62),
            (NSColor(calibratedRed: 0.43, green: 0.38, blue: 0.73, alpha: 1), 1))!
            .draw(in: tile, angle: 62)

        // A clipped glow gives the tile depth without resembling a browser
        // window or the user's actual menu bar status item.
        NSGraphicsContext.saveGraphicsState()
        tile.addClip()
        let glow = NSBezierPath(ovalIn: NSRect(x: -260, y: 570, width: 900, height: 700))
        NSGradient(starting: NSColor(calibratedRed: 0.49, green: 0.85, blue: 0.83, alpha: 0.19),
                   ending: NSColor(calibratedRed: 0.49, green: 0.85, blue: 0.83, alpha: 0))!
            .draw(in: glow, relativeCenterPosition: NSPoint(x: -0.45, y: 0.36))
        NSGraphicsContext.restoreGraphicsState()

        NSColor.white.withAlphaComponent(0.18).setStroke()
        tile.lineWidth = 3.5
        tile.stroke()

        let upper = NSBezierPath(roundedRect: NSRect(x: 162, y: 562, width: 700, height: 166), xRadius: 83, yRadius: 83)
        NSGraphicsContext.saveGraphicsState()
        let upperShadow = NSShadow()
        upperShadow.shadowColor = NSColor.black.withAlphaComponent(0.24)
        upperShadow.shadowBlurRadius = 28
        upperShadow.shadowOffset = NSSize(width: 0, height: -16)
        upperShadow.set()
        NSColor(calibratedRed: 0.98, green: 0.98, blue: 1, alpha: 1).setFill()
        upper.fill()
        NSGraphicsContext.restoreGraphicsState()

        // Menu items retained on the original bar.
        NSColor(calibratedRed: 0.33, green: 0.30, blue: 0.53, alpha: 1).setFill()
        for x in [226.0, 320.0, 414.0] {
            NSBezierPath(ovalIn: NSRect(x: x, y: 625, width: 40, height: 40)).fill()
        }
        NSColor(calibratedRed: 0.42, green: 0.39, blue: 0.63, alpha: 0.23).setFill()
        NSBezierPath(roundedRect: NSRect(x: 528, y: 610, width: 258, height: 70), xRadius: 35, yRadius: 35).fill()

        let overflow = NSBezierPath(roundedRect: NSRect(x: 224, y: 296, width: 640, height: 190), xRadius: 95, yRadius: 95)
        NSGraphicsContext.saveGraphicsState()
        let overflowShadow = NSShadow()
        overflowShadow.shadowColor = NSColor(calibratedRed: 0.04, green: 0.08, blue: 0.17, alpha: 0.38)
        overflowShadow.shadowBlurRadius = 34
        overflowShadow.shadowOffset = NSSize(width: 0, height: -20)
        overflowShadow.set()
        NSColor(calibratedRed: 0.39, green: 0.85, blue: 0.72, alpha: 1).setFill()
        overflow.fill()
        NSGraphicsContext.restoreGraphicsState()
        NSGradient(colorsAndLocations:
            (NSColor(calibratedRed: 0.35, green: 0.78, blue: 0.76, alpha: 1), 0),
            (NSColor(calibratedRed: 0.62, green: 0.97, blue: 0.73, alpha: 1), 1))!
            .draw(in: overflow, angle: 18)
        NSColor.white.withAlphaComponent(0.43).setStroke()
        overflow.lineWidth = 3
        overflow.stroke()

        // Larger items on the expanded track remain readable at 16 pt.
        NSColor(calibratedRed: 0.13, green: 0.24, blue: 0.38, alpha: 0.89).setFill()
        for x in [294.0, 414.0, 534.0, 654.0, 774.0] {
            NSBezierPath(ovalIn: NSRect(x: x, y: 361, width: 58, height: 58)).fill()
        }
        NSColor.white.withAlphaComponent(0.54).setFill()
        NSBezierPath(roundedRect: NSRect(x: 286, y: 441, width: 510, height: 6), xRadius: 3, yRadius: 3).fill()
    }
}
