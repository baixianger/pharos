import AppKit
import WebKit
import XCTest
@testable import Pharos

@MainActor
final class WorkspaceWebViewPortTests: XCTestCase {
    private final class LoadDelegate: NSObject, WKNavigationDelegate {
        let loaded: XCTestExpectation
        init(_ loaded: XCTestExpectation) { self.loaded = loaded }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { loaded.fulfill() }
    }

    /// Present so `transport.js` takes the native `pharosBridge` path instead of
    /// starting its web pollers/WebSocket (which would clobber injected state).
    private final class NoopBridge: NSObject, WKScriptMessageHandler {
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {}
    }

    private final class Bridge: NSObject, WKScriptMessageHandler {
        let received: XCTestExpectation
        var action: String?
        init(_ received: XCTestExpectation) { self.received = received }
        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            action = (message.body as? [String: Any])?["action"] as? String
            received.fulfill()
        }
    }

    func testBundledWorkspaceRendersNativeState() async throws {
        let url = try XCTUnwrap(WorkspaceWebView.pageURL)
        let loaded = expectation(description: "workspace loaded")
        let delegate = LoadDelegate(loaded)
        let received = expectation(description: "native bridge action")
        let bridge = Bridge(received)
        let config = WKWebViewConfiguration()
        config.userContentController.add(bridge, name: "pharosBridge")
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        webView.navigationDelegate = delegate
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        await fulfillment(of: [loaded], timeout: 15)
        let result: String = try await withCheckedThrowingContinuation { continuation in
            webView.callAsyncJavaScript("""
            window.pharosWorkspace.update({ tab:'sessions', selection:'s', title:'Native test', theme:'light',
              rows:[{id:'s',title:'Native test',subtitle:'',identity:{shape:'sphere',color:'black'},members:[]}],
              identity:{shape:'sphere',color:'black'}, activity:'idle', canSend:true, detail:null,
              turns:[], streamingText:'', reasoningText:'', tools:[], approval:null, goal:null,
              todos:[], messages:[], members:[], error:null });
            return document.querySelector('.gb-bot-list').textContent;
            """, arguments: [:], in: nil, in: .page) { outcome in
                switch outcome {
                case .success(let value): continuation.resume(returning: value as? String ?? "")
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
        XCTAssertTrue(result.contains("Native test"), "returned: \(result)")
        _ = try await webView.evaluateJavaScript("document.querySelector('[data-action=settings]').click()")
        await fulfillment(of: [received], timeout: 5)
        XCTAssertEqual(bridge.action, "settings")
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "pharosBridge")
        withExtendedLifetime(delegate) {}
    }

    /// The real bridge path: encode the native `WorkspaceWebState` exactly like
    /// `WorkspaceWebView.Coordinator` does, hand it to the bundled page, and
    /// assert `workspace.js` renders the typed configuration controls and
    /// capability gates from it.
    func testEncodedNativeStateDrivesConfigurationAndCapabilityGates() async throws {
        let bridge = NoopBridge()
        let (webView, delegate) = try await loadedWebView(bridge: bridge)

        let supported = workspaceState(
            configurationControls: [
                .select(id: "model", name: "Model", currentValue: "gpt-5",
                        options: [.init(value: "gpt-5", name: "gpt-5"), .init(value: "gpt-6", name: "gpt-6")],
                        readOnly: false),
                .select(id: "mode", name: "Mode", currentValue: "safe",
                        options: [.init(value: "safe", name: "Safe"), .init(value: "yolo", name: "YOLO")],
                        readOnly: false),
            ],
            capabilities: ["attachments": true, "commands": false, "stop": true, "revive": false]
        )
        let first = try await render(supported, in: webView, inspect: """
            document.querySelector('[data-action=composer-menu]').click();
            document.querySelector('[data-action=details]').click();
            const container = document.querySelector('#session-config-controls');
            const selects = [...container.querySelectorAll('select')].map(select => ({
              configId: select.dataset.configId, value: select.value, disabled: select.disabled,
              options: [...select.options].map(option => option.value)
            }));
            return JSON.stringify({
              hidden: container.hidden,
              selects,
              menu: document.querySelector('.gb-composer-menu').textContent,
              stopDisabled: document.querySelector('[data-action=stop]')?.disabled ?? null,
              reviveDisabled: document.querySelector('[data-action=revive]')?.disabled ?? null
            });
            """)
        XCTAssertFalse(first["hidden"] as? Bool ?? true, "selected session configuration is visible")
        let selects = try XCTUnwrap(first["selects"] as? [[String: Any]])
        XCTAssertEqual(selects.map { $0["configId"] as? String }, ["model", "mode"])
        XCTAssertEqual(selects[0]["value"] as? String, "gpt-5")
        XCTAssertEqual(selects[0]["disabled"] as? Bool, false)
        XCTAssertEqual(selects[1]["value"] as? String, "safe")
        XCTAssertEqual(selects[0]["options"] as? [String], ["gpt-5", "gpt-6"])
        XCTAssertTrue((first["menu"] as? String ?? "").contains("Add text files"), "attachment capability enables the composer menu item")
        XCTAssertEqual(first["stopDisabled"] as? Bool, false, "stop is advertised by the adapter")
        XCTAssertEqual(first["reviveDisabled"] as? Bool, true, "revive stays disabled when the adapter does not advertise it")

        let unavailable = workspaceState(
            configurationControls: [.status(name: "Configuration unavailable")],
            capabilities: ["attachments": false, "commands": false, "stop": false, "revive": false]
        )
        let second = try await render(unavailable, in: webView, inspect: """
            document.querySelector('[data-action=composer-menu]').click();
            document.querySelector('[data-action=composer-menu]').click();
            const container = document.querySelector('#session-config-controls');
            return JSON.stringify({
              hidden: container.hidden,
              notice: container.textContent,
              selects: container.querySelectorAll('select').length,
              menu: document.querySelector('.gb-composer-menu').textContent,
              stopDisabled: document.querySelector('[data-action=stop]')?.disabled ?? null
            });
            """)
        XCTAssertFalse(second["hidden"] as? Bool ?? true)
        XCTAssertEqual(second["notice"] as? String, "Configuration unavailable")
        XCTAssertEqual(second["selects"] as? Int, 0)
        XCTAssertFalse((second["menu"] as? String ?? "").contains("Add text files"), "no attachment capability, no attach item")
        XCTAssertEqual(second["stopDisabled"] as? Bool, true, "stop stays disabled when not advertised")
        withExtendedLifetime((delegate, bridge)) {}
    }

    // MARK: - Helpers

    private func loadedWebView(bridge: WKScriptMessageHandler? = nil) async throws -> (WKWebView, LoadDelegate) {
        let url = try XCTUnwrap(WorkspaceWebView.pageURL)
        let loaded = expectation(description: "workspace loaded")
        let delegate = LoadDelegate(loaded)
        let configuration = WKWebViewConfiguration()
        if let bridge { configuration.userContentController.add(bridge, name: "pharosBridge") }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600),
                                configuration: configuration)
        webView.navigationDelegate = delegate
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        await fulfillment(of: [loaded], timeout: 15)
        return (webView, delegate)
    }

    private func workspaceState(
        configurationControls: [WorkspaceWebState.SessionConfigControl],
        capabilities: [String: Bool]
    ) -> WorkspaceWebState {
        WorkspaceWebState(
            tab: "sessions", selection: "s", title: "Native test", theme: "light",
            rows: [.init(id: "s", title: "Native test", subtitle: "", identity: .init(shape: "sphere", color: "black"))],
            identity: .init(shape: "sphere", color: "black"),
            detail: .init(sessionID: "s", agent: "codex", host: "mini", status: "idle",
                          workspace: "/tmp/project", model: "gpt-5", mode: "safe", models: ["gpt-5"]),
            turns: [], streamingText: "", reasoningText: "", tools: [], approval: nil,
            sessionConfiguration: configurationControls,
            capabilities: capabilities,
            messages: [], members: [], error: nil
        )
    }

    /// Mirrors `WorkspaceWebView.Coordinator.sync()`: encode the state, then
    /// hand the JSON object to `window.pharosWorkspace.update(state)`.
    private func render(
        _ state: WorkspaceWebState,
        in webView: WKWebView,
        inspect script: String
    ) async throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result: String = try await withCheckedThrowingContinuation { continuation in
            webView.callAsyncJavaScript("""
            window.pharosWorkspace.update(state);
            \(script)
            """, arguments: ["state": json], in: nil, in: .page) { outcome in
                switch outcome {
                case .success(let value): continuation.resume(returning: value as? String ?? "")
                case .failure(let error): continuation.resume(throwing: error)
                }
            }
        }
        let resultData = try XCTUnwrap(result.data(using: .utf8))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: resultData) as? [String: Any])
    }
}
