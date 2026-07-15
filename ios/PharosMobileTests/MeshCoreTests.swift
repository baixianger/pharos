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

    @Test func attachCommandTargetsExactPaneSession() throws {
        let command = try RemoteCommandBuilder.attach(pane: "%12")
        #expect(command.contains("display-message -p -t '%12'"))
        // `-d` detaches other clients so a single terminal drives the size (no flushing).
        #expect(command.contains("attach-session -d -t \"=$s\""))
    }

    @Test func attachCommandRejectsInjection() {
        #expect(throws: (any Error).self) { try RemoteCommandBuilder.attach(pane: "%12; reboot") }
    }

    @Test func spawnCommandUsesRemotePharosCLI() throws {
        let command = try RemoteCommandBuilder.spawn(room: "team", nick: "codex-02", kind: .codex)
        #expect(command.contains("pharos mesh spawn team codex-02 codex"))
    }

    @Test func spawnCommandRejectsUnsafeNick() {
        #expect(throws: (any Error).self) {
            try RemoteCommandBuilder.spawn(room: "team", nick: "codex; reboot", kind: .codex)
        }
    }

    @Test func spawnCommandDefaultsToNoWorkDirFlag() throws {
        let command = try RemoteCommandBuilder.spawn(room: "team", nick: "codex-02", kind: .codex)
        #expect(!command.contains("--cwd"))
        #expect(!command.contains("--project"))
    }

    @Test func spawnCommandAppendsProject() throws {
        let command = try RemoteCommandBuilder.spawn(room: "team", nick: "cc", kind: .claude,
                                                     workDir: .project("Pharos"))
        #expect(command.contains("pharos mesh spawn team cc claude --project 'Pharos'"))
    }

    @Test func spawnCommandQuotesCustomPath() throws {
        let command = try RemoteCommandBuilder.spawn(room: "team", nick: "cc", kind: .claude,
                                                     workDir: .path("/Users/pai/omika.AI/lelantos"))
        #expect(command.contains("--cwd '/Users/pai/omika.AI/lelantos'"))
    }

    @Test func spawnCommandRejectsPathInjection() {
        #expect(throws: (any Error).self) {
            try RemoteCommandBuilder.spawn(room: "team", nick: "cc", kind: .claude,
                                           workDir: .path("/tmp'; reboot #"))
        }
    }

    @Test func spawnCommandRejectsRelativePath() {
        #expect(throws: (any Error).self) {
            try RemoteCommandBuilder.spawn(room: "team", nick: "cc", kind: .claude,
                                           workDir: .path("relative/dir"))
        }
    }

    @Test func spawnCommandRejectsProjectInjection() {
        #expect(throws: (any Error).self) {
            try RemoteCommandBuilder.spawn(room: "team", nick: "cc", kind: .claude,
                                           workDir: .project("p'; reboot #"))
        }
    }

    @Test func parseProjectsExtractsNames() {
        let json = """
        {"count":2,"projects":[
          {"name":"Pharos","localPath":"/Users/pai/personal/pharos"},
          {"name":"Lelantos","localPath":null}
        ]}
        """
        let projects = RemoteAgentService.parseProjects(json)
        #expect(projects.map(\.name) == ["Pharos", "Lelantos"])
        #expect(projects.first?.hasLocalPath == true)
        #expect(projects.last?.hasLocalPath == false)
    }

    @Test func parseProjectsToleratesLeadingNoise() {
        let noisy = "warning: something\n{\"projects\":[{\"name\":\"Only\"}]}"
        #expect(RemoteAgentService.parseProjects(noisy).map(\.name) == ["Only"])
    }

    @Test func parseProjectsExtractsRichFields() {
        let json = """
        {"projects":[{"name":"Pharos","localPath":"/p","githubRemote":"https://github.com/x/pharos.git","tags":["personal","tools"]}]}
        """
        let p = RemoteAgentService.parseProjects(json).first
        #expect(p?.localPath == "/p")
        #expect(p?.githubRemote == "https://github.com/x/pharos.git")
        #expect(p?.tags == ["personal", "tools"])
        #expect(p?.hasLocalPath == true)
    }

    @Test func parseIssuesExtractsFields() {
        let json = """
        {"issues":[
          {"project":"Pharos","number":2,"title":"do X","status":"todo","priority":"low","labels":["feature"]},
          {"project":"brainstorm","number":5,"title":"fix Y","status":"doing","priority":"high","labels":[]}
        ]}
        """
        let issues = RemoteAgentService.parseIssues(json)
        #expect(issues.count == 2)
        #expect(issues.first?.id == "Pharos#2")
        #expect(issues.first?.status == "todo")
        #expect(issues.last?.project == "brainstorm")
        #expect(issues.last?.priority == "high")
    }

    @Test func parseIssuesToleratesNoiseAndSkipsMalformed() {
        let noisy = "warning: x\n{\"issues\":[{\"project\":\"P\",\"number\":1,\"title\":\"t\"},{\"project\":\"Q\"}]}"
        #expect(RemoteAgentService.parseIssues(noisy).map(\.id) == ["P#1"])
    }
}
