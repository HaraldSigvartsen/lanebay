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

    /// Shown when no Markdown file can be listed. Pinned by `VerktoyPanelsTests`.
    public static let emptyStateTitle = "Ingen Markdown-filer"

    public init(model: MarkdownPanelModel) { self.model = model }

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
                    .accessibilityIdentifier("markdown.projectRoot")
                }
            }

            if let error = model.errorMessage {
                PanelSection("Feil") { errorText(error) }
            } else if model.projectRoots.isEmpty {
                EmptyStateView(
                    symbol: "folder",
                    title: Self.emptyStateTitle,
                    message: "Legg til en prosjektmappe i arbeidsområdet for å bla gjennom Markdown-filene.",
                    identifier: "markdown.empty")
            } else if model.documents.isEmpty {
                EmptyStateView(
                    symbol: "text.alignleft",
                    title: Self.emptyStateTitle,
                    message: "Fant ingen Markdown-filer i prosjektmappen.",
                    identifier: "markdown.empty")
            } else {
                PanelSection("Markdown", fillsHeight: true) { browser }
                    .frame(maxHeight: .infinity)
            }

            Text("Kun lesing · Lokal Markdown · Eksterne bilder av · Maks 1 MB")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.mutedInk)
        }
        .padding(DS.Space.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var browser: some View {
        VStack(alignment: .leading, spacing: DS.Space.sm) {
            HStack(spacing: DS.Space.xs) {
                Text(model.selectedDocument?.relativePath ?? "Markdown")
                    .font(DS.Font.caption)
                    .foregroundStyle(DS.Color.secondaryInk)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Picker("View", selection: $model.mode) {
                    ForEach(MarkdownPanelModel.Mode.allCases) { mode in Text(mode.rawValue).tag(mode) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
                .disabled(model.selectedDocument == nil)
                .accessibilityIdentifier("markdown.mode")
            }

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
                .accessibilityIdentifier("markdown.fileList")

                Rectangle().fill(DS.Color.hairline).frame(width: 1)

                Group {
                    if let document = model.selectedDocument {
                        ScrollView {
                            Group {
                                if let error = model.selectionError {
                                    EmptyStateView(
                                        symbol: "exclamationmark.triangle",
                                        title: "Unable to read Markdown",
                                        message: error,
                                        identifier: "markdown.selectionError")
                                } else if model.mode == .source {
                                    Text(model.source)
                                        .font(DS.Font.mono)
                                        .textSelection(.enabled)
                                } else if model.renderedText != nil {
                                    MarkdownBlocks(markdown: model.source, onOpenLink: model.openLink)
                                        .font(DS.Font.body)
                                        .tint(DS.Color.accent)
                                        .environment(\.openURL, OpenURLAction { url in
                                            model.openLink(url)
                                            return .handled
                                        })
                                } else {
                                    Text(model.source).font(DS.Font.body)
                                }
                            }
                            .foregroundStyle(DS.Color.ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(DS.Space.sm)
                        }
                        .accessibilityLabel("Markdown document \(document.relativePath)")
                        .accessibilityIdentifier("markdown.text")
                    } else {
                        EmptyStateView(
                            symbol: "text.alignleft",
                            title: "Select a Markdown file",
                            message: "Markdown files in the project folder appear here.",
                            identifier: "markdown.noSelection")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func errorText(_ error: String) -> some View {
        Text(error)
            .font(DS.Font.caption)
            .foregroundStyle(DS.Color.status(.error))
            .textSelection(.enabled)
    }
}
