import SwiftUI
import PharosClientKit

/// Shape varieties for deterministic procedural avatars.
/// Ported from Grok Bot avatar parameter specification (THIRD_PARTY_NOTICES.md).
public enum AvatarShape: String, CaseIterable, Identifiable, Sendable, Codable {
    case blob = "blob"
    case cloud = "cloud"
    case square = "square"
    case sparkle = "sparkle"
    case clover = "clover"
    case heart = "heart"
    case flower = "flower"
    case teardrop = "teardrop"
    case tablet = "tablet"
    case wedge = "wedge"
    case house = "house"
    case star = "star"
    case hex = "hex"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .blob: return "Blob"
        case .cloud: return "Cloud"
        case .square: return "Square"
        case .sparkle: return "Sparkle"
        case .clover: return "Clover"
        case .heart: return "Heart"
        case .flower: return "Flower"
        case .teardrop: return "Teardrop"
        case .tablet: return "Tablet"
        case .wedge: return "Wedge"
        case .house: return "House"
        case .star: return "Star"
        case .hex: return "Hexagon"
        }
    }
}

/// Palette colors with exact Light / Dark mode hex values and gradients.
/// Ported from Grok Bot color system (THIRD_PARTY_NOTICES.md).
public enum AvatarPaletteColor: String, CaseIterable, Identifiable, Sendable, Codable {
    case blue = "blue"
    case violet = "violet"
    case magenta = "magenta"
    case cyan = "cyan"
    case green = "green"
    case yellow = "yellow"
    case orange = "orange"
    case red = "red"
    case brown = "brown"
    case gray = "gray"
    case black = "black"

    public var id: String { rawValue }

    public var lightHex: String {
        switch self {
        case .black: return "#000000"
        case .brown: return "#A27952"
        case .red: return "#FF3E51"
        case .orange: return "#FF781C"
        case .yellow: return "#FFAF38"
        case .green: return "#00C972"
        case .cyan: return "#1CC3B0"
        case .blue: return "#2A92FE"
        case .violet: return "#A97EFE"
        case .magenta: return "#FF5EB1"
        case .gray: return "#959595"
        }
    }

    public var darkHex: String {
        switch self {
        case .black: return "#FFFFFF"
        case .brown: return "#855C36"
        case .red: return "#E02135"
        case .orange: return "#FF6700"
        case .yellow: return "#FF9800"
        case .green: return "#009957"
        case .cyan: return "#00A592"
        case .blue: return "#0E74E0"
        case .violet: return "#804EE0"
        case .magenta: return "#E02A88"
        case .gray: return "#777777"
        }
    }

    public func color(isDark: Bool) -> Color {
        let hex = isDark ? darkHex : lightHex
        return Color(hex: hex)
    }

    public func gradient(isDark: Bool) -> Gradient {
        let c = color(isDark: isDark)
        return Gradient(colors: [c.opacity(0.85), c])
    }
}

/// Procedural eye expressions adhering to Grok Bot expression specifications.
public enum AvatarExpression: String, CaseIterable, Sendable, Codable {
    case neutral = "neutral"
    case happy = "happy"
    case surprised = "surprised"
    case sad = "sad"
    case sleepy = "sleepy"
    case squinted = "squinted"
    case calm = "calm"
    case inspecting = "inspecting"
    case confused = "confused"
}

/// Real-time avatar activity status controlling state rings and facial expressions.
public enum AvatarActivityStatus: String, Sendable, Codable, Equatable {
    case idle = "idle"
    case working = "working"
    case needsHuman = "needs_human"
    case stopped = "stopped"

    public var defaultExpression: AvatarExpression {
        switch self {
        case .idle: return .calm
        case .working: return .neutral
        case .needsHuman: return .surprised
        case .stopped: return .sleepy
        }
    }
}

/// Deterministic generator mapping arbitrary string seeds (memberId + sessionId) into shapes and colors.
public struct AvatarParameters: Sendable {

    /// Generates a 64-bit deterministic hash from any input string.
    public static func computeSeed(_ input: String) -> UInt64 {
        var hash: UInt64 = 14695981039346656037 // FNV offset basis
        for byte in input.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211 // FNV prime
        }
        return hash
    }

    /// Selects a shape deterministically from the 13 canonical shapes.
    public static func shape(for seed: UInt64) -> AvatarShape {
        let shapes = AvatarShape.allCases
        let index = Int(seed % UInt64(shapes.count))
        return shapes[index]
    }

    /// Selects a vibrant color deterministically (excluding black by default for high contrast).
    public static func color(for seed: UInt64) -> AvatarPaletteColor {
        // Exclude black so all deterministic avatars have vibrant color
        let vibrantPalette: [AvatarPaletteColor] = [
            .blue, .violet, .magenta, .cyan, .green, .yellow, .orange, .red, .brown, .gray
        ]
        let shifted = seed >> 8
        let index = Int(shifted % UInt64(vibrantPalette.count))
        return vibrantPalette[index]
    }
}

// MARK: - Color Hex Initializer

extension Color {
    public init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255.0,
            green: Double(g) / 255.0,
            blue: Double(b) / 255.0,
            opacity: Double(a) / 255.0
        )
    }
}
