import AppKit
import Foundation
import LanebayCore
import SwiftUI

@MainActor
@Observable
public final class MarkdownPanelModel {
    public enum Mode: String, CaseIterable, Identifiable {
        case rendered = "Rendered"
        case source = "Source"
        public var id: String { rawValue }
    }

    public private(set) var projectRoots: [URL]
    public private(set) var selectedRoot: URL?
    public private(set) var documents: [WorkspaceDocument] = []
    public private(set) var selectedDocument: WorkspaceDocument?
    public private(set) var source = ""
    public private(set) var errorMessage: String?
    public private(set) var selectionError: String?
    public var mode: Mode = .rendered
    private let reader: WorkspaceDocuments

    public init(workspace: Workspace?, reader: WorkspaceDocuments = WorkspaceDocuments()) {
        self.reader = reader
        var seen = Set<String>()
        projectRoots = (workspace?.repos ?? []).sorted { $0.path < $1.path }
            .filter { seen.insert($0.resolvingSymlinksInPath().standardizedFileURL.path).inserted }
        selectedRoot = projectRoots.first
        reload()
    }

    public var renderedText: AttributedString? {
        guard selectedDocument != nil else { return nil }
        return try? AttributedString(markdown: source, options: .init(interpretedSyntax: .full))
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
            source = try reader.read(document, in: root)
            selectedDocument = document
            errorMessage = nil
            selectionError = nil
        } catch {
            source = ""
            selectedDocument = document
            selectionError = error.localizedDescription
        }
    }

    public func reload() {
        source = ""
        selectedDocument = nil
        selectionError = nil
        guard let root = selectedRoot else { documents = []; errorMessage = nil; return }
        do {
            documents = try reader.list(in: root)
                .filter { ["md", "markdown"].contains($0.url.pathExtension.lowercased()) }
                .filter { document in
                    do {
                        _ = try reader.read(document, in: root)
                        return true
                    } catch {
                        return false
                    }
                }
            errorMessage = nil
        } catch {
            documents = []
            errorMessage = error.localizedDescription
        }
    }

    /// Opens only explicitly clicked HTTP(S) links in the user's default browser.
    public func openLink(_ url: URL) {
        SafeExternalLinkOpener.open(url) { NSWorkspace.shared.open($0) }
    }
}

public struct MarkdownPanel: View {
    @Bindable private var model: MarkdownPanelModel

    public init(model: MarkdownPanelModel) { self.model = model }

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
                Text("Add a project folder to this workspace to browse its Markdown files.")
                    .font(Typography.body).foregroundStyle(Palette.secondaryInk)
            } else {
                HStack(spacing: Spacing.xs) {
                    Text(model.selectedDocument?.relativePath ?? "Markdown")
                        .font(Typography.caption).foregroundStyle(Palette.secondaryInk).lineLimit(1)
                    Spacer(minLength: 0)
                    Picker("View", selection: $model.mode) {
                        ForEach(MarkdownPanelModel.Mode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 150)
                    .disabled(model.selectedDocument == nil)
                }
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
                            ScrollView {
                                Group {
                                    if let error = model.selectionError {
                                        ContentUnavailableView("Unable to read Markdown", systemImage: "exclamationmark.triangle", description: Text(error))
                                    } else if model.mode == .source {
                                        Text(model.source).font(Typography.body.monospaced()).textSelection(.enabled)
                                    } else if model.renderedText != nil {
                                        MarkdownBlocks(markdown: model.source, onOpenLink: model.openLink)
                                            .font(Typography.body)
                                            .tint(Palette.accent)
                                            .environment(\.openURL, OpenURLAction { url in
                                                model.openLink(url)
                                                return .handled
                                            })
                                    } else {
                                        Text(model.source).font(Typography.body)
                                    }
                                }
                                .foregroundStyle(Palette.ink)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(Spacing.sm)
                            }
                            .accessibilityLabel("Markdown document \(document.relativePath)")
                        } else {
                            ContentUnavailableView("Select a Markdown file", systemImage: "text.alignleft", description: Text("Markdown files in the project folder appear here."))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .overlay { RoundedRectangle(cornerRadius: Spacing.radiusSmall).stroke(Palette.border, lineWidth: 1) }
                .clipShape(RoundedRectangle(cornerRadius: Spacing.radiusSmall))
            }
            Text("Read-only · Local Markdown · 1 MB limit · Remote images disabled")
                .font(Typography.caption).foregroundStyle(Palette.mutedInk)
        }
        .padding(Spacing.sm)
        .background(Palette.surface)
    }
}
