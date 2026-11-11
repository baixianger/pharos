import Foundation

/// Latest provider-reported progress snapshot for an opened Session.
public struct CanonicalSessionProgress: Sendable, Codable, Equatable {
    public let goal: CanonicalSessionGoal?
    public let todos: [CanonicalSessionTodo]

    public init(goal: CanonicalSessionGoal?, todos: [CanonicalSessionTodo]) {
        self.goal = goal
        self.todos = todos
    }
}

/// Agent-reported session goal. Status preserves the provider's vocabulary.
public struct CanonicalSessionGoal: Sendable, Codable, Equatable {
    public let objective: String
    public let status: String

    public init(objective: String, status: String) {
        self.objective = objective
        self.status = status
    }
}

/// One item from the latest complete todo/plan snapshot for a Session.
public struct CanonicalSessionTodo: Sendable, Codable, Equatable {
    public enum Status: String, Sendable, Codable {
        case pending, inProgress, completed, unknown
    }

    public let text: String
    public let status: Status
    /// Provider-reported priority; nil means it was not supplied.
    public let priority: String?

    public init(text: String, status: Status, priority: String? = nil) {
        self.text = text
        self.status = status
        self.priority = priority
    }
}
