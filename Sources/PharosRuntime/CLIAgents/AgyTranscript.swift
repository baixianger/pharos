import Foundation

public struct AgyStep: Equatable, Sendable {
    public var index: Int
    public var source: String
    public var type: String
    public var status: String
    public var createdAt: Date?
    public var content: String
    public var hasToolCalls: Bool

    public init(
        index: Int,
        source: String,
        type: String,
        status: String,
        createdAt: Date? = nil,
        content: String = "",
        hasToolCalls: Bool = false
    ) {
        self.index = index
        self.source = source
        self.type = type
        self.status = status
        self.createdAt = createdAt
        self.content = content
        self.hasToolCalls = hasToolCalls
    }
}

public struct AgyTranscript: Sendable {
    private static func parseDate(_ string: String?) -> Date? {
        guard let string, !string.isEmpty else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: string) { return d }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: string)
    }

    /// Path to transcript file: `~/.gemini/antigravity-cli/brain/<conversationId>/.system_generated/logs/transcript.jsonl`
    public static func path(conversationID: String, appData: URL) -> URL {
        appData
            .appendingPathComponent("brain")
            .appendingPathComponent(conversationID)
            .appendingPathComponent(".system_generated")
            .appendingPathComponent("logs")
            .appendingPathComponent("transcript.jsonl")
    }

    /// Parse transcript JSONL lines. Skips unparsable bad lines and ignores a torn last line.
    public static func parse(_ text: String) -> [AgyStep] {
        var lines = text.components(separatedBy: "\n")
        while let last = lines.last, last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.removeLast()
        }
        guard !lines.isEmpty else { return [] }

        var steps: [AgyStep] = []
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            guard let data = trimmed.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                continue
            }

            guard let stepIndex = (obj["step_index"] as? Int) ?? (obj["index"] as? Int),
                  let source = obj["source"] as? String,
                  let type = obj["type"] as? String,
                  let status = obj["status"] as? String else {
                continue
            }

            let createdAt = parseDate(obj["created_at"] as? String)
            let content = (obj["content"] as? String) ?? ""
            let hasToolCalls: Bool
            if let calls = obj["tool_calls"] as? [Any] {
                hasToolCalls = !calls.isEmpty
            } else {
                hasToolCalls = false
            }

            steps.append(
                AgyStep(
                    index: stepIndex,
                    source: source,
                    type: type,
                    status: status,
                    createdAt: createdAt,
                    content: content,
                    hasToolCalls: hasToolCalls
                )
            )
        }
        return steps
    }

    /// Load steps from disk. Returns `[]` if the file does not exist or cannot be read.
    public static func load(_ url: URL) -> [AgyStep] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return []
        }
        return parse(text)
    }

    /// Highest step_index, or -1 when empty. This is the ReplyCursor value ("agy-step").
    public static func cursor(_ steps: [AgyStep]) -> Int {
        steps.map(\.index).max() ?? -1
    }

    /// The reply to the turn that started after `cursor`: steps with index > cursor; find the first USER_INPUT
    /// among them (if none, consider all of them); after it, the LAST step with source MODEL,
    /// type PLANNER_RESPONSE, status DONE, !hasToolCalls and non-empty trimmed content —
    /// but only if no later USER_INPUT follows it (a newer turn not finished yet -> keep looking in that newer turn instead:
    /// i.e. return the final answer of the FIRST turn after cursor that has one). Returns (text, stepIndex) or nil.
    public static func reply(after cursor: Int, in steps: [AgyStep]) -> (text: String, step: Int)? {
        let candidates = steps.filter { $0.index > cursor }
        guard !candidates.isEmpty else { return nil }

        func isFinalAnswer(_ step: AgyStep) -> Bool {
            step.source == "MODEL" &&
            step.type == "PLANNER_RESPONSE" &&
            step.status == "DONE" &&
            !step.hasToolCalls &&
            !step.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }

        let userIndices = candidates.indices.filter { candidates[$0].type == "USER_INPUT" }

        if userIndices.isEmpty {
            if let match = candidates.last(where: isFinalAnswer) {
                return (text: match.content, step: match.index)
            }
            return nil
        }

        for (turnIdx, uIdx) in userIndices.enumerated() {
            let nextUIdx = (turnIdx + 1 < userIndices.count) ? userIndices[turnIdx + 1] : candidates.count
            let turnSteps = candidates[(uIdx + 1)..<nextUIdx]
            if let match = turnSteps.last(where: isFinalAnswer) {
                return (text: match.content, step: match.index)
            }
        }

        return nil
    }

    /// Same but anchored by time: first turn whose USER_INPUT createdAt >= since (allow 2 s skew).
    public static func reply(since: Date, in steps: [AgyStep]) -> (text: String, step: Int)? {
        let cutoff = since.addingTimeInterval(-2.0)
        guard let firstIndex = steps.firstIndex(where: {
            $0.type == "USER_INPUT" && ($0.createdAt ?? .distantPast) >= cutoff
        }) else {
            return nil
        }
        let remaining = Array(steps[firstIndex...])
        return reply(after: remaining[0].index - 1, in: remaining)
    }

    /// Strip the `<USER_REQUEST>...</USER_REQUEST>` wrapper from a USER_INPUT content (for display/tests).
    public static func userText(_ content: String) -> String {
        let openTag = "<USER_REQUEST>"
        let closeTag = "</USER_REQUEST>"
        if let openRange = content.range(of: openTag),
           let closeRange = content.range(of: closeTag, range: openRange.upperBound..<content.endIndex) {
            let inside = content[openRange.upperBound..<closeRange.lowerBound]
            return inside.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
