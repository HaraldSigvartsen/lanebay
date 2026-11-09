import LanebayCore
import LanebayDesign
import SwiftUI

/// "Bytt AI" — choose which AI (or plain terminal) a card runs, and its model.
struct ProviderPickerSheet: View {
  @Bindable var model: BoardViewModel
  let nodeID: UUID
  @State private var agentID: String = "shell"
  @State private var modelName: String = ""

  private var agents: [NewTerminalAgent] {
    let draft = model.settings.newTerminalDraft()
    return draft.featuredAgents.filter { $0.id != OrchestratorKind.agentID } + draft.customAgents
  }

  var body: some View {
    VStack(alignment: .leading, spacing: DS.Pastel.sectionSpacing) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Bytt AI").font(.title2.weight(.semibold))
        Text("Velg hvem som skal jobbe i dette kortet. Kortet starter på nytt hvis det kjører.")
          .font(.callout).foregroundStyle(.secondary)
      }
      LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
        ForEach(agents) { agent in
          let selected = agent.id == agentID
          Button {
            agentID = agent.id
            modelName = model.settings.preferences.lastModelByAgentID[agent.id] ?? ""
          } label: {
            HStack(spacing: 8) {
              ProviderBadge(agentID: agent.id)
              VStack(alignment: .leading, spacing: 1) {
                Text(agent.title).font(.body.weight(.medium))
                Text(Self.blurb(agent.id)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
              }
              Spacer(minLength: 0)
              if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(DS.Pastel.lavenderInk) }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .pastelFill(selected ? DS.Pastel.lavender : Color.primary, radius: DS.Pastel.controlRadius, opacity: selected ? 0.35 : 0.05)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityIdentifier("providerPicker.agent.\(agent.id)")
        }
      }
      modelSection
      HStack {
        Spacer()
        Button("Avbryt") { model.providerPickerNodeID = nil }.keyboardShortcut(.cancelAction)
        Button("Bruk") {
          let id = nodeID, agent = agentID, name = modelName
          model.providerPickerNodeID = nil
          Task { await model.changeProvider(id, agentID: agent, model: name) }
        }
        .keyboardShortcut(.defaultAction)
        .accessibilityIdentifier("providerPicker.apply")
      }
    }
    .padding(DS.Pastel.dialogPadding)
    .frame(width: 520)
    .pastelGlass(radius: DS.Pastel.dialogRadius)
    .onAppear {
      let node = model.workspace?.nodes.first { $0.id == nodeID }
      agentID = node?.agentID ?? "shell"
      modelName = node?.model ?? ""
    }
  }

  @ViewBuilder private var modelSection: some View {
    if ProviderModels.supportsModel(agentID) {
      VStack(alignment: .leading, spacing: 8) {
        Text("Modell").font(.headline)
        TextField("Standard (la stå tomt)", text: $modelName)
          .textFieldStyle(.roundedBorder)
          .accessibilityIdentifier("providerPicker.model")
        let suggestions = ProviderModels.suggestions(for: agentID)
        if !suggestions.isEmpty {
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
              ForEach(suggestions, id: \.self) { s in
                Button(s) { modelName = s }
                  .buttonStyle(.plain)
                  .font(.caption)
                  .padding(.horizontal, 10).padding(.vertical, 5)
                  .pastelFill(modelName == s ? DS.Pastel.sky : Color.primary, radius: 10, opacity: modelName == s ? 0.45 : 0.06)
              }
            }
          }
        }
      }
    } else {
      Text(agentID == "freebuff" ? "FreeBuff velger modell selv (skriv /model inne i kortet)."
        : agentID == "shell" ? "Vanlig terminal – ingen AI-modell." : "\(model.providerTitle(agentID)) velger modell selv.")
        .font(.callout).foregroundStyle(.secondary)
    }
  }

  static func blurb(_ id: String) -> String {
    switch id {
    case "shell": "Vanlig terminal"
    case "freebuff": "Gratis kode-AI"
    case "codex": "OpenAI sin kode-AI"
    case "opencode": "Åpen kode-AI, mange modeller"
    case "claude": "Anthropic sin kode-AI"
    case "cursor-agent": "Cursor i terminalen"
    default: "Eget program"
    }
  }
}
