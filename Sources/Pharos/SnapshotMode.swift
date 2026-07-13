import AppKit
import ScreenCaptureKit
import SwiftUI

/// `PHAROS_SNAPSHOT="<route>@<out.png>[@<settleSeconds>]"` — screenshot mode
/// for README/site shots: the app navigates itself to `route`, waits for live
/// data to settle, captures ITS OWN window (rendering our own view hierarchy
/// needs no screen-recording permission), writes the PNG, and exits.
///
/// Routes: `dashboard` · `chat` · `project:<name>` ·
/// `settings:general|launch|projects|cli|machines`
///
/// Meant to run against a STAGED environment (`PHAROS_REGISTRY`,
/// `PHAROS_MESH_DIR`, `PHAROS_HOST`, `-pharos.*` argument-domain prefs) so
/// shots never show — or touch — the user's real data.
/// Identifiable wrapper so an Int can drive a SwiftUI `.sheet(item:)`.
struct IntID: Identifiable { let value: Int; var id: Int { value } }

@MainActor
enum SnapshotMode {
    struct Spec { let route: String; let out: String; let settle: Double }

    static let spec: Spec? = {
        guard let raw = ProcessInfo.processInfo.environment["PHAROS_SNAPSHOT"], !raw.isEmpty else { return nil }
        let parts = raw.split(separator: "@", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return nil }
        return Spec(route: parts[0], out: parts[1],
                    settle: parts.count > 2 ? (Double(parts[2]) ?? 3) : 3)
    }()

    /// Route `settings:<outer>[:<inner>]` — e.g. `settings:cli:codex`. The outer
    /// segment picks the Settings TabView tab; the optional inner segment picks
    /// the CLI tab's CLI/Claude/Codex sub-strip.
    private static var settingsParts: [String] {
        guard let r = spec?.route, r.hasPrefix("settings:") else { return [] }
        return String(r.dropFirst("settings:".count)).split(separator: ":").map(String.init)
    }

    /// Which tab the Settings window opens on (SettingsView seeds its selection).
    static var settingsTab: Int? {
        switch settingsParts.first {
        case "launch": return 1
        case "projects": return 2
        case "cli": return 3
        case "machines": return 4
        case .some: return 0
        case nil: return nil
        }
    }

    /// The CLI settings sub-tab ("cli" | "claude" | "codex") — CLISettingsTab
    /// seeds its inner picker from this. nil = default (cli).
    static var settingsSubTab: String? {
        settingsParts.count > 1 ? settingsParts[1] : nil
    }

    private static func diag(_ s: String) {
        let line = "snapshot: \(s)\n"
        fputs(line, stderr)
        if let out = spec?.out {
            let log = URL(fileURLWithPath: out).deletingLastPathComponent().appendingPathComponent("snapshot.log")
            if let fh = try? FileHandle(forWritingTo: log) { fh.seekToEndOfFile(); fh.write(Data(line.utf8)); try? fh.close() }
            else { try? line.data(using: .utf8)?.write(to: log) }
        }
    }

    /// Called from ContentView once the main window is up. `showSettings(tab)`
    /// presents the Settings panel as a SHEET on the main window — the separate
    /// Settings SCENE won't open for an `.accessory` (silent) app, so we capture
    /// the main window with the sheet up instead.
    static func run(store: ProjectStore, select: @escaping (Project.ID?) -> Void,
                    openRoom: @escaping (String?) -> Void,
                    showSettings: @escaping (Int?) -> Void) async {
        guard let spec else { return }
        diag("route=\(spec.route) registry=\(PharosCore.registryURL.path) "
             + "PHAROS_REGISTRY=\(ProcessInfo.processInfo.environment["PHAROS_REGISTRY"] ?? "nil") "
             + "projects=\(store.projects.count)")
        switch spec.route {
        case "dashboard":
            select(nil); openRoom(nil)
        case "chat":
            select(nil); openRoom("")
        case let r where r.hasPrefix("project:"):
            let name = String(r.dropFirst("project:".count))
            guard let p = store.projects.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else {
                fputs("snapshot: no project named \(name)\n", stderr); exit(2)
            }
            select(p.id)
        case let r where r.hasPrefix("settings:"):
            // Capture the Settings panel as its OWN standalone window (like the
            // real ⌘, panel) — NOT embedded in the main window, which read as
            // "still inside the app". The SwiftUI Settings scene won't open for
            // an .accessory app, so host SettingsView in a dedicated window.
            await captureSettingsWindow(store: store, tab: settingsTab ?? 0, out: spec.out, settle: spec.settle)
            return   // captureSettingsWindow exits
        default:
            fputs("snapshot: unknown route \(spec.route)\n", stderr); exit(2)
        }

        // Size + park OFF-SCREEN so shots never steal focus or flash on the
        // user's display (launched with `open -g`, the window still renders and
        // SCScreenshotManager captures it there).
        try? await Task.sleep(for: .seconds(0.6))
        for win in NSApp.windows where win.isVisible {
            win.setFrame(NSRect(x: -6000, y: 200, width: 1360, height: 850), display: true)
        }
        try? await Task.sleep(for: .seconds(spec.settle))

        guard let w = pickWindow(settings: false) else {
            fputs("snapshot: no window to capture\n", stderr); exit(3)
        }
        w.makeFirstResponder(nil)   // clear any auto text selection (e.g. Notes field)
        try? await Task.sleep(for: .seconds(0.3))
        diag("window num=\(w.windowNumber) frame=\(w.frame) title=\(w.title)")
        do {
            let png = try await capture(w)
            try png.write(to: URL(fileURLWithPath: spec.out))
            diag("WROTE \(spec.out) bytes=\(png.count)")
        } catch {
            diag("CAPTURE FAILED: \(error)")
            exit(3)
        }
        exit(0)
    }

