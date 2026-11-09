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

    /// Shown when no document can be listed. Pinned by `VerktoyPanelsTests`.
    public static let emptyStateTitle = "Ingen dokumenter"

    public init(model: DocsPanelModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            if model.projectRoots.count > 1 {
                PanelSection("Prosjektmappe") {
                    Picker("Project folder", selection: Binding(
                        get: { model.selectedRoot }, set: { root in if let root { model.selectRoot(root) } }
                    )) {
                        ForEach(model.projectRoots, id: \.path) { root in
                            Text(root.lastPathComponent).tag(Optional(root))
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .accessibilityIdentifier("docs.projectRoot")
                }
            }

            if let error = model.errorMessage {
                PanelSection("Feil") { errorText(error) }
            } else if model.projectRoots.isEmpty {
                EmptyStateView(
                    symbol: "folder",
                    title: Self.emptyStateTitle,
                    message: "Legg til en prosjektmappe i arbeidsområdet for å bla gjennom dokumentene.",
                    identifier: "docs.empty")
            } else if model.documents.isEmpty {
                EmptyStateView(
                    symbol: "doc.text.magnifyingglass",
                    title: Self.emptyStateTitle,
                    message: "Fant ingen dokumenter i prosjektmappen.",
                    identifier: "docs.empty")
            } else {
                PanelSection("Dokumenter", fillsHeight: true) { browser }
                    .frame(maxHeight: .infinity)
            }

            Text("Kun lesing · Lokale filer · Maks 1 MB")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.mutedInk)
        }
        .padding(DS.Space.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var browser: some View {
        HStack(spacing: 0) {
            List(selection: Binding(
                get: { model.selectedDocument?.id }, set: { id in
                    if let document = model.documents.first(where: { $0.id == id }) { model.select(document) }
                }
            )) {
                ForEach(model.documents) { document in
                    let isSelected = model.selectedDocument?.id == document.id
                    PanelRow(isSelected: isSelected) {
                        Text(document.relativePath)
                            .font(DS.Font.caption)
                            .foregroundStyle(isSelected ? DS.Color.accentInk : DS.Color.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .tag(Optional(document.id))
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(minWidth: 160, idealWidth: 190)
            .accessibilityIdentifier("docs.fileList")

            Rectangle().fill(DS.Color.hairline).frame(width: 1)

            Group {
                if let document = model.selectedDocument {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(document.relativePath)
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.secondaryInk)
                            .padding(DS.Space.sm)
                        if let error = model.selectionError {
                            EmptyStateView(
                                symbol: "exclamationmark.triangle",
                                title: "Unable to read document",
                                message: error,
                                identifier: "docs.selectionError")
                        } else {
                            ScrollView {
                                Text(model.text)
                                    .font(DS.Font.mono)
                                    .foregroundStyle(DS.Color.ink)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(DS.Space.sm)
                            }
                            .accessibilityIdentifier("docs.text")
                        }
                    }
                } else {
                    EmptyStateView(
                        symbol: "doc.text",
                        title: "Select a document",
                        message: "Markdown and plain text files in the project folder appear here.",
                        identifier: "docs.noSelection")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func errorText(_ error: String) -> some View {
        Text(error)
            .font(DS.Font.caption)
            .foregroundStyle(DS.Color.status(.error))
            .textSelection(.enabled)
    }
}
