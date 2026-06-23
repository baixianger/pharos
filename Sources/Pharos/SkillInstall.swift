import Foundation

/// Installs the bundled agent skills (`mesh`, `pharos`, …) into a Claude Code
/// skills directory by symlink, so agents auto-load them. Resolves the skill
/// source in both the installed app (Contents/Resources/skills) and a dev build
/// (<repo>/skills). Codex (which uses AGENTS.md, not a skills dir) is not handled
/// here yet.
enum SkillInstall {
    /// The on-disk directory holding the bundled skills, or nil if not found.
    static func skillsDir() -> URL? {
        let fm = FileManager.default
        if let r = Bundle.main.resourceURL {
            let s = r.appendingPathComponent("skills", isDirectory: true)
            if fm.fileExists(atPath: s.path) { return s }
        }
        // Dev build: walk up from the executable for a `skills/` dir (robust to
        // the symlinked `.build/debug`).
        var dir = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).deletingLastPathComponent()
        for _ in 0..<6 {
            let s = dir.appendingPathComponent("skills", isDirectory: true)
            if fm.fileExists(atPath: s.path) { return s }
            let parent = dir.deletingLastPathComponent()
            if parent == dir { break }
            dir = parent
        }
        return nil
    }

    /// Names of the bundled skills (sub-directories of the skills dir).
    static func available() -> [String] {
        guard let dir = skillsDir(),
              let items = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        return items
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { $0.lastPathComponent }
            .sorted()
    }

    /// Symlink skill(s) into a Claude skills dir. `projectDir == nil` → global
    /// `~/.claude/skills`; otherwise `<projectDir>/.claude/skills`. Returns
    /// human-readable status lines.
    @discardableResult
    static func install(_ name: String, projectDir: String?) -> [String] {
        guard let src = skillsDir() else { return ["Couldn't locate the bundled skills."] }
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let base = (projectDir.map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: home))
            .appendingPathComponent(".claude/skills", isDirectory: true)
        let names = (name == "all") ? available() : [name]
        guard !names.isEmpty else { return ["No skills to install."] }

        var out: [String] = []
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        for n in names {
            let source = src.appendingPathComponent(n, isDirectory: true)
            guard fm.fileExists(atPath: source.path) else { out.append("unknown skill: \(n)"); continue }
            let dest = base.appendingPathComponent(n, isDirectory: true)
            if (try? fm.destinationOfSymbolicLink(atPath: dest.path)) != nil {
                try? fm.removeItem(at: dest)                       // replace our old symlink
            } else if fm.fileExists(atPath: dest.path) {
                out.append("\(n): a real directory is at \(dest.path) — skipped"); continue
            }
            do {
                try fm.createSymbolicLink(at: dest, withDestinationURL: source)
                out.append("installed \(n) → \(dest.path.replacingOccurrences(of: home, with: "~"))")
            } catch {
                out.append("\(n): \(error.localizedDescription)")
            }
        }
        return out
    }
}
