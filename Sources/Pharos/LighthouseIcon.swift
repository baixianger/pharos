import AppKit

/// A monoline lighthouse drawn to live in the macOS menu bar beside SF Symbols —
/// Pharos means *lighthouse*, and SF Symbols has no lighthouse. Rendered as a
/// template image so it adapts to light/dark and selection automatically.
enum LighthouseIcon {
    static let menuBar: NSImage = make(size: 18, lineWidth: 1.5)

    static func make(size: CGFloat, lineWidth: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let s = rect.width
            // Design in a 22×22 box (y-up), then scale to the requested size.
            func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x / 22 * s, y: y / 22 * s) }

            let path = NSBezierPath()
            path.lineWidth = lineWidth
            path.lineCapStyle = .round
            path.lineJoinStyle = .round

            // Tower — wider at the base, narrowing toward the gallery.
            path.move(to: p(6.6, 2.6));  path.line(to: p(8.8, 13.4))
            path.move(to: p(15.4, 2.6)); path.line(to: p(13.2, 13.4))
            path.move(to: p(6.0, 2.6));  path.line(to: p(16.0, 2.6))   // base
            path.move(to: p(7.7, 8.0));  path.line(to: p(14.3, 8.0))   // band
            path.move(to: p(8.0, 13.4)); path.line(to: p(14.0, 13.4))  // gallery platform

            // Lantern room.
            path.move(to: p(9.1, 13.4))
            path.line(to: p(9.1, 16.6))
            path.line(to: p(12.9, 16.6))
            path.line(to: p(12.9, 13.4))

            // Roof.
            path.move(to: p(8.5, 16.6)); path.line(to: p(11.0, 19.4)); path.line(to: p(13.5, 16.6))

            // Light beams.
            path.move(to: p(8.7, 15.0)); path.line(to: p(6.1, 16.0))
            path.move(to: p(13.3, 15.0)); path.line(to: p(15.9, 16.0))

            NSColor.black.setStroke()
            path.stroke()
            return true
        }
        img.isTemplate = true
        return img
    }
}
