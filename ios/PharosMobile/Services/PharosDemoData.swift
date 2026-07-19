import Foundation

/// Deterministic, entirely fictional content used for App Store screenshots.
/// This payload never reads the registry, settings, caches, or Mesh broker.
struct PharosDemoData: Sendable {
    let rooms: [MeshRoom]
    let selectedRoom: String
    let messages: [MeshMessage]
    let members: [String: MeshMember]
    let projects: [RemoteProject]
    let issues: [RemoteIssue]

    static let store = PharosDemoData(
        rooms: [
            MeshRoom(name: "launch-room", members: ["human", "nova", "atlas", "pixel"]),
            MeshRoom(name: "ios-release", members: ["human", "nova", "pixel"]),
            MeshRoom(name: "design-lab", members: ["human", "atlas", "muse"]),
            MeshRoom(name: "infra", members: ["human", "forge"])
        ],
        selectedRoom: "launch-room",
        messages: decodeMessages(),
        members: RosterIndex.byNick([
            member("nova", kind: "codex", project: "Aurora", host: "studio-mac", pane: "%3",
                   state: "busy", rooms: ["launch-room", "ios-release"]),
            member("atlas", kind: "claude", project: "Atlas", host: "studio-mac", pane: "%5",
                   state: "idle", rooms: ["launch-room", "design-lab"]),
            member("pixel", kind: "codex", project: "Pocket Studio", host: "travel-mac", pane: "%2",
                   state: "busy", rooms: ["launch-room", "ios-release"]),
            member("muse", kind: "claude", project: "Field Notes", host: "travel-mac", pane: "%4",
                   state: "blocked", reason: "permission:review design export", rooms: ["design-lab"]),
            member("forge", kind: "codex", project: "Beacon", host: "home-lab", pane: "%7",
                   state: "idle", rooms: ["infra"])
        ]),
        projects: projects,
        issues: projects.flatMap(\.issues)
    )

    private static let projects: [RemoteProject] = [
        RemoteProject(
            name: "Aurora",
            localPath: "/Users/demo/Projects/aurora",
            githubRemote: "https://example.com/aurora.git",
            tags: ["ios", "swift"],
            notes: "A calm workspace for planning and shipping creative work.",
            issues: [
                issue("Aurora", 24, "Polish the welcome experience", "in-progress", "high", ["design"], 0),
                issue("Aurora", 27, "Add offline project snapshots", "todo", "medium", ["ios"], 0)
            ],
            updates: [RemoteProjectUpdate(id: "aurora-update", body: "The new navigation flow is ready for review.",
                                          kind: "note", issueNumber: 24)]
        ),
        RemoteProject(
            name: "Atlas",
            localPath: "/Users/demo/Projects/atlas",
            githubRemote: "https://example.com/atlas.git",
            tags: ["agents", "research"],
            notes: "Coordinate research agents and turn findings into decisions.",
            issues: [
                issue("Atlas", 12, "Summarize the weekly research run", "todo", "medium", ["agents"], 1),
                issue("Atlas", 15, "Review source confidence labels", "backlog", "low", ["research"], 0)
            ]
        ),
        RemoteProject(
            name: "Pocket Studio",
            localPath: "/Users/demo/Projects/pocket-studio",
            githubRemote: nil,
            tags: ["mobile", "prototype"],
            notes: "Small experiments designed and shipped from anywhere.",
            issues: [
                issue("Pocket Studio", 8, "Tune the compact dashboard", "in-progress", "urgent", ["mobile"], 1),
                issue("Pocket Studio", 9, "Prepare the beta checklist", "done", "medium", ["release"], 0)
            ]
        ),
        RemoteProject(
            name: "Field Notes",
            localPath: nil,
            githubRemote: nil,
            tags: ["writing"],
            notes: "A portable notebook for observations and ideas.",
            issues: [issue("Field Notes", 4, "Organize the summer collection", "backlog", "none", ["content"], 2)]
        )
    ]

