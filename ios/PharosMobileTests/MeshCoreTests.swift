import Foundation
import Testing
@testable import PharosMobile

struct MeshCoreTests {
    @Test func extractsUniqueMentions() {
        #expect(MentionParser.targets(in: "hello @claude-rfc021 and @codex_02 then @claude-rfc021")
                == ["claude-rfc021", "codex_02"])
    }

    @Test func ignoresEmailAddresses() {
        #expect(MentionParser.targets(in: "mail a@b.com, ping @agent") == ["agent"])
    }

    @Test func roundTripsWireResponse() throws {
        let value = MeshResponse(ok: true, rooms: [.init(name: "team", members: ["human", "codex"])])
        let decoded = try JSONDecoder().decode(MeshResponse.self, from: JSONEncoder().encode(value))
        #expect(decoded == value)
    }

    @Test func pokeCommandRejectsShellInjection() {
        #expect(throws: (any Error).self) {
            try TmuxPokeCommand.build(nick: "codex;rm", memberID: "session", pane: "%1", kind: "codex")
        }
    }

    @Test func pokeCommandIncludesSafetyProbe() throws {
        let command = try TmuxPokeCommand.build(nick: "codex", memberID: "019f-test", pane: "%12", kind: "codex")
        #expect(command.contains("capture-pane"))
        #expect(command.contains("esc to interrupt"))
        #expect(command.contains("pharos mesh recv codex --member 019f-test"))
    }

    @Test func rosterAcceptsSameNickInMultipleRooms() {
        let older = MeshMember(id: "one", nick: "codex", project: nil, session: nil, host: nil,
                               tmuxPane: nil, state: nil, stateTs: nil, unread: nil, kind: "codex",
                               rooms: ["a"], lastSeen: 1)
        let newer = MeshMember(id: "one", nick: "codex", project: nil, session: nil, host: nil,
                               tmuxPane: nil, state: nil, stateTs: nil, unread: nil, kind: "codex",
                               rooms: ["a", "b"], lastSeen: 2)
        let index = RosterIndex.byNick([older, newer])
        #expect(index.count == 1)
        #expect(index["codex"]?.rooms == ["a", "b"])
    }
}
