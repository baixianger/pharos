import Foundation

/// The `pharos` command-line front door — Pharos's interface for agents and
/// scripts. A thin shim: it parses argv, calls `PharosCore`, and prints the
/// result. Reads print a human table by default and JSON under `--json`;
/// mutations print a one-line confirmation. Exit codes: 0 ok, 1 operation
/// error, 2 usage error.
///
/// An agent (or a script) can shell out to it directly, e.g.
///   pharos list --json
///   pharos launch myrepo claude --tmux
///   pharos remove myrepo            # reversible — see `pharos trash`
enum CLI {

    /// True if `token` should route to the CLI rather than the GUI. Any bare
    /// word (not starting with `-`) is treated as a CLI subcommand — known or a
    /// typo — so typos surface a usage error instead of silently opening the GUI.
    /// GUI launch arguments from LaunchServices all start with `-` (`-psn_…`,
    /// `-NSDocumentRevisionsDebugMode`, …) and fall through to the app, except
    /// the explicit help/version flags handled here.
    static func isCommand(_ token: String) -> Bool {
        if ["--help", "-h", "--version", "-v"].contains(token) { return true }
        return !token.hasPrefix("-")
    }

    // MARK: Entry

    /// Run the CLI. `args` excludes the program name. Returns the process exit code.
    static func run(_ args: [String]) -> Int32 {
        guard let command = args.first else { printUsage(); return 0 }
        let rest = Array(args.dropFirst())

        switch command {
        case "help", "--help", "-h":
            printUsage(); return 0
        case "version", "--version", "-v":
            print("pharos \(version)"); return 0
        default:
            break
        }

        let p = parse(rest)

        do {
            switch command {
            // Reads
            case "list", "projects":
                return emit(PharosCore.listProjects(), json: p.has("json"))
            case "groups":
                return emit(PharosCore.listGroups(), json: p.has("json"))
            case "trash":
                return try runTrash(p)
            case "git":
                return emit(try PharosCore.gitStatus(project: p.arg(0) ?? ""), json: p.has("json"))
            case "worktrees":
                return emit(try PharosCore.listWorktrees(project: p.arg(0) ?? ""), json: p.has("json"))
            case "sessions":
                return emit(try PharosCore.listSessions(project: p.arg(0) ?? "", agent: p.arg(1) ?? ""), json: p.has("json"))

            // Actions
            case "launch":
                let yolo: Bool? = p.has("no-yolo") ? false : (p.has("yolo") ? true : nil)
                let tmux: Bool? = p.has("tmux") ? true : nil
                return ok(try PharosCore.launchAgent(project: p.arg(0), agent: p.arg(1), yolo: yolo, tmux: tmux, source: .cli))
            case "resume":
                return ok(try PharosCore.resumeSession(project: p.arg(0), agent: p.arg(1), sessionID: p.arg(2)))
            case "playbook":
                return ok(try PharosCore.runPlaybook(project: p.arg(0), playbook: p.arg(1)))
            case "open":
                return ok(try PharosCore.openTerminal(project: p.arg(0)))
            case "editor":
                return ok(try PharosCore.openEditor(project: p.arg(0)))
            case "reveal":
                return ok(try PharosCore.revealInFinder(project: p.arg(0)))

            // Writes
            case "add":
                return ok(try PharosCore.addProject(name: p.arg(0), localPath: p.opt("path"),
                                                    githubRemote: p.opt("remote"),
                                                    tags: p.all("tag"), notes: p.opt("notes")))
            case "remove":
                let message = try PharosCore.removeProject(name: p.arg(0))
                AuditLog.record(actor: .cli, action: "remove_project", detail: p.arg(0) ?? "")
                return ok(message)
            case "rename":
                return ok(try PharosCore.renameProject(name: p.arg(0), newName: p.arg(1)))
            case "describe":
                // Everything after the project name is the description text.
                let text = p.positional.dropFirst().joined(separator: " ")
                return ok(try PharosCore.setDescription(name: p.arg(0), description: text))
            case "group":
                return try runGroup(p)
            case "issue":
                return try runIssue(p)
            case "update":
                return try runUpdate(p)
            case "attach":
                return try runAttach(p)
            case "path":
                return ok(try PharosCore.setLocalPath(project: p.arg(0), path: p.arg(1), clear: p.has("clear")))
            case "host":
                return emit(PharosCore.hostInfo(), json: p.has("json"))
            case "yolo":
                return ok(try PharosCore.setFlag(name: p.arg(0), flag: "yolo", value: try boolArg(p.arg(1), label: "on|off")))
            case "tmux":
                return ok(try PharosCore.setFlag(name: p.arg(0), flag: "tmux", value: try boolArg(p.arg(1), label: "on|off")))

            default:
                return usageError("Unknown command: \(command)")
            }
        } catch let e as CoreError {
            return fail(e.message)
        } catch let e as UsageError {
            return usageError(e.message)
        } catch {
            return fail("\(error)")
        }
    }

