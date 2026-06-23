import AppKit

/// A filled monochrome lighthouse for the macOS menu bar — Pharos means
/// *lighthouse*, and SF Symbols has none. Drawn (not an asset) as a template
/// image so it adapts to light/dark and selection like an SF symbol. Solid glyph
/// with the window + tower stripes punched out (transparent).
enum LighthouseIcon {
    static let menuBar: NSImage = make(size: 18)

    static func make(size: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let s = rect.width
            // Design in a 24×24 box (y-up), then scale.
            func p(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x / 24 * s, y: y / 24 * s) }
            func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
                NSRect(x: x / 24 * s, y: y / 24 * s, width: w / 24 * s, height: h / 24 * s)
            }
            func wedge(_ pts: [(CGFloat, CGFloat)]) -> NSBezierPath {
                let path = NSBezierPath(); path.move(to: p(pts[0].0, pts[0].1))
                for q in pts.dropFirst() { path.line(to: p(q.0, q.1)) }
                path.close(); return path
            }

            NSColor.black.setFill()

            // Base — wide rounded bar.
            NSBezierPath(roundedRect: r(3.4, 1.8, 17.2, 2.5), xRadius: 1.2 / 24 * s, yRadius: 1.2 / 24 * s).fill()
            // Tower — trapezoid (wide base → narrow gallery).
            wedge([(6.0, 4.0), (7.9, 15.6), (16.1, 15.6), (18.0, 4.0)]).fill()
            // Lantern room.
            NSBezierPath(rect: r(8.0, 15.6, 8.0, 3.9)).fill()
            // Roof.
            wedge([(6.9, 19.5), (12.0, 22.4), (17.1, 19.5)]).fill()
            // Light beams (bow-tie wedges, wider at the outer edge).
            wedge([(6.6, 19.0), (2.6, 20.1), (2.6, 15.9), (6.6, 17.0)]).fill()
            wedge([(17.4, 19.0), (21.4, 20.1), (21.4, 15.9), (17.4, 17.0)]).fill()

            // Punch holes (transparent): the window + three tower stripes.
            NSGraphicsContext.current?.compositingOperation = .clear
            NSBezierPath(rect: r(10.1, 16.4, 3.8, 2.6)).fill()        // window
            for y in [6.3, 9.5, 12.7] {
                NSBezierPath(rect: r(3.0, y, 18.0, 1.0)).fill()       // stripe (clips to tower)
            }
            NSGraphicsContext.current?.compositingOperation = .sourceOver
            return true
        }
        img.isTemplate = true
        return img
    }
}
