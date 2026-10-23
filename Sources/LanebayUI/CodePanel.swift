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

    public init(model: CodePanelModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if model.projectRoots.count > 1 {
                Picker("Project folder", selection: Binding(
                    get: { model.selectedRoot }, set: { root in if let root { model.selectRoot(root) } }
                )) {
                    ForEach(model.projectRoots, id: \.path) { root in Text(root.lastPathComponent).tag(Optional(root)) }
                }.pickerStyle(.menu)
            }
            if let error = model.errorMessage {
                Text(error).font(Typography.caption).foregroundStyle(Palette.status(.error)).textSelection(.enabled)
            } else if model.projectRoots.isEmpty {
                Text("Add a project folder to this workspace to browse its source code.")
                    .font(Typography.body).foregroundStyle(Palette.secondaryInk)
            } else {
                HStack(spacing: 0) {
                    List(selection: Binding(
                        get: { model.selectedFile?.id }, set: { id in
                            if let file = model.files.first(where: { $0.id == id }) { model.select(file) }
                        }
                    )) {
                        ForEach(model.files) { file in
                            Text(file.relativePath).font(Typography.caption.monospaced()).tag(Optional(file.id))
                        }
                    }
                    .listStyle(.sidebar)
                    .frame(minWidth: 170, idealWidth: 210)
                    Rectangle().fill(Palette.border).frame(width: 1)
                    Group {
                        if let file = model.selectedFile {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(file.relativePath).font(Typography.caption).foregroundStyle(Palette.secondaryInk).padding(Spacing.sm)
                                if let error = model.selectionError {
                                    ContentUnavailableView("Unable to read source file", systemImage: "exclamationmark.triangle", description: Text(error))
                                } else {
                                    ScrollView([.horizontal, .vertical]) {
                                        HStack(alignment: .top, spacing: Spacing.sm) {
                                            let lines = model.text.components(separatedBy: "\n")
                                            VStack(alignment: .trailing, spacing: 0) {
                                                ForEach(lines.indices, id: \.self) { index in
                                                    Text("\(index + 1)").foregroundStyle(Palette.mutedInk)
                                                        .frame(minWidth: 32, alignment: .trailing)
                                                }
                                            }
                                            VStack(alignment: .leading, spacing: 0) {
                                                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                                                    Text(line.isEmpty ? " " : line).foregroundStyle(Palette.ink)
                                                }
                                            }
                                            .textSelection(.enabled)
                                        }
                                        .font(Typography.terminal)
                                        .padding(Spacing.sm)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                            }
                        } else {
                            ContentUnavailableView("Select a source file", systemImage: "chevron.left.forwardslash.chevron.right", description: Text("Project source files appear here."))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .overlay { RoundedRectangle(cornerRadius: Spacing.radiusSmall).stroke(Palette.border, lineWidth: 1) }
                .clipShape(RoundedRectangle(cornerRadius: Spacing.radiusSmall))
            }
            Text("Read-only · Local source files · 1 MB limit").font(Typography.caption).foregroundStyle(Palette.mutedInk)
        }
        .padding(Spacing.sm)
        .background(Palette.surface)
    }
}
