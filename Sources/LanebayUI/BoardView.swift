import AppKit
import LanebayCore
import SwiftUI

public struct BoardView: View {
  @Bindable private var model: BoardViewModel
  @State private var command = ""
  @State private var renamingID: UUID?
  @State private var workspaceName = ""
  @State private var pinchStart: Double?
  @State private var groupName = ""
  @State private var showingGroupPrompt = false
  @State private var showingGroups = false
  @State private var openPanel: BoardSidePanel?
  @State private var docsPanelModel: DocsPanelModel
  @State private var codePanelModel: CodePanelModel
  @State private var markdownPanelModel: MarkdownPanelModel
  @State private var skillsPanelModel: SkillsPanelModel
  @State private var showingAgentPicker = false
  @State private var memoryPanelModel: MemoryPanelModel
  @State private var presetsPanelModel: PresetsPanelModel?
  @State private var chatPanelModel: ChatPanelModel
  @State private var gitHubPanelModel: GitHubPanelModel
  @State private var usagePanelModel: UsagePanelModel
  @State private var gitHelpersPanelModel: GitHelpersPanelModel
  @State private var screenshotPanelModel: ScreenshotLibraryPanelModel
  @State private var plannerPanelModel: PlannerPanelModel
  @State private var voiceModel: VoiceCommandModel
  @State private var voiceHotkeyMonitor = PushToTalkHotkeyMonitor()
  private let presetsStore: PresetsStore
  private let chatStore: ChatTranscriptStore
  let memoryHomeRoot: URL
  let panelSupportRoot: URL

  public init(
    model: BoardViewModel,
    presetsStore: PresetsStore? = nil,
    chatStore: ChatTranscriptStore? = nil,
    memoryHomeRoot: URL? = nil,
    usageRoot: URL? = nil,
    screenshotRoot: URL? = nil
  ) {
    let home = memoryHomeRoot ?? model.homeDirectory
    let support = PanelStorage.supportRoot(homeDirectory: home)
    let resolvedPresets = presetsStore ?? PresetsStore(rootURL: support)
    let resolvedChat = chatStore ?? ChatTranscriptStore(rootURL: PanelStorage.chatRoot(homeDirectory: home))
    self.model = model
    self.presetsStore = resolvedPresets
    self.chatStore = resolvedChat
    self.memoryHomeRoot = home
    self.panelSupportRoot = usageRoot ?? support
    _docsPanelModel = State(initialValue: DocsPanelModel(workspace: model.workspace))
    _codePanelModel = State(initialValue: CodePanelModel(workspace: model.workspace))
    _markdownPanelModel = State(initialValue: MarkdownPanelModel(workspace: model.workspace))
    _skillsPanelModel = State(initialValue: SkillsPanelModel(workspace: model.workspace, homeRoot: home))
    _memoryPanelModel = State(initialValue: MemoryPanelModel(workspace: model.workspace, homeRoot: home))
    _presetsPanelModel = State(initialValue: nil)
    _chatPanelModel = State(initialValue: ChatPanelModel(workspaceID: nil, store: resolvedChat))
    _gitHubPanelModel = State(initialValue: GitHubPanelModel(workspace: model.workspace))
    _usagePanelModel = State(initialValue: UsagePanelModel(store: UsageStatsStore(rootURL: usageRoot ?? support), homeRoot: home))
    _gitHelpersPanelModel = State(initialValue: GitHelpersPanelModel(
      workspace: model.workspace,
      draftTargets: model.runningDraftTargets,
      openWorkspace: { cloned in model.openClonedRepositoryAsWorkspace(cloned) },
      sendDraftPrompt: { nodeID, prompt in model.requestCommitDraftFromConsole(prompt, nodeID: nodeID) }
    ))
    _screenshotPanelModel = State(initialValue: ScreenshotLibraryPanelModel(
      store: ScreenshotLibraryStore(rootURL: screenshotRoot ?? support),
      attachTargets: model.runningScreenshotTargets,
      attachToConsole: { nodeID, path in model.sendToConsole(path, nodeID: nodeID) }
    ))
    _plannerPanelModel = State(initialValue: PlannerPanelModel(
      workspace: model.workspace,
      runningConsoleIDs: Set(model.sessions.compactMap { $0.value.isRunning ? $0.key : nil }),
      cliOptions: BoardView.plannerCLIOptions(from: model),
      executeAction: { action in
        switch action {
        case let .sendToConsole(nodeID, text):
          return model.sendToConsole(text, nodeID: nodeID)
            ? .success("Sent to console.")
            : .failure("Dispatch gate rejected sendToConsole.")
        case let .broadcastToGroup(groupID, text):
          return model.broadcastToGroup(text, groupID: groupID)
            ? .success("Broadcast delivered.")
            : .failure("Dispatch gate rejected broadcastToGroup.")
        case let .createLoop(name, targetNodeID, prompt, trigger, maxIterations):
          return model.createLoop(name: name, targetNodeID: targetNodeID, prompt: prompt, trigger: trigger, maxIterations: maxIterations) != nil
            ? .success("Loop created.")
            : .failure("Could not create loop.")
        case let .startConsole(nodeID):
          await model.startConsole(nodeID)
          return model.sessions[nodeID]?.isRunning == true
            ? .success("Console started.")
            : .failure("Console could not start.")
        case let .note(text):
          return .success(text)
        }
      }
    ))
    _voiceModel = State(initialValue: VoiceCommandModel())
  }

