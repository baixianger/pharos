import SwiftUI

/// Procedural vector path generator rendering body geometry and eye expressions for Pharos avatars.
/// Ported from Grok Bot avatar geometry specification (THIRD_PARTY_NOTICES.md).
public struct PharosAvatarShape {

    // MARK: - 1. Body Shapes

    public static func path(for shape: AvatarShape, in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let x = rect.minX
        let y = rect.minY

        switch shape {
        case .blob:
            // Organic smooth rounded sphere / squircle
            let r = min(w, h) * 0.46
            let center = CGPoint(x: x + w * 0.5, y: y + h * 0.5)
            return Path { p in
                p.addArc(center: center, radius: r, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
            }

        case .square:
            let cr = min(w, h) * 0.28
            return Path { p in
                p.addRoundedRect(in: rect.insetBy(dx: w * 0.04, dy: h * 0.04), cornerSize: CGSize(width: cr, height: cr))
            }

        case .tablet:
            let cr = min(w, h) * 0.42
            return Path { p in
                p.addRoundedRect(in: rect.insetBy(dx: w * 0.10, dy: h * 0.02), cornerSize: CGSize(width: cr, height: cr))
            }

        case .hex:
            return Path { p in
                let cx = x + w * 0.5
                let cy = y + h * 0.5
                let r = min(w, h) * 0.46
                for i in 0..<6 {
                    let angle = Double(i) * Double.pi / 3.0 - Double.pi / 6.0
                    let pt = CGPoint(x: cx + r * CGFloat(cos(angle)), y: cy + r * CGFloat(sin(angle)))
                    if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
                p.closeSubpath()
            }

        case .cloud:
            return Path { p in
                let b = rect.insetBy(dx: w * 0.04, dy: h * 0.08)
                let cy = b.minY + b.height * 0.6
                // Base puffy cloud lobes
                let r1 = b.width * 0.22
                let r2 = b.width * 0.28
                let r3 = b.width * 0.22

                p.addArc(center: CGPoint(x: b.minX + r1 + b.width * 0.05, y: cy), radius: r1, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
                p.addArc(center: CGPoint(x: b.minX + b.width * 0.5, y: b.minY + r2 + b.height * 0.02), radius: r2, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
                p.addArc(center: CGPoint(x: b.maxX - r3 - b.width * 0.05, y: cy), radius: r3, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
            }

        case .sparkle:
            return Path { p in
                let cx = x + w * 0.5
                let cy = y + h * 0.5
                let r = min(w, h) * 0.46
                let inner = r * 0.26

                p.move(to: CGPoint(x: cx, y: cy - r))
                p.addQuadCurve(to: CGPoint(x: cx + r, y: cy), control: CGPoint(x: cx + inner, y: cy - inner))
                p.addQuadCurve(to: CGPoint(x: cx, y: cy + r), control: CGPoint(x: cx + inner, y: cy + inner))
                p.addQuadCurve(to: CGPoint(x: cx - r, y: cy), control: CGPoint(x: cx - inner, y: cy + inner))
                p.addQuadCurve(to: CGPoint(x: cx, y: cy - r), control: CGPoint(x: cx - inner, y: cy - inner))
                p.closeSubpath()
            }

        case .clover:
            return Path { p in
                let cx = x + w * 0.5
                let cy = y + h * 0.5
                let lobeR = min(w, h) * 0.23
                let d = min(w, h) * 0.19
                p.addArc(center: CGPoint(x: cx, y: cy - d), radius: lobeR, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
                p.addArc(center: CGPoint(x: cx + d, y: cy), radius: lobeR, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
                p.addArc(center: CGPoint(x: cx, y: cy + d), radius: lobeR, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
                p.addArc(center: CGPoint(x: cx - d, y: cy), radius: lobeR, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
            }

        case .heart:
            return Path { p in
                let cx = x + w * 0.5
                let topY = y + h * 0.28
                let botY = y + h * 0.88
                let r = min(w, h) * 0.24

                p.move(to: CGPoint(x: cx, y: topY + r * 0.4))
                // Left curve
                p.addCurve(
                    to: CGPoint(x: cx - r * 1.8, y: topY - r * 0.2),
                    control1: CGPoint(x: cx - r * 0.4, y: topY - r * 0.4),
                    control2: CGPoint(x: cx - r * 1.4, y: topY - r * 0.5)
                )
                // Left lobe to bottom
                p.addCurve(
                    to: CGPoint(x: cx, y: botY),
                    control1: CGPoint(x: cx - r * 2.0, y: topY + r * 1.2),
                    control2: CGPoint(x: cx - r * 0.6, y: botY - r * 0.4)
                )
                // Right lobe from bottom
                p.addCurve(
                    to: CGPoint(x: cx + r * 1.8, y: topY - r * 0.2),
                    control1: CGPoint(x: cx + r * 0.6, y: botY - r * 0.4),
                    control2: CGPoint(x: cx + r * 2.0, y: topY + r * 1.2)
                )
                // Right curve back to center top
                p.addCurve(
                    to: CGPoint(x: cx, y: topY + r * 0.4),
                    control1: CGPoint(x: cx + r * 1.4, y: topY - r * 0.5),
                    control2: CGPoint(x: cx + r * 0.4, y: topY - r * 0.4)
                )
                p.closeSubpath()
            }

        case .flower:
            return Path { p in
                let cx = x + w * 0.5
                let cy = y + h * 0.5
                let r = min(w, h) * 0.17
                let d = min(w, h) * 0.24
                let petals = 6
                for i in 0..<petals {
                    let angle = Double(i) * Double.pi * 2.0 / Double(petals)
                    let px = cx + d * CGFloat(cos(angle))
                    let py = cy + d * CGFloat(sin(angle))
                    p.addArc(center: CGPoint(x: px, y: py), radius: r, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
                }
                p.addArc(center: CGPoint(x: cx, y: cy), radius: r * 1.1, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
            }

        case .teardrop:
            return Path { p in
                let cx = x + w * 0.5
                let r = min(w, h) * 0.38
                let cy = y + h * 0.58

                p.move(to: CGPoint(x: cx, y: y + h * 0.12))
                p.addQuadCurve(to: CGPoint(x: cx + r, y: cy), control: CGPoint(x: cx + r * 0.9, y: y + h * 0.32))
                p.addArc(center: CGPoint(x: cx, y: cy), radius: r, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
                p.addQuadCurve(to: CGPoint(x: cx, y: y + h * 0.12), control: CGPoint(x: cx - r * 0.9, y: y + h * 0.32))
                p.closeSubpath()
            }

        case .wedge:
            return Path { p in
                let cx = x + w * 0.5
                let topW = w * 0.56
                let botW = w * 0.88
                let cr = min(w, h) * 0.14

                p.move(to: CGPoint(x: cx - topW * 0.5 + cr, y: y + h * 0.12))
                p.addLine(to: CGPoint(x: cx + topW * 0.5 - cr, y: y + h * 0.12))
                p.addQuadCurve(to: CGPoint(x: cx + topW * 0.5, y: y + h * 0.12 + cr), control: CGPoint(x: cx + topW * 0.5, y: y + h * 0.12))
                p.addLine(to: CGPoint(x: cx + botW * 0.5, y: y + h * 0.88 - cr))
                p.addQuadCurve(to: CGPoint(x: cx + botW * 0.5 - cr, y: y + h * 0.88), control: CGPoint(x: cx + botW * 0.5, y: y + h * 0.88))
                p.addLine(to: CGPoint(x: cx - botW * 0.5 + cr, y: y + h * 0.88))
                p.addQuadCurve(to: CGPoint(x: cx - botW * 0.5, y: y + h * 0.88 - cr), control: CGPoint(x: cx - botW * 0.5, y: y + h * 0.88))
                p.addLine(to: CGPoint(x: cx - topW * 0.5, y: y + h * 0.12 + cr))
                p.addQuadCurve(to: CGPoint(x: cx - topW * 0.5 + cr, y: y + h * 0.12), control: CGPoint(x: cx - topW * 0.5, y: y + h * 0.12))
                p.closeSubpath()
            }

        case .house:
            return Path { p in
                let cx = x + w * 0.5
                let topY = y + h * 0.10
                let eavesY = y + h * 0.44
                let botY = y + h * 0.88
                let leftX = x + w * 0.16
                let rightX = x + w * 0.84
                let cr = min(w, h) * 0.12

                p.move(to: CGPoint(x: cx, y: topY))
                p.addLine(to: CGPoint(x: rightX, y: eavesY))
                p.addLine(to: CGPoint(x: rightX, y: botY - cr))
                p.addQuadCurve(to: CGPoint(x: rightX - cr, y: botY), control: CGPoint(x: rightX, y: botY))
                p.addLine(to: CGPoint(x: leftX + cr, y: botY))
                p.addQuadCurve(to: CGPoint(x: leftX, y: botY - cr), control: CGPoint(x: leftX, y: botY))
                p.addLine(to: CGPoint(x: leftX, y: eavesY))
                p.closeSubpath()
            }

        case .star:
            return Path { p in
                let cx = x + w * 0.5
                let cy = y + h * 0.52
                let rOut = min(w, h) * 0.46
                let rIn = rOut * 0.48
                let points = 6
                for i in 0..<(points * 2) {
                    let r = (i % 2 == 0) ? rOut : rIn
                    let angle = Double(i) * Double.pi / Double(points) - Double.pi / 2.0
                    let pt = CGPoint(x: cx + r * CGFloat(cos(angle)), y: cy + r * CGFloat(sin(angle)))
                    if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
                p.closeSubpath()
            }
        }
    }

    // MARK: - 2. Eye Expression Paths (Closed Geometry Without Distortion)

    public static func eyePaths(for expression: AvatarExpression, in rect: CGRect, blinkProgress: CGFloat = 0.0) -> Path {
        let w = rect.width
        let h = rect.height
        let x = rect.minX
        let y = rect.minY

        let leftCenterX = x + w * 0.40
        let rightCenterX = x + w * 0.60
        let centerY = y + h * 0.48

        // Effective eye height scales down during blink
        let scaleY = max(0.06, 1.0 - blinkProgress)
        let eyeW = w * 0.08
        let eyeH = h * 0.18 * scaleY
        let strokeWidth = max(2.0, w * 0.042)

        switch expression {
        case .neutral, .calm:
            // Symmetrical smooth rounded vertical capsules
            return Path { p in
                let leftRect = CGRect(x: leftCenterX - eyeW * 0.5, y: centerY - eyeH * 0.5, width: eyeW, height: eyeH)
                let rightRect = CGRect(x: rightCenterX - eyeW * 0.5, y: centerY - eyeH * 0.5, width: eyeW, height: eyeH)
                let cr = eyeW * 0.5
                p.addRoundedRect(in: leftRect, cornerSize: CGSize(width: cr, height: cr))
                p.addRoundedRect(in: rightRect, cornerSize: CGSize(width: cr, height: cr))
            }

        case .happy:
            // Upward smiling arcs rendered as stroked round bands
            let rawPath = Path { p in
                let arcW = w * 0.11
                let dip = h * 0.05 * scaleY
                p.move(to: CGPoint(x: leftCenterX - arcW * 0.5, y: centerY + dip * 0.4))
                p.addQuadCurve(
                    to: CGPoint(x: leftCenterX + arcW * 0.5, y: centerY + dip * 0.4),
                    control: CGPoint(x: leftCenterX, y: centerY - dip)
                )
                p.move(to: CGPoint(x: rightCenterX - arcW * 0.5, y: centerY + dip * 0.4))
                p.addQuadCurve(
                    to: CGPoint(x: rightCenterX + arcW * 0.5, y: centerY + dip * 0.4),
                    control: CGPoint(x: rightCenterX, y: centerY - dip)
                )
            }
            return rawPath.strokedPath(StrokeStyle(lineWidth: strokeWidth, lineCap: .round))

        case .surprised:
            // Wide open rounded circles/ovals
            return Path { p in
                let rW = eyeW * 1.3
                let rH = eyeH * 1.1
                let leftRect = CGRect(x: leftCenterX - rW * 0.5, y: centerY - rH * 0.5, width: rW, height: rH)
                let rightRect = CGRect(x: rightCenterX - rW * 0.5, y: centerY - rH * 0.5, width: rW, height: rH)
                p.addEllipse(in: leftRect)
                p.addEllipse(in: rightRect)
            }

        case .sad:
            // Downward droop arcs rendered as stroked round bands
            let rawPath = Path { p in
                let arcW = w * 0.11
                let droop = h * 0.05 * scaleY
                p.move(to: CGPoint(x: leftCenterX - arcW * 0.5, y: centerY - droop * 0.3))
                p.addQuadCurve(
                    to: CGPoint(x: leftCenterX + arcW * 0.5, y: centerY - droop * 0.3),
                    control: CGPoint(x: leftCenterX, y: centerY + droop)
                )
                p.move(to: CGPoint(x: rightCenterX - arcW * 0.5, y: centerY - droop * 0.3))
                p.addQuadCurve(
                    to: CGPoint(x: rightCenterX + arcW * 0.5, y: centerY - droop * 0.3),
                    control: CGPoint(x: rightCenterX, y: centerY + droop)
                )
            }
            return rawPath.strokedPath(StrokeStyle(lineWidth: strokeWidth, lineCap: .round))

        case .sleepy:
            // Gentle resting horizontal slits
            let rawPath = Path { p in
                let slitW = w * 0.10
                p.move(to: CGPoint(x: leftCenterX - slitW * 0.5, y: centerY))
                p.addLine(to: CGPoint(x: leftCenterX + slitW * 0.5, y: centerY))
                p.move(to: CGPoint(x: rightCenterX - slitW * 0.5, y: centerY))
                p.addLine(to: CGPoint(x: rightCenterX + slitW * 0.5, y: centerY))
            }
            return rawPath.strokedPath(StrokeStyle(lineWidth: strokeWidth, lineCap: .round))

        case .squinted:
            // Narrow horizontal capsules
            return Path { p in
                let sw = w * 0.10
                let sh = max(3.0, eyeW * 0.45 * scaleY)
                let leftRect = CGRect(x: leftCenterX - sw * 0.5, y: centerY - sh * 0.5, width: sw, height: sh)
                let rightRect = CGRect(x: rightCenterX - sw * 0.5, y: centerY - sh * 0.5, width: sw, height: sh)
                p.addRoundedRect(in: leftRect, cornerSize: CGSize(width: sh * 0.5, height: sh * 0.5))
                p.addRoundedRect(in: rightRect, cornerSize: CGSize(width: sh * 0.5, height: sh * 0.5))
            }

        case .inspecting:
            // Asymmetric eyes: one curious, one attentive
            return Path { p in
                let leftH = eyeH * 1.2
                let leftW = eyeW * 1.2
                let rightH = eyeH * 0.75
                let rightW = eyeW * 0.75

                let leftRect = CGRect(x: leftCenterX - leftW * 0.5, y: centerY - leftH * 0.5, width: leftW, height: leftH)
                let rightRect = CGRect(x: rightCenterX - rightW * 0.5, y: centerY - rightH * 0.5, width: rightW, height: rightH)

                p.addRoundedRect(in: leftRect, cornerSize: CGSize(width: leftW * 0.5, height: leftW * 0.5))
                p.addRoundedRect(in: rightRect, cornerSize: CGSize(width: rightW * 0.5, height: rightW * 0.5))
            }

        case .confused:
            // Asymmetric tilt eyes
            let rawPath = Path { p in
                let arcW = w * 0.10
                p.move(to: CGPoint(x: leftCenterX - arcW * 0.5, y: centerY + h * 0.02))
                p.addLine(to: CGPoint(x: leftCenterX + arcW * 0.5, y: centerY - h * 0.02))
                p.move(to: CGPoint(x: rightCenterX - arcW * 0.5, y: centerY - h * 0.02))
                p.addLine(to: CGPoint(x: rightCenterX + arcW * 0.5, y: centerY + h * 0.02))
            }
            return rawPath.strokedPath(StrokeStyle(lineWidth: strokeWidth, lineCap: .round))
        }
    }
}
