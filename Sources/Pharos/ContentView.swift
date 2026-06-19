import SwiftUI

struct ContentView: View {
    @Environment(ProjectStore.self) private var store
    @AppStorage("pharos.onboarded")    private var onboarded  = false
    @AppStorage("pharos.launchCount")  private var launchCount = 0
    @State private var selectedProject: Project.ID?
    @State private var showAdd = false
    @State private var showImport = false
    @State private var showPalette = false
    @State private var showOnboarding = false
    @State private var searchText = ""
    @State private var launchCounted = false

    /// Native window-tab label — the current project's name, so each tab reads
    /// the project it shows.
    private var tabTitle: String {
        if let id = selectedProject, let p = store.project(id) { return p.name }
        return "Pharos"
    }

    var body: some View {
        @Bindable var store = store
        NavigationSplitView {
            ProjectsSidebar(selectedProject: $selectedProject, searchText: searchText)
                .navigationSplitViewColumnWidth(min: 248, ideal: 300, max: 400)
        } detail: {
            if let id = selectedProject, store.project(id) != nil {
                ProjectDetailView(projectID: id)
            } else {
                ContentUnavailableView("Select a project",
                                       systemImage: "sidebar.left",
                                       description: Text("Pick a project to see git status and launch agents."))
            }
        }
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { store.refreshAllGit() } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .help("Reload git status")
                .accessibilityLabel("Refresh git status")

                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Settings")
                .accessibilityLabel("Open Settings")

                Menu {
                    Button { store.requestAdd() } label: { Label("Add Local Folder…", systemImage: "folder.badge.plus") }
                    Button { store.requestImport() } label: { Label("Import from GitHub…", systemImage: "arrow.down.circle") }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .help("Add a project")
                .accessibilityLabel("Add project")

                Button(role: .destructive) {
                    if let id = selectedProject, let p = store.project(id) {
                        store.remove(p)
                        selectedProject = nil
                    }
                } label: {
                    Label("Remove", systemImage: "trash")
                }
                .help("Remove the selected project from Pharos")
                .accessibilityLabel("Remove selected project")
                .disabled(selectedProject == nil)
            }
        }
        .toolbarBackground(.visible, for: .windowToolbar)
        .background(WindowTabBar(title: tabTitle))
        .sheet(isPresented: $showAdd) { AddProjectSheet() }
        .sheet(isPresented: $showImport) { GitHubImportSheet() }
        .sheet(isPresented: $showPalette) {
            CommandPalette(selectedProject: $selectedProject, isPresented: $showPalette)
                .environment(store)
        }
        .sheet(isPresented: $showOnboarding) {
            OnboardingView {
                onboarded = true
                showOnboarding = false
            }
            .environment(store)
        }
        .alert("Something went wrong",
               isPresented: Binding(
                   get: { store.lastError != nil },
                   set: { if !$0 { store.lastError = nil } }
               ),
               actions: {
                   Button("OK") { store.lastError = nil }
               },
               message: {
                   Text(store.lastError ?? "")
               })
        .onChange(of: store.addRequested) { _, requested in
            if requested { showAdd = true; store.addRequested = false }
        }
        .onChange(of: store.importRequested) { _, requested in
            if requested { showImport = true; store.importRequested = false }
        }
        .onChange(of: store.paletteRequested) { _, requested in
            if requested { showPalette = true; store.paletteRequested = false }
        }
        .onChange(of: store.projects) { _, projects in
            // Mark onboarded once the user has at least one project
            if !projects.isEmpty { onboarded = true }
        }
        .overlay(alignment: .bottom) {
            StarPromptBanner()
                .environment(store)
                .animation(.spring(duration: 0.35), value: launchCount)
        }
        .onAppear {
            if !onboarded && store.projects.isEmpty {
                showOnboarding = true
            }
            // Increment the launch counter once per process launch.
            if !launchCounted {
                launchCounted = true
                launchCount += 1
            }
        }
    }
}