  public var body: some View {
    HStack(spacing: 0) {
      BoardRail(
        panels: [
          BoardRailPanel(id: "board", icon: .workspace, title: "Board", isSelected: openPanel == nil) {
            openPanel = nil
          },
        ] + BoardSidePanel.railOrder.map { panel in
          BoardRailPanel(id: panel.rawValue, icon: panel.icon, title: panel.railTitle, isSelected: openPanel == panel) {
            togglePanel(panel)
          }
        },
        canCreateGroup: model.canCreateGroup,
        canManageGroups: model.workspace?.groups.isEmpty == false,
        onCreateGroup: { showingGroupPrompt = true },
        onManageGroups: { showingGroups = true }
      ) {
        AXActionButton(
          title: "Console",
          systemImage: Icon.add.rawValue,
          identifier: "rail.addConsole",
          accessibilityLabel: "Add console",
          enabled: model.workspace != nil,
          highlighted: showingAgentPicker,
          compact: true
        ) {
          showingAgentPicker.toggle()
        }
        .frame(width: BoardRailMetrics.buttonWidth, height: BoardRailMetrics.buttonHeight)
      }
      Rectangle().fill(Palette.border).frame(width: 1)
      VStack(spacing: 0) {
        tabs
        if let message = model.errorMessage {
          HStack(spacing: Spacing.xs) {
            Icon.warning.image.foregroundStyle(Palette.status(.error))
            Text(verbatim: message).font(Typography.body).textSelection(.enabled)
            Spacer()
            Button("Retry") {
              if model.workspaces.isEmpty {
                model.reload()
              } else {
                do { try model.saveNow() } catch {}
              }
            }
          }
          .foregroundStyle(Palette.ink)
          .padding(Spacing.sm)
          .background(Palette.surface)
        }
        if let approval = model.orchestratorApprovals.first {
          OrchestratorApprovalBanner(
            approval: approval,
            waitingCount: model.orchestratorApprovals.count,
            onApprove: { _ = model.approveOrchestratorSend(approval.id) },
            onDeny: { _ = model.denyOrchestratorSend(approval.id) }
          )
          .padding(Spacing.sm)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(Palette.canvas)
        }
        HStack(spacing: 0) {
          canvas
          if let openPanel { sidePanel(openPanel) }
        }
        CommandBar(
          text: $command, destination: model.commandDestination,
          canSubmit: model.canSendCommand,
          hasIdleRecipients: !model.idleConsoleIDs.isEmpty,
          onBroadcastToIdle: { model.broadcastToIdle($0) },
          isVoiceRecording: voiceModel.isRecording,
          voiceStatus: voiceModel.statusMessage,
          voiceError: voiceModel.errorMessage,
          onPushToTalkPressChanged: { isPressed in
            Task { await voiceModel.setPressed(isPressed) }
          }
        ) { text in
          if model.sendCommand(text) { command = "" }
        }
        .padding(Spacing.sm)
        .background(Palette.canvas)
      }
    }
    .background(Palette.canvas)
    .alert(
      "Rename workspace",
      isPresented: Binding(get: { renamingID != nil }, set: { if !$0 { renamingID = nil } })
    ) {
      TextField("Workspace name", text: $workspaceName)
      Button("Cancel", role: .cancel) { renamingID = nil }
      Button("Rename") {
        if let id = renamingID { model.renameWorkspace(id, name: workspaceName) }
        renamingID = nil
      }
    }
    .alert("Create group", isPresented: $showingGroupPrompt) {
      TextField("Group name", text: $groupName)
      Button("Cancel", role: .cancel) { groupName = "" }
      Button("Create") {
        _ = model.createGroup(name: groupName)
        groupName = ""
      }
    } message: { Text("Selected consoles will be added to the group.") }
    .sheet(isPresented: $showingGroups) { GroupManagementSheet(model: model) }
    .sheet(isPresented: $model.showingNewTerminal) {
      NewTerminalSheet(model: model)
    }
    .onChange(of: model.presentedChromeDismissals) { _, _ in
      showingGroupPrompt = false
      showingGroups = false
      showingAgentPicker = false
      model.showingNewTerminal = false
    }
    .onChange(of: model.workspace?.repos) { _, _ in
      docsPanelModel.update(workspace: model.workspace)
      codePanelModel.update(workspace: model.workspace)
      markdownPanelModel.update(workspace: model.workspace)
      skillsPanelModel.update(workspace: model.workspace)
      memoryPanelModel.setWorkspace(model.workspace)
      gitHubPanelModel.update(workspace: model.workspace)
      gitHelpersPanelModel.update(workspace: model.workspace, draftTargets: model.runningDraftTargets)
      plannerPanelModel.update(
        workspace: model.workspace,
        runningConsoleIDs: Set(model.sessions.compactMap { $0.value.isRunning ? $0.key : nil }),
        cliOptions: Self.plannerCLIOptions(from: model)
      )
    }
    .onChange(of: model.workspace?.id) { _, id in
      memoryPanelModel.setWorkspace(model.workspace)
      if openPanel == .chat { chatPanelModel.setWorkspace(id) }
      gitHelpersPanelModel.update(workspace: model.workspace, draftTargets: model.runningDraftTargets)
      plannerPanelModel.update(
        workspace: model.workspace,
        runningConsoleIDs: Set(model.sessions.compactMap { $0.value.isRunning ? $0.key : nil }),
        cliOptions: Self.plannerCLIOptions(from: model)
      )
    }
    .onChange(of: model.sessions.map { "\($0.key.uuidString):\($0.value.isRunning):\($0.value.isClosed)" }.sorted()) { _, _ in
      gitHelpersPanelModel.update(workspace: model.workspace, draftTargets: model.runningDraftTargets)
      screenshotPanelModel.updateAttachTargets(model.runningScreenshotTargets)
      plannerPanelModel.update(
        workspace: model.workspace,
        runningConsoleIDs: Set(model.sessions.compactMap { $0.value.isRunning ? $0.key : nil }),
        cliOptions: Self.plannerCLIOptions(from: model)
      )
    }
    .onChange(of: voiceModel.latestTranscript) { _, _ in
      guard let transcript = voiceModel.consumeTranscript() else { return }
      if command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        command = transcript
      } else {
        command += " " + transcript
      }
    }
    .onAppear {
      voiceHotkeyMonitor.start { isPressed in
        Task { await voiceModel.setPressed(isPressed) }
      }
    }
    .onDisappear {
      voiceHotkeyMonitor.stop()
    }
    .overlay { agentPickerOverlay }
  }

  private static func plannerCLIOptions(from model: BoardViewModel) -> [PlannerCLIOption] {
    model.availableAgentTemplates.compactMap { template in
      if template.id == "shell" { return nil }
      let path: String
      if template.executable.hasPrefix("/") {
        path = template.executable
      } else if let resolved = AgentCatalog.resolve(
        executableName: template.executable, searchDirectories: model.settings.executableSearchDirectories)
      {
        path = resolved.path
      } else {
        return nil
      }
      return PlannerCLIOption(
        id: template.id,
        title: template.title,
        executablePath: path,
        defaultArguments: template.arguments
      )
    }
  }

  private func togglePanel(_ panel: BoardSidePanel) {
    let next = BoardSidePanel.toggled(openPanel, panel)
    openPanel = next
    if next == .presets { ensurePresetsModel() }
    if next == .chat { ensureChatModel() }
  }

  private func panelSubtitle(_ panel: BoardSidePanel) -> String {
    switch panel {
    case .settings: "App preferences"
    case .presets: "Reusable prompts and commands"
    default: model.workspace?.name ?? "No active workspace"
    }
  }

  @ViewBuilder
  private func sidePanel(_ panel: BoardSidePanel) -> some View {
    if panel == .loops {
      LoopPanel(model: model)
        .frame(width: panel.width)
        .padding(Spacing.sm)
        .background {
          PanelMarker(identifier: panel.marker, label: panel.hostTitle)
            .frame(width: 4, height: 4)
            .allowsHitTesting(false)
        }
    } else {
      PanelHost(
        title: panel.hostTitle,
        subtitle: panelSubtitle(panel),
        identifier: panel.hostIdentifier,
        onClose: { openPanel = nil }
      ) {
        panelBody(panel)
          .overlay(alignment: .topLeading) {
            PanelMarker(identifier: panel.marker, label: panel.hostTitle)
              .frame(width: 4, height: 4)
              .allowsHitTesting(false)
          }
      }
      .frame(width: panel.width)
    }
  }

  @ViewBuilder
  private func panelBody(_ panel: BoardSidePanel) -> some View {
    switch panel {
    case .settings:
      SettingsPanel(model: model.settings)
    case .docs:
      DocsPanel(model: docsPanelModel)
    case .code:
      CodePanel(model: codePanelModel)
    case .markdown:
      MarkdownPanel(model: markdownPanelModel)
    case .skills:
      SkillsPanel(model: skillsPanelModel)
    case .memory:
      MemoryPanel(model: memoryPanelModel)
    case .presets:
      if let presetsPanelModel {
        PresetsPanel(model: presetsPanelModel, agentKinds: availablePresetAgentKinds) { text, agentKind in
          model.sendPreset(text, targetAgentKind: agentKind)
        }
      }
    case .chat:
      ChatPanel(
        model: chatPanelModel, workspace: model.workspace, sessions: model.sessions,
        onSendConsole: { model.sendToConsole($0, nodeID: $1) },
        onSendLead: { model.sendToLead($0, groupID: $1) },
        onSendGroup: { model.broadcastToGroup($0, groupID: $1) },
        onExcerpt: { model.recentConsoleOutput($0) })
    case .github:
      GitHubPanel(model: gitHubPanelModel)
    case .usage:
      UsagePanel(model: usagePanelModel)
    case .git:
      GitHelpersPanel(model: gitHelpersPanelModel)
    case .shots:
      ScreenshotLibraryPanel(model: screenshotPanelModel)
    case .planner:
      PlannerPanel(model: plannerPanelModel)
    case .loops:
      EmptyView()
    }
  }

  private var availablePresetAgentKinds: [String] {
    let kinds = model.workspace?.nodes.compactMap(\.agentID) ?? []
    return Array(Set(kinds)).sorted()
  }

  private var tabs: some View {
    HStack(spacing: Spacing.xs) {
      ScrollView(.horizontal) {
        HStack(spacing: Spacing.xs) {
          ForEach(model.workspaces) { workspace in
            Button {
              resignTerminalFocus()
              model.switchWorkspace(workspace.id)
            } label: {
              Text(workspace.name)
                .font(Typography.bodyEmphasis)
                .lineLimit(1)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xs)
                .foregroundStyle(
                  workspace.id == model.activeWorkspaceID ? Palette.accent : Palette.secondaryInk
                )
                .background(
                  workspace.id == model.activeWorkspaceID ? Palette.accentSoft : Palette.surface,
                  in: RoundedRectangle(cornerRadius: Spacing.radiusSmall)
                )
                .overlay(
                  RoundedRectangle(cornerRadius: Spacing.radiusSmall)
                    .stroke(
                      workspace.id == model.activeWorkspaceID ? Palette.accent : Palette.border))
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(workspace.id == model.activeWorkspaceID ? .isSelected : [])
            .contextMenu { Button("Rename…") { beginRename(workspace) } }
            .help("Control-click to rename workspace")
          }
        }
      }
      Button {
        _ = model.createWorkspace(name: "Workspace \(model.workspaces.count + 1)")
      } label: {
        Icon.add.image
      }
      .help("New workspace").accessibilityLabel("New workspace")
      if let workspace = model.workspace {
        Button {
          beginRename(workspace)
        } label: {
          Icon.menu.image
        }
        .help("Rename workspace").accessibilityLabel("Rename workspace")
      }
      addConsoleControl(identifier: "toolbar.addConsole") {
        Label("Add console", systemImage: Icon.add.rawValue)
      }
      .fixedSize()
      newTerminalButton(identifier: "toolbar.newTerminal")
      Button {
        model.setZoom(model.zoom / 1.1)
      } label: {
        Text("−")
      }
      .help("Zoom out (⌘−)").accessibilityLabel("Zoom out")
      Text(model.zoom, format: .percent.precision(.fractionLength(0)))
        .font(Typography.caption).foregroundStyle(Palette.secondaryInk)
        .monospacedDigit().frame(minWidth: 36)
        .accessibilityLabel("Canvas zoom")
      Button {
        model.setZoom(model.zoom * 1.1)
      } label: {
        Icon.add.image
      }
      .help("Zoom in (⌘+)").accessibilityLabel("Zoom in")
      AXActionButton(
        title: "Loops",
        systemImage: "repeat",
        identifier: "toolbar.showLoops",
        accessibilityLabel: "Show loops",
        enabled: model.workspace != nil,
        highlighted: openPanel == .loops,
        compact: false,
        headerIcon: true
      ) { togglePanel(.loops) }
      .frame(width: 28, height: 28)
      .help("Show loops")
      Button { showingGroupPrompt = true } label: { Image(systemName: "rectangle.3.group") }
        .help("Group selected consoles").accessibilityLabel("Group selected consoles")
        .disabled(!model.canCreateGroup)
    }
    .padding(Spacing.xs)
    .background(Palette.surface)
    .overlay(alignment: .bottom) { Rectangle().fill(Palette.border).frame(height: 1) }
  }

  private var agentPickerOverlay: some View {
    ZStack(alignment: .bottomLeading) {
      if showingAgentPicker {
        Color.black.opacity(0.001)
          .contentShape(Rectangle())
          .onTapGesture { showingAgentPicker = false }
          .accessibilityLabel("Dismiss console list")
          .accessibilityIdentifier("agent.picker.dismiss")
          .zIndex(0)
        AgentPickerList(model: model) { showingAgentPicker = false }
          .padding(.leading, 76)
          .padding(.bottom, Spacing.sm)
          .zIndex(1)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
  }

  private func newTerminalButton(identifier: String) -> some View {
    AXActionButton(
      title: "New terminal",
      systemImage: Icon.add.rawValue,
      identifier: identifier,
      accessibilityLabel: "New terminal",
      enabled: model.workspace != nil,
      highlighted: model.showingNewTerminal,
      compact: false
    ) {
      model.beginNewTerminal()
    }
    .frame(width: 132, height: 28)
  }

  private func addConsoleControl<Label: View>(
    identifier: String, @ViewBuilder label: () -> Label
  ) -> some View {
    Button {
      showingAgentPicker.toggle()
    } label: {
      label()
    }
    .buttonStyle(.plain)
    .disabled(model.workspace == nil)
    .help("Add console")
    .accessibilityLabel("Add console")
    .accessibilityIdentifier(identifier)
  }

  private var canvas: some View {
    // The grid closure runs from AppKit layout, outside a Swift task. Keep it to plain numbers.
    let zoom = model.zoom
    let panX = model.panX
    let panY = model.panY
    return GeometryReader { geometry in
      ZStack(alignment: .topLeading) {
        Canvas { context, size in
          let step = Spacing.xl * zoom
          var grid = Path()
          for x in stride(
            from: panX.truncatingRemainder(dividingBy: step), through: size.width, by: step)
          {
            grid.move(to: CGPoint(x: x, y: 0))
            grid.addLine(to: CGPoint(x: x, y: size.height))
          }
          for y in stride(
            from: panY.truncatingRemainder(dividingBy: step), through: size.height, by: step)
          {
            grid.move(to: CGPoint(x: 0, y: y))
            grid.addLine(to: CGPoint(x: size.width, y: y))
          }
          context.stroke(grid, with: .color(Palette.border.opacity(0.5)), lineWidth: 0.5)
        }
        .background(Palette.canvas)
        .allowsHitTesting(false)
        CanvasBackground(
          onPan: { model.pan(dx: $0, dy: $1) },
          onSelect: {
            resignTerminalFocus()
            model.select(nil)
          })
        GroupMap(
          workspace: model.workspace,
          members: Dictionary(
            uniqueKeysWithValues: (model.workspace?.nodes ?? []).map { ($0.id, groupMember($0)) }),
          zoom: model.zoom, panX: model.panX, panY: model.panY
        )
        .allowsHitTesting(false)
        ForEach(model.workspace?.nodes.filter { $0.kind == .console } ?? []) { node in
          BoardConsoleCard(model: model, node: node)
            .frame(width: node.frame.w, height: node.frame.h)
            .scaleEffect(model.zoom, anchor: .topLeading)
            .offset(
              x: node.frame.x * model.zoom + model.panX, y: node.frame.y * model.zoom + model.panY
            )
            .zIndex(model.selectedNodeIDs.contains(node.id) ? 1 : 0)
        }
        OrchestratorLinkOverlay(
          links: model.orchestratorLinks,
          nodes: model.workspace?.nodes ?? [],
          zoom: model.zoom,
          panX: model.panX,
          panY: model.panY
        )
        .zIndex(2)
        if model.workspace?.nodes.isEmpty == true {
          VStack(spacing: Spacing.sm) {
            Text("Room to work").font(Typography.display).foregroundStyle(Palette.ink)
            Text("Add a console. Drag the background or scroll to pan; pinch to zoom.")
              .font(Typography.body).foregroundStyle(Palette.secondaryInk)
            addConsoleControl(identifier: "canvas.addConsole") {
              Label("Add console", systemImage: Icon.add.rawValue)
            }
            .fixedSize()
            newTerminalButton(identifier: "canvas.newTerminal")
          }
          .padding(Spacing.lg)
          .background(Palette.surface, in: RoundedRectangle(cornerRadius: Spacing.radiusLarge))
          .frame(width: geometry.size.width, height: geometry.size.height)
          .allowsHitTesting(true)
        }
      }
      .coordinateSpace(name: "boardViewport")
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .clipped()
      .onAppear {
        model.revealConsolesInViewport(width: geometry.size.width, height: geometry.size.height)
      }
      .onChange(of: geometry.size) { _, size in
        model.revealConsolesInViewport(width: size.width, height: size.height)
      }
      .onChange(of: model.activeWorkspaceID) { _, _ in
        model.revealConsolesInViewport(width: geometry.size.width, height: geometry.size.height)
      }
      .simultaneousGesture(
        MagnifyGesture().onChanged { value in
          if pinchStart == nil { pinchStart = model.zoom }
          model.setZoom(
            (pinchStart ?? model.zoom) * value.magnification,
            anchorX: value.startAnchor.x * geometry.size.width,
            anchorY: value.startAnchor.y * geometry.size.height)
        }.onEnded { _ in pinchStart = nil })
    }
  }

  private func beginRename(_ workspace: Workspace) {
    workspaceName = workspace.name
    renamingID = workspace.id
  }
  private func ensurePresetsModel() {
    guard presetsPanelModel == nil else { return }
    presetsPanelModel = PresetsPanelModel(store: presetsStore)
  }
  private func ensureChatModel() {
    chatPanelModel.setWorkspace(model.workspace?.id)
  }
  private func resignTerminalFocus() { NSApp.keyWindow?.makeFirstResponder(nil) }

  private func groupMember(_ node: Node) -> GroupMemberState {
    if let session = model.sessions[node.id] {
      return GroupMemberState(status: session.status, label: session.status.label(exitCode: session.exitCode))
    }
    if let status = model.orchestratorStatuses[node.id] {
      return GroupMemberState(status: status, label: status.label())
    }
    if model.consoleLaunchErrors[node.id] != nil {
      return GroupMemberState(status: .error, label: AgentStatus.error.label())
    }
    return GroupMemberState(status: .stopped, label: AgentStatus.stopped.label())
  }
}

public enum ConsoleCardControl {
  public static func restartIdentifier(_ id: UUID) -> String { "console.restart.\(id.uuidString)" }
  public static func closeIdentifier(_ id: UUID) -> String { "console.close.\(id.uuidString)" }
  public static func statusIdentifier(_ id: UUID) -> String { "console.status.\(id.uuidString)" }
}

/// A live session owns the light. A failed launch is an error. A card that has not started is stopped.
public enum ConsoleCardStatus {
  public static func resolve(sessionStatus: AgentStatus?, hasLaunchError: Bool) -> AgentStatus {
    if let sessionStatus { return sessionStatus }
    return hasLaunchError ? .error : .stopped
  }
}

private struct BoardConsoleCard: View {
  let model: BoardViewModel
  let node: Node
  @State private var dragOrigin: NodeFrame?
  @State private var resizeOrigin: NodeFrame?

  private var session: ConsoleSession? { model.sessions[node.id] }
  private var orchestratorStatus: AgentStatus? {
    node.agentID == OrchestratorKind.agentID ? model.orchestratorStatuses[node.id] : nil
  }
  var body: some View {
    ConsoleCardChrome(
      title: model.workspace?.groups.first(where: { $0.leadNodeID == node.id }) == nil ? node.title : "★ \(node.title) · Lead",
      icon: node.agentID == OrchestratorKind.agentID ? .agents : .terminal,
      status: ConsoleCardStatus.resolve(
        sessionStatus: session?.status ?? orchestratorStatus,
        hasLaunchError: model.consoleLaunchErrors[node.id] != nil),
      isSelected: model.selectedNodeIDs.contains(node.id)
    ) {
      ZStack {
        if node.agentID == OrchestratorKind.agentID, model.orchestratorTranscripts[node.id] != nil {
          OrchestratorConsoleBody(model: model, nodeID: node.id)
        } else if let session {
          ConsoleTerminal(session: session)
            .id(ObjectIdentifier(session))
          if let message = session.failureMessage {
            VStack {
              Spacer()
              Text(message).font(Typography.caption).foregroundStyle(Palette.status(.error))
                .padding(Spacing.xs).background(Palette.surface)
            }
          }
        } else {
          VStack(spacing: Spacing.sm) {
            Text("\(node.title) is ready to start").font(Typography.body).foregroundStyle(
              Palette.secondaryInk)
            Text(node.cwd.path)
              .font(Typography.caption)
              .foregroundStyle(Palette.secondaryInk)
              .lineLimit(1)
              .truncationMode(.middle)
              .multilineTextAlignment(.center)
              .padding(.horizontal, Spacing.sm)
              .accessibilityIdentifier("console.directory.\(node.id.uuidString)")
              .accessibilityLabel("Working folder")
            if let message = model.consoleLaunchErrors[node.id] {
              Text(message)
                .font(Typography.caption)
                .foregroundStyle(Palette.status(.error))
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.sm)
                .accessibilityIdentifier("console.launchError")
            }
            AXActionButton(
              title: "Start",
              systemImage: nil,
              identifier: "console.start.\(node.id.uuidString)",
              accessibilityLabel: "Start \(node.title)",
              enabled: true,
              highlighted: false,
              compact: false
            ) {
              Task { await model.startConsole(node.id) }
            }
            .frame(width: 72, height: 28)
          }
          .simultaneousGesture(
            TapGesture().onEnded {
              model.select(node.id, extending: NSEvent.modifierFlags.contains(.shift))
            })
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .statusDetail(exitCode: session?.exitCode, identifier: ConsoleCardControl.statusIdentifier(node.id))
    .headerDrag(
      onChanged: { translation in
        if dragOrigin == nil {
          dragOrigin = node.frame
          if !model.selectedNodeIDs.contains(node.id) { model.select(node.id) }
        }
        guard let origin = dragOrigin else { return }
        model.moveNode(
          node.id, x: origin.x + translation.width / model.zoom,
          y: origin.y + translation.height / model.zoom)
      }, onEnded: { dragOrigin = nil }
    )
    .keyboardFocus(model.focusedNodeID == node.id)
    .headerSelection {
      model.select(node.id, extending: NSEvent.modifierFlags.contains(.shift))
    }
    .headerControls {
      HStack(spacing: 0) {
        AXActionButton(
          title: "Restart",
          systemImage: Icon.restart.rawValue,
          identifier: ConsoleCardControl.restartIdentifier(node.id),
          accessibilityLabel: "Restart \(node.title)",
          enabled: true,
          highlighted: false,
          compact: false,
          headerIcon: true
        ) {
          Task { await model.restartConsole(node.id) }
        }
        .frame(width: 28, height: 28)
        AXActionButton(
          title: "Close",
          systemImage: Icon.close.rawValue,
          identifier: ConsoleCardControl.closeIdentifier(node.id),
          accessibilityLabel: "Close \(node.title)",
          enabled: true,
          highlighted: false,
          compact: false,
          headerIcon: true
        ) {
          Task { await model.closeConsole(node.id) }
        }
        .frame(width: 28, height: 28)
      }
    }
    .overlay(alignment: .bottomTrailing) {
      CardResizeGrip(label: "Resize \(node.title)", identifier: "console.resize.\(node.title)") { dx, dy in
        if resizeOrigin == nil {
          resizeOrigin = node.frame
          model.select(node.id)
        }
        guard let origin = resizeOrigin else { return }
        model.resizeNode(
          node.id, width: origin.w + Double(dx) / model.zoom,
          height: origin.h + Double(dy) / model.zoom)
      } onDragEnd: {
        resizeOrigin = nil
      } onAdjust: { amount in
        model.resizeNode(node.id, width: node.frame.w + amount, height: node.frame.h + amount)
      }
      .frame(width: 20, height: 20)
    }
  }
}

struct BoardRailPanel: Identifiable {
  let id: String
  let icon: Icon
  let title: String
  let isSelected: Bool
  let action: () -> Void

  init(id: String? = nil, icon: Icon, title: String, isSelected: Bool, action: @escaping () -> Void) {
    self.id = id ?? title
    self.icon = icon
    self.title = title
    self.isSelected = isSelected
    self.action = action
  }
}

/// Panel buttons scroll. Add console, Group, and Manage stay on screen at an 800pt window.
/// Compact rail buttons are wide enough for the longest caption at 11 pt.
/// A 52 pt button draws "Markdown" as "Markdo..." because that string is about 54 pt wide.
public enum BoardRailMetrics {
  public static let buttonHeight: CGFloat = 48
  /// "Markdown" at the compact 11 pt font is 54 pt. The extra width keeps the truncating tail from drawing an ellipsis.
  public static let buttonWidth: CGFloat = 64
  public static var railWidth: CGFloat { buttonWidth + Spacing.xs * 2 }

  @MainActor
  public static func captionFits(_ button: NSButton) -> Bool {
    guard let cell = button.cell as? NSButtonCell else { return false }
    let rect = cell.titleRect(forBounds: button.bounds)
    return button.attributedTitle.size().width <= rect.width
  }
}

struct BoardRail<AgentMenu: View>: View {
  let panels: [BoardRailPanel]
  let canCreateGroup: Bool
  let canManageGroups: Bool
  let onCreateGroup: () -> Void
  let onManageGroups: () -> Void
  @ViewBuilder var agentMenu: () -> AgentMenu

  var body: some View {
    VStack(spacing: 0) {
      ScrollView {
        VStack(spacing: Spacing.xs) {
          ForEach(panels) { panel in
            AXActionButton(
              title: panel.title,
              systemImage: panel.icon.rawValue,
              identifier: "rail.panel.\(panel.id)",
              accessibilityLabel: panel.title,
              enabled: true,
              highlighted: panel.isSelected,
              compact: true
            ) {
              panel.action()
            }
            .frame(width: BoardRailMetrics.buttonWidth, height: BoardRailMetrics.buttonHeight)
          }
        }
        .padding(.horizontal, Spacing.xs)
        .padding(.top, Spacing.xs)
      }
      .scrollIndicators(.visible)
      .frame(minHeight: 0, maxHeight: .infinity)
      VStack(spacing: Spacing.xs) {
        agentMenu()
        AXActionButton(
          title: "Group",
          systemImage: "rectangle.3.group",
          identifier: "rail.createGroup",
          accessibilityLabel: "Create group",
          enabled: canCreateGroup,
          highlighted: false,
          compact: true
        ) {
          onCreateGroup()
        }
        .frame(width: BoardRailMetrics.buttonWidth, height: BoardRailMetrics.buttonHeight)
        .help("Create a group from the selected consoles")
        AXActionButton(
          title: "Manage",
          systemImage: "slider.horizontal.3",
          identifier: "rail.manageGroups",
          accessibilityLabel: "Manage groups",
          enabled: canManageGroups,
          highlighted: false,
          compact: true
        ) {
          onManageGroups()
        }
        .frame(width: BoardRailMetrics.buttonWidth, height: BoardRailMetrics.buttonHeight)
        .help("Rename groups, edit membership, or delete groups")
      }
      .padding(Spacing.xs)
      .frame(maxWidth: .infinity)
      .fixedSize(horizontal: false, vertical: true)
      .layoutPriority(1)
      .background(Palette.surface)
    }
    .frame(width: BoardRailMetrics.railWidth)
    .frame(maxHeight: .infinity, alignment: .top)
    .background(Palette.surface)
  }
}

/// AppKit window Y grows upward. A downward drag of the card corner must grow the card.
enum CardResizeMath {
  static func translation(from start: CGPoint, to current: CGPoint) -> CGSize {
    CGSize(width: current.x - start.x, height: start.y - current.y)
  }
}

/// Corner grip. Accessibility increment runs on the main actor; SwiftUI's adjustable action does not.
struct CardResizeGrip: NSViewRepresentable {
  var label: String
  var identifier: String
  var onDrag: (CGFloat, CGFloat) -> Void
  var onDragEnd: () -> Void
  var onAdjust: (CGFloat) -> Void

  func makeNSView(context: Context) -> CardResizeGripView {
    let view = CardResizeGripView()
    view.onDrag = onDrag
    view.onDragEnd = onDragEnd
    view.onAdjust = onAdjust
    return view
  }

  func updateNSView(_ view: CardResizeGripView, context: Context) {
    view.onDrag = onDrag
    view.onDragEnd = onDragEnd
    view.onAdjust = onAdjust
    view.setAccessibilityElement(true)
    view.setAccessibilityRole(.incrementor)
    view.setAccessibilityLabel(label)
    view.setAccessibilityIdentifier(identifier)
  }

  func sizeThatFits(_ proposal: ProposedViewSize, nsView: CardResizeGripView, context: Context) -> CGSize? {
    CGSize(width: 20, height: 20)
  }
}

final class CardResizeGripView: NSView {
  var onDrag: ((CGFloat, CGFloat) -> Void)?
  var onDragEnd: (() -> Void)?
  var onAdjust: ((CGFloat) -> Void)?
  private var dragStart: CGPoint?

  override var isFlipped: Bool { true }

  override func draw(_ dirtyRect: NSRect) {
    NSColor(Palette.secondaryInk).setStroke()
    let path = NSBezierPath()
    path.lineWidth = 1
    path.move(to: NSPoint(x: 4, y: 16))
    path.line(to: NSPoint(x: 16, y: 4))
    path.move(to: NSPoint(x: 10, y: 16))
    path.line(to: NSPoint(x: 16, y: 10))
    path.stroke()
  }

  override func mouseDown(with event: NSEvent) {
    dragStart = event.locationInWindow
  }

  override func mouseDragged(with event: NSEvent) {
    guard let dragStart else { return }
    let translation = CardResizeMath.translation(from: dragStart, to: event.locationInWindow)
    onDrag?(translation.width, translation.height)
  }

  override func mouseUp(with event: NSEvent) {
    dragStart = nil
    onDragEnd?()
  }

  /// Accessibility calls this off the main actor. Hop before touching the board.
  nonisolated override func accessibilityPerformIncrement() -> Bool {
    Task { @MainActor in self.onAdjust?(32) }
    return true
  }

  nonisolated override func accessibilityPerformDecrement() -> Bool {
    Task { @MainActor in self.onAdjust?(-32) }
    return true
  }
}

/// Window-space pointer deltas grow upward. Canvas pan grows downward, so a downward drag follows the pointer.
/// Scroll deltas already follow the system scroll-direction setting: positive Y reveals content above.
enum CanvasPan {
  static func drag(deltaX: CGFloat, deltaY: CGFloat) -> (x: Double, y: Double) {
    (Double(deltaX), Double(-deltaY))
  }

  static func scroll(deltaX: CGFloat, deltaY: CGFloat, precise: Bool) -> (x: Double, y: Double) {
    let scale = precise ? 1.0 : 12.0
    return (Double(deltaX) * scale, Double(deltaY) * scale)
  }
}

private struct CanvasBackground: NSViewRepresentable {
  let onPan: (Double, Double) -> Void
  let onSelect: () -> Void
  func makeNSView(context: Context) -> BackgroundView { BackgroundView() }
  func updateNSView(_ view: BackgroundView, context: Context) {
    view.onPan = onPan
    view.onSelect = onSelect
  }
  final class BackgroundView: NSView {
    var onPan: ((Double, Double) -> Void)?
    var onSelect: (() -> Void)?
    override var isFlipped: Bool { true }
    override func mouseDown(with event: NSEvent) { onSelect?() }
    override func mouseDragged(with event: NSEvent) {
      let translation = CanvasPan.drag(deltaX: event.deltaX, deltaY: event.deltaY)
      onPan?(translation.x, translation.y)
    }
    override func scrollWheel(with event: NSEvent) {
      let translation = CanvasPan.scroll(
        deltaX: event.scrollingDeltaX, deltaY: event.scrollingDeltaY,
        precise: event.hasPreciseScrollingDeltas)
      onPan?(translation.x, translation.y)
    }
  }
}

/// Screen-space frames for the group map. The name, status words, and lead mark sit in the band above each card.
enum GroupMapLayout {
  static let headerHeight: CGFloat = 52
  static let sidePad: CGFloat = 16
  static let footerPad: CGFloat = 16

  static func cardRect(_ frame: NodeFrame, zoom: Double, panX: Double, panY: Double) -> CGRect {
    CGRect(
      x: frame.x * zoom + panX, y: frame.y * zoom + panY,
      width: frame.w * zoom, height: frame.h * zoom)
  }

  static func groupBounds(frames: [NodeFrame], zoom: Double, panX: Double, panY: Double) -> CGRect {
    let cards = frames.map { cardRect($0, zoom: zoom, panX: panX, panY: panY) }
    guard var union = cards.first else { return .null }
    for card in cards.dropFirst() { union = union.union(card) }
    return CGRect(
      x: union.minX - sidePad, y: union.minY - headerHeight,
      width: union.width + sidePad * 2, height: union.height + headerHeight + footerPad)
  }

  /// 18pt disc in the name row, above the card and in from its right edge.
  static func leadBadge(frame: NodeFrame, zoom: Double, panX: Double, panY: Double) -> CGRect {
    let card = cardRect(frame, zoom: zoom, panX: panX, panY: panY)
    return CGRect(x: card.maxX - 26, y: card.minY - 46, width: 18, height: 18)
  }

  /// 10pt status light at the card's left, below the name row.
  static func statusDot(frame: NodeFrame, zoom: Double, panX: Double, panY: Double) -> CGRect {
    let card = cardRect(frame, zoom: zoom, panX: panX, panY: panY)
    return CGRect(x: card.minX, y: card.minY - 22, width: 10, height: 10)
  }

  /// Room for a status word such as "Waiting for input" beside the light.
  static func statusCaption(frame: NodeFrame, zoom: Double, panX: Double, panY: Double) -> CGRect {
    let dot = statusDot(frame: frame, zoom: zoom, panX: panX, panY: panY)
    return CGRect(x: dot.maxX + 4, y: dot.minY - 1, width: 72, height: 12)
  }
}

struct GroupMemberState: Equatable, Sendable {
  var status: AgentStatus
  var label: String
}

private struct GroupMap: View {
  let workspace: Workspace?
  let members: [UUID: GroupMemberState]
  let zoom: Double
  let panX: Double
  let panY: Double

  var body: some View {
    let workspace = workspace
    let memberStates = members
    let zoom = zoom
    let panX = panX
    let panY = panY
    return Canvas { context, _ in
      guard let workspace else { return }
      let nodes = Dictionary(uniqueKeysWithValues: workspace.nodes.map { ($0.id, $0) })
      for group in workspace.groups {
        let members = group.nodeIDs.compactMap { nodes[$0] }
        guard !members.isEmpty else { continue }
        let rect = GroupMapLayout.groupBounds(
          frames: members.map(\.frame), zoom: zoom, panX: panX, panY: panY)
        let path = Path(roundedRect: rect, cornerRadius: Spacing.radiusLarge)
        context.fill(path, with: .color(Palette.accentSoft.opacity(0.22)))
        context.stroke(path, with: .color(Palette.accent.opacity(0.72)), lineWidth: 1.5)
        context.draw(
          Text(group.name).font(Typography.caption.weight(.semibold)).foregroundColor(Palette.ink),
          at: CGPoint(x: rect.minX + 12, y: rect.minY + 14), anchor: .leading)
        let centers = members.map { member in
          let card = GroupMapLayout.cardRect(member.frame, zoom: zoom, panX: panX, panY: panY)
          return CGPoint(x: card.midX, y: card.midY)
        }
        if centers.count > 1, let first = centers.first {
          var graph = Path()
          for center in centers.dropFirst() {
            graph.move(to: first)
            graph.addLine(to: center)
          }
          context.stroke(
            graph, with: .color(Palette.accent.opacity(0.3)),
            style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }
        for member in members {
          let state = memberStates[member.id] ?? GroupMemberState(status: .stopped, label: AgentStatus.stopped.label())
          let dot = GroupMapLayout.statusDot(frame: member.frame, zoom: zoom, panX: panX, panY: panY)
          let caption = GroupMapLayout.statusCaption(frame: member.frame, zoom: zoom, panX: panX, panY: panY)
          context.fill(Path(ellipseIn: dot), with: .color(Palette.status(state.status)))
          context.draw(
            Text(state.label).font(Typography.caption).foregroundColor(Palette.ink),
            at: CGPoint(x: caption.minX, y: caption.midY), anchor: .leading)
        }
        if let leadID = group.leadNodeID, let lead = nodes[leadID] {
          let badge = GroupMapLayout.leadBadge(
            frame: lead.frame, zoom: zoom, panX: panX, panY: panY)
          context.fill(Path(ellipseIn: badge), with: .color(Palette.accent))
          context.draw(
            Text("★").font(.system(size: 12, weight: .bold)).foregroundColor(Palette.surface),
            at: CGPoint(x: badge.midX, y: badge.midY))
        }
      }
    }
  }
}
