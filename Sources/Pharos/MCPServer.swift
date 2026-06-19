import Foundation

#if !APP_STORE

/// A minimal, hand-rolled MCP (Model Context Protocol) server over stdio.
///
/// Speaks JSON-RPC 2.0 with newline-delimited JSON. `stdout` is the protocol
/// channel — only JSON-RPC response lines are ever written there (and flushed).
/// Any diagnostics go to `stderr`. The loop blocks on `stdin`, exiting 0 at EOF.
///
/// Wire shape:
///   request  → `{ "jsonrpc": "2.0", "id": …, "method": …, "params": … }`
///   response → `{ "jsonrpc": "2.0", "id": …, "result": … }`
///   error    → `{ "jsonrpc": "2.0", "id": …, "error": { "code", "message" } }`
///   notification (no `id`) → no response
enum MCPServer {

    // MARK: Entry point

    /// Blocking read/dispatch/write loop. Returns (and the process should exit 0)
    /// when stdin reaches EOF.
    static func run() {
        let stdin = FileHandle.standardInput
        var buffer = Data()

        while true {
            // Read a chunk; empty Data signals EOF.
            let chunk = stdin.availableData
            if chunk.isEmpty {
                break   // EOF → exit 0
            }
            buffer.append(chunk)

            // Drain every complete newline-terminated line from the buffer.
            while let nl = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                buffer.removeSubrange(buffer.startIndex...nl)
                handleLine(lineData)
            }
        }
    }

    // MARK: Line handling

    private static func handleLine(_ lineData: Data) {
        // Skip blank/whitespace-only lines silently.
        let trimmed = lineData.trimmedASCIIWhitespace()
        guard !trimmed.isEmpty else { return }

        guard
            let obj = try? JSONSerialization.jsonObject(with: trimmed),
            let dict = obj as? [String: Any]
        else {
            // Parse error — emit a JSON-RPC parse error with null id.
            writeError(id: NSNull(), code: -32_700, message: "Parse error")
            return
        }

        let method = dict["method"] as? String
        let id = dict["id"]   // absent for notifications

        guard let method else {
            // Not a request and not a notification we understand → ignore.
            return
        }

        // Notifications have no `id` and never get a response.
        let isNotification = (id == nil)

        switch method {
        case "initialize":
            guard let id else { return }
            writeResult(id: id, result: initializeResult())

        case "notifications/initialized", "initialized":
            // Notification — no response.
            return

        case "tools/list":
            guard let id else { return }
            writeResult(id: id, result: ["tools": toolDefinitions()])

        case "tools/call":
            guard let id else { return }
            let params = dict["params"] as? [String: Any] ?? [:]
            let callResult = callTool(params: params)
            writeResult(id: id, result: callResult)

        case "ping":
            guard let id else { return }
            writeResult(id: id, result: [String: Any]())

        default:
            if isNotification { return }   // unknown notification → ignore
            writeError(id: id ?? NSNull(), code: -32_601,
                       message: "Method not found: \(method)")
        }
    }

    // MARK: initialize

    private static func initializeResult() -> [String: Any] {
        [
            "protocolVersion": "2024-11-05",
            "capabilities": ["tools": [String: Any]()],
            "serverInfo": ["name": "pharos", "version": "0.1.0"],
        ]
    }

    // MARK: tools/list

    private static func toolDefinitions() -> [[String: Any]] {
        let stringSchema: (String) -> [String: Any] = { desc in
            ["type": "string", "description": desc]
        }
        // A schema for a single required `project` argument, reused by many tools.
        let projectOnly: (String) -> [String: Any] = { verb in
            [
                "type": "object",
                "properties": [
                    "project": stringSchema("Project name (as shown by list_projects)."),
                ],
                "required": ["project"],
                "additionalProperties": false,
            ]
        }
        let agentEnum: [String: Any] = [
            "type": "string",
            "enum": ["claude", "codex"],
            "description": "Which agent.",
        ]
        return [
            // -- Read tools --
            [
                "name": "list_projects",
                "description": "List all projects Pharos manages: name, local path, tags, notes, and yolo/tmux defaults.",
                "inputSchema": [
                    "type": "object",
                    "properties": [String: Any](),
                    "additionalProperties": false,
                ],
            ],
            [
                "name": "list_groups",
                "description": "List all groups with the number of projects in each.",
                "inputSchema": [
                    "type": "object",
                    "properties": [String: Any](),
                    "additionalProperties": false,
                ],
            ],
            [
                "name": "git_status",
                "description": "Git status for a project: branch, dirty flag, ahead/behind, and last commit.",
                "inputSchema": projectOnly("inspect"),
            ],
            [
                "name": "list_worktrees",
                "description": "List a project's git worktrees: name, branch, and path.",
                "inputSchema": projectOnly("inspect"),
            ],
            [
                "name": "list_sessions",
                "description": "List past agent sessions for a project, newest first: id and title.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "project": stringSchema("Project name (as shown by list_projects)."),
                        "agent": agentEnum,
                    ],
                    "required": ["project", "agent"],
                    "additionalProperties": false,
                ],
            ],
            // -- Action tools --
            [
                "name": "launch_agent",
                "description": "Launch a coding agent (Claude Code or Codex) in a project's local directory, in the configured terminal.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "project": stringSchema("Project name (as shown by list_projects)."),
                        "agent": agentEnum,
                        "yolo": [
                            "type": "boolean",
                            "description": "Launch in yolo mode (skip permission prompts). Default true.",
                        ],
                        "tmux": [
                            "type": "boolean",
                            "description": "Launch inside a persistent tmux session. Default false.",
                        ],
                    ],
                    "required": ["project", "agent"],
                    "additionalProperties": false,
                ],
            ],
            [
                "name": "resume_session",
                "description": "Resume a past agent session by id in a project's local directory.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "project": stringSchema("Project name (as shown by list_projects)."),
                        "agent": agentEnum,
                        "session_id": stringSchema("Session id (as shown by list_sessions)."),
                    ],
                    "required": ["project", "agent", "session_id"],
                    "additionalProperties": false,
                ],
            ],
            [
                "name": "run_playbook",
                "description": "Run one of a project's saved playbooks (a named command) in the configured terminal.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "project": stringSchema("Project name (as shown by list_projects)."),
                        "playbook": stringSchema("Playbook name attached to the project."),
                    ],
                    "required": ["project", "playbook"],
                    "additionalProperties": false,
                ],
            ],
            [
                "name": "open_terminal",
                "description": "Open the configured terminal at a project's local directory.",
                "inputSchema": projectOnly("open"),
            ],
            [
                "name": "open_editor",
                "description": "Open the configured editor at a project's local directory.",
                "inputSchema": projectOnly("open"),
            ],
            [
                "name": "reveal_in_finder",
                "description": "Reveal a project's local directory in Finder.",
                "inputSchema": projectOnly("reveal"),
            ],
            // -- Write tools (mutate the registry) --
            [
                "name": "add_project",
                "description": "Add a new project to the registry.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "name": stringSchema("Unique project name."),
                        "localPath": stringSchema("Absolute path to the local checkout (optional)."),
                        "githubRemote": stringSchema("GitHub remote URL (optional)."),
                        "tags": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Group memberships (optional).",
                        ],
                        "notes": stringSchema("Human description (optional)."),
                    ],
                    "required": ["name"],
                    "additionalProperties": false,
                ],
            ],
            [
                "name": "remove_project",
                "description": "Remove a project from the registry by name.",
                "inputSchema": projectOnly("remove"),
            ],
            [
                "name": "rename_project",
                "description": "Rename a project.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "name": stringSchema("Current project name."),
                        "new_name": stringSchema("New project name."),
                    ],
                    "required": ["name", "new_name"],
                    "additionalProperties": false,
                ],
            ],
            [
                "name": "set_description",
                "description": "Set a project's notes/description.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "name": stringSchema("Project name."),
                        "description": stringSchema("Description text (notes)."),
                    ],
                    "required": ["name", "description"],
                    "additionalProperties": false,
                ],
            ],
            [
                "name": "add_to_group",
                "description": "Add a project to a group (creates the group if needed).",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "name": stringSchema("Project name."),
                        "group": stringSchema("Group name."),
                    ],
                    "required": ["name", "group"],
                    "additionalProperties": false,
                ],
            ],
            [
                "name": "remove_from_group",
                "description": "Remove a project from a group.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "name": stringSchema("Project name."),
                        "group": stringSchema("Group name."),
                    ],
                    "required": ["name", "group"],
                    "additionalProperties": false,
                ],
            ],
            [
                "name": "create_group",
                "description": "Create an empty group.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "name": stringSchema("Group name."),
                    ],
                    "required": ["name"],
                    "additionalProperties": false,
                ],
            ],
            [
                "name": "delete_group",
                "description": "Delete a group and strip its tag from all projects.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "name": stringSchema("Group name."),
                    ],
                    "required": ["name"],
                    "additionalProperties": false,
                ],
            ],
            [
                "name": "set_yolo",
                "description": "Set a project's yolo default (skip permission prompts on launch).",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "name": stringSchema("Project name."),
                        "value": ["type": "boolean", "description": "New yolo value."],
                    ],
                    "required": ["name", "value"],
                    "additionalProperties": false,
                ],
            ],
            [
                "name": "set_tmux",
                "description": "Set a project's tmux default (launch agents inside a persistent tmux session).",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "name": stringSchema("Project name."),
                        "value": ["type": "boolean", "description": "New tmux value."],
                    ],
                    "required": ["name", "value"],
                    "additionalProperties": false,
                ],
            ],
        ]
    }

    // MARK: tools/call

    /// Dispatch a `tools/call`. Always returns an MCP tool result dict
    /// (`{ content: [...] , isError? }`) — tool-level failures are reported via
    /// `isError: true`, not JSON-RPC errors.
    private static func callTool(params: [String: Any]) -> [String: Any] {
        guard let name = params["name"] as? String else {
            return errorContent("Missing tool name.")
        }
        let args = params["arguments"] as? [String: Any] ?? [:]

        switch name {
        // Read
        case "list_projects":   return listProjects()
        case "list_groups":     return listGroups()
        case "git_status":      return gitStatus(args)
        case "list_worktrees":  return listWorktrees(args)
        case "list_sessions":   return listSessions(args)
        // Action
        case "launch_agent":    return launchAgent(args)
        case "resume_session":  return resumeSession(args)
        case "run_playbook":    return runPlaybook(args)
        case "open_terminal":   return openTerminal(args)
        case "open_editor":     return openEditor(args)
        case "reveal_in_finder": return revealInFinder(args)
        // Write
        case "add_project":      return addProject(args)
        case "remove_project":   return removeProject(args)
        case "rename_project":   return renameProject(args)
        case "set_description":  return setDescription(args)
        case "add_to_group":     return addToGroup(args)
        case "remove_from_group": return removeFromGroup(args)
        case "create_group":     return createGroup(args)
        case "delete_group":     return deleteGroup(args)
        case "set_yolo":         return setYolo(args)
        case "set_tmux":         return setTmux(args)
        default:
            return errorContent("Unknown tool: \(name)")
        }
    }

    // MARK: Tool implementations

    private static func listProjects() -> [String: Any] {
        let projects = loadProjects()
        let rows: [[String: Any]] = projects.map { p in
            [
                "name": p.name,
                "localPath": p.localPath ?? NSNull(),
                "githubRemote": p.githubRemote ?? NSNull(),
                "tags": p.tags,
                "notes": p.notes,
                "yolo": p.yolo,
                "tmux": p.tmux,
            ]
        }
        let payload: [String: Any] = ["projects": rows, "count": rows.count]
        return textContent(prettyJSON(payload))
    }

    private static func listGroups() -> [String: Any] {
        let store = loadStore()
        let rows: [[String: Any]] = store.groups
            .sorted { $0.lowercased() < $1.lowercased() }
            .map { g in
                ["name": g, "count": store.projects.filter { $0.tags.contains(g) }.count]
            }
        let payload: [String: Any] = ["groups": rows, "count": rows.count]
        return textContent(prettyJSON(payload))
    }

    private static func gitStatus(_ args: [String: Any]) -> [String: Any] {
        guard let (project, path) = resolveLocalProject(args) else {
            return projectResolutionError(args)
        }
        let info = runBlocking { await GitService.info(for: path) }
        guard info.isRepo else {
            return textContent("'\(project.name)' is not a git repository.")
        }
        let payload: [String: Any] = [
            "project": project.name,
            "branch": info.branch,
            "dirty": info.isDirty,
            "ahead": info.ahead,
            "behind": info.behind,
            "lastCommit": [
                "hash": info.lastCommitHash,
                "subject": info.lastCommitSubject,
                "relative": info.lastCommitRelative,
            ],
        ]
        return textContent(prettyJSON(payload))
    }

    private static func listWorktrees(_ args: [String: Any]) -> [String: Any] {
        guard let (project, path) = resolveLocalProject(args) else {
            return projectResolutionError(args)
        }
        let trees = runBlocking { await GitService.worktrees(for: path) }
        let rows: [[String: Any]] = trees.map { wt in
            ["name": wt.name, "branch": wt.branch, "path": wt.path, "isMain": wt.isMain]
        }
        let payload: [String: Any] = ["project": project.name, "worktrees": rows, "count": rows.count]
        return textContent(prettyJSON(payload))
    }

    private static func listSessions(_ args: [String: Any]) -> [String: Any] {
        guard let agentRaw = args["agent"] as? String,
              let kind = AgentKind(rawValue: agentRaw) else {
            return errorContent("Argument 'agent' must be \"claude\" or \"codex\".")
        }
        guard let (project, path) = resolveLocalProject(args) else {
            return projectResolutionError(args)
        }
        let sessions = runBlocking { () async -> [AgentSession] in
            switch kind {
            case .claude: return await SessionsService.claudeSessions(for: path)
            case .codex:  return await SessionsService.codexSessions(for: path)
            }
        }
        // SessionsService already returns newest-first.
        let rows: [[String: Any]] = sessions.map { ["id": $0.id, "title": $0.title] }
        let payload: [String: Any] = [
            "project": project.name, "agent": kind.rawValue,
            "sessions": rows, "count": rows.count,
        ]
        return textContent(prettyJSON(payload))
    }

    private static func launchAgent(_ args: [String: Any]) -> [String: Any] {
        guard let projectName = args["project"] as? String, !projectName.isEmpty else {
            return errorContent("Missing required argument: project")
        }
        guard let agentRaw = args["agent"] as? String,
              let kind = AgentKind(rawValue: agentRaw) else {
            return errorContent("Argument 'agent' must be \"claude\" or \"codex\".")
        }
        guard let project = findProject(projectName) else {
            return errorContent("Project not found: \(projectName)")
        }
        guard let path = project.localPath, !path.isEmpty else {
            return errorContent("Project '\(projectName)' has no local path.")
        }

        let yolo = (args["yolo"] as? Bool) ?? true
        let tmux = (args["tmux"] as? Bool) ?? false
        let terminal = persistedTerminal()
        let tmuxName = LaunchService.tmuxSessionName(project, kind)

        // LaunchService shells out via /usr/bin/open / osascript, which work
        // headless. UI access (NSWorkspace) is not required for these paths.
        runOnMain {
            LaunchService.launchAgent(kind, atPath: path, yolo: yolo, tmux: tmux,
                                      tmuxName: tmuxName, terminal: terminal, extraArgs: "")
        }

        let mode = [yolo ? "yolo" : nil, tmux ? "tmux" : nil].compactMap { $0 }.joined(separator: ", ")
        let modeSuffix = mode.isEmpty ? "" : " (\(mode))"
        return textContent("Launched \(kind.label) in '\(project.name)' at \(path) using \(terminal.label)\(modeSuffix).")
    }

    private static func openTerminal(_ args: [String: Any]) -> [String: Any] {
        guard let (project, path) = resolveLocalProject(args) else {
            return projectResolutionError(args)
        }
        let terminal = persistedTerminal()
        runOnMain { LaunchService.openTerminal(at: path, terminal: terminal) }
        return textContent("Opened \(terminal.label) at '\(project.name)' (\(path)).")
    }

    private static func openEditor(_ args: [String: Any]) -> [String: Any] {
        guard let (project, path) = resolveLocalProject(args) else {
            return projectResolutionError(args)
        }
        let editor = persistedEditor()
        runOnMain { LaunchService.openEditor(editor, path: path) }
        return textContent("Opened \(editor.label) at '\(project.name)' (\(path)).")
    }

    private static func revealInFinder(_ args: [String: Any]) -> [String: Any] {
        guard let (project, path) = resolveLocalProject(args) else {
            return projectResolutionError(args)
        }
        runOnMain { LaunchService.revealInFinder(path) }
        return textContent("Revealed '\(project.name)' (\(path)) in Finder.")
    }

    private static func resumeSession(_ args: [String: Any]) -> [String: Any] {
        guard let agentRaw = args["agent"] as? String,
              let kind = AgentKind(rawValue: agentRaw) else {
            return errorContent("Argument 'agent' must be \"claude\" or \"codex\".")
        }
        guard let sessionID = args["session_id"] as? String, !sessionID.isEmpty else {
            return errorContent("Missing required argument: session_id")
        }
        guard let (project, path) = resolveLocalProject(args) else {
            return projectResolutionError(args)
        }
        let terminal = persistedTerminal()
        let session = AgentSession(id: sessionID, kind: kind, title: "",
                                   modified: Date(), resumeCwd: path)
        runOnMain {
            LaunchService.resumeSession(session, project: project, terminal: terminal)
        }
        return textContent("Resumed \(kind.label) session \(sessionID) in '\(project.name)' using \(terminal.label).")
    }

    private static func runPlaybook(_ args: [String: Any]) -> [String: Any] {
        guard let playbookName = args["playbook"] as? String, !playbookName.isEmpty else {
            return errorContent("Missing required argument: playbook")
        }
        guard let (project, path) = resolveLocalProject(args) else {
            return projectResolutionError(args)
        }
        // Exact name first, then case-insensitive.
        let playbook = project.playbooks.first { $0.name == playbookName }
            ?? project.playbooks.first { $0.name.caseInsensitiveCompare(playbookName) == .orderedSame }
        guard let playbook else {
            return errorContent("Playbook '\(playbookName)' not found in '\(project.name)'.")
        }
        let terminal = persistedTerminal()
        runOnMain {
            LaunchService.runCommand(playbook.command, at: path, terminal: terminal)
        }
        return textContent("Ran playbook '\(playbook.name)' (\(playbook.command)) in '\(project.name)' using \(terminal.label).")
    }

    // MARK: Write tools (mutate the registry)

    private static func addProject(_ args: [String: Any]) -> [String: Any] {
        guard let name = (args["name"] as? String)?.trimmingCharacters(in: .whitespaces),
              !name.isEmpty else {
            return errorContent("Missing required argument: name")
        }
        var store = loadStore()
        if projectIndex(name, in: store.projects) != nil {
            return errorContent("A project named '\(name)' already exists.")
        }
        let localPath = (args["localPath"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let remote = (args["githubRemote"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let tags = (args["tags"] as? [Any])?.compactMap { $0 as? String } ?? []
        let notes = (args["notes"] as? String) ?? ""
        let project = Project(name: name, localPath: localPath, githubRemote: remote,
                              tags: tags, notes: notes)
        store.projects.append(project)
        backfillGroups(&store)
        saveStore(store)
        return textContent("Added project '\(name)'.")
    }

    private static func removeProject(_ args: [String: Any]) -> [String: Any] {
        guard let name = args["project"] as? String, !name.isEmpty else {
            return errorContent("Missing required argument: project")
        }
        var store = loadStore()
        guard let idx = projectIndex(name, in: store.projects) else {
            return errorContent("Project not found: \(name)")
        }
        let removed = store.projects.remove(at: idx).name
        saveStore(store)
        return textContent("Removed project '\(removed)'.")
    }

    private static func renameProject(_ args: [String: Any]) -> [String: Any] {
        guard let name = args["name"] as? String, !name.isEmpty else {
            return errorContent("Missing required argument: name")
        }
        guard let newName = (args["new_name"] as? String)?.trimmingCharacters(in: .whitespaces),
              !newName.isEmpty else {
            return errorContent("Missing required argument: new_name")
        }
        var store = loadStore()
        guard let idx = projectIndex(name, in: store.projects) else {
            return errorContent("Project not found: \(name)")
        }
        // Reject a clash with a *different* existing project.
        if let clash = projectIndex(newName, in: store.projects), clash != idx {
            return errorContent("A project named '\(newName)' already exists.")
        }
        let old = store.projects[idx].name
        store.projects[idx].name = newName
        saveStore(store)
        return textContent("Renamed project '\(old)' to '\(newName)'.")
    }

    private static func setDescription(_ args: [String: Any]) -> [String: Any] {
        guard let name = args["name"] as? String, !name.isEmpty else {
            return errorContent("Missing required argument: name")
        }
        guard let description = args["description"] as? String else {
            return errorContent("Missing required argument: description")
        }
        var store = loadStore()
        guard let idx = projectIndex(name, in: store.projects) else {
            return errorContent("Project not found: \(name)")
        }
        store.projects[idx].notes = description
        saveStore(store)
        return textContent("Set description for '\(store.projects[idx].name)'.")
    }

    private static func addToGroup(_ args: [String: Any]) -> [String: Any] {
        guard let name = args["name"] as? String, !name.isEmpty else {
            return errorContent("Missing required argument: name")
        }
        guard let group = (args["group"] as? String)?.trimmingCharacters(in: .whitespaces),
              !group.isEmpty else {
            return errorContent("Missing required argument: group")
        }
        var store = loadStore()
        guard let idx = projectIndex(name, in: store.projects) else {
            return errorContent("Project not found: \(name)")
        }
        if !store.projects[idx].tags.contains(group) {
            store.projects[idx].tags.append(group)
        }
        if !store.groups.contains(group) { store.groups.append(group) }
        backfillGroups(&store)
        saveStore(store)
        return textContent("Added '\(store.projects[idx].name)' to group '\(group)'.")
    }

    private static func removeFromGroup(_ args: [String: Any]) -> [String: Any] {
        guard let name = args["name"] as? String, !name.isEmpty else {
            return errorContent("Missing required argument: name")
        }
        guard let group = (args["group"] as? String), !group.isEmpty else {
            return errorContent("Missing required argument: group")
        }
        var store = loadStore()
        guard let idx = projectIndex(name, in: store.projects) else {
            return errorContent("Project not found: \(name)")
        }
        store.projects[idx].tags.removeAll { $0 == group }
        saveStore(store)
        return textContent("Removed '\(store.projects[idx].name)' from group '\(group)'.")
    }

    private static func createGroup(_ args: [String: Any]) -> [String: Any] {
        guard let name = (args["name"] as? String)?.trimmingCharacters(in: .whitespaces),
              !name.isEmpty else {
            return errorContent("Missing required argument: name")
        }
        var store = loadStore()
        if store.groups.contains(name) {
            return textContent("Group '\(name)' already exists.")
        }
        store.groups.append(name)
        store.groups.sort { $0.lowercased() < $1.lowercased() }
        saveStore(store)
        return textContent("Created group '\(name)'.")
    }

    private static func deleteGroup(_ args: [String: Any]) -> [String: Any] {
        guard let name = args["name"] as? String, !name.isEmpty else {
            return errorContent("Missing required argument: name")
        }
        var store = loadStore()
        store.groups.removeAll { $0 == name }
        for i in store.projects.indices { store.projects[i].tags.removeAll { $0 == name } }
        saveStore(store)
        return textContent("Deleted group '\(name)'.")
    }

    private static func setYolo(_ args: [String: Any]) -> [String: Any] {
        setFlag(args, keyPath: \.yolo, label: "yolo")
    }

    private static func setTmux(_ args: [String: Any]) -> [String: Any] {
        setFlag(args, keyPath: \.tmux, label: "tmux")
    }

    /// Shared mutator for the boolean project flags (yolo / tmux).
    private static func setFlag(_ args: [String: Any],
                                keyPath: WritableKeyPath<Project, Bool>,
                                label: String) -> [String: Any] {
        guard let name = args["name"] as? String, !name.isEmpty else {
            return errorContent("Missing required argument: name")
        }
        guard let value = args["value"] as? Bool else {
            return errorContent("Argument 'value' must be a boolean.")
        }
        var store = loadStore()
        guard let idx = projectIndex(name, in: store.projects) else {
            return errorContent("Project not found: \(name)")
        }
        store.projects[idx][keyPath: keyPath] = value
        saveStore(store)
        return textContent("Set \(label) = \(value) for '\(store.projects[idx].name)'.")
    }

    // MARK: Project resolution helpers

    /// Resolve `args["project"]` to a project that has a non-empty local path.
    private static func resolveLocalProject(_ args: [String: Any]) -> (Project, String)? {
        guard let projectName = args["project"] as? String,
              let project = findProject(projectName),
              let path = project.localPath, !path.isEmpty else {
            return nil
        }
        return (project, path)
    }

    /// A precise error message for why `resolveLocalProject` failed.
    private static func projectResolutionError(_ args: [String: Any]) -> [String: Any] {
        guard let projectName = args["project"] as? String, !projectName.isEmpty else {
            return errorContent("Missing required argument: project")
        }
        guard let project = findProject(projectName) else {
            return errorContent("Project not found: \(projectName)")
        }
        if (project.localPath?.isEmpty ?? true) {
            return errorContent("Project '\(projectName)' has no local path.")
        }
        return errorContent("Could not resolve project: \(projectName)")
    }

    private static func findProject(_ name: String) -> Project? {
        let projects = loadProjects()
        // Exact match first, then case-insensitive.
        if let exact = projects.first(where: { $0.name == name }) { return exact }
        return projects.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Index of a project in a given list: exact name first, then case-insensitive.
    private static func projectIndex(_ name: String, in projects: [Project]) -> Int? {
        if let exact = projects.firstIndex(where: { $0.name == name }) { return exact }
        return projects.firstIndex { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Ensure every tag used by a project exists as a group, then sort groups —
    /// mirrors `ProjectStore.backfillGroups()`.
    private static func backfillGroups(_ store: inout StoreData) {
        for tag in store.projects.flatMap({ $0.tags }) where !store.groups.contains(tag) {
            store.groups.append(tag)
        }
        store.groups.sort { $0.lowercased() < $1.lowercased() }
    }

    // MARK: Registry loading & saving

    /// Location of the shared registry file (same path ProjectStore uses).
    private static var registryURL: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pharos", isDirectory: true)
            .appendingPathComponent("projects.json")
    }

    /// Read `~/Library/Application Support/Pharos/projects.json` and decode the
    /// `StoreData` registry. Tolerates a missing/legacy file by returning [].
    private static func loadProjects() -> [Project] {
        loadStore().projects
    }

    /// Read the full `StoreData` (projects + groups). Tolerates a missing file
    /// (returns an empty store) and migrates the older flat-array format.
    private static func loadStore() -> StoreData {
        guard let data = try? Data(contentsOf: registryURL) else { return StoreData() }
        let decoder = JSONDecoder()
        if let store = try? decoder.decode(StoreData.self, from: data) {
            return store
        }
        // Migrate older flat-array format, mirroring ProjectStore.load().
        if let legacy = try? decoder.decode([Project].self, from: data) {
            return StoreData(projects: legacy, groups: [])
        }
        return StoreData()
    }

    /// Write the registry back, pretty-printed with sorted keys and an atomic
    /// write — mirroring `ProjectStore.save()` so the GUI's file watcher picks it
    /// up. Ensures the containing directory exists first.
    private static func saveStore(_ store: StoreData) {
        let dir = registryURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(store) {
            try? data.write(to: registryURL, options: .atomic)
        }
    }

    // MARK: Persisted prefs

    private static func persistedTerminal() -> TerminalApp {
        let raw = UserDefaults.standard.string(forKey: "pharos.terminal") ?? ""
        return TerminalApp(rawValue: raw) ?? .ghostty
    }

    private static func persistedEditor() -> EditorApp {
        let raw = UserDefaults.standard.string(forKey: "pharos.editor") ?? ""
        return EditorApp(rawValue: raw) ?? .vscode
    }

    // MARK: Main-actor bridging

    /// `LaunchService` is not actor-isolated but touches AppKit-adjacent APIs;
    /// run its calls on the main thread to be safe. Blocks until done.
    private static func runOnMain(_ work: @escaping @Sendable () -> Void) {
        if Thread.isMainThread {
            work()
        } else {
            DispatchQueue.main.sync(execute: work)
        }
    }

    /// Drive an async operation to completion from the synchronous dispatch loop.
    /// The MCP loop runs on a single thread and never has a live actor context,
    /// so blocking on a semaphore here is safe (the detached task hops to a
    /// background executor).
    private static func runBlocking<T: Sendable>(_ work: @escaping @Sendable () async -> T) -> T {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox<T>()
        Task.detached(priority: .userInitiated) {
            let value = await work()
            box.value = value
            semaphore.signal()
        }
        semaphore.wait()
        return box.value!
    }

    // MARK: Response writers

    private static func writeResult(id: Any, result: [String: Any]) {
        var payload: [String: Any] = ["jsonrpc": "2.0", "result": result]
        payload["id"] = id
        writeJSON(payload)
    }

    private static func writeError(id: Any, code: Int, message: String) {
        var payload: [String: Any] = [
            "jsonrpc": "2.0",
            "error": ["code": code, "message": message],
        ]
        payload["id"] = id
        writeJSON(payload)
    }

    /// Serialize `payload` to a single newline-terminated line on stdout and flush.
    private static func writeJSON(_ payload: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else {
            logStderr("failed to serialize response")
            return
        }
        var line = data
        line.append(0x0A)   // newline-delimited
        let out = FileHandle.standardOutput
        out.write(line)
        // Force a flush so the client sees the response immediately.
        try? out.synchronize()
    }

    // MARK: content helpers

    private static func textContent(_ text: String) -> [String: Any] {
        ["content": [["type": "text", "text": text]]]
    }

    private static func errorContent(_ text: String) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": true]
    }

    private static func prettyJSON(_ obj: Any) -> String {
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
            let str = String(data: data, encoding: .utf8)
        else { return "{}" }
        return str
    }

    private static func logStderr(_ message: String) {
        FileHandle.standardError.write(Data("[pharos-mcp] \(message)\n".utf8))
    }
}

// MARK: - Concurrency helpers

/// A minimal box used to ferry an async result back to a blocking caller.
/// `@unchecked Sendable` is justified: the value is written exactly once by the
/// detached task before its semaphore signal, then read once after the wait —
/// the semaphore provides the necessary happens-before ordering.
private final class ResultBox<T: Sendable>: @unchecked Sendable {
    var value: T?
}

// MARK: - Data helpers

private extension Data {
    /// Trim leading/trailing ASCII whitespace (space, tab, CR, LF).
    func trimmedASCIIWhitespace() -> Data {
        let ws: Set<UInt8> = [0x20, 0x09, 0x0D, 0x0A]
        var start = startIndex
        var end = endIndex
        while start < end, ws.contains(self[start]) { start = index(after: start) }
        while end > start, ws.contains(self[index(before: end)]) { end = index(before: end) }
        return subdata(in: start..<end)
    }
}

#endif
