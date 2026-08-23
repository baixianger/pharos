import SwiftUI

/// Notes-style macOS shell. The sidebar is a native, resizable split column;
/// Pharos controls its dense contents while macOS owns the window physics.
struct AgentWorkspaceShell<Sidebar: View, Workspace: View>: View {
    @Binding private var isSidebarVisible: Bool
    private let sidebar: (@escaping () -> Void) -> Sidebar
    private let workspace: Workspace

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
                    .padding(.top, 42)
                    .background(.ultraThinMaterial)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }

            workspace
                .frame(minWidth: 560, maxWidth: .infinity, maxHeight: .infinity)
                .background(.background)
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
        .background(.background)
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
