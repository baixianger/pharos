#!/usr/bin/env swift
import Foundation
import WebKit
import AppKit

/// Headless-ish WebKit probe: load daemon UI and confirm document title / script.
/// Requires a window server; over SSH without GUI this exits PARTIAL.

final class Probe: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    let url: URL
    var done = false
    var ok = false
    var detail = ""

    init(url: URL) {
        self.url = url
        let config = WKWebViewConfiguration()
        self.webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        super.init()
        webView.navigationDelegate = self
    }

    func start() {
        webView.load(URLRequest(url: url))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("document.title + '|' + (typeof window.pharosAPI)") { result, error in
            if let error {
                self.detail = "js error: \(error)"
                self.ok = false
            } else {
                self.detail = "\(result ?? "nil")"
                self.ok = "\(result ?? "")".contains("object")
            }
            self.done = true
            CFRunLoopStop(CFRunLoopGetMain())
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        detail = "nav fail: \(error)"
        ok = false
        done = true
        CFRunLoopStop(CFRunLoopGetMain())
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        detail = "provisional fail: \(error)"
        ok = false
        done = true
        CFRunLoopStop(CFRunLoopGetMain())
    }
}

let base = ProcessInfo.processInfo.environment["PHAROS_SMOKE_BASE_URL"] ?? "http://127.0.0.1:18787"
guard let url = URL(string: base) else {
    fputs("bad url\n", stderr)
    exit(2)
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let probe = Probe(url: url)
probe.start()
let timeout = DispatchWorkItem {
    if !probe.done {
        probe.detail = "timeout"
        probe.done = true
        CFRunLoopStop(CFRunLoopGetMain())
    }
}
DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
CFRunLoopRun()
print("webkit_probe ok=\(probe.ok) detail=\(probe.detail)")
exit(probe.ok ? 0 : 1)
