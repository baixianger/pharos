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
            // Organic smooth rounded sphere/squircle
            return Path { p in
                let r = min(w, h) * 0.48
                let center = CGPoint(x: x + w * 0.5, y: y + h * 0.5)
                p.addArc(center: center, radius: r, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
            }

        case .square:
            return Path { p in
                let cr = min(w, h) * 0.24
                p.addRoundedRect(in: rect, cornerSize: CGSize(width: cr, height: cr))
            }

        case .tablet:
            return Path { p in
                let cr = min(w, h) * 0.4
                p.addRoundedRect(in: rect.insetBy(dx: w * 0.08, dy: 0), cornerSize: CGSize(width: cr, height: cr))
            }

        case .hex:
            return Path { p in
                let cx = x + w * 0.5
                let cy = y + h * 0.5
                let r = min(w, h) * 0.48
                for i in 0..<6 {
                    let angle = Double(i) * Double.pi / 3.0 - Double.pi / 6.0
                    let pt = CGPoint(x: cx + r * CGFloat(cos(angle)), y: cy + r * CGFloat(sin(angle)))
                    if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
                p.closeSubpath()
            }

        case .cloud:
            return Path { p in
                let b = rect.insetBy(dx: w * 0.05, dy: h * 0.1)
                p.move(to: CGPoint(x: b.minX + b.width * 0.2, y: b.maxY - b.height * 0.2))
                // Bottom left to top left lobe
                p.addQuadCurve(to: CGPoint(x: b.minX + b.width * 0.35, y: b.minY + b.height * 0.25),
                               control: CGPoint(x: b.minX, y: b.minY + b.height * 0.4))
                // Top center lobe
                p.addQuadCurve(to: CGPoint(x: b.minX + b.width * 0.7, y: b.minY + b.height * 0.2),
                               control: CGPoint(x: b.minX + b.width * 0.5, y: b.minY))
                // Top right lobe
                p.addQuadCurve(to: CGPoint(x: b.maxX, y: b.maxY - b.height * 0.3),
                               control: CGPoint(x: b.maxX, y: b.minY + b.height * 0.35))
                // Bottom base curve
                p.addQuadCurve(to: CGPoint(x: b.minX + b.width * 0.2, y: b.maxY - b.height * 0.2),
                               control: CGPoint(x: b.minX + b.width * 0.5, y: b.maxY))
                p.closeSubpath()
            }

        case .sparkle:
            return Path { p in
                let cx = x + w * 0.5
                let cy = y + h * 0.5
                let r = min(w, h) * 0.48
                let inner = r * 0.24

                // Top tip
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
                let lobeR = min(w, h) * 0.24
                let d = min(w, h) * 0.2
                // 4 lobes
                p.addArc(center: CGPoint(x: cx, y: cy - d), radius: lobeR, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
                p.addArc(center: CGPoint(x: cx + d, y: cy), radius: lobeR, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
                p.addArc(center: CGPoint(x: cx, y: cy + d), radius: lobeR, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
                p.addArc(center: CGPoint(x: cx - d, y: cy), radius: lobeR, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
            }

        case .heart:
            return Path { p in
                let cx = x + w * 0.5
                let topY = y + h * 0.28
                let bottomY = y + h * 0.92
                p.move(to: CGPoint(x: cx, y: bottomY))
                p.addCurve(to: CGPoint(x: x + w * 0.08, y: topY),
                           control1: CGPoint(x: x + w * 0.25, y: y + h * 0.7),
                           control2: CGPoint(x: x + w * 0.05, y: y + h * 0.45))
                p.addArc(center: CGPoint(x: x + w * 0.28, y: topY), radius: w * 0.2, startAngle: .degrees(180), endAngle: .zero, clockwise: false)
                p.addArc(center: CGPoint(x: x + w * 0.72, y: topY), radius: w * 0.2, startAngle: .degrees(180), endAngle: .zero, clockwise: false)
                p.addCurve(to: CGPoint(x: cx, y: bottomY),
                           control1: CGPoint(x: x + w * 0.95, y: y + h * 0.45),
                           control2: CGPoint(x: x + w * 0.75, y: y + h * 0.7))
                p.closeSubpath()
            }

        case .flower:
            return Path { p in
                let cx = x + w * 0.5
                let cy = y + h * 0.5
                let count = 6
                let petalR = min(w, h) * 0.18
                let dist = min(w, h) * 0.26
                for i in 0..<count {
                    let angle = Double(i) * Double.pi * 2.0 / Double(count)
                    let px = cx + dist * CGFloat(cos(angle))
                    let py = cy + dist * CGFloat(sin(angle))
                    p.addArc(center: CGPoint(x: px, y: py), radius: petalR, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
                }
                p.addArc(center: CGPoint(x: cx, y: cy), radius: min(w, h) * 0.2, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
            }

        case .teardrop:
            return Path { p in
                let cx = x + w * 0.5
                let topY = y + h * 0.08
                let botY = y + h * 0.62
                let r = min(w, h) * 0.38
                p.move(to: CGPoint(x: cx, y: topY))
                p.addQuadCurve(to: CGPoint(x: cx + r, y: botY), control: CGPoint(x: cx + r * 0.9, y: topY + h * 0.3))
                p.addArc(center: CGPoint(x: cx, y: botY), radius: r, startAngle: .zero, endAngle: .degrees(180), clockwise: false)
                p.addQuadCurve(to: CGPoint(x: cx, y: topY), control: CGPoint(x: cx - r * 0.9, y: topY + h * 0.3))
                p.closeSubpath()
            }

        case .wedge:
            return Path { p in
                let topW = w * 0.55
                let botW = w * 0.88
                let cx = x + w * 0.5
                let cr = min(w, h) * 0.16
                p.move(to: CGPoint(x: cx - topW * 0.5 + cr, y: y + h * 0.1))
                p.addLine(to: CGPoint(x: cx + topW * 0.5 - cr, y: y + h * 0.1))
                p.addQuadCurve(to: CGPoint(x: cx + topW * 0.5, y: y + h * 0.1 + cr), control: CGPoint(x: cx + topW * 0.5, y: y + h * 0.1))
                p.addLine(to: CGPoint(x: cx + botW * 0.5, y: y + h * 0.9 - cr))
                p.addQuadCurve(to: CGPoint(x: cx + botW * 0.5 - cr, y: y + h * 0.9), control: CGPoint(x: cx + botW * 0.5, y: y + h * 0.9))
                p.addLine(to: CGPoint(x: cx - botW * 0.5 + cr, y: y + h * 0.9))
                p.addQuadCurve(to: CGPoint(x: cx - botW * 0.5, y: y + h * 0.9 - cr), control: CGPoint(x: cx - botW * 0.5, y: y + h * 0.9))
                p.addLine(to: CGPoint(x: cx - topW * 0.5, y: y + h * 0.1 + cr))
                p.addQuadCurve(to: CGPoint(x: cx - topW * 0.5 + cr, y: y + h * 0.1), control: CGPoint(x: cx - topW * 0.5, y: y + h * 0.1))
                p.closeSubpath()
            }

        case .house:
            return Path { p in
                let cx = x + w * 0.5
                let topY = y + h * 0.08
                let eavesY = y + h * 0.42
                let botY = y + h * 0.9
                let leftX = x + w * 0.14
                let rightX = x + w * 0.86
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
                let cy = y + h * 0.54
                let rOut = min(w, h) * 0.48
                let rIn = rOut * 0.45
                let points = 5
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

    // MARK: - 2. Eye Expression Paths

    public static func eyePaths(for expression: AvatarExpression, in rect: CGRect, blinkProgress: CGFloat = 0.0) -> Path {
        let w = rect.width
        let h = rect.height
        let x = rect.minX
        let y = rect.minY

        let leftCenterX = x + w * 0.38
        let rightCenterX = x + w * 0.62
        let centerY = y + h * 0.48

        // Effective eye height scales down during blink
        let scaleY = max(0.08, 1.0 - blinkProgress)
        let eyeW = w * 0.085
        let eyeH = h * 0.16 * scaleY

        return Path { p in
            switch expression {
            case .neutral, .calm:
                // Symmetrical smooth rounded capsules
                let leftRect = CGRect(x: leftCenterX - eyeW * 0.5, y: centerY - eyeH * 0.5, width: eyeW, height: eyeH)
                let rightRect = CGRect(x: rightCenterX - eyeW * 0.5, y: centerY - eyeH * 0.5, width: eyeW, height: eyeH)
                p.addRoundedRect(in: leftRect, cornerSize: CGSize(width: eyeW * 0.5, height: eyeW * 0.5))
                p.addRoundedRect(in: rightRect, cornerSize: CGSize(width: eyeW * 0.5, height: eyeW * 0.5))

            case .happy:
                // Upward smiling arcs
                let arcW = w * 0.11
                p.move(to: CGPoint(x: leftCenterX - arcW * 0.5, y: centerY + eyeH * 0.2))
                p.addQuadCurve(to: CGPoint(x: leftCenterX + arcW * 0.5, y: centerY + eyeH * 0.2),
                               control: CGPoint(x: leftCenterX, y: centerY - eyeH * 0.6))
                p.move(to: CGPoint(x: rightCenterX - arcW * 0.5, y: centerY + eyeH * 0.2))
                p.addQuadCurve(to: CGPoint(x: rightCenterX + arcW * 0.5, y: centerY + eyeH * 0.2),
                               control: CGPoint(x: rightCenterX, y: centerY - eyeH * 0.6))

            case .surprised:
                // Wide open circles
                let r = min(eyeW, eyeH) * 0.95
                p.addArc(center: CGPoint(x: leftCenterX, y: centerY), radius: r, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
                p.addArc(center: CGPoint(x: rightCenterX, y: centerY), radius: r, startAngle: .zero, endAngle: .degrees(360), clockwise: false)

            case .sad:
                // Downward droop arcs
                let arcW = w * 0.11
                p.move(to: CGPoint(x: leftCenterX - arcW * 0.5, y: centerY - eyeH * 0.2))
                p.addQuadCurve(to: CGPoint(x: leftCenterX + arcW * 0.5, y: centerY - eyeH * 0.2),
                               control: CGPoint(x: leftCenterX, y: centerY + eyeH * 0.6))
                p.move(to: CGPoint(x: rightCenterX - arcW * 0.5, y: centerY - eyeH * 0.2))
                p.addQuadCurve(to: CGPoint(x: rightCenterX + arcW * 0.5, y: centerY - eyeH * 0.2),
                               control: CGPoint(x: rightCenterX, y: centerY + eyeH * 0.6))

            case .sleepy, .squinted:
                // Horizontal slits
                let slitH = max(2.0, h * 0.03)
                let leftRect = CGRect(x: leftCenterX - eyeW * 0.7, y: centerY - slitH * 0.5, width: eyeW * 1.4, height: slitH)
                let rightRect = CGRect(x: rightCenterX - eyeW * 0.7, y: centerY - slitH * 0.5, width: eyeW * 1.4, height: slitH)
                p.addRoundedRect(in: leftRect, cornerSize: CGSize(width: 1, height: 1))
                p.addRoundedRect(in: rightRect, cornerSize: CGSize(width: 1, height: 1))

            case .inspecting:
                // Asymmetric eyes: left eye large and wide, right eye narrow/squinted
                let leftR = min(eyeW, eyeH) * 1.05
                p.addArc(center: CGPoint(x: leftCenterX, y: centerY), radius: leftR, startAngle: .zero, endAngle: .degrees(360), clockwise: false)
                let rightH = max(2.5, eyeH * 0.35)
                let rightRect = CGRect(x: rightCenterX - eyeW * 0.5, y: centerY - rightH * 0.5, width: eyeW, height: rightH)
                p.addRoundedRect(in: rightRect, cornerSize: CGSize(width: rightH * 0.5, height: rightH * 0.5))

            case .confused:
                // One eye higher and tilted
                let leftRect = CGRect(x: leftCenterX - eyeW * 0.5, y: centerY - eyeH * 0.7, width: eyeW, height: eyeH * 0.8)
                let rightRect = CGRect(x: rightCenterX - eyeW * 0.5, y: centerY - eyeH * 0.2, width: eyeW, height: eyeH)
                p.addRoundedRect(in: leftRect, cornerSize: CGSize(width: eyeW * 0.5, height: eyeW * 0.5))
                p.addRoundedRect(in: rightRect, cornerSize: CGSize(width: eyeW * 0.5, height: eyeW * 0.5))
            }
        }
    }
}