    // MARK: Sub-dispatchers

    private static func runTrash(_ p: Parsed) throws -> Int32 {
        switch p.arg(0) {
        case nil, "list":
            return emit(PharosCore.listTrash(), json: p.has("json"))
        case "restore":
            return ok(try PharosCore.restoreTrash(id: p.arg(1)))
        case "empty":
            return ok(PharosCore.emptyTrash())
        case let other?:
            return usageError("Unknown trash subcommand: \(other) (use list | restore <id> | empty)")
        }
    }

    private static func runGroup(_ p: Parsed) throws -> Int32 {
        switch p.arg(0) {
        case "create":
            return ok(try PharosCore.createGroup(name: p.arg(1)))
        case "delete":
            let message = try PharosCore.deleteGroup(name: p.arg(1))
            AuditLog.record(actor: .cli, action: "delete_group", detail: p.arg(1) ?? "")
            return ok(message)
        case "add":
            return ok(try PharosCore.addToGroup(name: p.arg(1), group: p.arg(2)))
        case "remove":
            return ok(try PharosCore.removeFromGroup(name: p.arg(1), group: p.arg(2)))
        default:
            return usageError("Usage: pharos group <create|delete|add|remove> …")
        }
    }

    private static func runIssue(_ p: Parsed) throws -> Int32 {
        let number = p.arg(2).flatMap { Int($0) }
        switch p.arg(0) {
        case "list", nil:
            return emit(try PharosCore.issueList(project: p.arg(1), all: p.has("all")), json: p.has("json"))
        case "add":
            return ok(try PharosCore.issueAdd(project: p.arg(1), title: p.arg(2),
                                              priority: p.opt("priority"), body: p.opt("body"),
                                              attach: p.all("attach")))
        case "status":
            return ok(try PharosCore.issueSetStatus(project: p.arg(1), number: number, status: p.arg(3)))
        case "priority":
            return ok(try PharosCore.issueSetPriority(project: p.arg(1), number: number, priority: p.arg(3)))
        case "start":
            let yolo: Bool? = p.has("no-yolo") ? false : (p.has("yolo") ? true : nil)
            let tmux: Bool? = p.has("tmux") ? true : nil
            return ok(try PharosCore.issueStart(project: p.arg(1), number: number, agent: p.arg(3),
                                                yolo: yolo, tmux: tmux, source: .cli))
        case "rm", "remove":
            let message = try PharosCore.issueRemove(project: p.arg(1), number: number)
            AuditLog.record(actor: .cli, action: "issue_remove", detail: "\(p.arg(1) ?? "")#\(number ?? 0)")
            return ok(message)
        case let other?:
            return usageError("Unknown issue subcommand: \(other) (use list|add|status|priority|start|rm)")
        }
    }

    private static func runAttach(_ p: Parsed) throws -> Int32 {
        let number = p.arg(2).flatMap { Int($0) }
        switch p.arg(0) {
        case "add":
            // Files are the positionals after <project> <#>, plus any --file values.
            let files = Array(p.positional.dropFirst(3)) + p.all("file")
            return ok(try PharosCore.attachAdd(project: p.arg(1), number: number, paths: files))
        case "list", nil:
            return emit(try PharosCore.attachList(project: p.arg(1), number: number), json: p.has("json"))
        case "rm", "remove":
            return ok(try PharosCore.attachRemove(project: p.arg(1), number: number, ref: p.arg(3)))
        case let other?:
            return usageError("Unknown attach subcommand: \(other) (use add|list|rm)")
        }
    }

    private static func runUpdate(_ p: Parsed) throws -> Int32 {
        switch p.arg(0) {
        case "list", nil:
            return emit(try PharosCore.updateList(project: p.arg(1)), json: p.has("json"))
        case "add":
            // Everything after the project name is the update text.
            let text = p.positional.dropFirst(2).joined(separator: " ")
            let issue = p.opt("issue").flatMap { Int($0) }
            return ok(try PharosCore.updateAdd(project: p.arg(1), body: text, issueNumber: issue))
        case let other?:
            return usageError("Unknown update subcommand: \(other) (use list|add)")
        }
    }

    // MARK: Output

    private static func ok(_ message: String) -> Int32 { print(message); return 0 }

    private static func emit(_ outcome: CoreOutcome, json: Bool) -> Int32 {
        if json, let payload = outcome.json {
            print(prettyJSON(payload))
        } else {
            print(outcome.text)
        }
        return 0
    }

