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
      Text("New terminal")
        .font(Typography.title)
        .foregroundStyle(Palette.ink)
        .accessibilityAddTraits(.isHeader)
      Text("Agent")
        .font(Typography.caption)
        .foregroundStyle(Palette.secondaryInk)
      VStack(alignment: .leading, spacing: 0) {
        ForEach(draft.featuredAgents) { agent in
          agentButton(agent)
        }
      }
      Text("Custom")
        .font(Typography.caption)
        .foregroundStyle(Palette.secondaryInk)
      if draft.customAgents.isEmpty {
        AXActionButton(
          title: "No custom agents yet",
          systemImage: nil,
          identifier: "newTerminal.customEmpty",
          accessibilityLabel: "No custom agents yet",
          enabled: false,
          highlighted: false,
          compact: false
        ) {}
      } else {
        ForEach(draft.customAgents) { agent in
          agentButton(agent)
        }
      }
      Text("Working folder")
        .font(Typography.caption)
        .foregroundStyle(Palette.secondaryInk)
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
      if let error = model.newTerminalError {
        Text(error)
          .font(Typography.caption)
          .foregroundStyle(Palette.status(.error))
          .accessibilityIdentifier("newTerminal.error")
      }
      HStack(spacing: Spacing.sm) {
        AXActionButton(
          title: "Choose…",
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
          title: "Cancel",
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
          title: "Create",
          systemImage: nil,
          identifier: "newTerminal.create",
          accessibilityLabel: "Create terminal",
          enabled: model.workspace != nil && !draft.selectedDirectoryPath.isEmpty,
          highlighted: true,
          compact: false,
          keyEquivalent: "\r"
        ) {
          create()
        }
        .frame(width: 88, height: 28)
      }
    }
    .padding(Spacing.lg)
    .frame(width: 480)
    .background(Palette.surface)
    .accessibilityElement(children: .contain)
    .accessibilityIdentifier("newTerminal.sheet")
    .onAppear { draft = model.settings.newTerminalDraft() }
  }

  private func agentButton(_ agent: NewTerminalAgent) -> some View {
    AXActionButton(
      title: agent.title,
      systemImage: nil,
      identifier: "newTerminal.agent.\(agent.id)",
      accessibilityLabel: agent.title,
      enabled: true,
      highlighted: draft.selectedAgentID == agent.id,
      compact: false,
      selectionValue: draft.selectedAgentID == agent.id ? "selected" : "unselected"
    ) {
      draft = draft.selectingAgent(agent.id)
    }
  }

  private func create() {
    guard let directory = draft.selectedDirectory else {
      return
    }
    _ = model.createConsoleFromNewTerminal(agentID: draft.selectedAgentID, directory: directory)
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
