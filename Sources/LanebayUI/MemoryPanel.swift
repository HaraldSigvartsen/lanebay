import Foundation
import LanebayCore
import SwiftUI

public struct AgentMemoryDocument: Identifiable, Sendable, Equatable {
    public enum Scope: String, Sendable, Equatable { case project = "Project", user = "User" }

    public let scope: Scope
    public let source: String
    public let relativePath: String
    fileprivate let root: URL
    fileprivate let document: WorkspaceDocument
    public var id: String { "\(scope.rawValue):\(root.path):\(relativePath)" }
    public var title: String { "\(source) / \(relativePath)" }
}

@MainActor
@Observable
public final class MemoryPanelModel {
    public private(set) var projectDocuments: [AgentMemoryDocument] = []
    public private(set) var userDocuments: [AgentMemoryDocument] = []
    public private(set) var selectedDocument: AgentMemoryDocument?
    public private(set) var source = ""
    public private(set) var errorMessage: String?
    private let homeRoot: URL
    private let reader: WorkspaceDocuments
    private var projectRoots: [URL] = []

    public init(workspace: Workspace?, homeRoot: URL = FileManager.default.homeDirectoryForCurrentUser,
                reader: WorkspaceDocuments = WorkspaceDocuments()) {
        self.homeRoot = homeRoot
        self.reader = reader
        setWorkspace(workspace)
    }

    public var renderedText: AttributedString? {
        guard selectedDocument != nil else { return nil }
        return try? AttributedString(markdown: source, options: .init(interpretedSyntax: .full))
    }

    public func setWorkspace(_ workspace: Workspace?) {
        var seen = Set<String>()
        projectRoots = (workspace?.repos ?? []).map { $0.resolvingSymlinksInPath().standardizedFileURL }
            .filter { seen.insert($0.path).inserted }
        reload()
    }

    public func select(_ document: AgentMemoryDocument) {
        guard (document.scope == .project ? projectDocuments : userDocuments).contains(document) else { return }
        do {
            source = try reader.read(document.document, in: document.root)
            selectedDocument = document
            errorMessage = nil
        } catch {
            source = ""
            selectedDocument = nil
            errorMessage = error.localizedDescription
        }
    }

    public func reload() {
        source = ""
        selectedDocument = nil
        errorMessage = nil
        var errors: [String] = []
        projectDocuments = collect(roots: projectRoots, scope: .project, errors: &errors)
        userDocuments = collect(roots: [homeRoot], scope: .user, errors: &errors)
        errorMessage = errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    private func collect(roots: [URL], scope: AgentMemoryDocument.Scope, errors: inout [String]) -> [AgentMemoryDocument] {
        let fileManager = FileManager.default
        let paths = scope == .project
            ? ["AGENTS.md", "CLAUDE.md", ".codex/AGENTS.md", ".claude/CLAUDE.md"]
            : [".codex/AGENTS.md", ".claude/CLAUDE.md"]
        var result: [AgentMemoryDocument] = []
        for rootURL in roots {
            let root = rootURL.resolvingSymlinksInPath().standardizedFileURL
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue,
                  rootURL.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL.path == root.path else { continue }
            let source = scope == .user ? "Home" : root.lastPathComponent
            for path in paths {
                let url = root.appendingPathComponent(path)
                guard fileManager.fileExists(atPath: url.path) else { continue }
                let document = WorkspaceDocument(url: url, relativePath: path)
                do {
                    _ = try reader.read(document, in: root)
                    result.append(AgentMemoryDocument(scope: scope, source: source, relativePath: path, root: root, document: document))
                } catch {
                    errors.append("\(source)/\(path): \(error.localizedDescription)")
                }
            }
        }
        return result
    }
}

public struct MemoryPanel: View {
    @Bindable private var model: MemoryPanelModel
    public init(model: MemoryPanelModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if let error = model.errorMessage {
                Text(error).font(Typography.caption).foregroundStyle(Palette.status(.error)).textSelection(.enabled)
            }
            HStack(spacing: 0) {
                List(selection: Binding(get: { model.selectedDocument?.id }, set: { id in
                    if let document = (model.projectDocuments + model.userDocuments).first(where: { $0.id == id }) {
                        model.select(document)
                    }
                })) {
                    if !model.projectDocuments.isEmpty {
                        Section("Project") {
                            ForEach(model.projectDocuments) { document in
                                Text(document.title).font(Typography.caption).tag(Optional(document.id))
                            }
                        }
                    }
                    if !model.userDocuments.isEmpty {
                        Section("User") {
                            ForEach(model.userDocuments) { document in
                                Text(document.title).font(Typography.caption).tag(Optional(document.id))
                            }
                        }
                    }
                }
                .listStyle(.sidebar).frame(minWidth: 180, idealWidth: 220)
                Rectangle().fill(Palette.border).frame(width: 1)
                Group {
                    if let document = model.selectedDocument {
                        ScrollView {
                            Group {
                                if let rendered = model.renderedText {
                                    Text(rendered).font(Typography.body).tint(Palette.accent)
                                } else {
                                    Text(model.source).font(Typography.body)
                                }
                            }
                            .foregroundStyle(Palette.ink).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(Spacing.sm)
                        }.accessibilityLabel("Memory document \(document.relativePath)")
                    } else {
                        ContentUnavailableView("No memory files found", systemImage: "brain", description: Text("Project and user agent instruction files appear here when present."))
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay { RoundedRectangle(cornerRadius: Spacing.radiusSmall).stroke(Palette.border, lineWidth: 1) }
            .clipShape(RoundedRectangle(cornerRadius: Spacing.radiusSmall))
            Text("Read-only · Local memory files · 1 MB limit").font(Typography.caption).foregroundStyle(Palette.mutedInk)
        }
        .padding(Spacing.sm).background(Palette.surface)
    }
}
