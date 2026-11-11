import SwiftUI
import WebKit
import PharosClientKit

struct WorkspaceWebState: Encodable, Equatable {
    struct Avatar: Codable, Equatable {
        let shape: String
        let color: String

        static let shapes = ["sphere", "cloud", "square", "sparkle", "clover", "heartChubby",
                             "starFlower", "teardrop", "tablet", "wedge", "house", "star6", "hex"]
        static let colors = ["black", "brown", "red", "orange", "yellow", "green",
                             "cyan", "blue", "violet", "magenta", "gray"]

        init(shape: String, color: String) {
            self.shape = shape
            self.color = color
        }

        init(seed: String) {
            let hash = seed.unicodeScalars.reduce(UInt32(2_166_136_261)) { ($0 ^ $1.value) &* 16_777_619 }
            self.init(shape: Self.shapes[Int(hash) % Self.shapes.count],
                      color: Self.colors[Int(hash >> 8) % Self.colors.count])
        }
    }

    struct Row: Encodable, Equatable {
        let id: String
        let title: String
        let subtitle: String
        let identity: Avatar
        var members: [RosterAvatar] = []
    }

    struct RosterAvatar: Encodable, Equatable {
        let id: String
        let name: String
        let identity: Avatar
    }

    struct ProjectSession: Encodable, Equatable {
        let sessionId: String
        let title: String
        let agentType: String
        let machineId: String
        let status: SessionActivityStatus
        let inventoryStale: Bool?
        let connectionRoute: String?

        init(_ session: ClientSessionSummary) {
            sessionId = session.id
            title = session.title
            agentType = session.agentType
            machineId = session.machineId
            status = session.status
            inventoryStale = session.inventoryStale
            connectionRoute = session.connectionRoute
        }
    }

    struct SubmissionResult: Encodable, Equatable {
        let requestID: String
        let accepted: Bool
    }

    struct Details: Encodable, Equatable {
        var sessionID = ""
        var agent = ""
        var host = ""
        var status = ""
        var workspace = ""
        var model = ""
        var mode = ""
        var models: [String] = []
    }

    let tab: String
    let selection: String?
    let title: String
    let theme: String
    let rows: [Row]
    let identity: Avatar
    var activity = "idle"
    var canSend = true
    let detail: Details?
    let turns: [CanonicalTurn]
    let streamingText: String
    let reasoningText: String
    let tools: [SessionConversationViewModel.LiveTool]
    let approval: CanonicalApprovalRequest?
    var goal: CanonicalSessionGoal?
    var todos: [CanonicalSessionTodo] = []
    var sessionConfiguration: [JSONValue]?
    var supportsTextAttachments = false
    var configurationInFlight = false
    var inventoryIssues: [ClientSessionInventoryIssue] = []
    var commandResult: String?
    var submissionResults: [String: SubmissionResult] = [:]
    var projectSessions: [ProjectSession] = []
    var projectInventoryLoaded = false
    var projectHosts: [String] = []
    var projectCheckoutUnavailableHosts: [String] = []
    var canBindThreadSession = false
    var threadBindingInFlight = false
    var threadBindingCandidates: [ProjectSession] = []
    let messages: [ClientThreadMessage]
    let members: [ClientMemberDetail]
    let error: String?
}

struct WorkspaceWebView: NSViewRepresentable {
    static let channel = "pharosBridge"

    var state: WorkspaceWebState
    var onAction: (String, [String: Any]) -> Void

    static var pageURL: URL? {
        Bundle.main.url(forResource: "workspace", withExtension: "html", subdirectory: "WebCanvas")
            ?? Bundle.module.url(forResource: "workspace", withExtension: "html")
    }

    func makeCoordinator() -> Coordinator { Coordinator(view: self) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(context.coordinator, name: Self.channel)
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        context.coordinator.webView = webView
        if let url = Self.pageURL {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            webView.loadHTMLString("<p>Pharos workspace resources could not be loaded.</p>", baseURL: nil)
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.view = self
        context.coordinator.sync()
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: channel)
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var view: WorkspaceWebView
        weak var webView: WKWebView?
        private var isReady = false
        private var lastState: WorkspaceWebState?

        init(view: WorkspaceWebView) { self.view = view }

        func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
            guard frame.isMainFrame, frame.request.url == WorkspaceWebView.pageURL else { completionHandler(nil); return }
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = parameters.allowsMultipleSelection
            panel.begin { response in completionHandler(response == .OK ? panel.urls : nil) }
        }

        func sync() {
            guard isReady, let webView, lastState != view.state else { return }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(view.state),
                  let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            lastState = view.state
            webView.callAsyncJavaScript(
                "window.pharosWorkspace.update(state)", arguments: ["state": state], in: nil, in: .page
            ) { result in
                if case .failure(let error) = result {
                    NSLog("Pharos workspace render failed: %@", error.localizedDescription)
                }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isReady = true
            lastState = nil
            sync()
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            isReady = false
            webView.reload()
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let url = action.request.url
            decisionHandler(action.targetFrame?.isMainFrame == true
                            && (url == WorkspaceWebView.pageURL || url?.absoluteString == "about:blank")
                            ? .allow : .cancel)
        }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard isReady, message.frameInfo.isMainFrame, message.frameInfo.request.url == WorkspaceWebView.pageURL,
                  message.name == WorkspaceWebView.channel,
                  let body = message.body as? [String: Any],
                  let action = body["action"] as? String,
                  let payload = body["payload"] as? [String: Any] else { return }
            view.onAction(action, payload)
        }
    }
}
