import Foundation

public struct LightMemberRuntimeReport: Codable, Equatable, Sendable {
    public var member: String
    public var node: String          // reporting node name
    public var tmux: String
    public var live: String          // alive | agent-exited | dead | ended | stopped
    public var activity: String      // idle | thinking | needs_human | unknown
    public var detail: String        // short, metadata only (no message text)
    public var at: Date
    public var binding: LightTmuxBinding?   // set when the node changed the binding (ended marker, auto-revive)

    public init(
        member: String,
        node: String,
        tmux: String,
        live: String,
        activity: String,
        detail: String,
        at: Date,
        binding: LightTmuxBinding? = nil
    ) {
        self.member = member
        self.node = node
        self.tmux = tmux
        self.live = live
        self.activity = activity
        self.detail = detail
        self.at = at
        self.binding = binding
    }
}
