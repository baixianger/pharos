import SwiftUI
import WebKit
import PharosClientKit

/// A high-fidelity WebKit canvas rendering the DeepSeek Harness (DSH) style agent conversation stream.
/// Features DeepSeek blue `#4176E6`, collapsible brain reasoning accordion, monospace tool execution cards,
/// live typing cursor, and interactive approval cards.
///
/// On the rust-api path (`daemonBaseURL` set), WebKit loads the daemon-served UI at
/// `http://127.0.0.1:<port>/` and product mutations (e.g. approval resolve) go through
/// `fetch` to `/api/v1/...`. The legacy `pharosBridge` handler remains only as a
/// compatibility shim for the desktop-mesh / file:// path.
public struct PharosWebCanvasView: NSViewRepresentable {
    public let turns: [CanonicalTurn]
    public let liveStreamingText: String
    public let liveReasoningText: String
    public let activeApproval: CanonicalApprovalRequest?
    public let isTurnInProgress: Bool
    public let onResolveApproval: (ApprovalDecision) -> Void
    /// When non-nil, load the S4 daemon Web UI instead of bundled file:// WebCanvas.
    public let daemonBaseURL: URL?

    public init(
        turns: [CanonicalTurn],
        liveStreamingText: String = "",
        liveReasoningText: String = "",
        activeApproval: CanonicalApprovalRequest? = nil,
        isTurnInProgress: Bool = false,
        onResolveApproval: @escaping (ApprovalDecision) -> Void = { _ in },
        daemonBaseURL: URL? = {
            let config = PharosAPIConfiguration.resolve()
            return config.backendKind == .rustAPI ? config.webUIURL : nil
        }()
    ) {
        self.turns = turns
        self.liveStreamingText = liveStreamingText
        self.liveReasoningText = liveReasoningText
        self.activeApproval = activeApproval
        self.isTurnInProgress = isTurnInProgress
        self.onResolveApproval = onResolveApproval
        self.daemonBaseURL = daemonBaseURL
    }

    public func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    public func makeNSView(context: Context) -> WKWebView {
        let userContent = WKUserContentController()
        // Compatibility shim only — product calls prefer fetch (see dsh-stream.js).
        userContent.add(context.coordinator, name: "pharosBridge")

        let config = WKWebViewConfiguration()
        config.userContentController = userContent

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground") // Transparent background
        webView.enclosingScrollView?.drawsBackground = false

        context.coordinator.webView = webView
        context.coordinator.loadContent()

        return webView
    }

