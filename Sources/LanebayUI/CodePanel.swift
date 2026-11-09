import LanebayCore
import SwiftUI

@MainActor
@Observable
public final class CodePanelModel {
    public private(set) var projectRoots: [URL]
    public private(set) var selectedRoot: URL?
    public private(set) var files: [WorkspaceSourceFile] = []
    public private(set) var selectedFile: WorkspaceSourceFile?
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

    public func select(_ file: WorkspaceSourceFile) {
        guard let root = selectedRoot, files.contains(file) else { return }
        do {
            text = try reader.readSourceFile(file, in: root)
            selectedFile = file
            errorMessage = nil
            selectionError = nil
        } catch {
            text = ""
            selectedFile = file
            selectionError = error.localizedDescription
        }
    }

    public func reload() {
        text = ""
        selectedFile = nil
        selectionError = nil
        guard let root = selectedRoot else { files = []; errorMessage = nil; return }
        do {
            files = try reader.listSourceFiles(in: root)
            errorMessage = nil
        } catch {
            files = []
            errorMessage = error.localizedDescription
        }
    }
}

public struct CodePanel: View {
    @Bindable private var model: CodePanelModel

    /// Shown when no source file can be listed. Pinned by `VerktoyPanelsTests`.
    public static let emptyStateTitle = "Ingen kildefiler"

    public init(model: CodePanelModel) { self.model = model }

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
                    .accessibilityIdentifier("code.projectRoot")
                }
            }

            if let error = model.errorMessage {
                PanelSection("Feil") { errorText(error) }
            } else if model.projectRoots.isEmpty {
                EmptyStateView(
                    symbol: "folder",
                    title: Self.emptyStateTitle,
                    message: "Legg til en prosjektmappe i arbeidsområdet for å bla gjennom kildekoden.",
                    identifier: "code.empty")
            } else if model.files.isEmpty {
                EmptyStateView(
                    symbol: "doc.text.magnifyingglass",
                    title: Self.emptyStateTitle,
                    message: "Fant ingen kildefiler i prosjektmappen.",
                    identifier: "code.empty")
            } else {
                PanelSection("Filer", fillsHeight: true) { browser }
                    .frame(maxHeight: .infinity)
            }

            Text("Kun lesing · Lokal kildekode · Maks 1 MB")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.mutedInk)
        }
        .padding(DS.Space.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var browser: some View {
        HStack(spacing: 0) {
            List(selection: Binding(
                get: { model.selectedFile?.id }, set: { id in
                    if let file = model.files.first(where: { $0.id == id }) { model.select(file) }
                }
            )) {
                ForEach(model.files) { file in
                    let isSelected = model.selectedFile?.id == file.id
                    PanelRow(isSelected: isSelected) {
                        Text(file.relativePath)
                            .font(DS.Font.mono)
                            .foregroundStyle(isSelected ? DS.Color.accentInk : DS.Color.ink)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .tag(Optional(file.id))
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(minWidth: 170, idealWidth: 210)
            .accessibilityIdentifier("code.fileList")

            Rectangle().fill(DS.Color.hairline).frame(width: 1)

            Group {
                if let file = model.selectedFile {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(file.relativePath)
                            .font(DS.Font.caption)
                            .foregroundStyle(DS.Color.secondaryInk)
                            .padding(DS.Space.sm)
                        if let error = model.selectionError {
                            EmptyStateView(
                                symbol: "exclamationmark.triangle",
                                title: "Unable to read source file",
                                message: error,
                                identifier: "code.selectionError")
                        } else {
                            sourceText
                        }
                    }
                } else {
                    EmptyStateView(
                        symbol: "chevron.left.forwardslash.chevron.right",
                        title: "Select a source file",
                        message: "Project source files appear here.",
                        identifier: "code.noSelection")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var sourceText: some View {
        ScrollView([.horizontal, .vertical]) {
            HStack(alignment: .top, spacing: DS.Space.sm) {
                let lines = model.text.components(separatedBy: "\n")
                VStack(alignment: .trailing, spacing: 0) {
                    ForEach(lines.indices, id: \.self) { index in
                        Text("\(index + 1)").foregroundStyle(DS.Color.mutedInk)
                            .frame(minWidth: 32, alignment: .trailing)
                    }
                }
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : line).foregroundStyle(DS.Color.ink)
                    }
                }
                .textSelection(.enabled)
            }
            .font(DS.Font.mono)
            .padding(DS.Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("code.source")
    }

    private func errorText(_ error: String) -> some View {
        Text(error)
            .font(DS.Font.caption)
            .foregroundStyle(DS.Color.status(.error))
            .textSelection(.enabled)
    }
}
