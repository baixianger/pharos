import SwiftUI
import AppKit

/// Category classification for session artifacts.
public enum ArtifactCategory: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case patches = "Patches"
    case files = "Files"
    case outputs = "Outputs"
    case attachments = "Attachments"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .patches: return "arrow.triangle.pull"
        case .files: return "doc.text"
        case .outputs: return "terminal"
        case .attachments: return "paperclip"
        }
    }

    public var color: Color {
        switch self {
        case .all: return .secondary
        case .patches: return .purple
        case .files: return .blue
        case .outputs: return .green
        case .attachments: return .orange
        }
    }
}

/// A project file, tool output, generated patch, or attachment associated with a session.
public struct ClientSessionArtifact: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let category: ArtifactCategory
    public let path: String
    public let sizeDescription: String
    public let timestamp: Date
    public let previewContent: String?

    public init(
        id: String = UUID().uuidString,
        name: String,
        category: ArtifactCategory,
        path: String,
        sizeDescription: String,
        timestamp: Date = Date(),
        previewContent: String? = nil
    ) {
        self.id = id
        self.name = name
        self.category = category
        self.path = path
        self.sizeDescription = sizeDescription
        self.timestamp = timestamp
        self.previewContent = previewContent
    }
}

/// The Session Library pane (Library sub-tab).
public struct SessionLibraryView: View {
    @State private var selectedCategory: ArtifactCategory = .all
    @State private var searchText: String = ""
    @State private var previewArtifact: ClientSessionArtifact? = nil
    @State private var copiedId: String? = nil

    public var artifacts: [ClientSessionArtifact]

    public init(artifacts: [ClientSessionArtifact] = []) {
        if artifacts.isEmpty {
            // Default seed items demonstrating session artifacts
            self.artifacts = [
                ClientSessionArtifact(
                    name: "diff_fix_concurrency.patch",
                    category: .patches,
                    path: "internal/patches/2026-11-05_concurrency.patch",
                    sizeDescription: "+34 / -12 lines",
                    previewContent: "--- a/BackendWireEvent.swift\n+++ b/BackendWireEvent.swift\n@@ -10,3 +10,5 @@\n+public struct BackendWireEvent: @unchecked Sendable {\n+    public var payload: [String: Any]\n+}"
                ),
                ClientSessionArtifact(
                    name: "Package.swift",
                    category: .files,
                    path: "Package.swift",
                    sizeDescription: "2.4 KB",
                    previewContent: "// swift-tools-version: 5.10\nimport PackageDescription\n\nlet package = Package(\n    name: \"Pharos\",\n..."
                ),
                ClientSessionArtifact(
                    name: "swift-test.log",
                    category: .outputs,
                    path: "internal/evidence/swift_test_20261105.log",
                    sizeDescription: "737 passed • 0 failed",
                    previewContent: "Test Suite 'All tests' passed at 2026-11-05 17:36:39.\nExecuted 737 tests, with 0 failures in 1.42s"
                ),
                ClientSessionArtifact(
                    name: "architecture_audit.json",
                    category: .attachments,
                    path: "docs/evidence/architecture_audit.json",
                    sizeDescription: "18.2 KB",
                    previewContent: "{\n  \"timestamp\": \"2026-11-05T15:00:00Z\",\n  \"violations\": 0,\n  \"status\": \"VERIFIED\"\n}"
                )
            ]
        } else {
            self.artifacts = artifacts
        }
    }

    private var filteredArtifacts: [ClientSessionArtifact] {
        artifacts.filter { artifact in
            let matchesCategory = (selectedCategory == .all || artifact.category == selectedCategory)
            let matchesSearch = searchText.isEmpty ||
                artifact.name.localizedCaseInsensitiveContains(searchText) ||
                artifact.path.localizedCaseInsensitiveContains(searchText)
            return matchesCategory && matchesSearch
        }
    }

    public var body: some View {
        VStack(spacing: 12) {
            // Category Filter Pills
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(ArtifactCategory.allCases) { category in
                        categoryPill(category)
                    }
                }
                .padding(.horizontal, 2)
            }

            // Search Bar
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("Search artifacts...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            // Artifact List
            if filteredArtifacts.isEmpty {
                emptyStateView
            } else {
                VStack(spacing: 6) {
                    ForEach(filteredArtifacts) { artifact in
                        artifactRow(artifact)
                    }
                }
            }
        }
        .sheet(item: $previewArtifact) { artifact in
            previewSheet(artifact)
        }
    }

    // MARK: - Subviews

    private func categoryPill(_ category: ArtifactCategory) -> some View {
        Button(action: { selectedCategory = category }) {
            HStack(spacing: 4) {
                Image(systemName: category.icon)
                    .font(.system(size: 9))
                Text(category.rawValue)
                    .font(.system(size: 10, weight: selectedCategory == category ? .bold : .medium))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                selectedCategory == category
                    ? category.color.opacity(0.18)
                    : Color(nsColor: .controlBackgroundColor)
            )
            .foregroundStyle(
                selectedCategory == category
                    ? category.color
                    : Color.secondary
            )
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func artifactRow(_ artifact: ClientSessionArtifact) -> some View {
        HStack(spacing: 10) {
            Image(systemName: artifact.category.icon)
                .font(.system(size: 13))
                .foregroundStyle(artifact.category.color)
                .frame(width: 26, height: 26)
                .background(artifact.category.color.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(artifact.name)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(artifact.path)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(artifact.sizeDescription)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)

                HStack(spacing: 6) {
                    // Preview Button
                    Button(action: { previewArtifact = artifact }) {
                        Image(systemName: "eye")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Preview")

                    // Copy Path
                    Button(action: {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString(artifact.path, forType: .string)
                        copiedId = artifact.id
                        Task {
                            try? await Task.sleep(nanoseconds: 1_200_000_000)
                            copiedId = nil
                        }
                    }) {
                        Image(systemName: copiedId == artifact.id ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 10))
                            .foregroundStyle(copiedId == artifact.id ? Color.green : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Copy Path")

                    // Reveal in Finder
                    Button(action: {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: artifact.path)
                    }) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Reveal in Finder")
                }
            }
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text("No artifacts match")
                .font(.system(size: 12, weight: .medium))
            Text("Try selecting another category or clearing search.")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 120)
    }

    private func previewSheet(_ artifact: ClientSessionArtifact) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: artifact.category.icon)
                    .foregroundStyle(artifact.category.color)
                Text(artifact.name)
                    .font(.system(size: 13, weight: .bold))
                Spacer()
                Button(action: { previewArtifact = nil }) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, 4)

            ScrollView {
                Text(artifact.previewContent ?? "No content preview available.")
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(Color(red: 0.08, green: 0.09, blue: 0.11))
                    .foregroundStyle(Color(white: 0.9))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            HStack {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: artifact.path)
                }
                Spacer()
                Button("Done") {
                    previewArtifact = nil
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(minWidth: 420, minHeight: 300)
    }
}