    public func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.syncState()
    }

    @MainActor
    public final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var parent: PharosWebCanvasView
        weak var webView: WKWebView?
        private var isLoaded = false
        private var lastTurnCount = -1
        private var lastStreamingText = ""
        private var lastReasoningText = ""
        private var lastApprovalId: String? = nil

        init(_ parent: PharosWebCanvasView) {
            self.parent = parent
        }

        func loadContent() {
            // Phase D / S6: prefer daemon-served Web UI at S4 base URL.
            if let daemonURL = parent.daemonBaseURL {
                NSLog("PharosWebCanvasView: loading daemon UI \(daemonURL.absoluteString)")
                webView?.load(URLRequest(url: daemonURL))
                return
            }

            var htmlURL: URL? = nil

            // 1. Check Bundle.module (SwiftPM resource bundle)
            #if SWIFT_PACKAGE
            if let moduleURL = Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "WebCanvas") {
                htmlURL = moduleURL
            }
            #endif

            // 2. Check Bundle.main (Packaged Pharos.app)
            if htmlURL == nil {
                if let mainURL = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "WebCanvas") {
                    htmlURL = mainURL
                } else if let resURL = Bundle.main.resourceURL?.appendingPathComponent("WebCanvas/index.html"),
                          FileManager.default.fileExists(atPath: resURL.path) {
                    htmlURL = resURL
                }
            }

            // 3. Fallback to developer source tree path for local dev/tests
            if htmlURL == nil {
                let devPath = URL(fileURLWithPath: #file)
                    .deletingLastPathComponent() // Canvas
                    .deletingLastPathComponent() // UI
                    .appendingPathComponent("Resources/WebCanvas/index.html")
                if FileManager.default.fileExists(atPath: devPath.path) {
                    htmlURL = devPath
                }
            }

            guard let url = htmlURL else {
                NSLog("PharosWebCanvasView: Unable to locate WebCanvas/index.html")
                return
            }

            let directory = url.deletingLastPathComponent()
            webView?.loadFileURL(url, allowingReadAccessTo: directory)
        }

        public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isLoaded = true
            syncTheme()
            syncState(force: true)
        }

        func syncTheme() {
            guard isLoaded else { return }
            let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            webView?.evaluateJavaScript("window.pharosAPI.setTheme(\(isDark));", completionHandler: nil)
        }

        func syncState(force: Bool = false) {
            guard isLoaded, let webView = webView else { return }

            // 1. Sync turns
            if force || parent.turns.count != lastTurnCount {
                lastTurnCount = parent.turns.count
                if let jsonData = try? JSONEncoder().encode(parent.turns),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    webView.evaluateJavaScript("window.pharosAPI.setTurns(\(jsonString));", completionHandler: nil)
                }
            }

            // 2. Sync reasoning
            if force || parent.liveReasoningText != lastReasoningText {
                lastReasoningText = parent.liveReasoningText
                let escaped = escapeForJS(parent.liveReasoningText)
                webView.evaluateJavaScript("window.pharosAPI.setReasoning(\"\(escaped)\");", completionHandler: nil)
            }

            // 3. Sync live streaming text
            if force || parent.liveStreamingText != lastStreamingText {
                lastStreamingText = parent.liveStreamingText
                let escaped = escapeForJS(parent.liveStreamingText)
                webView.evaluateJavaScript("window.pharosAPI.setLiveText(\"\(escaped)\");", completionHandler: nil)
            }

            // 4. Sync approval (+ session context for fetch-based resolve on daemon path)
            let currentApprovalId = parent.activeApproval?.approvalId
            if force || currentApprovalId != lastApprovalId {
                lastApprovalId = currentApprovalId
                if let approval = parent.activeApproval,
                   let jsonData = try? JSONEncoder().encode(approval),
                   let jsonString = String(data: jsonData, encoding: .utf8) {
                    let sid = escapeForJS(approval.sessionId)
                    let aid = escapeForJS(approval.approvalId)
                    webView.evaluateJavaScript(
                        "window.pharosAPI.setSessionContext && window.pharosAPI.setSessionContext(\"\(sid)\", \"\(aid)\");",
                        completionHandler: nil
                    )
                    webView.evaluateJavaScript("window.pharosAPI.setApproval(\(jsonString));", completionHandler: nil)
                } else if currentApprovalId == nil {
                    webView.evaluateJavaScript(
                        "window.pharosAPI.setSessionContext && window.pharosAPI.setSessionContext(null, null);",
                        completionHandler: nil
                    )
                    webView.evaluateJavaScript("window.pharosAPI.setApproval(null);", completionHandler: nil)
                }
            }
        }

        private func escapeForJS(_ string: String) -> String {
            return string
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
        }

        public func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "pharosBridge",
                  let dict = message.body as? [String: Any],
                  let action = dict["action"] as? String else {
                return
            }

            if action == "resolveApproval" {
                if let payload = dict["payload"] as? [String: Any],
                   let choiceRaw = payload["choice"] as? String {
                    let choice: ApprovalChoice
                    switch choiceRaw {
                    case "allowed_always":
                        choice = .allowedAlways
                    case "rejected":
                        choice = .rejected
                    default:
                        choice = .allowedOnce
                    }
                    parent.onResolveApproval(ApprovalDecision(choice: choice))
                }
            }
        }
    }
}
