import Foundation
import SwiftUI

/// Represents a single styled span of terminal text.
public struct AnsiSegment: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let text: String
    public let foreground: Color?
    public let background: Color?
    public let isBold: Bool
    public let isDim: Bool
    public let isItalic: Bool
    public let isUnderline: Bool
    public let isInverted: Bool

    public init(
        id: UUID = UUID(),
        text: String,
        foreground: Color? = nil,
        background: Color? = nil,
        isBold: Bool = false,
        isDim: Bool = false,
        isItalic: Bool = false,
        isUnderline: Bool = false,
        isInverted: Bool = false
    ) {
        self.id = id
        self.text = text
        self.foreground = foreground
        self.background = background
        self.isBold = isBold
        self.isDim = isDim
        self.isItalic = isItalic
        self.isUnderline = isUnderline
        self.isInverted = isInverted
    }
}

/// Represents one line of output in a terminal session.
public struct AnsiTerminalLine: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let lineNumber: Int
    public let segments: [AnsiSegment]
    public let rawText: String

    public init(id: UUID = UUID(), lineNumber: Int = 1, segments: [AnsiSegment], rawText: String) {
        self.id = id
        self.lineNumber = lineNumber
        self.segments = segments
        self.rawText = rawText
    }
}

/// High-performance parser and sanitizer for ANSI terminal streams.
public final class AnsiTerminalParser: Sendable {
    public static let shared = AnsiTerminalParser()

    // ANSI CSI regex pattern: ESC [ <parameters> <command>
    private static let csiPattern = "\u{001B}\\[[0-9;?]*[a-zA-Z]"
    // ANSI OSC regex pattern: ESC ] <parameters> (BEL | ESC \)
    private static let oscPattern = "\u{001B}\\].*?(\u{0007}|\u{001B}\\\\)"
    // Generic escape regex for 2-character escape codes
    private static let genericEscPattern = "\u{001B}[()][AB012]|\u{001B}[=>]"

    private static let stripRegex: NSRegularExpression? = {
        let combined = "\(csiPattern)|\(oscPattern)|\(genericEscPattern)"
        return try? NSRegularExpression(pattern: combined, options: [])
    }()

    public init() {}

    /// Strips all ANSI escape codes, returning clean human-readable text.
    public static func stripAnsi(from text: String) -> String {
        guard let regex = stripRegex else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    }

    /// Parses ANSI formatted text into structured terminal lines.
    public func parse(text: String) -> [AnsiTerminalLine] {
        let rawLines = text.components(separatedBy: .newlines)
        var result: [AnsiTerminalLine] = []
        var lineNumber = 1

        var currentFg: Color? = nil
        var currentBg: Color? = nil
        var isBold = false
        var isDim = false
        var isItalic = false
        var isUnderline = false
        var isInverted = false

        for line in rawLines {
            let strippedLine = Self.stripAnsi(from: line)
            var segments: [AnsiSegment] = []

            var index = line.startIndex
            var buffer = ""

            while index < line.endIndex {
                if line[index] == "\u{001B}", index < line.index(before: line.endIndex) {
                    let nextIndex = line.index(after: index)
                    if line[nextIndex] == "[" {
                        // Flush buffer before applying style change
                        if !buffer.isEmpty {
                            segments.append(AnsiSegment(
                                text: buffer,
                                foreground: currentFg,
                                background: currentBg,
                                isBold: isBold,
                                isDim: isDim,
                                isItalic: isItalic,
                                isUnderline: isUnderline,
                                isInverted: isInverted
                            ))
                            buffer = ""
                        }

                        // Parse CSI sequence
                        var cursor = line.index(after: nextIndex)
                        var paramStr = ""
                        while cursor < line.endIndex && !line[cursor].isLetter {
                            paramStr.append(line[cursor])
                            cursor = line.index(after: cursor)
                        }

                        if cursor < line.endIndex {
                            let command = line[cursor]
                            index = line.index(after: cursor)

                            if command == "m" {
                                applySgr(
                                    paramStr: paramStr,
                                    fg: &currentFg,
                                    bg: &currentBg,
                                    bold: &isBold,
                                    dim: &isDim,
                                    italic: &isItalic,
                                    underline: &isUnderline,
                                    invert: &isInverted
                                )
                            }
                            continue
                        }
                    }
                }

                buffer.append(line[index])
                index = line.index(after: index)
            }

            if !buffer.isEmpty {
                segments.append(AnsiSegment(
                    text: buffer,
                    foreground: currentFg,
                    background: currentBg,
                    isBold: isBold,
                    isDim: isDim,
                    isItalic: isItalic,
                    isUnderline: isUnderline,
                    isInverted: isInverted
                ))
            }

            // Always create a line even if empty (for blank lines)
            result.append(AnsiTerminalLine(
                lineNumber: lineNumber,
                segments: segments,
                rawText: strippedLine
            ))
            lineNumber += 1
        }

        return result
    }

