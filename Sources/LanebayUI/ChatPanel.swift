import Foundation
import LanebayCore
import SwiftUI

public enum ChatTarget: Hashable, Identifiable {
    case console(UUID)
    case lead(UUID)
    case group(UUID)
    public var id: String {
        switch self { case .console(let id): "console-\(id)"; case .lead(let id): "lead-\(id)"; case .group(let id): "group-\(id)" }
    }
}

public struct ChatMessage: Codable, Identifiable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable { case sent, reply }
    public var id: UUID
    public var kind: Kind
    public var target: String
    public var text: String
    public var date: Date
    public init(id: UUID = UUID(), kind: Kind, target: String, text: String, date: Date = .now) {
        self.id = id; self.kind = kind; self.target = target; self.text = text; self.date = date
    }
}

public struct ChatTranscriptStore {
    public static let maxMessages = 200
    public static let maxMessageBytes = 8_192
    public static let maxTargetBytes = 256
    public static let maxFileBytes = 262_144
    private let rootURL: URL
    public init(rootURL: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Lanebay/Chat", isDirectory: true)) { self.rootURL = rootURL }
    private func file(_ workspaceID: UUID) -> URL { rootURL.appendingPathComponent("\(workspaceID.uuidString).json") }
    public func load(workspaceID: UUID) throws -> [ChatMessage] {
        let url = file(workspaceID)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        guard data.count <= Self.maxFileBytes else { throw ChatTranscriptStoreError.fileTooLarge(Self.maxFileBytes) }
        let messages = try JSONDecoder().decode([ChatMessage].self, from: data)
        return bounded(messages)
    }
    public func save(_ messages: [ChatMessage], workspaceID: UUID) throws {
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let bounded = bounded(messages)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Array(bounded))
        guard data.count <= Self.maxFileBytes else { throw ChatTranscriptStoreError.fileTooLarge(Self.maxFileBytes) }
        try AtomicPrivateFileWriter.write(data, to: file(workspaceID), temporaryPrefix: "chat")
    }
    private func bounded(_ messages: [ChatMessage]) -> [ChatMessage] {
        messages.suffix(Self.maxMessages).map { message -> ChatMessage in
            var copy = message
            copy.text = Self.bounded(copy.text, bytes: Self.maxMessageBytes)
            copy.target = Self.bounded(copy.target, bytes: Self.maxTargetBytes)
            return copy
        }
    }
    static func bounded(_ string: String, bytes: Int) -> String {
        guard string.utf8.count > bytes else { return string }
        var result = ""
        for scalar in string.unicodeScalars.reversed() {
            let next = String(scalar) + result
            if next.utf8.count > bytes { break }
            result = next
        }
        return result
    }
}

public enum ChatTranscriptStoreError: LocalizedError {
    case fileTooLarge(Int)
    public var errorDescription: String? {
        switch self {
        case .fileTooLarge(let max): return "Chat transcript is too large to load or save (limit \(max) bytes)."
        }
    }
}

@MainActor @Observable
public final class ChatPanelModel {
    public private(set) var messages: [ChatMessage] = []
    public private(set) var errorMessage: String?
    public var draft = ""
    public var target: ChatTarget?
    private let store: ChatTranscriptStore
    private var workspaceID: UUID?
    public init(workspaceID: UUID?, store: ChatTranscriptStore = ChatTranscriptStore()) { self.store = store; setWorkspace(workspaceID) }
    public func setWorkspace(_ id: UUID?) {
        guard id != workspaceID else { return }
        workspaceID = id; messages = []; target = nil
        guard let id else { return }
        do { messages = try store.load(workspaceID: id); errorMessage = nil } catch { errorMessage = error.localizedDescription }
    }
    @discardableResult public func send(text: String, targetName: String, dispatch: () -> Bool, reply: String?) -> Bool {
        guard let workspaceID, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, dispatch() else { return false }
        let boundedTarget = ChatTranscriptStore.bounded(targetName, bytes: ChatTranscriptStore.maxTargetBytes)
        messages.append(ChatMessage(kind: .sent, target: boundedTarget, text: ChatTranscriptStore.bounded(text, bytes: ChatTranscriptStore.maxMessageBytes)))
        if let reply, !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            messages.append(ChatMessage(kind: .reply, target: boundedTarget, text: ChatTranscriptStore.bounded(reply, bytes: ChatTranscriptStore.maxMessageBytes)))
        }
        messages = Array(messages.suffix(ChatTranscriptStore.maxMessages))
        do { try store.save(messages, workspaceID: workspaceID); errorMessage = nil } catch { errorMessage = error.localizedDescription }
        return true
    }
}

