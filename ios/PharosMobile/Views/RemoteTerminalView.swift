import SwiftTerm
import SwiftUI

struct TerminalTarget: Identifiable, Equatable {
    let member: MeshMember
    let profile: SSHHostProfile
    var id: String { member.id }
}

struct RemoteTerminalView: View {
    @Environment(SSHIdentityStore.self) private var identities
    @Environment(\.dismiss) private var dismiss
    let target: TerminalTarget
    @State private var session: InteractiveSSHSession?
    @State private var runTask: Task<Void, Never>?
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                TerminalRepresentable { feed in
                    guard runTask == nil else { return }
                    runTask = Task { await run(feed: feed) }
                }
                if let error {
                    ContentUnavailableView("Connection failed", systemImage: "exclamationmark.triangle",
                                           description: Text(error))
                        .foregroundStyle(.white)
                }
            }
            .navigationTitle("@\(target.member.nick)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Text(target.member.tmuxPane ?? "tmux").font(.caption.monospaced()).foregroundStyle(.secondary)
                }
            }
        }
        .onDisappear {
            runTask?.cancel()
            Task { await session?.close() }
        }
    }

    private func run(feed: TerminalFeed) async {
        do {
            guard let identityID = target.profile.identityID else { throw RemoteActionError.missingIdentity }
            let key = try identities.privateKey(for: identityID)
            let session = InteractiveSSHSession(profile: target.profile, privateKey: key)
            self.session = session
            try await session.connect()
            let shell = try await session.openShell()
            feed.onInput = { data in Task { try? await shell.write(data) } }
            feed.onResize = { cols, rows in Task { await shell.resize(cols: cols, rows: rows) } }
            let command = try RemoteCommandBuilder.attach(pane: target.member.tmuxPane ?? "") + "\n"
            try await shell.write(Data(command.utf8))
            for await chunk in shell.output { feed.write(chunk) }
        } catch is CancellationError {
        } catch {
            self.error = error.localizedDescription
        }
    }
}

@MainActor
private final class TerminalFeed {
    var write: (Data) -> Void = { _ in }
    var onInput: (Data) -> Void = { _ in }
    var onResize: (Int, Int) -> Void = { _, _ in }
}

private struct TerminalRepresentable: UIViewControllerRepresentable {
    let onReady: @MainActor (TerminalFeed) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIViewController {
        let controller = UIViewController()
        let terminal = SwiftTerm.TerminalView(frame: .zero)
        terminal.translatesAutoresizingMaskIntoConstraints = false
        terminal.backgroundColor = .black
        terminal.clipsToBounds = true
        try? terminal.setUseMetal(true)
        terminal.terminalDelegate = context.coordinator
        terminal.delegate = context.coordinator
        controller.view.addSubview(terminal)
        NSLayoutConstraint.activate([
            terminal.topAnchor.constraint(equalTo: controller.view.topAnchor),
            terminal.bottomAnchor.constraint(equalTo: controller.view.keyboardLayoutGuide.topAnchor),
            terminal.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
            terminal.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor),
        ])
        let feed = TerminalFeed()
        feed.write = { [weak terminal] data in terminal?.feed(byteArray: Array(data)[...]) }
        context.coordinator.feed = feed
        onReady(feed)
        DispatchQueue.main.async { _ = terminal.becomeFirstResponder() }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) { }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency SwiftTerm.TerminalViewDelegate, UIScrollViewDelegate {
        var feed: TerminalFeed?
        func scrollViewDidScroll(_ scrollView: UIScrollView) { scrollView.setNeedsDisplay() }
        func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) { feed?.onInput(Data(data)) }
        func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) { feed?.onResize(newCols, newRows) }
        func scrolled(source: SwiftTerm.TerminalView, position: Double) { }
        func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) { }
        func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) { }
        func clipboardCopy(source: SwiftTerm.TerminalView, content: Data) {
            UIPasteboard.general.string = String(data: content, encoding: .utf8)
        }
        func clipboardRead(source: SwiftTerm.TerminalView) -> Data? {
            UIPasteboard.general.string?.data(using: .utf8)
        }
        func requestOpenLink(source: SwiftTerm.TerminalView, link: String, params: [String: String]) { }
        func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) { }
        func bell(source: SwiftTerm.TerminalView) { }
        func iTermContent(source: SwiftTerm.TerminalView, content: ArraySlice<UInt8>) { }
    }
}