    /// Host `SettingsView` in a dedicated off-screen window (the same content
    /// the real ⌘, panel shows) and capture just it — a clean standalone
    /// Settings screenshot, no main-window sidebar.
    private static func captureSettingsWindow(store: ProjectStore, tab: Int, out: String, settle: Double) async {
        let view = SettingsView(initialTab: tab).environment(store)
        let hosting = NSHostingView(rootView: view)
        let size = hosting.fittingSize
        let win = NSWindow(contentRect: NSRect(x: -6000, y: 200,
                                               width: size.width > 0 ? size.width : 520,
                                               height: size.height > 0 ? size.height : 500),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "Settings"
        win.titlebarAppearsTransparent = false
        win.contentView = hosting
        win.orderFront(nil)
        try? await Task.sleep(for: .seconds(settle))
        diag("settings window num=\(win.windowNumber) frame=\(win.frame)")
        do {
            let png = try await capture(win)
            try png.write(to: URL(fileURLWithPath: out))
            diag("WROTE \(out) bytes=\(png.count)")
            exit(0)
        } catch {
            diag("CAPTURE FAILED: \(error)")
            exit(3)
        }
    }

    /// Pixel-true capture of one of OUR OWN windows via ScreenCaptureKit.
    /// (Everything simpler is a dead end on macOS 26: CGWindowListCreateImage
    /// is removed from the SDK, and both `cacheDisplay` and CALayer.render
    /// come back BLANK for SwiftUI content — Liquid Glass composites out of
    /// process.) First run triggers the system screen-recording prompt for
    /// Pharos; grant once and snapshot runs are fully automatic after that.
    private static func capture(_ w: NSWindow) async throws -> Data {
        // SCShareableContent's window list can lag a just-shown/re-keyed window;
        // retry until ours appears (or give up after ~2s).
        let target = CGWindowID(w.windowNumber)
        var scw: SCWindow?
        for attempt in 0..<10 {
            // onScreenWindowsOnly:false — our capture window lives off-screen.
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            if let hit = content.windows.first(where: { $0.windowID == target }) { scw = hit; break }
            if attempt == 0 {
                let ids = content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }
                    .map { "\($0.windowID)(\(Int($0.frame.width))x\(Int($0.frame.height)))" }
                diag("waiting for win \(target); our shareable wins: \(ids.joined(separator: ","))")
            }
            try? await Task.sleep(for: .seconds(0.2))
        }
        guard let scw else {
            throw NSError(domain: "snapshot", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "own window \(target) not in shareable content"])
        }
        let scale = w.backingScaleFactor
        let cfg = SCStreamConfiguration()
        cfg.width = Int(scw.frame.width * scale)
        cfg.height = Int(scw.frame.height * scale)
        cfg.showsCursor = false
        cfg.scalesToFit = false
        let img = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: scw),
            configuration: cfg)
        guard let png = NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:]) else {
            throw NSError(domain: "snapshot", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "png encode failed"])
        }
        return png
    }

    private static func pickWindow(settings: Bool) -> NSWindow? {
        // Real content windows only — NSApp.windows also holds the menu-bar
        // status item + other tiny helper windows (a 34×30 one got captured
        // before). Require a reasonable minimum size.
        let real = NSApp.windows.filter { $0.isVisible && $0.frame.width > 300 && $0.frame.height > 200 }
        if settings {
            // The Settings scene is a separate ~520pt window; pick the smaller
            // of the real windows (main is 1360 wide).
            return real.filter { $0 !== NSApp.mainWindow }.min { $0.frame.width < $1.frame.width }
                ?? real.first { $0 !== NSApp.mainWindow }
        }
        return real.first { $0 === NSApp.mainWindow } ?? real.first
    }
}