public struct ChatPanel: View {
    @Bindable private var model: ChatPanelModel
    let workspace: Workspace?
    let sessions: [UUID: ConsoleSession]
    let onSendConsole: (String, UUID) -> Bool
    let onSendLead: (String, UUID) -> Bool
    let onSendGroup: (String, UUID) -> Bool
    let onExcerpt: (UUID) -> String?
    public init(model: ChatPanelModel, workspace: Workspace?, sessions: [UUID: ConsoleSession], onSendConsole: @escaping (String, UUID) -> Bool, onSendLead: @escaping (String, UUID) -> Bool, onSendGroup: @escaping (String, UUID) -> Bool, onExcerpt: @escaping (UUID) -> String?) {
        self.model = model; self.workspace = workspace; self.sessions = sessions; self.onSendConsole = onSendConsole; self.onSendLead = onSendLead; self.onSendGroup = onSendGroup; self.onExcerpt = onExcerpt
    }
    private var targets: [(ChatTarget, String)] {
        guard let workspace else { return [] }
        var result = workspace.nodes.filter { $0.kind == .console }.map { (ChatTarget.console($0.id), $0.title) }
        for group in workspace.groups { if let id = group.leadNodeID, let node = workspace.nodes.first(where: { $0.id == id }) { result.append((.lead(group.id), "\(group.name) lead · \(node.title)")) }; result.append((.group(group.id), "\(group.name) · idle members")) }
        return result
    }
    public var body: some View {
        VStack(spacing: Spacing.sm) {
            Picker("Send to", selection: $model.target) { Text("Choose recipient").tag(ChatTarget?.none); ForEach(targets, id: \.0) { target, label in Text(label).tag(Optional(target)) } }.pickerStyle(.menu)
            ScrollViewReader { proxy in
                ScrollView { LazyVStack(alignment: .leading, spacing: Spacing.sm) {
                    ForEach(model.messages) { message in
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            Text(message.kind == .sent ? "You → \(message.target)" : "\(message.target) · console output").font(Typography.caption).foregroundStyle(Palette.mutedInk)
                            Text(message.text).font(Typography.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(Spacing.sm).background(message.kind == .sent ? Palette.accentSoft : Palette.raisedSurface, in: RoundedRectangle(cornerRadius: Spacing.radiusSmall)).id(message.id)
                    }
                }.padding(Spacing.sm) }.onChange(of: model.messages.last?.id) { _, id in if let id { proxy.scrollTo(id, anchor: .bottom) } }
            }.overlay { if model.messages.isEmpty { Text("Messages and recent console output will appear here.").font(Typography.caption).foregroundStyle(Palette.mutedInk) } }
            TextEditor(text: $model.draft).font(Typography.body).frame(minHeight: 72, maxHeight: 120).scrollContentBackground(.hidden).padding(Spacing.xxs).background(Palette.raisedSurface, in: RoundedRectangle(cornerRadius: Spacing.radiusSmall)).overlay(RoundedRectangle(cornerRadius: Spacing.radiusSmall).stroke(Palette.border)).accessibilityLabel("Chat message")
            HStack { if let error = model.errorMessage { Text(error).font(Typography.caption).foregroundStyle(Palette.status(.error)).lineLimit(2) }; Spacer(); Button { send() } label: { Label("Send", systemImage: "arrow.up") }.buttonStyle(.borderedProminent).disabled(model.target == nil || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(Spacing.sm).background(Palette.surface)
    }
    private func send() {
        guard let target = model.target else { return }
        let entry = targets.first { $0.0 == target }?.1 ?? "Console"
        let text = model.draft
        let dispatched = model.send(text: text, targetName: entry, dispatch: {
            switch target { case .console(let id): return onSendConsole(text, id); case .lead(let id): return onSendLead(text, id); case .group(let id): return onSendGroup(text, id) }
        }, reply: {
            let ids: [UUID]
            switch target { case .console(let id): ids = [id]; case .lead(let groupID): ids = workspace?.groups.first(where: { $0.id == groupID }).map { $0.leadNodeID.map { [$0] } ?? [] } ?? []; case .group(let groupID): ids = workspace?.groups.first(where: { $0.id == groupID })?.nodeIDs ?? [] }
            return ids.compactMap { id in onExcerpt(id).map { output in "\(workspace?.nodes.first(where: { $0.id == id })?.title ?? "Console"): \(output)" } }.joined(separator: "\n\n").nilIfEmpty
        }())
        if dispatched { model.draft = "" }
    }
}

private extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }
