import Foundation

/// Discovers DSH's dynamic launch modes — its agent presets, which are Cordis
/// plugin compositions and therefore user-extensible.
///
/// This mirrors DSH's own discovery (ctx.agentPresets.list(), package
/// @deepseek-ai/dsh-agent-presets/src/discovery.ts): a preset is a directory
/// holding agent.cordis.yml, optionally beside a preset.yml whose name /
/// description are display text. The shipped set plus any preset under
/// ~/.dsh/.agent-presets/ is enumerated from disk, so a newly authored preset
/// appears here with no Pharos code change.
///
/// SEPARATION: the New Session UI is agent-agnostic. It renders the
/// [AgentLaunchOption] this returns and hands the chosen id back through the
/// generic launch seam; it never interprets what a preset means. DSH-specific
/// knowledge (preset ids, how a session composes from one) lives here, in the
/// adapter layer.
enum DSHLaunchDiscovery {
    static let shippedPresetNames = ["standard", "code", "minimal", "cordis"]

    private struct Preset {
        let id: String
        let name: String?
        let description: String?
    }

    static func presets() -> [AgentLaunchOption] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var dirs: [URL] = [home.appendingPathComponent(".dsh/.agent-presets")]
        if let dsh = resolveDSHExecutable() {
            dirs.append(dsh.deletingLastPathComponent().appendingPathComponent("config/agent-presets"))
            dirs.append(dsh.appendingPathComponent("config/agent-presets"))
        }

        var presets: [Preset] = []
        var seen = Set<String>()
        for dir in dirs {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { continue }
            for item in items.sorted() where seen.insert(item).inserted {
                let presetDir = dir.appendingPathComponent(item)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: presetDir.path, isDirectory: &isDir), isDir.boolValue else { continue }
                let composition = presetDir.appendingPathComponent("agent.cordis.yml").path
                guard FileManager.default.isReadableFile(atPath: composition) else { continue }
                let meta = readMetadata(at: presetDir)
                presets.append(Preset(id: item, name: meta.name, description: meta.description))
            }
        }
        if presets.isEmpty {
            presets = shippedPresetNames.map { Preset(id: $0, name: nil, description: nil) }
        }

        return presets.map { preset in
            AgentLaunchOption(
                id: preset.id,
                label: preset.name ?? label(for: preset.id),
                detail: preset.description ?? "DSH agent preset",
                extraArgs: ""
            )
        }
    }

    private static func readMetadata(at dir: URL) -> (name: String?, description: String?) {
        let path = dir.appendingPathComponent("preset.yml").path
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return (nil, nil) }
        var name: String?
        var description: String?
        for rawLine in content.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if name == nil, line.hasPrefix("name:") {
                name = fieldValue(line, after: "name:")
            } else if description == nil, line.hasPrefix("description:") {
                description = fieldValue(line, after: "description:")
            }
        }
        return (name, description)
    }

    private static func fieldValue(_ line: String, after key: String) -> String? {
        guard let range = line.range(of: key) else { return nil }
        let value = line[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func label(for preset: String) -> String {
        switch preset {
        case "standard": return "Standard"
        case "code":     return "Code Mode"
        case "minimal":  return "Minimal"
        case "cordis":   return "Cordis"
        default:         return preset.capitalized
        }
    }

    private static func resolveDSHExecutable() -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            "/opt/homebrew/bin/dsh",
            "/usr/local/bin/dsh",
            home.appendingPathComponent(".local/bin/dsh").path,
            home.appendingPathComponent(".npm-global/bin/dsh").path,
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path).resolvingSymlinksInPath()
        }
        return nil
    }
}