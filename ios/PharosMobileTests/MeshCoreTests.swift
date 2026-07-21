import Foundation
import PharosMeshProtocol
import PharosMeshReplica
import Testing
@testable import PharosMobile

struct MeshCoreTests {
    @Test func distributedRegistryPreservesAdvancedProjectAndIssueFields() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pharos-mobile-registry-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let replica = try MeshLocalReplica.openIsolated(rootURL: root)
        let group = try await replica.ensureActiveTrustGroup()
        let registry = MobileDistributedRegistry(replica: replica, group: group)
        let milestone = RemoteMilestone(
            id: UUID().uuidString, name: "Release", due: Date(timeIntervalSince1970: 2_000_000_000)
        )
        let playbook = RemotePlaybook(
            id: UUID().uuidString, name: "Verify", command: "swift test"
        )
        try await registry.addProject(
            name: "Pharos", githubRemote: "https://github.com/example/pharos",
            notes: "Personal control plane", tags: ["ios"],
            yolo: false, tmux: true, playbooks: [playbook],
            milestones: [milestone]
        )
        try await registry.addIssue(
            to: "Pharos", title: "Parent", body: "Root work",
            status: "in_progress", priority: "high", labels: ["mesh"],
            milestoneID: milestone.id, parent: nil, relations: [], attachments: []
        )
        try await registry.addIssue(
            to: "Pharos", title: "Child", body: "Mobile work",
            status: "todo", priority: "medium", labels: ["ios"],
            milestoneID: milestone.id, parent: 1,
            relations: [RemoteIssueRelation(kind: "blocks", target: 1)],
            attachments: []
        )

        var project = try #require((try await registry.projects()).first)
        #expect(project.yolo == false)
        #expect(project.tmux == true)
        #expect(project.playbooks == [playbook])
        #expect(project.milestones == [milestone])
        let parent = try #require(project.issues.first { $0.number == 1 })
        let child = try #require(project.issues.first { $0.number == 2 })
        #expect(child.parent == 1)
        #expect(child.relations == [RemoteIssueRelation(kind: "blocks", target: 1)])
        #expect(parent.relations == [RemoteIssueRelation(kind: "blocked_by", target: 2)])

