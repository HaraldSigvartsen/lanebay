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
  @State private var boardViewportWidth: Double = 1000
  @State private var openPanel: BoardSidePanel?
  /// The card under the pointer, so its wire ports can show.
  @State private var hoveredCard: UUID?
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
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
        workspaceName: model.workspace?.name,
        panels: [boardPanel] + railPanels
      )
      .zIndex(3)
      Rectangle().fill(Palette.border).frame(width: 1).zIndex(3)
      if model.workspace != nil, model.chatPanelOpen {
        BoardChatPanel(model: model)
          .zIndex(3)
          .transition(.move(edge: .leading).combined(with: .opacity))
        Rectangle().fill(Palette.border).frame(width: 1).zIndex(3)
      }
      VStack(spacing: 0) {
        tabs.zIndex(2)
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
        canvas
          .overlay(alignment: .topLeading) {
            if model.workspace != nil, !model.chatPanelOpen {
              Button {
                withAnimation(.easeOut(duration: 0.22)) { model.setChatPanel(open: true) }
              } label: {
                Label("Chat", systemImage: "bubble.left.and.text.bubble.right")
                  .font(Typography.caption.weight(.semibold))
                  .padding(.horizontal, Spacing.sm)
                  .frame(height: 28)
                  .background(Palette.surface, in: Capsule())
                  .overlay(Capsule().stroke(Palette.border))
              }
              .buttonStyle(.plain)
              .foregroundStyle(Palette.ink)
              .padding(Spacing.sm)
              .help("Vis chat (⌘⇧C)")
            }
          }
          .background {
            Button("") { withAnimation(.easeOut(duration: 0.22)) { model.setChatPanel(open: !model.chatPanelOpen) } }
              .keyboardShortcut("c", modifiers: [.command, .shift])
              .opacity(0).allowsHitTesting(false)
          }
          .onChange(of: model.consoleNodes.map(\.title)) { _, _ in model.makeConsoleNamesUnique() }
        if !model.chatPanelOpen || model.workspace == nil {
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
    }
    .background(Palette.canvas)
    .overlay {
      DialogOverlay(
        isPresented: openPanel != nil,
        preferredWidth: openPanel?.width ?? DialogLayout.minWidth,
        onClose: { openPanel = nil }
      ) {
        if let panel = openPanel { dialogPanel(panel).id(panel) }
      }
    }
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
    .sheet(item: Binding(
      get: { model.providerPickerNodeID.map(ProviderPickerTarget.init) },
      set: { model.providerPickerNodeID = $0?.id })
    ) { target in
      ProviderPickerSheet(model: model, nodeID: target.id)
        .presentationBackground(.clear)
    }
    .sheet(isPresented: $model.showingNewTerminal) {
      NewTerminalSheet(model: model)
    }
    .onChange(of: model.presentedChromeDismissals) { _, _ in
      showingGroupPrompt = false
      showingGroups = false
      showingAgentPicker = false
      model.showingNewTerminal = false
    }
    .onChange(of: model.navigationRequest) { _, request in
      guard let request else { return }
      navigate(request.target)
      model.clearNavigationRequest()
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
      model.startCronScheduler()
      SettingsViewModel.applyAppearance(model.settings.preferences.appearance)
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

  private var boardPanel: BoardRailPanel {
    BoardRailPanel(
      id: "board", icon: .workspace, title: "Agenter", section: .primary,
      badge: model.runningConsoleCount, isSelected: openPanel == nil
    ) {
      openPanel = nil
    }
  }

  private var railPanels: [BoardRailPanel] {
    BoardSidePanel.railOrder.map { panel in
      BoardRailPanel(
        id: panel.rawValue,
        icon: panel.icon,
        title: panel.railTitle,
        section: panel.section,
        badge: model.railBadge(for: panel),
        isSelected: openPanel == panel
      ) {
        togglePanel(panel)
      }
    }
  }

  private func togglePanel(_ panel: BoardSidePanel) {
    let next = BoardSidePanel.toggled(openPanel, panel)
    show(next)
  }

  private func show(_ panel: BoardSidePanel?) {
    // The board's first responder (a terminal) draws its focus ring above SwiftUI overlays; drop it under a dialog.
    if panel != nil { NSApp.keyWindow?.makeFirstResponder(nil) }
    openPanel = panel
    if panel == .presets { ensurePresetsModel() }
    if panel == .chat { ensureChatModel() }
    if panel == .activity { model.markActivityRead() }
  }

  /// ⌘1–⌘5 from the app menu. Agenter goes home; a section opens that panel without toggling it shut.
  private func navigate(_ target: BoardNavigation) {
    switch target {
    case .board: show(nil)
    case let .panel(panel): show(panel)
    }
  }

  private func panelSubtitle(_ panel: BoardSidePanel) -> String {
    switch panel {
    case .presets: "Reusable prompts and commands"
    default: model.workspace?.name ?? "No active workspace"
    }
  }

  @ViewBuilder
  private func dialogPanel(_ panel: BoardSidePanel) -> some View {
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
  }

  @ViewBuilder
  private func panelBody(_ panel: BoardSidePanel) -> some View {
    switch panel {
    case .settings:
      SettingsPanel(model: model.settings) { show(.usage) }
    case .activity:
      ActivityPanel(model: model)
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
      PlannerPanel(
        model: plannerPanelModel,
        header: AnyView(WiresSection(model: model, onDone: { openPanel = nil })))
    case .loops:
      LoopPanel(model: model)
    }
  }

  private var availablePresetAgentKinds: [String] {
    let kinds = model.workspace?.nodes.compactMap(\.agentID) ?? []
    return Array(Set(kinds)).sorted()
  }

  private var tabs: some View {
    HStack(spacing: DS.Space.xs) {
      ScrollView(.horizontal, showsIndicators: false) {
        HStack(spacing: DS.Space.xs) {
          ForEach(model.workspaces) { workspace in
            workspacePill(workspace)
          }
        }
        .padding(.vertical, 1)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      Button {
        _ = model.createWorkspace(name: "Workspace \(model.workspaces.count + 1)")
      } label: {
        Icon.add.image
      }
      .buttonStyle(.lbIcon)
      .help("New workspace").accessibilityLabel("New workspace")
      if let workspace = model.workspace {
        Button {
          beginRename(workspace)
        } label: {
          Icon.menu.image
        }
        .buttonStyle(.lbIcon)
        .help("Rename workspace").accessibilityLabel("Rename workspace")
      }
      AXActionButton(
        title: "Cron",
        systemImage: "repeat",
        identifier: "toolbar.showLoops",
        accessibilityLabel: "Show cron",
        enabled: model.workspace != nil,
        highlighted: openPanel == .loops,
        compact: false,
        headerIcon: true
      ) { togglePanel(.loops) }
      .frame(width: 28, height: 28)
      .help("Show cron")
      boardActions
      zoomControls
      newTerminalButton(identifier: "toolbar.newTerminal", primary: true)
    }
    .padding(.horizontal, DS.Space.sm)
    .padding(.vertical, DS.Space.sm)
    .background(.ultraThinMaterial)
    .overlay(alignment: .bottom) { Rectangle().fill(DS.Color.hairline).frame(height: 1) }
  }

  private func workspacePill(_ workspace: Workspace) -> some View {
    let isActive = workspace.id == model.activeWorkspaceID
    return Button {
      resignTerminalFocus()
      model.switchWorkspace(workspace.id)
    } label: {
      Text(workspace.name)
        .font(DS.Font.bodyEmphasis)
        .lineLimit(1)
        .padding(.horizontal, DS.Space.sm)
        .padding(.vertical, 6)
        .foregroundStyle(isActive ? DS.Color.accentInk : DS.Color.secondaryInk)
        .background(isActive ? DS.Color.accentSoft : Color.clear, in: Capsule())
        .overlay(
          Capsule()
            .strokeBorder(
              isActive ? DS.Color.accent.opacity(0.35) : DS.Color.hairline.opacity(0.6), lineWidth: 1))
        .animation(
          DS.Motion.animation(DS.Motion.snappy, reduceMotion: reduceMotion), value: model.activeWorkspaceID)
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isActive ? .isSelected : [])
    .contextMenu { Button("Rename…") { beginRename(workspace) } }
    .help("Control-click to rename workspace")
  }

  private var zoomControls: some View {
    HStack(spacing: 0) {
      Button {
        model.setZoom(model.zoom / 1.1)
      } label: {
        Text("−")
      }
      .buttonStyle(.lbIcon)
      .help("Zoom out (⌘−)").accessibilityLabel("Zoom out")
      Text(model.zoom, format: .percent.precision(.fractionLength(0)))
        .font(DS.Font.caption).foregroundStyle(DS.Color.secondaryInk)
        .monospacedDigit().frame(minWidth: 36)
        .accessibilityLabel("Canvas zoom")
      Button {
        model.setZoom(model.zoom * 1.1)
      } label: {
        Icon.add.image
      }
      .buttonStyle(.lbIcon)
      .help("Zoom in (⌘+)").accessibilityLabel("Zoom in")
    }
    .padding(.horizontal, DS.Space.xxs)
    .frame(height: 32)
    .background(DS.Color.raisedSurface.opacity(0.7), in: Capsule())
    .overlay(Capsule().strokeBorder(DS.Color.hairline, lineWidth: 1))
  }

  /// Board tools folded out of the sidebar: quick add, tidy, group and manage groups.
  private var boardActions: some View {
    HStack(spacing: DS.Space.xxs) {
      headerAction("Hurtigstart", "bolt.fill", "rail.addConsole", "Add console",
        enabled: model.workspace != nil, highlighted: showingAgentPicker,
        help: "Start en agent raskt fra lista") { showingAgentPicker.toggle() }
      headerAction("Rydd", "square.grid.2x2", "board.tidy", "Rydd tavla",
        enabled: (model.workspace?.nodes.isEmpty ?? true) == false,
        help: "Rydd tavla: legg kortene i et rutenett uten overlapp") {
          model.tidyBoard(viewportWidth: boardViewportWidth)
        }
      headerAction("Grupper", "rectangle.3.group", "rail.createGroup", "Create group",
        enabled: model.canCreateGroup, help: "Lag en gruppe av de valgte terminalene") {
          showingGroupPrompt = true
        }
      headerAction("Administrer grupper", "slider.horizontal.3", "rail.manageGroups", "Manage groups",
        enabled: model.workspace?.groups.isEmpty == false,
        help: "Gi nytt navn, endre medlemmer eller slett grupper") { showingGroups = true }
    }
    .padding(DS.Space.xxs)
    .background(Capsule().fill(DS.Color.surface.opacity(0.6)))
    .overlay(Capsule().strokeBorder(DS.Color.hairline, lineWidth: 1))
  }

  private func headerAction(
    _ title: String, _ symbol: String, _ identifier: String, _ label: String,
    enabled: Bool, highlighted: Bool = false, help: String, action: @escaping () -> Void
  ) -> some View {
    AXActionButton(
      title: title,
      systemImage: symbol,
      identifier: identifier,
      accessibilityLabel: label,
      enabled: enabled,
      highlighted: highlighted,
      compact: false,
      headerIcon: true,
      action: action
    )
    .frame(width: 28, height: 28)
    .help(help)
  }

  private var agentPickerOverlay: some View {
    ZStack(alignment: .topTrailing) {
      if showingAgentPicker {
        Color.black.opacity(0.001)
          .contentShape(Rectangle())
          .onTapGesture { showingAgentPicker = false }
          .accessibilityLabel("Dismiss console list")
          .accessibilityIdentifier("agent.picker.dismiss")
          .zIndex(0)
        AgentPickerList(model: model) { showingAgentPicker = false }
          .padding(.trailing, 160)
          .padding(.top, 52)
          .zIndex(1)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
  }

  private func newTerminalButton(identifier: String, primary: Bool = false) -> some View {
    AXActionButton(
      title: "Ny terminal",
      systemImage: Icon.add.rawValue,
      identifier: identifier,
      accessibilityLabel: "New terminal",
      enabled: model.workspace != nil,
      highlighted: model.showingNewTerminal,
      primary: primary,
      compact: false
    ) {
      model.beginNewTerminal()
    }
    .frame(width: 132, height: primary ? 32 : 28)
    .background {
      if primary {
        RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
          .fill(DS.Color.accentGradient)
      }
    }
  }

  /// The workspace as drawn: idle, unselected cards use the compact height so group frames hug them.
  private var displayedWorkspace: Workspace? {
    guard var workspace = model.workspace else { return nil }
    workspace.nodes = workspace.nodes.map { node in
      var node = node
      node.frame = model.displayedFrame(node)
      return node
    }
    return workspace
  }

  private var canvas: some View {
    // The grid closure runs from AppKit layout, outside a Swift task. Keep it to plain numbers.
    let zoom = model.zoom
    let panX = model.panX
    let panY = model.panY
    return GeometryReader { geometry in
      ZStack(alignment: .topLeading) {
        Canvas { context, size in
          // Faint dot grid. Spacing follows zoom but never gets denser than 16 pt.
          let step = max(16, DS.Space.xl * zoom)
          let radius: CGFloat = 1
          var dots = Path()
          for x in stride(
            from: panX.truncatingRemainder(dividingBy: step), through: size.width, by: step)
          {
            for y in stride(
              from: panY.truncatingRemainder(dividingBy: step), through: size.height, by: step)
            {
              dots.addEllipse(
                in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
            }
          }
          context.fill(dots, with: .color(Palette.secondaryInk.opacity(0.06)))
        }
        .background(DS.Color.canvasGlow)
        .background(DS.Color.canvasGradient)
        .allowsHitTesting(false)
        CanvasBackground(
          onPan: { model.pan(dx: $0, dy: $1) },
          onSelect: {
            resignTerminalFocus()
            model.select(nil)
          })
        GroupMap(
          workspace: displayedWorkspace,
          members: Dictionary(
            uniqueKeysWithValues: (model.workspace?.nodes ?? []).map { ($0.id, groupMember($0)) }),
          zoom: model.zoom, panX: model.panX, panY: model.panY
        )
        .allowsHitTesting(false)
        WireLayer(
          model: model, frames: wireFrames,
          transform: BoardTransform(zoom: model.zoom, panX: model.panX, panY: model.panY))
        ForEach(model.workspace?.nodes.filter { $0.kind == .console } ?? []) { node in
          let compact = BoardLayout.isCompact(idle: model.consoleIsIdle(node.id))
          let shown = model.displayedFrame(node)
          BoardConsoleCard(model: model, node: node)
            .frame(width: shown.w, height: shown.h)
            .animation(DS.Motion.animation(DS.Motion.snappy, reduceMotion: false), value: compact)
            .scaleEffect(model.zoom, anchor: .topLeading)
            .offset(
              x: node.frame.x * model.zoom + model.panX, y: node.frame.y * model.zoom + model.panY
            )
            .zIndex(model.selectedNodeIDs.contains(node.id) ? 1 : 0)
        }
        WirePortsLayer(
          model: model, frames: wireFrames,
          order: (model.workspace?.nodes ?? []).filter { $0.kind == .console }.map(\.id),
          transform: BoardTransform(zoom: model.zoom, panX: model.panX, panY: model.panY),
          hoveredCard: hoveredCard
        )
        .zIndex(1.5)
        if model.selectedWireID != nil {
          Button("Slett tråd") {
            if let id = model.selectedWireID { model.removeWire(id) }
          }
          .keyboardShortcut(.delete, modifiers: [])
          .opacity(0)
          .frame(width: 0, height: 0)
          .accessibilityHidden(true)
        }
        OrchestratorLinkOverlay(
          links: model.orchestratorLinks,
          nodes: model.workspace?.nodes ?? [],
          zoom: model.zoom,
          panX: model.panX,
          panY: model.panY
        )
        .zIndex(2)
        if OnboardingCard.shouldShow(workspace: model.workspace) {
          OnboardingCard(
            hasWorkspace: model.workspace != nil,
            onStart: { model.beginNewTerminal() },
            onDocs: { show(.docs) },
            onCreateWorkspace: {
              _ = model.createWorkspace(name: "Workspace \(model.workspaces.count + 1)")
            }
          )
          .frame(width: geometry.size.width, height: geometry.size.height)
          .allowsHitTesting(true)
        }
      }
      .coordinateSpace(name: "boardViewport")
      .onContinuousHover(coordinateSpace: .named("boardViewport")) { phase in
        switch phase {
        case let .active(location):
          let point = BoardTransform(zoom: model.zoom, panX: model.panX, panY: model.panY).board(location)
          let card = WireGeometry.card(at: point, in: model.consoleFrames(), padding: 24)
          if card != hoveredCard { hoveredCard = card }
        case .ended:
          hoveredCard = nil
        }
      }
      .onChange(of: model.focusedNodeID) { _, focused in
        // Typing in a terminal must never hit a selected wire's Delete shortcut.
        if focused != nil { model.selectedWireID = nil }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .clipped()
      .onAppear {
        boardViewportWidth = geometry.size.width
        model.revealConsolesInViewport(width: geometry.size.width, height: geometry.size.height)
      }
      .onChange(of: model.runningConsoleCount) { _, _ in
        model.tidyBoardIfOverlapping(viewportWidth: geometry.size.width)
      }
      .onChange(of: model.workspace?.nodes.count) { _, _ in
        model.tidyBoardIfOverlapping(viewportWidth: geometry.size.width)
      }
      .onChange(of: geometry.size) { _, size in
        boardViewportWidth = size.width
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

  private var wireFrames: [UUID: NodeFrame] {
    Dictionary(model.consoleFrames(), uniquingKeysWith: { first, _ in first })
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

  /// The card's one-line live activity: the short task when there is one, else the newest output line.
  private var activityLine: String? {
    if let task = model.agentTasks[node.id] { return AgentTaskBanner.label(task) }
    // Output text is not published; the byte count is. Reading it keeps the strip fresh.
    let _ = session?.outputByteCount
    guard let output = model.recentConsoleOutput(node.id, maxBytes: 4_096) else { return nil }
    return ConsoleActivityLine.latest(in: output)
  }
  var body: some View {
    ConsoleCardChrome(
      title: model.workspace?.groups.first(where: { $0.leadNodeID == node.id }) == nil ? node.title : "★ \(node.title) · Lead",
      agentID: node.agentID ?? "shell",
      status: ConsoleCardStatus.resolve(
        sessionStatus: session?.status ?? orchestratorStatus,
        hasLaunchError: model.consoleLaunchErrors[node.id] != nil),
      isSelected: model.selectedNodeIDs.contains(node.id),
      activity: activityLine
    ) {
      VStack(spacing: 0) {
      if let agentTask = model.agentTasks[node.id] {
        AgentTaskBanner(record: agentTask)
      }
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
          ViewThatFits(in: .vertical) {
          VStack(spacing: DS.Space.sm) {
            Image(systemName: "play.circle")
              .font(.system(size: 20, weight: .medium))
              .foregroundStyle(DS.Color.accent)
              .frame(width: 48, height: 48)
              .background(DS.Color.accentSoft, in: Circle())
            Text("Klar til start")
              .font(DS.Font.title)
              .foregroundStyle(DS.Color.ink)
            Text(node.cwd.path)
              .font(DS.Font.mono)
              .foregroundStyle(DS.Color.secondaryInk)
              .lineLimit(1)
              .truncationMode(.middle)
              .multilineTextAlignment(.center)
              .padding(.horizontal, DS.Space.sm)
              .accessibilityIdentifier("console.directory.\(node.id.uuidString)")
              .accessibilityLabel("Working folder")
            if let message = model.consoleLaunchErrors[node.id] {
              Text(message)
                .font(DS.Font.caption)
                .foregroundStyle(DS.Color.status(.error))
                .multilineTextAlignment(.center)
                .padding(.horizontal, DS.Space.sm)
                .accessibilityIdentifier("console.launchError")
            }
            Button("Start") {
              Task { await model.startConsole(node.id) }
            }
            .buttonStyle(.lbPrimary)
            .accessibilityIdentifier("console.start.\(node.id.uuidString)")
            .accessibilityLabel("Start \(node.title)")
          }
          // Compact strip for idle cards (BoardLayout.compactHeight).
          HStack(spacing: DS.Space.sm) {
            Image(systemName: "play.circle")
              .font(.system(size: 16, weight: .medium))
              .foregroundStyle(DS.Color.accent)
              .frame(width: 32, height: 32)
              .background(DS.Color.accentSoft, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
              Text("Klar til start")
                .font(DS.Font.bodyEmphasis)
                .foregroundStyle(DS.Color.ink)
              Text(model.consoleLaunchErrors[node.id] ?? node.cwd.path)
                .font(DS.Font.caption)
                .foregroundStyle(
                  model.consoleLaunchErrors[node.id] == nil ? DS.Color.secondaryInk : DS.Color.status(.error))
                .lineLimit(1)
                .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Button("Start") {
              Task { await model.startConsole(node.id) }
            }
            .buttonStyle(.lbPrimary)
            .accessibilityIdentifier("console.start.\(node.id.uuidString)")
            .accessibilityLabel("Start \(node.title)")
          }
          .padding(.horizontal, DS.Space.sm)
          }
          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .padding(DS.Space.sm)
          .simultaneousGesture(
            TapGesture().onEnded {
              model.select(node.id, extending: NSEvent.modifierFlags.contains(.shift))
            })
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
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
    .working(model.chatWorking[node.id] != nil)
    .renamable(
      name: node.title, isRenaming: model.renamingNodeID == node.id,
      onBegin: { model.renamingNodeID = node.id },
      onCommit: { name in
        if let name { model.renameConsole(node.id, to: name) }
        model.renamingNodeID = nil
      })
    .headerSelection {
      model.select(node.id, extending: NSEvent.modifierFlags.contains(.shift))
    }
    .headerControls {
      HStack(spacing: 0) {
        Menu {
          Button("Gi nytt navn…") { model.renamingNodeID = node.id }
          Button("Bytt AI og modell…") { model.providerPickerNodeID = node.id }
          Button("Tagg @\(TerminalHandle.slug(node.title)) i chatten") { model.insertChatMention(node.id) }
          Divider()
          Button("Start på nytt") { Task { await model.restartConsole(node.id) } }
          Button("Lukk") { Task { await model.closeConsole(node.id) } }
        } label: {
          Icon.menu.image.foregroundStyle(Palette.secondaryInk)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Kortmeny")
        .accessibilityLabel("\(node.title) meny")
        Button {
          Task { await model.restartConsole(node.id) }
        } label: {
          Icon.restart.image
        }
        .buttonStyle(.lbIcon)
        .help("Restart \(node.title)")
        .accessibilityLabel("Restart \(node.title)")
        .accessibilityIdentifier(ConsoleCardControl.restartIdentifier(node.id))
        Button {
          Task { await model.closeConsole(node.id) }
        } label: {
          Icon.close.image
        }
        .buttonStyle(.lbIcon)
        .help("Close \(node.title)")
        .accessibilityLabel("Close \(node.title)")
        .accessibilityIdentifier(ConsoleCardControl.closeIdentifier(node.id))
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
  let section: RailSection
  let badge: Int?
  let isSelected: Bool
  let action: () -> Void

  init(
    id: String? = nil,
    icon: Icon,
    title: String,
    section: RailSection = .primary,
    badge: Int? = nil,
    isSelected: Bool,
    action: @escaping () -> Void
  ) {
    self.id = id ?? title
    self.icon = icon
    self.title = title
    self.section = section
    self.badge = badge
    self.isSelected = isSelected
    self.action = action
  }
}

/// Panel rows scroll. Console, Group, and Manage stay on screen at an 800 pt window.
/// The 208 pt sidebar keeps the longest label beside its icon without clipping.
public enum BoardRailMetrics {
  public static let sidebarWidth: CGFloat = 208
  public static let rowHeight: CGFloat = 32

  /// Icon-over-label buttons in sheets and pickers.
  public static let buttonHeight: CGFloat = 52
  public static let buttonWidth: CGFloat = 76

  @MainActor
  public static func captionFits(_ button: NSButton) -> Bool {
    guard let cell = button.cell as? NSButtonCell else { return false }
    let rect = cell.titleRect(forBounds: button.bounds)
    return button.attributedTitle.size().width <= rect.width
  }

  /// AppKit has no `lineLimit`/`minimumScaleFactor`: shrink the caption to 85% before it ellipsises.
  public static func fittedCaption(
    _ title: String,
    width: CGFloat = buttonWidth,
    color: NSColor = NSColor(Palette.secondaryInk)
  ) -> NSAttributedString {
    let available = width - 8
    let paragraph = NSMutableParagraphStyle()
    paragraph.lineBreakMode = .byTruncatingTail
    let minimum: CGFloat = 11 * 0.85
    func attributed(_ size: CGFloat) -> NSAttributedString {
      NSAttributedString(
        string: title,
        attributes: [
          .font: NSFont.systemFont(ofSize: size),
          .foregroundColor: color,
          .paragraphStyle: paragraph,
        ])
    }
    var size: CGFloat = 11
    while size > minimum, attributed(size).size().width > available {
      size -= 0.25
    }
    return attributed(size)
  }
}

/// The translucent sidebar: workspace name, the five places, a collapsible `Verktøy` group,
/// and Console / Group / Manage pinned at the bottom.
/// Sidebar navigation only. Board actions (Hurtigstart, Rydd, Grupper) live in the board's top bar.
struct BoardRail: View {
  let workspaceName: String?
  let panels: [BoardRailPanel]

  @AppStorage("lanebay.sidebar.toolsExpanded") private var toolsExpanded = true
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var primaryPanels: [BoardRailPanel] { panels.filter { $0.section == .primary } }
  private var toolPanels: [BoardRailPanel] { panels.filter { $0.section == .tools } }

  var body: some View {
    VStack(spacing: 0) {
      Text(workspaceName ?? "Lanebay")
        .font(DS.Font.title)
        .foregroundStyle(DS.Color.ink)
        .lineLimit(1)
        .truncationMode(.middle)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DS.Space.sm)
        .padding(.top, DS.Space.md)
        .padding(.bottom, DS.Space.xs)
        .help(workspaceName ?? "Lanebay")
        .accessibilityLabel("Workspace")
        .accessibilityIdentifier("rail.workspace")

      ScrollView(.vertical, showsIndicators: false) {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
          ForEach(primaryPanels) { panel in row(panel) }
          toolsSection
        }
        .padding(.horizontal, DS.Space.sm)
        .padding(.bottom, DS.Space.xs)
      }
      .frame(minHeight: 0, maxHeight: .infinity)

    }
    .frame(width: BoardRailMetrics.sidebarWidth)
    .frame(maxHeight: .infinity, alignment: .top)
    .background(DS.Color.sidebarWash)
    .background(DS.Color.canvasDeep.opacity(0.9))
    .background(SidebarVibrancy())
  }

  private func row(_ panel: BoardRailPanel) -> some View {
    ZStack(alignment: .trailing) {
      if panel.isSelected {
        RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous)
          .fill(DS.Color.accent.opacity(0.22))
          .overlay(alignment: .leading) {
            Capsule().fill(DS.Color.accentGradient).frame(width: 3).padding(.vertical, 6)
          }
          .allowsHitTesting(false)
      }
      AXActionButton(
        title: panel.title,
        systemImage: panel.icon.rawValue,
        identifier: "rail.panel.\(panel.id)",
        accessibilityLabel: panel.title,
        enabled: true,
        highlighted: panel.isSelected,
        compact: false,
        row: true
      ) {
        panel.action()
      }
      if let badge = panel.badge, badge > 0 {
        Text("\(badge)")
          .font(DS.Font.caption)
          .monospacedDigit()
          .fontWeight(.semibold)
          .foregroundStyle(Color.white)
          .padding(.horizontal, 6)
          .frame(minWidth: 18, minHeight: 18)
          .background(DS.Color.accentGradient, in: Capsule())
          .padding(.trailing, DS.Space.xs)
          .allowsHitTesting(false)
          .accessibilityHidden(true)
      }
    }
    .frame(height: BoardRailMetrics.rowHeight)
  }

  private var toolsSection: some View {
    VStack(alignment: .leading, spacing: DS.Space.xxs) {
      Button {
        withAnimation(DS.Motion.animation(DS.Motion.snappy, reduceMotion: reduceMotion)) {
          toolsExpanded.toggle()
        }
      } label: {
        HStack(spacing: DS.Space.xxs) {
          Text("Verktøy").sectionCaptionStyle()
          Spacer(minLength: 0)
          Image(systemName: "chevron.down")
            .font(DS.Font.caption)
            .foregroundStyle(DS.Color.mutedInk)
            .rotationEffect(.degrees(toolsExpanded ? 0 : -90))
        }
        .padding(.horizontal, DS.Space.xs)
        .frame(height: DS.Space.lg)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(toolsExpanded ? "Hide tools" : "Show tools")
      .accessibilityIdentifier("rail.toolsToggle")
      if toolsExpanded {
        ForEach(toolPanels) { panel in row(panel) }
          .transition(DS.Motion.appear)
      }
    }
    .padding(.top, DS.Space.xxs)
  }

  private func bottomAction(
    title: String,
    systemImage: String,
    identifier: String,
    accessibilityLabel: String,
    enabled: Bool,
    help: String,
    action: @escaping () -> Void
  ) -> some View {
    AXActionButton(
      title: title,
      systemImage: systemImage,
      identifier: identifier,
      accessibilityLabel: accessibilityLabel,
      enabled: enabled,
      highlighted: false,
      compact: false,
      row: true,
      action: action
    )
    .frame(height: BoardRailMetrics.rowHeight)
    .help(help)
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

  /// Room for a status word such as "Venter på deg" beside the light.
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

/// Behind-window vibrancy for the sidebar; opaque enough that the board never shows through.
struct SidebarVibrancy: NSViewRepresentable {
  func makeNSView(context: Context) -> NSVisualEffectView {
    let view = NSVisualEffectView()
    view.material = .sidebar
    view.blendingMode = .behindWindow
    view.state = .followsWindowActiveState
    return view
  }

  func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct ProviderPickerTarget: Identifiable { let id: UUID }