    // MARK: - SGR Parser (Select Graphic Rendition)

    private func applySgr(
        paramStr: String,
        fg: inout Color?,
        bg: inout Color?,
        bold: inout Bool,
        dim: inout Bool,
        italic: inout Bool,
        underline: inout Bool,
        invert: inout Bool
    ) {
        if paramStr.isEmpty {
            // SGR 0 (default reset)
            fg = nil
            bg = nil
            bold = false
            dim = false
            italic = false
            underline = false
            invert = false
            return
        }

        let parts = paramStr.split(separator: ";").compactMap { Int($0) }
        var i = 0

        while i < parts.count {
            let code = parts[i]
            switch code {
            case 0: // Reset
                fg = nil
                bg = nil
                bold = false
                dim = false
                italic = false
                underline = false
                invert = false
            case 1: bold = true
            case 2: dim = true
            case 3: italic = true
            case 4: underline = true
            case 7: invert = true
            case 21, 22:
                bold = false
                dim = false
            case 23: italic = false
            case 24: underline = false
            case 27: invert = false
            case 30...37:
                fg = standardColor(code - 30, bright: false)
            case 39:
                fg = nil // Default foreground
            case 40...47:
                bg = standardColor(code - 40, bright: false)
            case 49:
                bg = nil // Default background
            case 90...97:
                fg = standardColor(code - 90, bright: true)
            case 100...107:
                bg = standardColor(code - 100, bright: true)
            case 38: // Extended foreground (256 or RGB)
                if i + 2 < parts.count && parts[i + 1] == 5 {
                    fg = color256(parts[i + 2])
                    i += 2
                } else if i + 4 < parts.count && parts[i + 1] == 2 {
                    fg = Color(
                        red: Double(parts[i + 2]) / 255.0,
                        green: Double(parts[i + 3]) / 255.0,
                        blue: Double(parts[i + 4]) / 255.0
                    )
                    i += 4
                }
            case 48: // Extended background (256 or RGB)
                if i + 2 < parts.count && parts[i + 1] == 5 {
                    bg = color256(parts[i + 2])
                    i += 2
                } else if i + 4 < parts.count && parts[i + 1] == 2 {
                    bg = Color(
                        red: Double(parts[i + 2]) / 255.0,
                        green: Double(parts[i + 3]) / 255.0,
                        blue: Double(parts[i + 4]) / 255.0
                    )
                    i += 4
                }
            default:
                break
            }
            i += 1
        }
    }

    // MARK: - Standard & 256 Color Palettes

    public func standardColor(_ index: Int, bright: Bool) -> Color {
        switch (index, bright) {
        case (0, false): return Color(red: 0.15, green: 0.15, blue: 0.16) // Black
        case (0, true):  return Color(red: 0.45, green: 0.45, blue: 0.48) // Bright Black (Gray)
        case (1, false): return Color(red: 0.85, green: 0.25, blue: 0.25) // Red
        case (1, true):  return Color(red: 0.95, green: 0.40, blue: 0.40) // Bright Red
        case (2, false): return Color(red: 0.20, green: 0.78, blue: 0.35) // Green
        case (2, true):  return Color(red: 0.35, green: 0.90, blue: 0.50) // Bright Green
        case (3, false): return Color(red: 0.88, green: 0.65, blue: 0.15) // Yellow
        case (3, true):  return Color(red: 0.98, green: 0.80, blue: 0.30) // Bright Yellow
        case (4, false): return Color(red: 0.25, green: 0.50, blue: 0.95) // Blue
        case (4, true):  return Color(red: 0.45, green: 0.68, blue: 1.00) // Bright Blue
        case (5, false): return Color(red: 0.75, green: 0.35, blue: 0.88) // Magenta
        case (5, true):  return Color(red: 0.88, green: 0.50, blue: 0.98) // Bright Magenta
        case (6, false): return Color(red: 0.20, green: 0.75, blue: 0.85) // Cyan
        case (6, true):  return Color(red: 0.40, green: 0.88, blue: 0.95) // Bright Cyan
        case (7, false): return Color(red: 0.88, green: 0.88, blue: 0.90) // White
        case (7, true):  return Color(red: 1.00, green: 1.00, blue: 1.00) // Bright White
        default: return .white
        }
    }

    public func color256(_ n: Int) -> Color {
        if n < 8 {
            return standardColor(n, bright: false)
        } else if n < 16 {
            return standardColor(n - 8, bright: true)
        } else if n < 232 {
            // 6x6x6 color cube
            let val = n - 16
            let r = (val / 36) % 6
            let g = (val / 6) % 6
            let b = val % 6
            let steps: [Double] = [0.0, 0.37, 0.53, 0.69, 0.84, 1.0]
            return Color(red: steps[r], green: steps[g], blue: steps[b])
        } else {
            // Grayscale ramp
            let gray = Double((n - 232) * 10 + 8) / 255.0
            return Color(red: gray, green: gray, blue: gray)
        }
    }
}
