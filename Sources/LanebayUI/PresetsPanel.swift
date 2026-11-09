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

    /// Shown when no preset is stored yet. Pinned by `VerktoyPanelsTests`.
    public static let emptyStateTitle = "Ingen maler ennå"

    public init(model: PresetsPanelModel, agentKinds: [String], onSend: @escaping (String, String?) -> Bool) {
        self.model = model
        self.agentKinds = agentKinds
        self.onSend = onSend
    }

    private var canSave: Bool {
        !model.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canSend: Bool {
        model.selectedPreset != nil && !model.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.lg) {
            PanelSection("Maler", fillsHeight: true) {
                HStack(spacing: DS.Space.xs) {
                    Text("Saved prompts and commands")
                        .font(DS.Font.caption)
                        .foregroundStyle(DS.Color.secondaryInk)
                    Spacer(minLength: 0)
                    Button { model.newPreset() } label: { Label("New", systemImage: "plus") }
                        .buttonStyle(.lbSecondary)
                        .accessibilityIdentifier("presets.new")
                }

                HStack(spacing: 0) {
                    presetList
                    Rectangle().fill(DS.Color.hairline).frame(width: 1)
                    editor
                }
                .frame(maxHeight: .infinity)
            }

            Text("Send targets running, idle consoles in the active workspace.")
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.mutedInk)
        }
        .padding(DS.Space.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private var presetList: some View {
        if model.presets.isEmpty {
            EmptyStateView(
                symbol: "text.badge.plus",
                title: Self.emptyStateTitle,
                message: "Lagre et prompt eller en kommando du bruker ofte.",
                actionTitle: "Ny mal",
                action: { model.newPreset() },
                identifier: "presets.empty")
            .frame(minWidth: 150, idealWidth: 180)
        } else {
            List(selection: Binding(get: { model.selectedID }, set: { id in
                if let preset = model.presets.first(where: { $0.id == id }) { model.select(preset) }
            })) {
                ForEach(model.presets) { preset in
                    let isSelected = model.selectedID == preset.id
                    PanelRow(isSelected: isSelected) {
                        VStack(alignment: .leading, spacing: DS.Space.xxs) {
                            Text(preset.name)
                                .font(DS.Font.bodyEmphasis)
                                .foregroundStyle(isSelected ? DS.Color.accentInk : DS.Color.ink)
                                .lineLimit(1)
                            Text(preset.targetAgentKind ?? "Any agent")
                                .font(DS.Font.caption)
                                .foregroundStyle(DS.Color.mutedInk)
                        }
                    }
                    .tag(Optional(preset.id))
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .frame(minWidth: 150, idealWidth: 180)
            .accessibilityIdentifier("presets.list")
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            FormField("Navn") {
                TextField("Navn", text: $model.name)
                    .textFieldStyle(.lbField)
                    .accessibilityIdentifier("presets.name")
            }
            FormField("Mål") {
                Picker("Mål", selection: $model.targetAgentKind) {
                    Text("Alle agenter").tag(String?.none)
                    ForEach(agentKinds, id: \.self) { kind in Text(kind.capitalized).tag(Optional(kind)) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .accessibilityIdentifier("presets.target")
            }
            FormField("Prompt eller kommando") {
                TextEditor(text: $model.text)
                    .lbEditor(minHeight: 120)
                    .accessibilityLabel("Preset prompt or command")
            }
            if let error = model.errorMessage {
                FormStatus(error, tone: .error)
            }
            HStack(spacing: DS.Space.xs) {
                if model.selectedID != nil {
                    Button("Slett", role: .destructive) { model.deleteSelected() }
                        .buttonStyle(.lbGhost)
                        .accessibilityIdentifier("presets.delete")
                }
                Spacer(minLength: 0)
                Button("Lagre") { _ = model.save() }
                    .buttonStyle(.lbSecondary)
                    .disabled(!canSave)
                    .accessibilityIdentifier("presets.save")
                Button { _ = onSend(model.text, model.targetAgentKind) } label: { Label("Send", systemImage: "arrow.up") }
                    .buttonStyle(.lbPrimary)
                    .disabled(!canSend)
                    .accessibilityIdentifier("presets.send")
            }
        }
        .padding(DS.Space.sm)
        .frame(minWidth: 250)
    }
}
