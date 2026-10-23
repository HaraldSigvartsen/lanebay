import LanebayCore
import SwiftUI

@MainActor @Observable
public final class PresetsPanelModel {
    public private(set) var presets: [PromptPreset] = []
    public var selectedID: UUID?
    public var name = ""
    public var text = ""
    public var targetAgentKind: String?
    public private(set) var errorMessage: String?
    private let store: PresetsStore

    public init(store: PresetsStore = PresetsStore()) {
        self.store = store
        do { presets = try store.load() }
        catch { errorMessage = error.localizedDescription }
    }

    public var selectedPreset: PromptPreset? { presets.first { $0.id == selectedID } }

    public func select(_ preset: PromptPreset) {
        guard presets.contains(where: { $0.id == preset.id }) else { return }
        selectedID = preset.id
        name = preset.name
        text = preset.text
        targetAgentKind = preset.targetAgentKind
    }

    public func newPreset() {
        selectedID = nil
        name = ""
        text = ""
        targetAgentKind = nil
    }

    @discardableResult public func save() -> Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        var updated = presets
        if let selectedID, let index = updated.firstIndex(where: { $0.id == selectedID }) {
            updated[index] = PromptPreset(id: selectedID, name: name, text: text, targetAgentKind: targetAgentKind)
        } else {
            let preset = PromptPreset(name: name, text: text, targetAgentKind: targetAgentKind)
            updated.append(preset)
            selectedID = preset.id
        }
        return persist(updated)
    }

    public func deleteSelected() {
        guard let selectedID else { return }
        _ = persist(presets.filter { $0.id != selectedID })
        newPreset()
    }

    @discardableResult private func persist(_ updated: [PromptPreset]) -> Bool {
        do {
            try store.save(updated)
            presets = updated.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

public struct PresetsPanel: View {
    @Bindable private var model: PresetsPanelModel
    let agentKinds: [String]
    let onSend: (String, String?) -> Bool

    public init(model: PresetsPanelModel, agentKinds: [String], onSend: @escaping (String, String?) -> Bool) {
        self.model = model
        self.agentKinds = agentKinds
        self.onSend = onSend
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack {
                Text("Saved prompts and commands").font(Typography.caption).foregroundStyle(Palette.secondaryInk)
                Spacer()
                Button { model.newPreset() } label: { Label("New", systemImage: "plus") }
            }
            HStack(spacing: 0) {
                List(selection: Binding(get: { model.selectedID }, set: { id in
                    if let preset = model.presets.first(where: { $0.id == id }) { model.select(preset) }
                })) {
                    ForEach(model.presets) { preset in
                        VStack(alignment: .leading, spacing: Spacing.xxs) {
                            Text(preset.name).font(Typography.bodyEmphasis).lineLimit(1)
                            Text(preset.targetAgentKind ?? "Any agent").font(Typography.caption).foregroundStyle(Palette.mutedInk)
                        }.tag(Optional(preset.id))
                    }
                }
                .listStyle(.sidebar).frame(minWidth: 150, idealWidth: 180)
                Rectangle().fill(Palette.border).frame(width: 1)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    TextField("Name", text: $model.name).textFieldStyle(.roundedBorder)
                    Picker("Target", selection: $model.targetAgentKind) {
                        Text("Any agent").tag(String?.none)
                        ForEach(agentKinds, id: \.self) { kind in Text(kind.capitalized).tag(Optional(kind)) }
                    }
                    TextEditor(text: $model.text)
                        .font(Typography.body).scrollContentBackground(.hidden)
                        .padding(Spacing.xxs).background(Palette.raisedSurface, in: RoundedRectangle(cornerRadius: Spacing.radiusSmall))
                        .overlay(RoundedRectangle(cornerRadius: Spacing.radiusSmall).stroke(Palette.border))
                        .accessibilityLabel("Preset prompt or command")
                    if let error = model.errorMessage {
                        Text(error).font(Typography.caption).foregroundStyle(Palette.status(.error)).textSelection(.enabled)
                    }
                    HStack {
                        if model.selectedID != nil {
                            Button("Delete", role: .destructive) { model.deleteSelected() }
                        }
                        Spacer()
                        Button("Save") { _ = model.save() }
                            .disabled(model.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button { _ = onSend(model.text, model.targetAgentKind) } label: { Label("Send", systemImage: "arrow.up") }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.selectedPreset == nil || model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
                .padding(Spacing.sm).frame(minWidth: 250)
            }
            .overlay { RoundedRectangle(cornerRadius: Spacing.radiusSmall).stroke(Palette.border) }
            .clipShape(RoundedRectangle(cornerRadius: Spacing.radiusSmall))
            Text("Send targets running, idle consoles in the active workspace.").font(Typography.caption).foregroundStyle(Palette.mutedInk)
        }
        .padding(Spacing.sm).background(Palette.surface)
    }
}
