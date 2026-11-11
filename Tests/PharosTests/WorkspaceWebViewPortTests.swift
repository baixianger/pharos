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
        config.userContentController.removeScriptMessageHandler(forName: "pharosBridge")
        withExtendedLifetime(delegate) {}
    }
}
