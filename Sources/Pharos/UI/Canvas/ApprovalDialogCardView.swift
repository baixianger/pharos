import SwiftUI
import PharosClientKit

/// Interactive modal card displayed when an agent session enters `needs_human`.
/// Implements RFC-006 §3 approval waterfalls for tool permissions and questionnaires.
public struct ApprovalDialogCardView: View {
    public let request: CanonicalApprovalRequest
    public let onResolve: (ApprovalDecision) -> Void

    @State private var selectedAnswers: [String: String] = [:]

    public init(request: CanonicalApprovalRequest, onResolve: @escaping (ApprovalDecision) -> Void) {
        self.request = request
        self.onResolve = onResolve
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.shield.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(PharosDesignTokens.Colors.statusAttention)

                Text("Human Approval Required")
                    .font(.system(size: 14, weight: .bold))

                Spacer()
            }

            Divider()
                .overlay(PharosDesignTokens.Colors.statusAttention.opacity(0.2))

            // Body content according to ApprovalKind
            switch request.kind {
            case .toolPermission(let toolName, let params, let explanation):
                toolPermissionContent(toolName: toolName, params: params, explanation: explanation)

            case .structuredQuestionnaire(let intent, let questions):
                questionnaireContent(intent: intent, questions: questions)
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(PharosDesignTokens.Colors.statusAttention.opacity(0.4), lineWidth: 1.5)
        )
        .shadow(color: Color.black.opacity(0.08), radius: 8, x: 0, y: 3)
    }

    // MARK: - Tool Permission

    private func toolPermissionContent(toolName: String, params: [String: JSONValue], explanation: String?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Tool:")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(toolName)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }

            if let exp = explanation {
                Text(exp)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            if !params.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Parameters:")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.tertiary)
                    ForEach(Array(params.keys.sorted()), id: \.self) { key in
                        HStack(alignment: .top) {
                            Text("\(key):")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                            Text(String(describing: params[key]?.description ?? ""))
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(2)
                        }
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.03))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            HStack(spacing: 8) {
                Button("Reject") {
                    onResolve(ApprovalDecision(choice: .rejected))
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Allow Always") {
                    onResolve(ApprovalDecision(choice: .allowedAlways))
                }
                .buttonStyle(.bordered)

                Button("Allow Once") {
                    onResolve(ApprovalDecision(choice: .allowedOnce))
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 4)
        }
    }

    // MARK: - Structured Questionnaire

    private func questionnaireContent(intent: String, questions: [CanonicalQuestionOption]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("INTENT: \(intent.uppercased())")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)

            ForEach(questions) { q in
                VStack(alignment: .leading, spacing: 6) {
                    Text(q.question)
                        .font(.system(size: 12, weight: .medium))

                    ForEach(q.options, id: \.self) { opt in
                        Button {
                            selectedAnswers[q.id] = opt
                        } label: {
                            HStack {
                                Image(systemName: selectedAnswers[q.id] == opt ? "largecircle.fill.circle" : "circle")
                                    .foregroundStyle(selectedAnswers[q.id] == opt ? Color.accentColor : Color.secondary)
                                Text(opt)
                                    .font(.system(size: 12))
                                Spacer()
                            }
                            .padding(.vertical, 4)
                            .padding(.horizontal, 8)
                            .background(
                                selectedAnswers[q.id] == opt
                                    ? Color.accentColor.opacity(0.08)
                                    : Color.clear
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack {
                Button("Cancel") {
                    onResolve(ApprovalDecision(choice: .rejected))
                }
                .buttonStyle(.bordered)

                Spacer()

                Button("Submit Answers") {
                    var answersPayload: [String: [String]] = [:]
                    for (qId, answer) in selectedAnswers {
                        answersPayload[qId] = [answer]
                    }
                    onResolve(ApprovalDecision(choice: .allowedOnce, answers: answersPayload))
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 4)
        }
    }
}