        try await registry.updateIssue(
            child, title: child.title, body: child.body,
            status: child.status, priority: child.priority, labels: child.labels,
            milestoneID: child.milestoneID, parent: child.parent,
            relations: [RemoteIssueRelation(kind: "duplicate", target: 1)],
            attachments: child.attachments
        )
        project = try #require((try await registry.projects()).first)
        #expect(project.issues.first { $0.number == 1 }?.relations == [
            RemoteIssueRelation(kind: "duplicate", target: 2)
        ])
        let changedChild = try #require(project.issues.first { $0.number == 2 })
        try await registry.updateIssue(
            changedChild, title: changedChild.title, body: changedChild.body,
            status: changedChild.status, priority: changedChild.priority,
            labels: changedChild.labels, milestoneID: changedChild.milestoneID,
            parent: changedChild.parent, relations: [],
            attachments: changedChild.attachments
        )
        project = try #require((try await registry.projects()).first)
        #expect(project.issues.first { $0.number == 1 }?.relations.isEmpty == true)
        #expect(project.issues.first { $0.number == 2 }?.relations.isEmpty == true)

        var rejectedParentCycle = false
        do {
            try await registry.updateIssue(
                parent, title: parent.title, body: parent.body,
                status: parent.status, priority: parent.priority, labels: parent.labels,
                milestoneID: parent.milestoneID, parent: 2,
                relations: parent.relations, attachments: parent.attachments
            )
        } catch {
            rejectedParentCycle = true
        }
        #expect(rejectedParentCycle)

        try await registry.updateProject(
            project, name: project.name, githubRemote: project.githubRemote,
            notes: project.notes, tags: project.tags, yolo: project.yolo,
            tmux: project.tmux, playbooks: project.playbooks, milestones: []
        )
        project = try #require((try await registry.projects()).first)
        #expect(project.issues.allSatisfy { $0.milestoneID == nil })
    }

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

    @Test func decodesLegacyMessageWithoutV2Fields() throws {
        let data = Data(#"{"from":"human","room":"dev","text":"hello","ts":1,"to":[]}"#.utf8)
        let message = try JSONDecoder().decode(MeshMessage.self, from: data)
        #expect(message.id == nil)
        #expect(message.stableID == "legacy|dev|1.0|human")
        #expect(message.replyTo == nil)
        #expect(message.attachments == nil)
    }

    @Test func decodesReplyAndAttachmentMessage() throws {
        let data = Data(#"{"id":"m2","from":"codex","room":"dev","text":"done","ts":2,"to":[],"replyTo":{"messageID":"m1","from":"human","preview":"please review","ts":1},"attachments":[{"id":"a1","name":"design.pdf","mimeType":"application/pdf","byteSize":42,"sha256":"abc"}]}"#.utf8)
        let message = try JSONDecoder().decode(MeshMessage.self, from: data)
        #expect(message.id == "m2")
        #expect(message.replyTo?.messageID == "m1")
        #expect(message.attachments?.first?.name == "design.pdf")
    }

    @Test func hostResolverUsesStableAgentIdentity() {
        let expected = SSHHostProfile(meshHost: "home-ts", sshHost: "100.64.0.8", username: "pai")
        let other = SSHHostProfile(meshHost: "mac-mini", sshHost: "100.64.0.9", username: "pai")
        #expect(SSHHostResolver.profile(forHost: "HOME-TS", tailscaleIP: "100.64.0.8",
                                        in: [other, expected])?.id == expected.id)
    }

    @Test func hostResolverAcceptsTailscaleEndpointAlias() {
        let expected = SSHHostProfile(meshHost: "100.64.0.8", sshHost: "home-ts.tailnet.ts.net",
                                      username: "pai")
        #expect(SSHHostResolver.profile(forHost: "home-ts", tailscaleIP: "100.64.0.8",
                                        in: [expected])?.id == expected.id)
    }

    @Test func hostResolverPrefersTailscaleIPOverConflictingComputerName() {
        let correct = SSHHostProfile(meshHost: "office", sshHost: "100.64.0.8", username: "pai")
        let wrongName = SSHHostProfile(meshHost: "Xiang's Mac mini", sshHost: "100.64.0.9",
                                       username: "pai")
        #expect(SSHHostResolver.profile(forHost: "Xiang's Mac mini", tailscaleIP: "100.64.0.8",
                                        in: [wrongName, correct])?.id == correct.id)
    }

    @Test func hostResolverRejectsAmbiguousEndpointAliases() {
        let one = SSHHostProfile(meshHost: "one", sshHost: "100.64.0.8", username: "pai")
        let two = SSHHostProfile(meshHost: "two", sshHost: "100.64.0.8", username: "pai")
        #expect(SSHHostResolver.profile(forHost: "unknown", tailscaleIP: "100.64.0.8",
                                        in: [one, two]) == nil)
    }

    @Test func rosterAcceptsSameNickInMultipleRooms() {
        let older = MeshMember(id: "one", nick: "codex", project: nil, session: nil, host: nil,
                               tmuxPane: nil, state: nil, stateTs: nil, unread: nil, kind: "codex",
                               tailscaleIP: nil, rooms: ["a"], lastSeen: 1, nodeOnline: nil)
        let newer = MeshMember(id: "one", nick: "codex", project: nil, session: nil, host: nil,
                               tmuxPane: nil, state: nil, stateTs: nil, unread: nil, kind: "codex",
                               tailscaleIP: nil, rooms: ["a", "b"], lastSeen: 2, nodeOnline: nil)
        let index = RosterIndex.byNick([older, newer])
        #expect(index.count == 1)
        #expect(index["codex"]?.rooms == ["a", "b"])
    }

    @Test func attachCommandTargetsExactPaneSession() throws {
        let command = try RemoteCommandBuilder.attach(pane: "%12", socket: "/private/tmp/tmux-501/agent")
        #expect(command.contains("display-message -p -t '%12'"))
        #expect(command.contains("tmux -S '/private/tmp/tmux-501/agent'"))
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
        {"projects":[{"name":"Pharos","localPath":"/p","githubRemote":"https://github.com/x/pharos.git","tags":["personal","tools"],"notes":"Developer cockpit","issues":[{"number":3,"title":"Refine iOS","status":"in_progress","priority":"high","labels":["ios"],"body":"More context"}],"updates":[{"id":"u1","body":"Shipped broker sync","kind":"agent","issueNumber":3}]}]}
        """
        let p = RemoteAgentService.parseProjects(json).first
        #expect(p?.localPath == "/p")
        #expect(p?.githubRemote == "https://github.com/x/pharos.git")
        #expect(p?.tags == ["personal", "tools"])
        #expect(p?.notes == "Developer cockpit")
        #expect(p?.issues.first?.body == "More context")
        #expect(p?.updates.first?.issueNumber == 3)
        #expect(p?.hasLocalPath == true)
    }

    @Test func parseIssuesExtractsFields() {
        let json = """
        {"issues":[
          {"project":"Pharos","number":2,"title":"do X","status":"todo","priority":"low","labels":["feature"],"body":"Context","activeSession":"pharos-2"},
          {"project":"brainstorm","number":5,"title":"fix Y","status":"doing","priority":"high","labels":[]}
        ]}
        """
        let issues = RemoteAgentService.parseIssues(json)
        #expect(issues.count == 2)
        #expect(issues.first?.id == "Pharos#2")
        #expect(issues.first?.status == "todo")
        #expect(issues.first?.body == "Context")
        #expect(issues.first?.activeSession == "pharos-2")
        #expect(issues.last?.project == "brainstorm")
        #expect(issues.last?.priority == "high")
    }

    @Test func parseIssuesToleratesNoiseAndSkipsMalformed() {
        let noisy = "warning: x\n{\"issues\":[{\"project\":\"P\",\"number\":1,\"title\":\"t\"},{\"project\":\"Q\"}]}"
        #expect(RemoteAgentService.parseIssues(noisy).map(\.id) == ["P#1"])
    }
}
