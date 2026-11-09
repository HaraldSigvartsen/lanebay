import AppKit
import LanebayCore
import SwiftUI

struct NewTerminalSheet: View {
  @Bindable var model: BoardViewModel
  @State private var draft: NewTerminalDraft

  init(model: BoardViewModel) {
    self.model = model
    _draft = State(initialValue: model.settings.newTerminalDraft())
  }

  var body: some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
      Text("Ny terminal")
        .font(Typography.title)
        .foregroundStyle(Palette.ink)
        .accessibilityAddTraits(.isHeader)

      VStack(alignment: .leading, spacing: Spacing.xs) {
        sectionCaption("Hvem skal jobbe her")
        VStack(alignment: .leading, spacing: 0) {
          ForEach(draft.featuredAgents) { agent in
            agentButton(agent)
          }
        }
      }

      VStack(alignment: .leading, spacing: Spacing.xs) {
        sectionCaption("Egne programmer")
        if draft.customAgents.isEmpty {
          EmptyStateView(
            symbol: "person.crop.square",
            title: "Ingen egne agenter ennå",
            identifier: "newTerminal.customEmpty")
            .frame(height: 150)
        } else {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(draft.customAgents) { agent in
              agentButton(agent)
            }
          }
        }
      }

      modelSection

      VStack(alignment: .leading, spacing: Spacing.xs) {
        sectionCaption("Arbeidsmappe")
        ScrollView {
          VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(draft.directories.enumerated()), id: \.element.id) { index, directory in
              AXActionButton(
                title: directory.path,
                systemImage: "folder",
                identifier: "newTerminal.directory.\(index)",
                accessibilityLabel: directory.path,
                enabled: true,
                highlighted: draft.selectedDirectoryPath == directory.path,
                compact: false,
                selectionValue: draft.selectedDirectoryPath == directory.path ? "selected" : "unselected"
              ) {
                draft = draft.selectingDirectory(directory.path)
              }
            }
          }
        }
        .frame(maxHeight: 240)
      }

      if let error = model.newTerminalError {
        Text(error)
          .font(Typography.caption)
          .foregroundStyle(Palette.status(.error))
          .accessibilityIdentifier("newTerminal.error")
      }

      HStack(spacing: Spacing.sm) {
        AXActionButton(
          title: "Velg…",
          systemImage: nil,
          identifier: "newTerminal.choose",
          accessibilityLabel: "Choose folder",
          enabled: true,
          highlighted: false,
          compact: false
        ) {
          chooseDirectory()
        }
        .frame(width: 96, height: 28)
        Spacer()
        AXActionButton(
          title: "Avbryt",
          systemImage: nil,
          identifier: "newTerminal.cancel",
          accessibilityLabel: "Cancel",
          enabled: true,
          highlighted: false,
          compact: false,
          keyEquivalent: "\u{1b}"
        ) {
          model.showingNewTerminal = false
        }
        .frame(width: 88, height: 28)
        AXActionButton(
          title: "Opprett",
          systemImage: nil,
          identifier: "newTerminal.create",
          accessibilityLabel: "Create terminal",
          enabled: model.workspace != nil && !draft.selectedDirectoryPath.isEmpty,
          highlighted: false,
          primary: true,
          compact: false,
          keyEquivalent: "\r"
        ) {
          create()
        }
        .frame(width: 96, height: 32)
        .background(
          Palette.accentGradient,
          in: RoundedRectangle(cornerRadius: Spacing.radiusMedium, style: .continuous))
      }
    }
    .padding(Spacing.lg)
    .frame(width: 480)
    .background(
      .regularMaterial,
      in: RoundedRectangle(cornerRadius: Spacing.radiusXL, style: .continuous))
    .clipShape(RoundedRectangle(cornerRadius: Spacing.radiusXL, style: .continuous))
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("newTerminal.sheet")
    .onAppear { draft = model.settings.newTerminalDraft() }
  }

  private func sectionCaption(_ text: String) -> some View {
    Text(text)
      .font(Typography.caption)
      .textCase(.uppercase)
      .tracking(0.6)
      .foregroundStyle(Palette.secondaryInk)
  }

  private func agentButton(_ agent: NewTerminalAgent) -> some View {
    let selected = draft.selectedAgentID == agent.id
    return HStack(spacing: Spacing.xs) {
      ProviderBadge(agentID: agent.id)
      AXActionButton(
        title: agent.title,
        systemImage: nil,
        identifier: "newTerminal.agent.\(agent.id)",
        accessibilityLabel: agent.title,
        enabled: true,
        highlighted: selected,
        compact: false,
        selectionValue: selected ? "selected" : "unselected"
      ) {
        draft = draft.selectingAgent(agent.id)
      }
    }
    .padding(.horizontal, Spacing.xxs)
    .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
    .background(
      selected ? Palette.accentSoft : Color.clear,
      in: RoundedRectangle(cornerRadius: Spacing.radiusMedium, style: .continuous))
  }

  /// Agents with a model flag get an editable model; FreeBuff picks its model in its own TUI.
  @ViewBuilder
  private var modelSection: some View {
    if draft.supportsModel {
      VStack(alignment: .leading, spacing: Spacing.xs) {
        sectionCaption("Modell")
        TextField("Standard", text: $draft.selectedModel)
          .textFieldStyle(.roundedBorder)
          .font(Typography.body)
          .accessibilityIdentifier("newTerminal.model")
          .accessibilityLabel("Model")
          .onSubmit { create() }
        if !draft.modelSuggestions.isEmpty {
          ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.xxs) {
              ForEach(draft.modelSuggestions, id: \.self) { suggestion in
                AXActionButton(
                  title: suggestion,
                  systemImage: nil,
                  identifier: "newTerminal.model.suggestion.\(suggestion)",
                  accessibilityLabel: suggestion,
                  enabled: true,
                  highlighted: draft.selectedModel == suggestion,
                  compact: true,
                  selectionValue: draft.selectedModel == suggestion ? "selected" : "unselected"
                ) {
                  draft = draft.selectingModel(suggestion)
                }
                .frame(width: chipWidth(suggestion), height: 22)
              }
            }
          }
        }
      }
    } else {
      Text(modelNote)
        .font(Typography.caption)
        .foregroundStyle(Palette.secondaryInk)
        .accessibilityIdentifier("newTerminal.modelNote")
    }
  }

  private var modelNote: String {
    if draft.selectedAgentID == "freebuff" {
      return "FreeBuff velger modell selv (skriv /model inne i kortet)"
    }
    let title = draft.agents.first { $0.id == draft.selectedAgentID }?.title ?? draft.selectedAgentID
    return "\(title) velger modell selv"
  }

  private func chipWidth(_ title: String) -> CGFloat {
    let width = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width
    return ceil(width) + Spacing.md
  }

  private func create() {
    guard let directory = draft.selectedDirectory else {
      return
    }
    let selectedModel = draft.selectedModel.isEmpty ? nil : draft.selectedModel
    _ = model.createConsoleFromNewTerminal(
      agentID: draft.selectedAgentID, directory: directory, model: selectedModel)
  }

  private func chooseDirectory() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.prompt = "Choose Folder"
    if draft.selectedDirectoryPath.hasPrefix("/") {
      panel.directoryURL = URL(fileURLWithPath: draft.selectedDirectoryPath, isDirectory: true)
    }
    guard panel.runModal() == .OK, let url = panel.url else { return }
    draft = draft.insertingDirectory(url)
  }
}
