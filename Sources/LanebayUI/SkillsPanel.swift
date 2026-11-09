import LanebayCore
import SwiftUI
import AppKit

public struct AgentSkill: Identifiable, Sendable, Equatable {
    public let name: String
    public let description: String
    public let source: String
    public let relativePath: String
    fileprivate let document: WorkspaceDocument
    fileprivate let root: URL
    public var id: String { document.url.standardizedFileURL.resolvingSymlinksInPath().absoluteString }
}

@MainActor
@Observable
public final class SkillsPanelModel {
    public private(set) var skills: [AgentSkill] = []
    public private(set) var selectedSkill: AgentSkill?
    public private(set) var source = ""
    public private(set) var errorMessage: String?
    private let linkOpener: @MainActor (URL) -> Void
    private var projectRoots: [URL]
    private let homeRoot: URL
    private let reader: WorkspaceDocuments

    public init(workspace: Workspace?, homeRoot: URL = FileManager.default.homeDirectoryForCurrentUser,
                reader: WorkspaceDocuments = WorkspaceDocuments(), linkOpener: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.reader = reader
        self.linkOpener = linkOpener
        self.homeRoot = homeRoot
        var seen = Set<String>()
        projectRoots = (workspace?.repos ?? []).map { $0.resolvingSymlinksInPath().standardizedFileURL }
            .filter { seen.insert($0.path).inserted }
        reload()
    }

    public func select(_ skill: AgentSkill) {
        guard skills.contains(skill) else { return }
        do {
            source = try reader.read(skill.document, in: skill.root)
            selectedSkill = skill
            errorMessage = nil
        } catch {
            source = ""
            selectedSkill = nil
            errorMessage = error.localizedDescription
        }
    }

    public var renderedText: AttributedString? {
        guard selectedSkill != nil else { return nil }
        return try? AttributedString(markdown: source, options: .init(interpretedSyntax: .full))
    }

    public func openLink(_ url: URL) { SafeExternalLinkOpener.open(url, using: linkOpener) }

    public func update(workspace: Workspace?) {
        var seen = Set<String>()
        let nextRoots = (workspace?.repos ?? []).map { $0.resolvingSymlinksInPath().standardizedFileURL }
            .filter { seen.insert($0.path).inserted }
        guard nextRoots != projectRoots else { return }
        projectRoots = nextRoots
        reload()
    }

    public func reload() {
        skills = []
        selectedSkill = nil
        source = ""
        errorMessage = nil
        var found: [AgentSkill] = []
        var errors: [String] = []
        for root in projectRoots {
            for folder in [".codex/skills", ".claude/skills", ".agents/skills"] {
                collectSkills(in: root.appendingPathComponent(folder, isDirectory: true), source: root.lastPathComponent, into: &found, errors: &errors)
            }
        }
        for folder in [".codex/skills", ".claude/skills", ".agents/skills"] {
            collectSkills(in: homeRoot.appendingPathComponent(folder, isDirectory: true), source: "Home", into: &found, errors: &errors)
        }
        skills = found.sorted { ($0.source + $0.name).localizedStandardCompare($1.source + $1.name) == .orderedAscending }
        errorMessage = errors.isEmpty ? nil : errors.joined(separator: "\n")
    }

    private func collectSkills(in folder: URL, source: String, into found: inout [AgentSkill], errors: inout [String]) {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue,
              folder.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL.path == folder.standardizedFileURL.path else { return }
        do {
            let attributes = try fm.attributesOfItem(atPath: folder.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { return }
            let canonical = folder.standardizedFileURL
            let docs = try reader.listMarkdown(in: canonical)
            for doc in docs where URL(fileURLWithPath: doc.relativePath).lastPathComponent == "SKILL.md" {
                do {
                    let text = try reader.read(doc, in: canonical)
                    guard let metadata = Self.frontmatter(text) else { continue }
                    found.append(AgentSkill(name: metadata.name ?? URL(fileURLWithPath: doc.relativePath).deletingLastPathComponent().lastPathComponent,
                                            description: metadata.description ?? "", source: source,
                                            relativePath: doc.relativePath, document: doc, root: canonical))
                } catch { errors.append("\(source)/\(doc.relativePath): \(error.localizedDescription)") }
            }
        } catch { errors.append("\(source): \(error.localizedDescription)") }
    }

    private static func frontmatter(_ text: String) -> (name: String?, description: String?)? {
        let lines = text.components(separatedBy: .newlines)
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) else { return nil }
        var values: [String: String] = [:]
        for line in lines[1..<end] {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard key == "name" || key == "description" else { continue }
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, (first == "\"" || first == "'"), value.last == first {
                value.removeFirst(); value.removeLast()
            }
            values[key] = value
        }
        return (values["name"], values["description"])
    }
}

public struct SkillsPanel: View {
    @Bindable private var model: SkillsPanelModel

    /// Shown when no SKILL.md was found. Pinned by `VerktoyPanelsTests`.
    public static let emptyStateTitle = "Ingen skills funnet"

    public init(model: SkillsPanelModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            if let error = model.errorMessage {
                PanelSection("Feil") { errorText(error) }
            }

            if model.skills.isEmpty {
                EmptyStateView(
                    symbol: "sparkles",
                    title: Self.emptyStateTitle,
                    message: "Skills i prosjekt- og hjemmemappene .codex/skills, .claude/skills og .agents/skills vises her.",
                    identifier: "skills.empty")
            } else {
                PanelSection("Skills", fillsHeight: true) { browser }
                    .frame(maxHeight: .infinity)
            }

            Text("Kun lesing · Lokale skill-filer · Maks 1 MB")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.mutedInk)
        }
        .padding(DS.Space.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var browser: some View {
        HStack(spacing: 0) {
            List(selection: Binding(get: { model.selectedSkill?.id }, set: { id in
                if let skill = model.skills.first(where: { $0.id == id }) { model.select(skill) }
            })) {
                ForEach(model.skills) { skill in
                    let isSelected = model.selectedSkill?.id == skill.id
                    PanelRow(isSelected: isSelected) {
                        VStack(alignment: .leading, spacing: DS.Space.xxs) {
                            Text(skill.name)
                                .font(DS.Font.body)
                                .foregroundStyle(isSelected ? DS.Color.accentInk : DS.Color.ink)
                                .lineLimit(1)
                            Text("\(skill.source) · \(skill.description)")
                                .font(DS.Font.caption)
                                .foregroundStyle(DS.Color.secondaryInk)
                                .lineLimit(2)
                        }
                    }
                    .tag(Optional(skill.id))
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(minWidth: 190, idealWidth: 230)
            .accessibilityIdentifier("skills.list")

            Rectangle().fill(DS.Color.hairline).frame(width: 1)

            Group {
                if let skill = model.selectedSkill {
                    ScrollView {
                        Group {
                            if model.renderedText != nil {
                                MarkdownBlocks(markdown: model.source, onOpenLink: model.openLink)
                                    .font(DS.Font.body)
                                    .tint(DS.Color.accent)
                                    .textSelection(.enabled)
                            } else {
                                Text(model.source)
                                    .font(DS.Font.body)
                                    .foregroundStyle(DS.Color.ink)
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DS.Space.sm)
                    }
                    .accessibilityLabel("Skill \(skill.name)")
                    .accessibilityIdentifier("skills.text")
                } else {
                    EmptyStateView(
                        symbol: "sparkles",
                        title: "Select a skill",
                        message: "Skills found in project and home skill folders appear here.",
                        identifier: "skills.noSelection")
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
