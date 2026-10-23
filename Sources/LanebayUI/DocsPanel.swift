import LanebayCore
import SwiftUI

@MainActor
@Observable
public final class DocsPanelModel {
    public private(set) var projectRoots: [URL]
    public private(set) var selectedRoot: URL?
    public private(set) var documents: [WorkspaceDocument] = []
    public private(set) var selectedDocument: WorkspaceDocument?
    public private(set) var text = ""
    public private(set) var errorMessage: String?
    public private(set) var selectionError: String?
    private let reader: WorkspaceDocuments

    public init(workspace: Workspace?, reader: WorkspaceDocuments = WorkspaceDocuments()) {
        self.reader = reader
        var seen = Set<String>()
        projectRoots = (workspace?.repos ?? []).sorted { $0.path < $1.path }
            .filter { seen.insert($0.resolvingSymlinksInPath().standardizedFileURL.path).inserted }
        selectedRoot = projectRoots.first
        reload()
    }

    public func selectRoot(_ root: URL) {
        guard projectRoots.contains(root) else { return }
        selectedRoot = root
        reload()
    }

    public func update(workspace: Workspace?) {
        var seen = Set<String>()
        let nextRoots = (workspace?.repos ?? []).sorted { $0.path < $1.path }
            .filter { seen.insert($0.resolvingSymlinksInPath().standardizedFileURL.path).inserted }
        guard nextRoots != projectRoots else { return }
        let previousRoot = selectedRoot
        projectRoots = nextRoots
        selectedRoot = nextRoots.first(where: { $0 == previousRoot }) ?? nextRoots.first
        reload()
    }

    public func select(_ document: WorkspaceDocument) {
        guard let root = selectedRoot, documents.contains(document) else { return }
        do {
            text = try reader.read(document, in: root)
            selectedDocument = document
            errorMessage = nil
            selectionError = nil
        } catch {
            text = ""
            selectedDocument = document
            selectionError = error.localizedDescription
        }
    }

    public func reload() {
        text = ""
        selectedDocument = nil
        selectionError = nil
        guard let root = selectedRoot else { documents = []; errorMessage = nil; return }
        do {
            documents = try reader.list(in: root)
            errorMessage = nil
        } catch {
            documents = []
            errorMessage = error.localizedDescription
        }
    }
}

public struct DocsPanel: View {
    @Bindable private var model: DocsPanelModel

    public init(model: DocsPanelModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if model.projectRoots.count > 1 {
                Picker("Project folder", selection: Binding(
                    get: { model.selectedRoot }, set: { root in if let root { model.selectRoot(root) } }
                )) {
                    ForEach(model.projectRoots, id: \.path) { root in Text(root.lastPathComponent).tag(Optional(root)) }
                }
                .pickerStyle(.menu)
            }
            if let error = model.errorMessage {
                Text(error).font(Typography.caption).foregroundStyle(Palette.status(.error)).textSelection(.enabled)
            } else if model.projectRoots.isEmpty {
                Text("Add a project folder to this workspace to browse its documents.")
                    .font(Typography.body).foregroundStyle(Palette.secondaryInk)
            } else {
                HStack(spacing: 0) {
                    List(selection: Binding(
                        get: { model.selectedDocument?.id }, set: { id in
                            if let document = model.documents.first(where: { $0.id == id }) { model.select(document) }
                        }
                    )) {
                        ForEach(model.documents) { document in
                            Text(document.relativePath).font(Typography.caption).tag(Optional(document.id))
                        }
                    }
                    .listStyle(.sidebar)
                    .frame(minWidth: 160, idealWidth: 190)
                    Rectangle().fill(Palette.border).frame(width: 1)
                    Group {
                        if let document = model.selectedDocument {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(document.relativePath).font(Typography.caption).foregroundStyle(Palette.secondaryInk).padding(Spacing.sm)
                                if let error = model.selectionError {
                                    ContentUnavailableView("Unable to read document", systemImage: "exclamationmark.triangle", description: Text(error))
                                } else {
                                    ScrollView {
                                        Text(model.text).font(Typography.body.monospaced()).textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading).padding(Spacing.sm)
                                    }
                                }
                            }
                        } else {
                            ContentUnavailableView("Select a document", systemImage: "doc.text", description: Text("Markdown and plain text files in the project folder appear here."))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .overlay { RoundedRectangle(cornerRadius: Spacing.radiusSmall).stroke(Palette.border, lineWidth: 1) }
                .clipShape(RoundedRectangle(cornerRadius: Spacing.radiusSmall))
            }
            Text("Read-only · Local files · 1 MB limit").font(Typography.caption).foregroundStyle(Palette.mutedInk)
        }
        .padding(Spacing.sm)
        .background(Palette.surface)
    }
}
