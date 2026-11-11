import SwiftUI
import PharosClientKit

/// Highly responsive procedural vector avatar view rendered via native SwiftUI `Canvas`.
/// Provides deterministic shape and color generation, dynamic state rings, and eye animations.
/// Ported from Grok Bot avatar kernel & palette (THIRD_PARTY_NOTICES.md).
public struct PharosAvatarView: View {
    public let seed: String
    public let customShape: AvatarShape?
    public let customColor: AvatarPaletteColor?
    public let status: AvatarActivityStatus
    public let size: CGFloat
    public let showRing: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        seed: String,
        customShape: AvatarShape? = nil,
        customColor: AvatarPaletteColor? = nil,
        status: AvatarActivityStatus = .idle,
        size: CGFloat = 36,
        showRing: Bool = true
    ) {
        self.seed = seed
        self.customShape = customShape
        self.customColor = customColor
        self.status = status
        self.size = size
        self.showRing = showRing
    }

    private var isDark: Bool {
        colorScheme == .dark
    }

    private var numericSeed: UInt64 {
        AvatarParameters.computeSeed(seed)
    }

    public var effectiveShape: AvatarShape {
        customShape ?? AvatarParameters.shape(for: numericSeed)
    }

    public var effectiveColor: AvatarPaletteColor {
        customColor ?? AvatarParameters.color(for: numericSeed)
    }

    public var effectiveExpression: AvatarExpression {
        status.defaultExpression
    }

    public var body: some View {
        ZStack {
            // Dynamic State Ring (outer ring)
            if showRing {
                stateRing
            }

            // Procedural Canvas Body & Eyes
            if status == .working && !reduceMotion {
                // Animated Timeline rendering for active/working avatar
                TimelineView(.animation) { timeline in
                    let time = timeline.date.timeIntervalSinceReferenceDate
                    let blink = computeBlink(time: time)
                    avatarCanvas(blinkProgress: blink)
                }
            } else {
                // Static high-performance Canvas for idle / stopped states
                avatarCanvas(blinkProgress: 0.0)
            }
        }
        .frame(width: size, height: size)
    }

    // MARK: - Canvas Drawing

    private func avatarCanvas(blinkProgress: CGFloat) -> some View {
        Canvas { context, canvasSize in
            let inset: CGFloat = showRing ? 3.0 : 1.0
            let bodyRect = CGRect(origin: .zero, size: canvasSize).insetBy(dx: inset, dy: inset)

            // 1. Draw Body Shape
            let bodyPath = PharosAvatarShape.path(for: effectiveShape, in: bodyRect)
            let fillColor = effectiveColor.color(isDark: isDark)
            let fillGrad = effectiveColor.gradient(isDark: isDark)

            if status == .stopped {
                context.fill(bodyPath, with: .color(fillColor.opacity(0.35)))
            } else {
                context.fill(bodyPath, with: .linearGradient(
                    fillGrad,
                    startPoint: CGPoint(x: bodyRect.minX, y: bodyRect.minY),
                    endPoint: CGPoint(x: bodyRect.maxX, y: bodyRect.maxY)
                ))
            }

            // 2. Draw Eyes
            let eyePath = PharosAvatarShape.eyePaths(
                for: effectiveExpression,
                in: bodyRect,
                blinkProgress: blinkProgress
            )
            // Cutout eye color (contrasting dark/light cutout)
            let eyeColor = isDark ? Color.black.opacity(0.85) : Color.white.opacity(0.92)
            context.fill(eyePath, with: .color(eyeColor))
        }
    }

    // MARK: - State Ring

    @ViewBuilder
    private var stateRing: some View {
        switch status {
        case .idle:
            Circle()
                .stroke(Color.primary.opacity(0.12), lineWidth: 1.5)

        case .working:
            if reduceMotion {
                Circle()
                    .stroke(effectiveColor.color(isDark: isDark), lineWidth: 2)
            } else {
                TimelineView(.animation) { timeline in
                    let angle = Angle.degrees(timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.0) * 180.0)
                    Circle()
                        .strokeBorder(
                            AngularGradient(
                                colors: [
                                    effectiveColor.color(isDark: isDark),
                                    effectiveColor.color(isDark: isDark).opacity(0.1),
                                    effectiveColor.color(isDark: isDark)
                                ],
                                center: .center
                            ),
                            lineWidth: 2.0
                        )
                        .rotationEffect(angle)
                }
            }

        case .needsHuman:
            // Prominent pulsing attention ring
            Circle()
                .stroke(Color(hex: "#FF6700"), lineWidth: 2.5)
                .shadow(color: Color(hex: "#FF6700").opacity(0.5), radius: 3)

        case .stopped:
            Circle()
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1.5)
        }
    }

    // MARK: - Blink State Machine Helper

    private func computeBlink(time: TimeInterval) -> CGFloat {
        // Deterministic phase offset per avatar so multiple avatars don't blink in unison
        let offset = Double(numericSeed % 7)
        let period: Double = 4.2
        let cycle = (time + offset).truncatingRemainder(dividingBy: period)
        let blinkDuration: Double = 0.16

        if cycle < blinkDuration {
            let progress = cycle / blinkDuration
            // Triangle wave: 0 -> 1 -> 0
            return CGFloat(progress < 0.5 ? progress * 2.0 : (1.0 - progress) * 2.0)
        }
        return 0.0
    }
}
