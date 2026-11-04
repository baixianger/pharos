import Foundation

public enum AgyPaneState: Equatable, Sendable {
    case idle
    case busy
    case needsHuman(what: String)
    case quota(resetsIn: TimeInterval?)
    case unknown
}

public enum AgyPane {
    /// Look only at the last ~40 non-empty lines. Priority:
    /// needsHuman (what = the line after "Requesting permission for:", trimmed, clipped to 160 chars; or "trust folder")
    /// > quota (only if the quota line is below the last `> ` user-prompt echo line, i.e. it belongs to the latest turn)
    /// > busy (`esc to cancel`)
    /// > idle (`? for shortcuts`)
    /// > unknown.
    public static func classify(_ pane: String) -> AgyPaneState {
        let allLines = pane.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let lines = Array(allLines.suffix(40))
        guard !lines.isEmpty else { return .unknown }

        // 1. needsHuman
        if let permIdx = lines.firstIndex(where: { $0.contains("Requesting permission for:") }) {
            var what = ""
            if permIdx + 1 < lines.count {
                what = lines[permIdx + 1].trimmingCharacters(in: .whitespacesAndNewlines)
                if what.count > 160 {
                    what = String(what.prefix(160))
                }
            }
            return .needsHuman(what: what)
        }

        if lines.contains(where: {
            $0.contains("Do you trust the contents of this project?") ||
            $0.contains("Yes, I trust this folder") ||
            $0.contains("trust the contents of this project")
        }) {
            return .needsHuman(what: "trust folder")
        }

        // 2. quota (only if below the last `> ` user prompt echo line)
        var lastPromptIndex = -1
        for (idx, line) in lines.enumerated() {
            if line.hasPrefix("> ") && !line.dropFirst(2).trimmingCharacters(in: .whitespaces).isEmpty {
                lastPromptIndex = idx
            }
        }

        func isQuotaLine(_ text: String) -> Bool {
            let lower = text.lowercased()
            return lower.contains("individual quota reached") ||
                   lower.contains("resource_exhausted") ||
                   lower.contains("quota exceeded") ||
                   lower.contains("code 429") || lower.contains("error 429") || lower.contains("(429)")
        }

        if let quotaIdx = lines.lastIndex(where: isQuotaLine), quotaIdx > lastPromptIndex {
            let region = lines[quotaIdx...].joined(separator: " ")
            var resetsIn: TimeInterval? = nil
            if let range = region.range(of: "resets in", options: .caseInsensitive) {
                let after = region[range.upperBound...].trimmingCharacters(in: .whitespaces)
                let token = after.components(separatedBy: .whitespaces)
                    .first?
                    .trimmingCharacters(in: CharacterSet(charactersIn: ". ,;:")) ?? ""
                resetsIn = parseDuration(token)
            }
            return .quota(resetsIn: resetsIn)
        }

        // 3. busy
        if lines.contains(where: { $0.contains("esc to cancel") }) {
            return .busy
        }

        // 4. idle
        if lines.contains(where: { $0.contains("? for shortcuts") }) {
            return .idle
        }

        return .unknown
    }

    /// "27h59m2s" / "5m" / "45s" / "1h" -> seconds
    public static func parseDuration(_ s: String) -> TimeInterval? {
        let trimmed = s.trimmingCharacters(in: CharacterSet(charactersIn: ". ,;: \t\n\r"))
        guard !trimmed.isEmpty else { return nil }

        var total: TimeInterval = 0
        var currentDigits = ""
        var matchedAny = false

        for ch in trimmed {
            if ch.isNumber {
                currentDigits.append(ch)
            } else if ch == "h" || ch == "H" {
                guard let val = Double(currentDigits) else { return nil }
                total += val * 3600
                currentDigits = ""
                matchedAny = true
            } else if ch == "m" || ch == "M" {
                guard let val = Double(currentDigits) else { return nil }
                total += val * 60
                currentDigits = ""
                matchedAny = true
            } else if ch == "s" || ch == "S" {
                guard let val = Double(currentDigits) else { return nil }
                total += val
                currentDigits = ""
                matchedAny = true
            } else {
                return nil
            }
        }

        guard currentDigits.isEmpty, matchedAny else { return nil }
        return total
    }
}
