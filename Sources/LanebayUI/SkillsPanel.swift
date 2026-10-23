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
    public init(model: SkillsPanelModel) { self.model = model }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if let error = model.errorMessage {
                Text(error).font(Typography.caption).foregroundStyle(Palette.status(.error)).textSelection(.enabled)
            }
            HStack(spacing: 0) {
                List(selection: Binding(get: { model.selectedSkill?.id }, set: { id in
                    if let skill = model.skills.first(where: { $0.id == id }) { model.select(skill) }
                })) {
                    ForEach(model.skills) { skill in
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            Text(skill.name).font(Typography.body)
                            Text("\(skill.source) · \(skill.description)").font(Typography.caption).foregroundStyle(Palette.secondaryInk).lineLimit(2)
                        }.tag(Optional(skill.id))
                    }
                }
                .listStyle(.sidebar).frame(minWidth: 190, idealWidth: 230)
                Rectangle().fill(Palette.border).frame(width: 1)
                Group {
                    if let skill = model.selectedSkill {
                        ScrollView {
                            if model.renderedText != nil {
                                MarkdownBlocks(markdown: model.source, onOpenLink: model.openLink).font(Typography.body).tint(Palette.accent).textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(Spacing.sm)
                            } else { Text(model.source).font(Typography.body).textSelection(.enabled).padding(Spacing.sm) }
                        }.accessibilityLabel("Skill \(skill.name)")
                    } else {
                        ContentUnavailableView("Select a skill", systemImage: "sparkles", description: Text("Skills found in project and home skill folders appear here."))
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay { RoundedRectangle(cornerRadius: Spacing.radiusSmall).stroke(Palette.border, lineWidth: 1) }
            .clipShape(RoundedRectangle(cornerRadius: Spacing.radiusSmall))
            Text("Read-only · Local skill files · 1 MB limit").font(Typography.caption).foregroundStyle(Palette.mutedInk)
        }
        .padding(Spacing.sm).background(Palette.surface)
    }
}