    private static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
        return 1
    }

    private static func usageError(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("error: \(message)\n\nRun `pharos help` for usage.\n".utf8))
        return 2
    }

    // MARK: Argument parsing

    /// Marker error for bad usage (vs. a `CoreError` operation failure).
    struct UsageError: Error { let message: String }

    /// Parsed argv: positionals, single-valued options, repeatable options, and
    /// boolean flags.
    struct Parsed {
        var positional: [String] = []
        var options: [String: String] = [:]
        var multi: [String: [String]] = [:]
        var flags: Set<String> = []

        func arg(_ i: Int) -> String? { i < positional.count ? positional[i] : nil }
        func opt(_ key: String) -> String? { options[key] }
        func all(_ key: String) -> [String] { multi[key] ?? [] }
        func has(_ flag: String) -> Bool { flags.contains(flag) }
    }

    /// Flags that never take a value.
    private static let knownFlags: Set<String> = ["json", "tmux", "yolo", "no-yolo", "all", "clear"]

    static func parse(_ tokens: [String]) -> Parsed {
        var p = Parsed()
        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            if t == "--" {
                p.positional.append(contentsOf: tokens[(i + 1)...])
                break
            }
            if t.hasPrefix("--") {
                let body = String(t.dropFirst(2))
                if let eq = body.firstIndex(of: "=") {
                    let key = String(body[..<eq])
                    let val = String(body[body.index(after: eq)...])
                    p.options[key] = val
                    p.multi[key, default: []].append(val)
                } else if knownFlags.contains(body) {
                    p.flags.insert(body)
                } else if i + 1 < tokens.count, !tokens[i + 1].hasPrefix("-") {
                    let val = tokens[i + 1]
                    p.options[body] = val
                    p.multi[body, default: []].append(val)
                    i += 1
                } else {
                    p.flags.insert(body)
                }
            } else if t == "-j" {
                p.flags.insert("json")
            } else {
                p.positional.append(t)
            }
            i += 1
        }
        return p
    }

    private static func boolArg(_ value: String?, label: String) throws -> Bool {
        switch value?.lowercased() {
        case "on", "true", "1", "yes": return true
        case "off", "false", "0", "no": return false
        default: throw UsageError(message: "expected \(label), got \(value ?? "nothing")")
        }
    }

    // MARK: Misc

    private static var version: String { "0.1.0" }

    private static func prettyJSON(_ obj: Any) -> String {
        guard
            let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]),
            let str = String(data: data, encoding: .utf8)
        else { return "{}" }
        return str
    }

    private static func printUsage() {
        print("""
        pharos — Pharos project manager CLI. Agents and scripts drive Pharos here.

        USAGE
          pharos <command> [args] [--json]

        READ
          list                         List projects (alias: projects)
          groups                       List groups and their counts
          git <project>                Git status for a project
          worktrees <project>          List a project's git worktrees
          sessions <project> <agent>   List past sessions (agent: claude|codex)
          issue list <project> [--all] List issues (open only unless --all)
          update list <project>        Show the project-update feed
          trash [list]                 List soft-deleted items

        ISSUES & PROJECT LOG (single-user — no human assignees)
          issue add <project> "<title>" [--priority none|low|medium|high|urgent] [--body "…"] [--attach <file>]…
          issue status <project> <#> <backlog|todo|in_progress|done|canceled>
          issue priority <project> <#> <none|low|medium|high|urgent>
          issue start <project> <#> <agent> [--no-yolo] [--tmux]   Launch an agent ON an issue
          issue rm <project> <#>                                   (→ Trash, 30-day restore)
          attach add <project> <#> <file>…                         Attach files to an issue
          attach list <project> <#>                                List an issue's attachments
          attach rm <project> <#> <index|name>                     Remove an attachment
          update add <project> "<text>" [--issue <#>]              Log a progress note

        AGENTS / LAUNCH
          launch <project> <agent> [--no-yolo] [--tmux]   Launch an agent
          resume <project> <agent> <session_id>           Resume a past session
          playbook <project> <name>                       Run a saved playbook
          open <project>                                  Open the terminal there
          editor <project>                                Open the editor there
          reveal <project>                                Reveal in Finder

        REGISTRY (mutations are reversible via the Trash where noted)
          add <name> [--path P] [--remote URL] [--tag T]... [--notes N]
          remove <project>             Forget a project (→ Trash, 30-day restore)
          rename <project> <new-name>
          describe <project> <text…>   Set a project's notes
          group create <name>
          group delete <name>          (→ Trash, 30-day restore)
          group add <project> <group>
          group remove <project> <group>
          yolo <project> <on|off>
          tmux <project> <on|off>
          trash restore <id>           Restore a soft-deleted item
          trash empty                  Permanently purge the Trash

        MULTI-MACHINE (project data syncs; local paths are per-host)
          host                         Show this machine's host key
          path <project> <path>        Set THIS machine's local folder for a project
          path <project> --clear       Forget this machine's local folder

        OTHER
          help, version

        Add --json to any READ command for machine-readable output.
        Set PHAROS_REGISTRY=/path/to/projects.json to target an alternate store.
        """)
    }
}
