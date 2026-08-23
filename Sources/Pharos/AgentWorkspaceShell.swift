import SwiftUI

/// Notes-style macOS shell. The sidebar is a native, resizable split column;
/// Pharos controls its dense contents while macOS owns the window physics.
struct AgentWorkspaceShell<Sidebar: View, Workspace: View>: View {
    @Binding private var isSidebarVisible: Bool
    private let sidebar: (@escaping () -> Void) -> Sidebar
    private let workspace: Workspace

    /// Top inset so the sidebar clears the hidden title bar.
    private static var titleBarInset: CGFloat { 42 }

    init(
        isSidebarVisible: Binding<Bool>,
        @ViewBuilder sidebar: @escaping (@escaping () -> Void) -> Sidebar,
        @ViewBuilder workspace: () -> Workspace
    ) {
        _isSidebarVisible = isSidebarVisible
        self.sidebar = sidebar
        self.workspace = workspace()
    }

    var body: some View {
        HSplitView {
            if isSidebarVisible {
                sidebar(closeSidebar)
                    .frame(minWidth: 236, idealWidth: 286, maxWidth: 380)
                    .padding(.top, Self.titleBarInset)
                    .background(.ultraThinMaterial)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }

            workspace
                .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
                .background(.background)
                .clipShape(RoundedRectangle(cornerRadius: isSidebarVisible ? 24 : 0, style: .continuous))
                .shadow(color: .black.opacity(isSidebarVisible ? 0.10 : 0), radius: 18, y: 8)
                .padding(.top, isSidebarVisible ? 12 : 0)
                .padding(.trailing, isSidebarVisible ? 12 : 0)
                .padding(.bottom, isSidebarVisible ? 12 : 0)
                .overlay(alignment: .topLeading) {
                    if !isSidebarVisible {
                        Button(action: openSidebar) {
                            Image(systemName: "sidebar.left")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(width: 34, height: 34)
                        }
                        .buttonStyle(.glass)
                        .help("Show sidebar")
                        .padding(.top, 9)
                        .padding(.leading, 12)
                        .transition(.opacity.combined(with: .scale(scale: 0.92)))
                    }
                }
        }
        .background(PharosTheme.surface)
        .ignoresSafeArea(.container, edges: .top)
        .toolbarVisibility(.hidden, for: .windowToolbar)
        .overlay {
            Button("Toggle Sidebar") {
                withAnimation(.snappy(duration: 0.24)) {
                    isSidebarVisible.toggle()
                }
            }
            .keyboardShortcut("s", modifiers: [.command, .option])
            .opacity(0)
            .frame(width: 1, height: 1)
            .allowsHitTesting(false)
        }
    }

    private func openSidebar() {
        withAnimation(.snappy(duration: 0.24)) {
            isSidebarVisible = true
        }
    }

    private func closeSidebar() {
        withAnimation(.snappy(duration: 0.24)) {
            isSidebarVisible = false
        }
    }
}