    private static func member(
        _ nick: String, kind: String, project: String, host: String, pane: String,
        state: String, reason: String? = nil, rooms: [String]
    ) -> MeshMember {
        MeshMember(
            id: "demo-\(nick)", nick: nick, project: "/Users/demo/Projects/\(project)",
            session: "demo-\(nick)", host: host, tmuxPane: pane,
            tmuxSocket: "/tmp/pharos-demo.sock", state: state, stateTs: 1_721_467_260,
            stateReason: reason, unread: nick == "nova" ? 2 : nil, kind: kind,
            tailscaleIP: nil, rooms: rooms, lastSeen: 1_721_467_260, nodeOnline: true
        )
    }

    private static func issue(
        _ project: String, _ number: Int, _ title: String, _ status: String,
        _ priority: String, _ labels: [String], _ order: Double
    ) -> RemoteIssue {
        RemoteIssue(project: project, number: number, title: title, status: status,
                    priority: priority, labels: labels,
                    body: "A fictional demo issue created for the Pharos App Store preview.",
                    activeSession: status == "in-progress" ? "demo-session" : nil,
                    sortOrder: order)
    }

    private static func decodeMessages() -> [MeshMessage] {
        let json = #"""
        [
          {"id":"demo-1","from":"human","room":"launch-room","text":"Let’s make the release feel effortless. What should we finish first?","ts":1721466960,"to":["nova","atlas"]},
          {"id":"demo-2","from":"nova","room":"launch-room","text":"The project dashboard is ready. I’m tightening the empty states and checking the compact layout now.","ts":1721467020,"to":[]},
          {"id":"demo-3","from":"atlas","room":"launch-room","text":"I reviewed the launch checklist. The remaining work is small: final screenshots, accessibility pass, then the release notes.","ts":1721467080,"to":[]},
          {"id":"demo-4","from":"pixel","room":"launch-room","text":"iPhone and iPad builds are both green. I’ll prepare the store-ready capture set next.","ts":1721467140,"to":["nova"]},
          {"id":"demo-5","from":"human","room":"launch-room","text":"Perfect. Keep the screenshots focused on projects, issues, agents, and this room.","ts":1721467200,"to":[]},
          {"id":"demo-6","from":"nova","room":"launch-room","text":"On it — everything in the preview uses fictional demo content, and no live workspace is connected.","ts":1721467260,"to":[]},
          {"id":"demo-7","from":"atlas","room":"launch-room","text":"The accessibility pass is complete: larger text, VoiceOver labels, and keyboard focus all look good.","ts":1721467320,"to":[]},
          {"id":"demo-8","from":"pixel","room":"launch-room","text":"I’ve pinned the demo clock and locale so every capture stays consistent across devices.","ts":1721467380,"to":[]},
          {"id":"demo-9","from":"human","room":"launch-room","text":"Nice. Let’s keep the visual language calm, precise, and focused on the work.","ts":1721467440,"to":[]},
          {"id":"demo-10","from":"nova","room":"launch-room","text":"Projects and issues are framed. The live-agent view is next.","ts":1721467500,"to":["pixel"]},
          {"id":"demo-11","from":"pixel","room":"launch-room","text":"Agent states are clear at a glance: working, idle, or waiting for a decision.","ts":1721467560,"to":[]},
          {"id":"demo-12","from":"atlas","room":"launch-room","text":"Release notes are drafted and the final checklist has no blockers.","ts":1721467620,"to":[]},
          {"id":"demo-13","from":"human","room":"launch-room","text":"Great. Capture this room once the full conversation is visible on iPad.","ts":1721467680,"to":[]},
          {"id":"demo-14","from":"nova","room":"launch-room","text":"Ready. One workspace, one shared context, and a clean path to ship.","ts":1721467740,"to":[]}
        ]
        """#
        return (try? JSONDecoder().decode([MeshMessage].self, from: Data(json.utf8))) ?? []
    }
}

enum PharosDemoMode {
    static var isEnabled: Bool {
        let value = ProcessInfo.processInfo.environment["PHAROS_DEMO"]?.lowercased()
        return value == "1" || value == "true" || value == "yes"
    }

    static var scene: String? {
        ProcessInfo.processInfo.environment["PHAROS_SCENE"]?.lowercased()
    }
}
