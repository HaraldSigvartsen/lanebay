import AppKit
import Darwin
import LanebayUI

/// Drives Add console → Shell inside the running app, types a command, and records a missing-CLI error.
@MainActor
enum ConsoleFlowSelfTest {
  static func run(board: BoardViewModel, directory: URL) async {
    if LaunchIsolation.phase == "verify" {
      await verifyRestoredLayout(on: board, directory: directory)
      return
    }
    var notes: [String] = ["flow=console-echo"]
    let work = LaunchIsolation.root ?? FileManager.default.temporaryDirectory
    guard LaunchIsolation.root != nil else {
      notes.append("isolated=missing")
      await LaunchSnapshot.write(board: board, to: directory, notes: notes)
      return
    }
    board.settings.setDefaultWorkingDirectory(work)
    notes.append(contentsOf: await newTerminal(on: board, work: work, directory: directory))
    let shell = await startShell(on: board)
    notes.append(contentsOf: shell.notes)
    if let id = shell.id {
      notes.append(contentsOf: await reachRail(board: board, consoleID: id, directory: directory))
      notes.append(contentsOf: await typeEcho(board: board, consoleID: id))
      notes.append(contentsOf: await pasteEcho(board: board, consoleID: id))
      notes.append(contentsOf: await resizePty(board: board, consoleID: id))
      notes.append(contentsOf: await floodThenRecover(board: board, consoleID: id))
      notes.append(contentsOf: await restartShell(board: board, consoleID: id))
      notes.append(contentsOf: await observeStatusLights(board: board, consoleID: id, directory: directory))
      notes.append(contentsOf: await exerciseLoops(board: board, consoleID: id, directory: directory))
      notes.append(contentsOf: await exerciseCrew(board: board, leaderID: id, directory: directory))
    } else {
      notes.append("echo=no-console")
    }
    for agent in ["codex", "claude", "cursor-agent", "the-bins"] {
      notes.append(contentsOf: await missingOrSkip(agent, on: board))
    }
    var errorIndex = 0
    for node in board.workspace?.nodes ?? [] {
      if node.agentID == "shell" {
        board.moveNode(node.id, x: 24, y: 24)
      } else {
        board.moveNode(node.id, x: 540, y: 24 + Double(errorIndex) * 40)
        errorIndex += 1
      }
    }
    if let id = shell.id {
      notes.append(contentsOf: await observeExit(board: board, consoleID: id))
    }
    try? await Task.sleep(for: .milliseconds(200))
    await LaunchSnapshot.write(board: board, to: directory, notes: notes)
    if let id = shell.id {
      notes.append(contentsOf: await closeShell(board: board, consoleID: id))
      await LaunchSnapshot.write(board: board, to: directory, notes: notes, imageName: "closed.png")
    }
    notes.append(contentsOf: await orchestrate(on: board, directory: directory, prior: notes))
    notes.append(contentsOf: await openPanels(directory: directory))
    await LaunchSnapshot.write(
      board: board, to: directory, notes: notes, imageName: "panels-closed.png", probeAccessibility: false)
    if LaunchIsolation.phase == "arrange" {
      notes.append(contentsOf: await arrangeLayout(on: board, work: work, directory: directory))
      try? await Task.sleep(for: .milliseconds(250))
      await LaunchSnapshot.write(board: board, to: directory, notes: notes, imageName: "arranged.png")
    }
  }

  /// Two running shells with distinct folders, positions, and sizes. Quit persists them; the next process checks.
  private static func arrangeLayout(on board: BoardViewModel, work: URL, directory: URL) async -> [String] {
    var notes = ["phase=arrange"]
    let shellDir = work.appendingPathComponent("layout-shell", isDirectory: true)
    let otherDir = work.appendingPathComponent("layout-other", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: shellDir, withIntermediateDirectories: true)
      try FileManager.default.createDirectory(at: otherDir, withIntermediateDirectories: true)
    } catch {
      notes.append("arrange=mkdir-failed")
      return notes
    }
    let shell = board.createAndStartConsole(agentID: "shell", cwd: shellDir)
    let other = board.createAndStartConsole(agentID: "shell", cwd: otherDir)
    let running = await waitUntil(.seconds(8)) {
      board.sessions[shell]?.isRunning == true && board.sessions[other]?.isRunning == true
    }
    notes.append("arrangeRunning=\(running)")
    board.moveNode(shell, x: 40, y: 48)
    board.resizeNode(shell, width: 520, height: 280)
    board.moveNode(other, x: 40, y: 360)
    board.resizeNode(other, width: 440, height: 220)
    let layouts = layoutRecords(on: board)
    do {
      let data = try JSONEncoder().encode(layouts)
      try data.write(to: directory.appendingPathComponent("layout-expect.json"), options: .atomic)
      notes.append("expect=\(layouts.count)")
    } catch {
      notes.append("expect=encode-failed")
    }
    notes.append("arrangeShell=\(shell.uuidString)")
    notes.append("arrangeOther=\(other.uuidString)")
    return notes
  }

  /// After a real quit, the same consoles come back not started at the same place and start in the saved folder.
  private static func verifyRestoredLayout(on board: BoardViewModel, directory: URL) async {
    var notes = ["flow=layout-restore", "phase=verify"]
    let expectURL = directory.appendingPathComponent("layout-expect.json")
    guard let data = try? Data(contentsOf: expectURL),
      let expected = try? JSONDecoder().decode([LayoutRecord].self, from: data)
    else {
      notes.append("expect=missing")
      await LaunchSnapshot.write(board: board, to: directory, notes: notes, imageName: "restored.png")
      return
    }
    let actual = layoutRecords(on: board)
    let actualByID = Dictionary(uniqueKeysWithValues: actual.map { ($0.id, $0) })
    notes.append("restoredCount=\(actual.count)")
    notes.append("expectedCount=\(expected.count)")
    notes.append("sessions=\(board.sessions.count)")
    var matches = expected.count == actual.count && board.sessions.isEmpty
    for item in expected {
      guard let got = actualByID[item.id] else {
        matches = false
        notes.append("missing=\(item.id.uuidString)")
        continue
      }
      let node = board.workspace?.nodes.first { $0.id == item.id }
      let same = got == item && node?.notStarted == true
      if !same { matches = false }
      let folder = item.cwd.split(separator: "/").last.map(String.init) ?? item.id.uuidString
      notes.append("card.\(folder)=\(same)")
    }
    let consoles = (board.workspace?.nodes ?? []).filter { $0.kind == .console }
    let allNotStarted = !consoles.isEmpty && consoles.allSatisfy(\.notStarted)
    notes.append("allNotStarted=\(allNotStarted)")
    notes.append("layoutMatch=\(matches && allNotStarted)")
    try? await Task.sleep(for: .milliseconds(300))
    await LaunchSnapshot.write(board: board, to: directory, notes: notes, imageName: "restored.png")

    guard let target = expected.first(where: { $0.cwd.hasSuffix("/layout-shell") }) else {
      notes.append("start=no-target")
      await LaunchSnapshot.write(board: board, to: directory, notes: notes, imageName: "started.png")
      return
    }
    let startID = "console.start.\(target.id.uuidString)"
    let ax = await AccessibilityProbe.press(
      pid: getpid(), names: [startID, "Start Shell"], actions: [kAXPressAction as String])
    notes.append("pressStartAX=\(ax)")
    if board.sessions[target.id]?.isRunning != true,
      let content = LaunchSnapshot.boardWindow()?.contentView,
      let button = ControlFinder.button(identifier: startID, in: content) {
      button.performClick(nil)
      notes.append("pressStart=performClick")
    }
    let running = await waitUntil(.seconds(8)) { board.sessions[target.id]?.isRunning == true }
    notes.append("restoredRunning=\(running)")
    let launched = board.sessions[target.id]?.launchedWorkingDirectory ?? ""
    let wanted = URL(fileURLWithPath: target.cwd).standardizedFileURL.path
    notes.append("launchDirMatch=\(!launched.isEmpty && launched == wanted)")
    let othersQuiet = expected.filter { $0.id != target.id }.allSatisfy { board.sessions[$0.id]?.isRunning != true }
    notes.append("othersQuiet=\(othersQuiet)")
    if running {
      _ = board.writeToConsole("pwd\r", nodeID: target.id)
      let resolved = URL(fileURLWithPath: target.cwd).resolvingSymlinksInPath().path
      let saw = await waitUntil(.seconds(6)) {
        guard let text = board.recentConsoleOutput(target.id, maxBytes: 8_000) else { return false }
        return text.contains(resolved) || text.contains(wanted) || text.contains("layout-shell")
      }
      notes.append("pwdMatch=\(saw)")
    } else {
      notes.append("pwdMatch=false")
    }
    try? await Task.sleep(for: .milliseconds(200))
    await LaunchSnapshot.write(board: board, to: directory, notes: notes, imageName: "started.png")
  }

  private struct LayoutRecord: Codable, Equatable {
    var id: UUID
    var agentID: String
    var title: String
    var x: Double
    var y: Double
    var w: Double
    var h: Double
    var cwd: String
  }

  private static func layoutRecords(on board: BoardViewModel) -> [LayoutRecord] {
    (board.workspace?.nodes ?? []).filter { $0.kind == .console }.map { node in
      LayoutRecord(
        id: node.id,
        agentID: node.agentID ?? "",
        title: node.title,
        x: node.frame.x,
        y: node.frame.y,
        w: node.frame.w,
        h: node.frame.h,
        cwd: node.cwd.standardizedFileURL.path
      )
    }
  }

  /// Opens New terminal with Command-T, creates a shell with Return, then checks the next sheet remembers it.
  private static func newTerminal(on board: BoardViewModel, work: URL, directory: URL) async -> [String] {
    var notes: [String] = []
    NewTerminalShortcut.board = board
    let before = board.workspace?.nodes.count ?? 0
    guard let window = LaunchSnapshot.boardWindow() else {
      notes.append("newTerminal=no-window")
      return notes
    }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    if let event = keyEvent("t", type: .keyDown, keyCode: 17, modifiers: .command, window: window) {
      NSApp.sendEvent(event)
    }
    var opened = await waitUntil(.seconds(2)) {
      LaunchSnapshot.windowContaining(identifier: "newTerminal.create") != nil
    }
    notes.append("shortcut=\(opened)")
    if !opened {
      if let host = window.contentView,
        let button = ControlFinder.button(identifier: "toolbar.newTerminal", in: host) {
        button.performClick(nil)
        notes.append("pressNew=performClick")
      }
      opened = await waitUntil(.seconds(2)) {
        LaunchSnapshot.windowContaining(identifier: "newTerminal.create") != nil
      }
    }
    notes.append("sheet=\(opened)")
    guard opened else {
      notes.append("create=false")
      board.showingNewTerminal = false
      return notes
    }
    try? await Task.sleep(for: .milliseconds(200))
    guard let sheet = LaunchSnapshot.windowContaining(identifier: "newTerminal.create"),
      let content = sheet.contentView
    else {
      notes.append("create=false")
      board.showingNewTerminal = false
      return notes
    }
    sheet.layoutIfNeeded()
    content.layoutSubtreeIfNeeded()
    _ = await waitUntil(.seconds(1.5)) {
      guard let host = LaunchSnapshot.windowContaining(identifier: "newTerminal.create")?.contentView else { return false }
      return ControlFinder.buttons(in: host).contains {
        $0.accessibilityIdentifier().hasPrefix("newTerminal.directory.")
          && ($0.accessibilityValue() as? String) == "selected"
      }
    }
    guard let ready = LaunchSnapshot.windowContaining(identifier: "newTerminal.create"),
      let readyContent = ready.contentView
    else {
      notes.append("create=false")
      board.showingNewTerminal = false
      return notes
    }
    notes.append("snapshot=\(LaunchSnapshot.writeIdentifier("newTerminal.create", to: directory, imageName: "new-terminal.png"))")
    for agent in ["shell", "codex", "claude", "cursor-agent"] {
      let found = ControlFinder.button(identifier: "newTerminal.agent.\(agent)", in: readyContent) != nil
      notes.append("agent.\(agent)=\(found)")
    }
    notes.append("customEmpty=\(ControlFinder.view(identifier: "newTerminal.customEmpty", in: readyContent) != nil)")
    let shellSelected = ControlFinder.button(identifier: "newTerminal.agent.shell", in: readyContent)?.accessibilityValue() as? String == "selected"
    notes.append("defaultAgent=\(shellSelected ? "shell" : "other")")
    let selectedFolder = ControlFinder.buttons(in: readyContent).first {
      $0.accessibilityIdentifier().hasPrefix("newTerminal.directory.")
        && ($0.accessibilityValue() as? String) == "selected"
    }?.title ?? ""
    notes.append("folderSelected=\(!selectedFolder.isEmpty)")
    var createdByReturn = false
    if let event = keyEvent("\r", type: .keyDown, keyCode: 36, window: ready) {
      createdByReturn = ready.performKeyEquivalent(with: event)
      if !createdByReturn, let button = ControlFinder.button(identifier: "newTerminal.create", in: readyContent) {
        createdByReturn = button.performKeyEquivalent(with: event)
      }
      if !createdByReturn {
        NSApp.sendEvent(event)
        createdByReturn = true
        notes.append("return=sendEvent")
      }
    }
    let created = await waitUntil(.seconds(2)) { (board.workspace?.nodes.count ?? 0) > before }
    notes.append("create=\(created ? (createdByReturn ? "return" : "pending") : "false")")
    guard created, let node = board.workspace?.nodes.last else {
      board.showingNewTerminal = false
      return notes
    }
    let id = node.id
    let expected = URL(fileURLWithPath: selectedFolder).resolvingSymlinksInPath().path
    let actual = node.cwd.resolvingSymlinksInPath().path
    notes.append("cwdMatch=\(!selectedFolder.isEmpty && actual == expected)")
    notes.append("agentMatch=\(node.agentID == "shell")")
    _ = await waitUntil(.seconds(3)) { board.sessions[id]?.isRunning == true }
    await board.closeConsole(id)
    notes.append("closedFirst=\(board.workspace?.nodes.contains { $0.id == id } != true)")
    let other = work.appendingPathComponent("other-dir", isDirectory: true)
    try? FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
    board.settings.setDefaultWorkingDirectory(other)
    board.showingNewTerminal = false
    if let event = keyEvent("t", type: .keyDown, keyCode: 17, modifiers: .command, window: window) {
      NSApp.sendEvent(event)
    }
    var reopened = await waitUntil(.seconds(2)) {
      LaunchSnapshot.windowContaining(identifier: "newTerminal.create") != nil
    }
    if !reopened, let host = window.contentView,
      let button = ControlFinder.button(identifier: "toolbar.newTerminal", in: host) {
      button.performClick(nil)
      reopened = await waitUntil(.seconds(2)) {
        LaunchSnapshot.windowContaining(identifier: "newTerminal.create") != nil
      }
    }
    notes.append("reopened=\(reopened)")
    _ = await waitUntil(.seconds(1.5)) {
      guard let host = LaunchSnapshot.windowContaining(identifier: "newTerminal.create")?.contentView else { return false }
      return ControlFinder.button(identifier: "newTerminal.agent.shell", in: host)?.accessibilityValue() as? String == "selected"
    }
    if let again = LaunchSnapshot.windowContaining(identifier: "newTerminal.create")?.contentView {
      again.layoutSubtreeIfNeeded()
      let agent = ControlFinder.button(identifier: "newTerminal.agent.shell", in: again)?.accessibilityValue() as? String == "selected"
      let folder = ControlFinder.buttons(in: again).first {
        $0.accessibilityIdentifier().hasPrefix("newTerminal.directory.")
          && ($0.accessibilityValue() as? String) == "selected"
      }?.title ?? ""
      notes.append("rememberedAgent=\(agent)")
      let rememberedPath = URL(fileURLWithPath: folder).resolvingSymlinksInPath().path
      notes.append("rememberedFolder=\(!folder.isEmpty && rememberedPath == expected)")
      if let cancel = ControlFinder.button(identifier: "newTerminal.cancel", in: again) {
        cancel.performClick(nil)
      }
    } else {
      notes.append("rememberedAgent=false")
      notes.append("rememberedFolder=false")
    }
    _ = await waitUntil(.seconds(1)) { board.showingNewTerminal == false }
    board.showingNewTerminal = false
    board.settings.setDefaultWorkingDirectory(work)
    _ = await waitUntil(.seconds(2)) {
      board.showingNewTerminal == false && LaunchSnapshot.windowContaining(identifier: "newTerminal.create") == nil
    }
    try? await Task.sleep(for: .milliseconds(200))
    return notes
  }

  private static func waitUntil(_ timeout: Duration, _ check: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if check() { return true }
      try? await Task.sleep(for: .milliseconds(40))
    }
    return check()
  }

  private static func startShell(on board: BoardViewModel) async -> (id: UUID?, notes: [String]) {
    var notes = await clickAgent("shell", title: "Shell", on: board)
    let pressedShell = notes.contains("press.shell=true")
    notes.append("pressShell=\(pressedShell)")
    guard pressedShell, let id = board.workspace?.nodes.last(where: { $0.agentID == "shell" })?.id else {
      return (nil, notes)
    }
    let deadline = ContinuousClock.now + .seconds(8)
    var running = false
    while ContinuousClock.now < deadline {
      if board.sessions[id]?.isRunning == true {
        running = true
        break
      }
      if board.consoleLaunchErrors[id] != nil { break }
      try? await Task.sleep(for: .milliseconds(40))
    }
    notes.append("shellRunning=\(running)")
    return (id, notes)
  }

  private static func typeEcho(board: BoardViewModel, consoleID: UUID) async -> [String] {
    var notes: [String] = []
    var terminal: NSView?
    let appear = ContinuousClock.now + .seconds(4)
    while ContinuousClock.now < appear {
      if let window = LaunchSnapshot.boardWindow(), let content = window.contentView,
        let found = TerminalFinder.find(in: content) {
        terminal = found
        break
      }
      try? await Task.sleep(for: .milliseconds(40))
    }
    guard let terminal else {
      notes.append("terminal=missing")
      notes.append("echo=false")
      return notes
    }
    terminal.window?.makeFirstResponder(terminal)
    let mode = deliver("echo lanebay-ok", to: terminal)
    notes.append("typed=\(mode)")
    var saw = await waitForEcho(board: board, consoleID: consoleID, timeout: .seconds(2.5))
    if !saw {
      (terminal as? NSTextInputClient)?.insertText(
        "echo lanebay-ok\r", replacementRange: NSRange(location: NSNotFound, length: 0))
      notes.append("typedFallback=insertText")
      saw = await waitForEcho(board: board, consoleID: consoleID, timeout: .seconds(4))
    }
    notes.append("echo=\(saw)")
    return notes
  }

  private static func pasteEcho(board: BoardViewModel, consoleID: UUID) async -> [String] {
    var notes: [String] = []
    guard let window = LaunchSnapshot.boardWindow(), let content = window.contentView,
      let terminal = TerminalFinder.find(in: content)
    else {
      notes.append("paste=no-terminal")
      return notes
    }
    let pasteboard = NSPasteboard.general
    let previousString = pasteboard.string(forType: .string)
    let previousFileURL = pasteboard.string(forType: .fileURL)
    defer {
      pasteboard.clearContents()
      if let previousFileURL { pasteboard.setString(previousFileURL, forType: .fileURL) }
      if let previousString { pasteboard.setString(previousString, forType: .string) }
    }
    let token = "lanebay-paste-9f3"
    pasteboard.clearContents()
    pasteboard.setString("/bin/echo \(token)", forType: .string)
    window.makeKeyAndOrderFront(nil)
    window.makeFirstResponder(terminal)
    if let event = keyEvent("v", type: .keyDown, keyCode: 9, modifiers: .command, window: window) {
      NSApp.sendEvent(event)
      notes.append("pasteKey=sendEvent")
    } else {
      notes.append("pasteKey=no-event")
    }
    if let enter = keyEvent("\r", type: .keyDown, keyCode: 36, window: window) {
      terminal.keyDown(with: enter)
    }
    let saw = await waitForToken(token, board: board, consoleID: consoleID, timeout: .seconds(4))
    notes.append("paste=\(saw)")
    return notes
  }

  private static func waitForEcho(board: BoardViewModel, consoleID: UUID, timeout: Duration) async -> Bool {
    await waitForToken("lanebay-ok", board: board, consoleID: consoleID, timeout: timeout)
  }

  private static func waitForToken(
    _ token: String, board: BoardViewModel, consoleID: UUID, timeout: Duration
  ) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if board.recentConsoleOutput(consoleID)?.contains(token) == true { return true }
      try? await Task.sleep(for: .milliseconds(40))
    }
    return false
  }

  private static func deliver(_ line: String, to view: NSView) -> String {
    for character in line {
      guard let down = keyEvent(String(character), type: .keyDown, window: view.window) else { continue }
      view.keyDown(with: down)
      if let up = keyEvent(String(character), type: .keyUp, window: view.window) {
        view.keyUp(with: up)
      }
    }
    if let enter = keyEvent("\r", type: .keyDown, keyCode: 36, window: view.window) {
      view.keyDown(with: enter)
    }
    return "keydown"
  }

  private static func keyEvent(
    _ characters: String, type: NSEvent.EventType, keyCode: UInt16 = 0,
    modifiers: NSEvent.ModifierFlags = [], window: NSWindow?
  ) -> NSEvent? {
    NSEvent.keyEvent(
      with: type,
      location: .zero,
      modifierFlags: modifiers,
      timestamp: ProcessInfo.processInfo.systemUptime,
      windowNumber: window?.windowNumber ?? 0,
      context: nil,
      characters: characters,
      charactersIgnoringModifiers: characters,
      isARepeat: false,
      keyCode: keyCode)
  }

  /// At an 800×800 window the pinned rail actions stay on screen, and each one opens its UI.
  private static func reachRail(board: BoardViewModel, consoleID: UUID, directory: URL) async -> [String] {
    var notes: [String] = []
    guard let window = LaunchSnapshot.boardWindow(), let content = window.contentView else {
      notes.append("rail800=no-window")
      return notes
    }
    window.setContentSize(NSSize(width: 800, height: 800))
    window.makeKeyAndOrderFront(nil)
    window.layoutIfNeeded()
    content.layoutSubtreeIfNeeded()
    try? await Task.sleep(for: .milliseconds(350))
    notes.append("rail800.add=\(await waitPlacement("rail.addConsole", in: content))")
    notes.append("rail800.group=\(await waitPlacement("rail.createGroup", in: content))")
    notes.append("rail800.manage=\(await waitPlacement("rail.manageGroups", in: content))")
    let tops = (board.workspace?.nodes ?? []).filter { $0.kind == .console }.map {
      $0.frame.y * board.zoom + board.panY
    }
    if let minTop = tops.min() {
      notes.append(String(format: "rail800.minScreenY=%.1f", minTop))
      notes.append("rail800.headersInside=\(minTop >= -0.5)")
    }
    await LaunchSnapshot.write(
      board: board, to: directory, notes: notes, imageName: "rail.png",
      contentSize: NSSize(width: 800, height: 800))

    let add = await pressIdentifier("rail.addConsole", names: ["rail.addConsole", "Add console"])
    notes.append("pressAdd800=\(add)")
    let pickerDeadline = ContinuousClock.now + .seconds(2)
    var pickerOpen = false
    while ContinuousClock.now < pickerDeadline {
      if pickerVisible() { pickerOpen = true; break }
      try? await Task.sleep(for: .milliseconds(40))
    }
    notes.append("picker800=\(pickerOpen)")
    if pickerOpen {
      _ = await pressIdentifier("rail.addConsole", names: ["rail.addConsole", "Add console"])
      try? await Task.sleep(for: .milliseconds(200))
    }

    board.select(consoleID)
    notes.append("groupEnabled=\(await waitEnabled("rail.createGroup"))")
    let groupPress = await pressIdentifier("rail.createGroup", names: ["rail.createGroup", "Create group"])
    notes.append("pressGroup=\(groupPress)")
    let created = await confirmCreateGroup(on: window, board: board)
    notes.append(contentsOf: created)

    if board.workspace?.groups.isEmpty == false {
      notes.append("manageEnabled=\(await waitEnabled("rail.manageGroups"))")
      let managePress = await pressIdentifier(
        "rail.manageGroups", names: ["rail.manageGroups", "Manage groups"])
      notes.append("pressManage=\(managePress)")
      let appeared = ContinuousClock.now + .seconds(2)
      while !manageSheetVisible() && ContinuousClock.now < appeared {
        try? await Task.sleep(for: .milliseconds(40))
      }
      // An accessibility walk of this sheet updates its body off the main actor and traps.
      notes.append("manageSheet=\(manageSheetVisible())")
      if let sheetWindow = NSApp.windows.first(where: { candidate in
        guard let root = candidate.contentView else { return false }
        return ControlFinder.view(identifier: "groups.manage", in: root) != nil
      }) {
        sheetWindow.makeKeyAndOrderFront(nil)
        LaunchSnapshot.writeWindow(sheetWindow, to: directory.appendingPathComponent("groups-sheet.png"))
        notes.append("groupsSheet=\(Int(sheetWindow.frame.width))x\(Int(sheetWindow.frame.height))")
      }
      await LaunchSnapshot.write(
        board: board, to: directory, notes: notes, imageName: "groups.png",
        contentSize: NSSize(width: 800, height: 800), probeAccessibility: false)
      dismissManage()
      board.dismissPresentedChrome()
      let closed = ContinuousClock.now + .seconds(2)
      while manageSheetVisible() && ContinuousClock.now < closed {
        try? await Task.sleep(for: .milliseconds(40))
      }
      if manageSheetVisible() {
        for window in NSApp.windows where window != LaunchSnapshot.boardWindow() {
          guard let root = window.contentView,
            ControlFinder.view(identifier: "groups.manage", in: root) != nil
          else { continue }
          window.orderOut(nil)
          window.close()
        }
      }
      notes.append("manageClosed=\(!manageSheetVisible())")
    } else {
      notes.append("pressManage=skipped")
      notes.append("manageSheet=false")
    }

    window.setContentSize(NSSize(width: 1200, height: 800))
    window.layoutIfNeeded()
    board.select(consoleID)
    return notes
  }

  private static func waitPlacement(_ identifier: String, in content: NSView) async -> String {
    let deadline = ContinuousClock.now + .seconds(2)
    var last = "missing"
    while ContinuousClock.now < deadline {
      content.layoutSubtreeIfNeeded()
      last = placement(identifier, in: content)
      if last == "inside" || last == "outside" { return last }
      try? await Task.sleep(for: .milliseconds(40))
    }
    return last
  }

  private static func placement(_ identifier: String, in content: NSView) -> String {
    guard let button = ControlFinder.button(identifier: identifier, in: content) else { return "missing" }
    let frame = button.convert(button.bounds, to: content)
    guard frame.width > 1, frame.height > 1 else { return "empty" }
    let center = CGPoint(x: frame.midX, y: frame.midY)
    return content.bounds.contains(center) ? "inside" : "outside"
  }

  private static func waitEnabled(_ identifier: String) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < deadline {
      if let content = LaunchSnapshot.boardWindow()?.contentView,
        let button = ControlFinder.button(identifier: identifier, in: content), button.isEnabled {
        return true
      }
      try? await Task.sleep(for: .milliseconds(40))
    }
    return false
  }

  /// One click. An accessibility press can schedule the action and still return failure, and a second click would toggle it shut.
  private static func pressIdentifier(_ identifier: String, names: [String]) async -> String {
    if let content = LaunchSnapshot.boardWindow()?.contentView,
      let button = ControlFinder.button(identifier: identifier, in: content), button.isEnabled {
      button.performClick(nil)
      return "performClick"
    }
    if await AccessibilityProbe.press(pid: getpid(), names: names, actions: [kAXPressAction as String]) {
      return "ax"
    }
    return "failed"
  }

  private static func confirmCreateGroup(on window: NSWindow, board: BoardViewModel) async -> [String] {
    var notes: [String] = []
    let deadline = ContinuousClock.now + .seconds(2)
    var sheet: NSWindow?
    while ContinuousClock.now < deadline {
      sheet = window.attachedSheet ?? window.sheets.first
      if sheet != nil { break }
      try? await Task.sleep(for: .milliseconds(40))
    }
    guard let sheet, let sheetContent = sheet.contentView else {
      notes.append("groupAlert=missing")
      let titles = NSApp.windows.map(\.title).filter { !$0.isEmpty }
      notes.append("windowTitles=\(titles.prefix(6).joined(separator: "|"))")
      return notes
    }
    notes.append("groupAlert=sheet")
    notes.append("sheetButtons=\(ControlFinder.buttonTitles(in: sheetContent).prefix(8).joined(separator: "|"))")
    notes.append("groupName=\(fillGroupName("Lane", in: sheet))")
    try? await Task.sleep(for: .milliseconds(80))
    let before = board.workspace?.groups.count ?? 0
    if let button = ControlFinder.button(title: "Create", in: sheetContent) {
      button.performClick(nil)
      notes.append("groupCreate=performClick")
    } else if let cell = sheet.defaultButtonCell, let button = cell.controlView as? NSButton {
      button.performClick(nil)
      notes.append("groupCreate=default")
    } else if await AccessibilityProbe.press(pid: getpid(), names: ["Create"], actions: [kAXPressAction as String]) {
      notes.append("groupCreate=ax")
    } else {
      notes.append("groupCreate=missing")
    }
    let createdDeadline = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < createdDeadline {
      if (board.workspace?.groups.count ?? 0) > before { break }
      try? await Task.sleep(for: .milliseconds(40))
    }
    notes.append("groupCreated=\((board.workspace?.groups.count ?? 0) > before)")
    return notes
  }

  private static func fillGroupName(_ name: String, in sheet: NSWindow) -> String {
    guard let content = sheet.contentView, let field = ControlFinder.textField(in: content) else { return "missing" }
    sheet.makeFirstResponder(field)
    if let editor = sheet.firstResponder as? NSTextView {
      let range = NSRange(location: 0, length: editor.string.utf16.count)
      editor.insertText(name, replacementRange: range)
      return "insertText"
    }
    field.stringValue = name
    NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: field)
    return "stringValue"
  }

  private static func pickerVisible() -> Bool {
    for window in NSApp.windows {
      guard let root = window.contentView else { continue }
      if ControlFinder.button(identifier: "agent.shell", in: root) != nil { return true }
      if ControlFinder.view(identifier: "agent.picker", in: root) != nil { return true }
    }
    return false
  }

  private static func manageSheetVisible() -> Bool {
    for window in NSApp.windows where window.isVisible {
      guard let root = window.contentView else { continue }
      if ControlFinder.view(identifier: "groups.manage", in: root) != nil { return true }
    }
    return false
  }

  private static func dismissManage() {
    for window in NSApp.windows {
      let roots = [window.contentView].compactMap { $0 } + window.sheets.compactMap(\.contentView)
      for root in roots {
        guard ControlFinder.view(identifier: "groups.manage", in: root) != nil else { continue }
        if let cancel = ControlFinder.button(title: "Cancel", in: root)
          ?? ControlFinder.button(title: "Avbryt", in: root) {
          cancel.performClick(nil)
          return
        }
      }
    }
    for window in NSApp.windows where window.isSheet {
      guard let root = window.contentView,
        ControlFinder.view(identifier: "groups.manage", in: root) != nil,
        let parent = window.sheetParent
      else { continue }
      parent.endSheet(window)
      return
    }
    for window in NSApp.windows where window != LaunchSnapshot.boardWindow() {
      guard let root = window.contentView,
        ControlFinder.view(identifier: "groups.manage", in: root) != nil
      else { continue }
      window.close()
      return
    }
    guard let window = LaunchSnapshot.boardWindow(),
      let event = keyEvent("\u{1b}", type: .keyDown, keyCode: 53, window: window)
    else { return }
    NSApp.sendEvent(event)
  }

  /// Grows the shell card and checks `stty size` follows the terminal grid.
  private static func resizePty(board: BoardViewModel, consoleID: UUID) async -> [String] {
    var notes: [String] = []
    guard let before = await readSize(previous: nil, board: board, consoleID: consoleID) else {
      notes.append("sttyBefore=missing")
      notes.append("sttyChanged=false")
      return notes
    }
    notes.append("sttyBefore=\(before.rows) \(before.cols)")
    let startWidth = board.workspace?.nodes.first { $0.id == consoleID }?.frame.w ?? 0
    var usedAX = true
    for _ in 0..<4 {
      let pressed = await AccessibilityProbe.adjust(
        pid: getpid(), names: ["console.resize.Shell", "Resize Shell"], increment: true)
      if !pressed { usedAX = false; break }
      try? await Task.sleep(for: .milliseconds(80))
    }
    let widthNow = board.workspace?.nodes.first { $0.id == consoleID }?.frame.w ?? startWidth
    if !usedAX || widthNow < startWidth + 60 {
      usedAX = false
      board.resizeNode(consoleID, width: startWidth + 220, height: (board.workspace?.nodes.first { $0.id == consoleID }?.frame.h ?? 320) + 160)
    }
    notes.append("resizeAX=\(usedAX)")
    LaunchSnapshot.boardWindow()?.contentView?.layoutSubtreeIfNeeded()
    let gridDeadline = ContinuousClock.now + .seconds(2)
    var grid = board.consoleGrid(for: consoleID)
    while ContinuousClock.now < gridDeadline {
      grid = board.consoleGrid(for: consoleID)
      if let grid, grid.columns != before.cols || grid.rows != before.rows { break }
      try? await Task.sleep(for: .milliseconds(40))
    }
    if let grid { notes.append("grid=\(grid.rows) \(grid.columns)") }
    let ptyDeadline = ContinuousClock.now + .seconds(3)
    var pty = await board.consolePtyWindow(for: consoleID)
    while ContinuousClock.now < ptyDeadline {
      pty = await board.consolePtyWindow(for: consoleID)
      if let pty, let grid, pty.columns == grid.columns, pty.rows == grid.rows,
        pty.columns != before.cols || pty.rows != before.rows {
        break
      }
      try? await Task.sleep(for: .milliseconds(40))
    }
    if let pty { notes.append("ptyAfter=\(pty.rows) \(pty.columns)") }
    let changed = pty.map { $0.columns != before.cols || $0.rows != before.rows } ?? false
    let matches = pty.flatMap { size in grid.map { $0.columns == size.columns && $0.rows == size.rows } } ?? false
    notes.append("sttyChanged=\(changed)")
    notes.append("sttyMatch=\(matches)")
    return notes
  }

  /// `yes | head` must leave the shell running and the main thread able to take input.
  private static func floodThenRecover(board: BoardViewModel, consoleID: UUID) async -> [String] {
    var notes: [String] = []
    let gate = FloodObservation()
    let sampler = Task.detached { () -> Int in
      var worstMs = 0
      let deadline = ContinuousClock.now + .seconds(12)
      while ContinuousClock.now < deadline {
        let start = ContinuousClock.now
        let stop = await gate.stop
        let gapMs = Int(start.duration(to: .now) / .milliseconds(1))
        if gapMs > worstMs { worstMs = gapMs }
        if stop { break }
        try? await Task.sleep(for: .milliseconds(12))
      }
      return worstMs
    }
    // The marker is assembled in the shell so the typed command is not mistaken for completion.
    let sent = board.writeToConsole(
      "token=$(printf 'LANEBAY-FLOOD-%s' DONE); /usr/bin/yes | /usr/bin/head -n 200000; /bin/echo \"$token\"\r",
      nodeID: consoleID)
    notes.append("floodSent=\(sent)")
    let done = await waitForToken("LANEBAY-FLOOD-DONE", board: board, consoleID: consoleID, timeout: .seconds(10))
    notes.append("floodDone=\(done)")
    let session = board.sessions[consoleID]
    let alive = session?.isRunning == true && session?.failureMessage == nil && session?.hasFinished != true
    notes.append("floodAlive=\(alive)")
    _ = board.writeToConsole("echo lanebay-after-flood\r", nodeID: consoleID)
    let echoed = await waitForToken("lanebay-after-flood", board: board, consoleID: consoleID, timeout: .seconds(8))
    notes.append("floodEcho=\(echoed)")
    gate.finish()
    let worstMs = await sampler.value
    notes.append("floodPingMs=\(worstMs)")
    notes.append("floodResponsive=\(worstMs < 400)")
    return notes
  }

  /// Presses the card's Restart button and checks the old process is gone and a new shell answers.
  private static func restartShell(board: BoardViewModel, consoleID: UUID) async -> [String] {
    var notes: [String] = []
    guard let oldPID = await publishPID(board: board, consoleID: consoleID) else {
      notes.append("restartPid=missing")
      notes.append("pressRestartAX=false")
      notes.append("restartRunning=false")
      notes.append("oldPidDead=false")
      notes.append("restartEcho=false")
      return notes
    }
    notes.append("restartPid=\(oldPID)")
    let oldSession = board.sessions[consoleID]?.sessionID
    let ax = await AccessibilityProbe.press(
      pid: getpid(),
      names: [ConsoleCardControl.restartIdentifier(consoleID), "Restart Shell"],
      actions: [kAXPressAction as String]
    )
    notes.append("pressRestartAX=\(ax)")
    let runningDeadline = ContinuousClock.now + .seconds(8)
    var running = false
    while ContinuousClock.now < runningDeadline {
      let session = board.sessions[consoleID]
      if session?.isRunning == true, let sessionID = session?.sessionID, sessionID != oldSession {
        running = true
        break
      }
      try? await Task.sleep(for: .milliseconds(40))
    }
    let dead = processIsGone(oldPID)
    notes.append("restartRunning=\(running)")
    notes.append("oldPidDead=\(dead)")
    guard running else {
      notes.append("restartEcho=false")
      return notes
    }
    _ = board.writeToConsole("echo lanebay-restarted\r", nodeID: consoleID)
    let saw = await waitForToken("lanebay-restarted", board: board, consoleID: consoleID, timeout: .seconds(6))
    notes.append("restartEcho=\(saw)")
    return notes
  }

  /// Presses Close and checks the card and its process are both gone.
  private static func closeShell(board: BoardViewModel, consoleID: UUID) async -> [String] {
    var notes: [String] = []
    let pid = await publishPID(board: board, consoleID: consoleID)
    if let pid { notes.append("closePid=\(pid)") } else { notes.append("closePid=missing") }
    let ax = await AccessibilityProbe.press(
      pid: getpid(),
      names: [ConsoleCardControl.closeIdentifier(consoleID), "Close Shell"],
      actions: [kAXPressAction as String]
    )
    notes.append("pressCloseAX=\(ax)")
    let goneDeadline = ContinuousClock.now + .seconds(2)
    var gone = board.workspace?.nodes.contains(where: { $0.id == consoleID }) != true
    while !gone, ContinuousClock.now < goneDeadline {
      gone = board.workspace?.nodes.contains(where: { $0.id == consoleID }) != true
      if gone { break }
      try? await Task.sleep(for: .milliseconds(40))
    }
    notes.append("closeGone=\(gone)")
    var dead = pid == nil
    if let pid {
      let deadDeadline = ContinuousClock.now + .seconds(4)
      while ContinuousClock.now < deadDeadline {
        if processIsGone(pid) { dead = true; break }
        try? await Task.sleep(for: .milliseconds(40))
      }
    }
    notes.append("closePidDead=\(dead)")
    return notes
  }

  private static func publishPID(board: BoardViewModel, consoleID: UUID) async -> pid_t? {
    guard board.sessions[consoleID]?.isRunning == true else { return nil }
    guard board.writeToConsole("printf 'LANEBAY-PID:%s\\n' $$\r", nodeID: consoleID) else { return nil }
    let deadline = ContinuousClock.now + .seconds(6)
    while ContinuousClock.now < deadline {
      if let text = board.recentConsoleOutput(consoleID, maxBytes: 8_000), let pid = latestPID(in: text), pid > 1 {
        return pid
      }
      try? await Task.sleep(for: .milliseconds(40))
    }
    return nil
  }

  private static func latestPID(in text: String) -> pid_t? {
    let marker = "LANEBAY-PID:"
    var found: pid_t?
    var search = text.startIndex
    while let range = text.range(of: marker, range: search..<text.endIndex) {
      var index = range.upperBound
      var value: Int32 = 0
      var digits = 0
      while index < text.endIndex, let digit = text[index].wholeNumberValue {
        value = value * 10 + Int32(digit)
        digits += 1
        index = text.index(after: index)
        if digits > 8 { value = 0; break }
      }
      if digits > 0, value > 1 { found = value }
      search = range.upperBound
    }
    return found
  }

  private static func processIsGone(_ pid: pid_t) -> Bool {
    guard pid > 1 else { return false }
    return kill(pid, 0) == -1 && errno == ESRCH
  }

  private static func readSize(
    previous: (rows: Int, cols: Int)?, board: BoardViewModel, consoleID: UUID
  ) async -> (rows: Int, cols: Int)? {
    guard board.writeToConsole("printf 'SZ%s\\n' \"$(/bin/stty size)\"\r", nodeID: consoleID) else { return nil }
    let deadline = ContinuousClock.now + .seconds(8)
    while ContinuousClock.now < deadline {
      if let text = board.recentConsoleOutput(consoleID, maxBytes: 16_000),
        let size = lastIntegerPair(in: text) {
        if let previous, size == previous { continue }
        return size
      }
      try? await Task.sleep(for: .milliseconds(50))
    }
    return nil
  }

  private static func lastIntegerPair(in text: String) -> (rows: Int, cols: Int)? {
    var found: (rows: Int, cols: Int)?
    let chars = Array(text)
    var index = 0
    while index < chars.count {
      if chars[index].isNumber, index == 0 || !chars[index - 1].isNumber {
        var rows = 0
        while index < chars.count, chars[index].isNumber {
          rows = rows * 10 + (chars[index].wholeNumberValue ?? 0)
          index += 1
        }
        if index < chars.count, chars[index] == " ", index + 1 < chars.count, chars[index + 1].isNumber {
          index += 1
          var cols = 0
          while index < chars.count, chars[index].isNumber {
            cols = cols * 10 + (chars[index].wholeNumberValue ?? 0)
            index += 1
          }
          if index >= chars.count || !chars[index].isNumber, (1...500).contains(rows), (1...500).contains(cols) {
            found = (rows, cols)
          }
          continue
        }
      }
      index += 1
    }
    return found
  }

  /// Waits until a quiet prompt is idle, then a `read` prompt is waiting for input, and answers it.
  private static func observeStatusLights(
    board: BoardViewModel, consoleID: UUID, directory: URL
  ) async -> [String] {
    var notes: [String] = []
    let idle = await waitStatus(.idle, board: board, consoleID: consoleID, timeout: .seconds(6))
    notes.append("statusIdle=\(statusLabel(board: board, consoleID: consoleID))")
    notes.append("statusIdleOK=\(idle)")
    if let tail = board.recentConsoleOutput(consoleID, maxBytes: 240) {
      notes.append("statusTail=\(sanitizedTail(tail))")
    }
    await LaunchSnapshot.write(board: board, to: directory, notes: notes, imageName: "idle.png")
    guard board.writeToConsole("printf 'Enter value: '; read -r reply\r", nodeID: consoleID) else {
      notes.append("statusWait=not-running")
      notes.append("statusWaitOK=false")
      return notes
    }
    let waiting = await waitStatus(.waitingForInput, board: board, consoleID: consoleID, timeout: .seconds(4))
    notes.append("statusWait=\(statusLabel(board: board, consoleID: consoleID))")
    notes.append("statusWaitOK=\(waiting)")
    await LaunchSnapshot.write(board: board, to: directory, notes: notes, imageName: "waiting.png")
    _ = board.writeToConsole("ok\r", nodeID: consoleID)
    _ = await waitStatus(.idle, board: board, consoleID: consoleID, timeout: .seconds(6))
    return notes
  }

  /// Exits the shell and checks the light keeps the code after trailing output.
  private static func observeExit(board: BoardViewModel, consoleID: UUID) async -> [String] {
    var notes: [String] = []
    guard board.sessions[consoleID]?.isRunning == true,
      board.writeToConsole("echo bye; exit 3\r", nodeID: consoleID)
    else {
      notes.append("statusExit=\(statusLabel(board: board, consoleID: consoleID))")
      notes.append("statusExitOK=false")
      return notes
    }
    let deadline = ContinuousClock.now + .seconds(6)
    var ok = false
    while ContinuousClock.now < deadline {
      if board.sessions[consoleID]?.exitCode == 3, board.sessions[consoleID]?.status == .error {
        ok = true
        break
      }
      try? await Task.sleep(for: .milliseconds(40))
    }
    notes.append("statusExit=\(statusLabel(board: board, consoleID: consoleID))")
    notes.append("statusExitCode=\(board.sessions[consoleID]?.exitCode.map(String.init) ?? "nil")")
    notes.append("statusExitOK=\(ok)")
    try? await Task.sleep(for: .seconds(2.2))
    let stayed = board.sessions[consoleID]?.status == .error && board.sessions[consoleID]?.exitCode == 3
    notes.append("statusExitStayed=\(stayed)")
    return notes
  }

  private static func waitStatus(
    _ wanted: AgentStatus, board: BoardViewModel, consoleID: UUID, timeout: Duration
  ) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if board.sessions[consoleID]?.status == wanted { return true }
      try? await Task.sleep(for: .milliseconds(50))
    }
    return board.sessions[consoleID]?.status == wanted
  }

  private static func statusLabel(board: BoardViewModel, consoleID: UUID) -> String {
    guard let session = board.sessions[consoleID] else { return "nil" }
    return session.status.label(exitCode: session.exitCode)
  }

  /// Last visible characters of a prompt, with controls removed, so a report can show why a light stayed Working.
  private static func sanitizedTail(_ text: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " $%#>❯›➜▶→»λ❱_./-"))
    let scalars = text.unicodeScalars.suffix(48).map { scalar -> Character in
      allowed.contains(scalar) ? Character(scalar) : "·"
    }
    return String(scalars)
  }

  /// Clicks a catalog row. Installed non-shell agents are left alone so the test never starts the user's CLIs.
  private static func missingOrSkip(_ agent: String, on board: BoardViewModel) async -> [String] {
    let installed = board.installedLaunchExecutable(agentID: agent)
    if installed {
      return ["\(agent)=installed-not-clicked"]
    }
    var notes = await clickAgent(agent, title: title(for: agent), on: board)
    guard notes.contains("press.\(agent)=true"),
      let id = board.workspace?.nodes.last(where: { $0.agentID == agent })?.id
    else {
      notes.append("\(agent)Spawned=false")
      notes.append("\(agent)Error=none")
      return notes
    }
    let deadline = ContinuousClock.now + .seconds(2)
    while board.consoleLaunchErrors[id] == nil && ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(20))
    }
    let spawned = board.sessions[id] != nil
    if spawned { await board.closeConsole(id) }
    notes.append("\(agent)Spawned=\(spawned)")
    notes.append("\(agent)Error=\(board.consoleLaunchErrors[id] == nil ? "none" : "set")")
    return notes
  }

  private static func clickAgent(_ agent: String, title: String, on board: BoardViewModel) async -> [String] {
    var notes: [String] = []
    let before = board.workspace?.nodes.filter { $0.agentID == agent }.count ?? 0
    let pressedAdd = await AccessibilityProbe.press(
      pid: getpid(), names: ["rail.addConsole"], actions: [kAXPressAction as String])
    notes.append("pressAdd=\(pressedAdd)")
    try? await Task.sleep(for: .milliseconds(250))
    var pressed = false
    let names = [AgentPickerCatalog.accessibilityIdentifier(agentID: agent), title]
    let deadline = ContinuousClock.now + .seconds(3)
    while ContinuousClock.now < deadline {
      if (board.workspace?.nodes.filter { $0.agentID == agent }.count ?? 0) > before {
        pressed = true
        break
      }
      if await AccessibilityProbe.press(pid: getpid(), names: names, actions: [kAXPressAction as String]) {
        pressed = true
      }
      try? await Task.sleep(for: .milliseconds(80))
    }
    let created = (board.workspace?.nodes.filter { $0.agentID == agent }.count ?? 0) > before
    notes.append("press.\(agent)=\(pressed && created)")
    if !pressed || !created {
      let visible = await AccessibilityProbe.names(pid: getpid())
      let menu = visible.filter { $0.contains(title) || $0.hasPrefix("agent.") }
      notes.append("menuNames=\(menu.prefix(16).joined(separator: "|"))")
    }
    return notes
  }

  /// Opens every rail panel at 800pt, including the ones that start below the fold.
  private static func openPanels(directory: URL) async -> [String] {
    var notes = ["flow=panels"]
    guard let window = LaunchSnapshot.boardWindow(), let content = window.contentView else {
      notes.append("panels=no-window")
      return notes
    }
    window.setContentSize(NSSize(width: 800, height: 800))
    window.makeKeyAndOrderFront(nil)
    window.layoutIfNeeded()
    content.layoutSubtreeIfNeeded()
    try? await Task.sleep(for: .milliseconds(200))
    var opened: [String] = []
    var exclusive = true
    for panel in BoardSidePanel.railOrder {
      content.layoutSubtreeIfNeeded()
      guard let button = ControlFinder.button(identifier: panel.railIdentifier, in: content) else {
        notes.append("panel.\(panel.rawValue)=missing-button")
        continue
      }
      let before = placement(panel.railIdentifier, in: content)
      button.scrollToVisible(button.bounds)
      if let scroll = button.enclosingScrollView {
        let rect = button.convert(button.bounds, to: scroll.contentView)
        scroll.contentView.scrollToVisible(rect)
      }
      window.layoutIfNeeded()
      content.layoutSubtreeIfNeeded()
      let after = placement(panel.railIdentifier, in: content)
      notes.append("panel.\(panel.rawValue).scroll=\(before)->\(after)")
      button.performClick(nil)
      let shown = await waitMarker(panel.hostIdentifier)
      let hosts = Set(markerIdentifiers(prefix: "panel.host.", in: content))
      if !shown || hosts != [panel.hostIdentifier] { exclusive = false }
      notes.append("panel.\(panel.rawValue)=\(shown)")
      notes.append("panel.\(panel.rawValue).hosts=\(hosts.sorted().joined(separator: "|"))")
      if shown { opened.append(panel.rawValue) }
      if panel == .settings {
        let toggle = await waitMarker("settings.askBeforeSending")
        notes.append("settingsToggle=\(toggle)")
        LaunchSnapshot.writeWindow(window, to: directory.appendingPathComponent("panel-settings.png"))
      } else if panel == .docs {
        LaunchSnapshot.writeWindow(window, to: directory.appendingPathComponent("panel-docs.png"))
      } else if panel == .markdown {
        let textWidth = button.attributedTitle.size().width
        let boxWidth = (button.cell as? NSButtonCell)?.titleRect(forBounds: button.bounds).width ?? 0
        notes.append("markdownTitle=\(button.title)")
        notes.append(String(format: "markdownText=%.1f", textWidth))
        notes.append(String(format: "markdownBox=%.1f", boxWidth))
        notes.append("markdownFits=\(BoardRailMetrics.captionFits(button) && button.title == "Markdown")")
        LaunchSnapshot.writeWindow(window, to: directory.appendingPathComponent("panel-markdown.png"))
      } else if panel == .planner {
        LaunchSnapshot.writeWindow(window, to: directory.appendingPathComponent("panel-planner.png"))
      }
    }
    notes.append("panelsOpened=\(opened.joined(separator: ","))")
    notes.append("panelsExclusive=\(exclusive)")
    if let boardButton = ControlFinder.button(identifier: "rail.panel.board", in: content) {
      boardButton.scrollToVisible(boardButton.bounds)
      boardButton.performClick(nil)
    }
    let closed = await waitUntil(.seconds(2)) {
      guard let content = LaunchSnapshot.boardWindow()?.contentView else { return false }
      return markerIdentifiers(prefix: "panel.host.", in: content).isEmpty
    }
    notes.append("panelsClosed=\(closed)")
    return notes
  }

  private static func waitMarker(_ identifier: String) async -> Bool {
    await waitUntil(.seconds(2)) {
      guard let content = LaunchSnapshot.boardWindow()?.contentView else { return false }
      return ControlFinder.view(identifier: identifier, in: content) != nil
    }
  }

  private static func markerIdentifiers(prefix: String, in view: NSView) -> [String] {
    var found: [String] = []
    let identifier = view.accessibilityIdentifier()
    if identifier.hasPrefix(prefix) {
      found.append(identifier)
    }
    for child in view.subviews {
      found.append(contentsOf: markerIdentifiers(prefix: prefix, in: child))
    }
    return found
  }

  /// Orchestrator asks, then a shell runs `echo sub-ok`, then the orchestrator reports it.
  private static func orchestrate(on board: BoardViewModel, directory: URL, prior: [String]) async -> [String] {
    var notes = ["flow=orchestrator"]
    let shellsBefore = Set((board.workspace?.nodes ?? []).filter { $0.agentID == "shell" }.map(\.id))
    let orchestratorsBefore = Set((board.workspace?.nodes ?? []).filter { $0.agentID == "orchestrator" }.map(\.id))
    notes.append(contentsOf: await clickAgent("shell", title: "Shell", on: board))
    notes.append(contentsOf: await clickAgent("orchestrator", title: "Orchestrator", on: board))
    let shell = (board.workspace?.nodes ?? []).last { $0.agentID == "shell" && !shellsBefore.contains($0.id) }?.id
    var orchestrator = (board.workspace?.nodes ?? []).last {
      $0.agentID == "orchestrator" && !orchestratorsBefore.contains($0.id)
    }?.id
    if orchestrator == nil {
      orchestrator = board.createAndStartConsole(agentID: "orchestrator")
      notes.append("orchestrator=fallback-create")
    }
    guard let shell, let orchestrator else {
      notes.append("asked=false")
      notes.append("reported=false")
      await LaunchSnapshot.write(board: board, to: directory, notes: prior + notes, imageName: "orchestrator.png")
      return notes
    }
    let shellUp = await waitUntil(.seconds(8)) { board.sessions[shell]?.isRunning == true }
    let orchestratorUp = await waitUntil(.seconds(4)) {
      board.orchestratorTranscripts[orchestrator]?.contains("Orchestrator ready") == true
    }
    notes.append("shellUp=\(shellUp)")
    notes.append("orchestratorUp=\(orchestratorUp)")
    board.moveNode(shell, x: 24, y: 28)
    board.resizeNode(shell, width: 420, height: 300)
    board.moveNode(orchestrator, x: 640, y: 28)
    board.resizeNode(orchestrator, width: 460, height: 340)
    guard shellUp, orchestratorUp else {
      notes.append("asked=false")
      notes.append("reported=false")
      await LaunchSnapshot.write(board: board, to: directory, notes: prior + notes, imageName: "orchestrator.png")
      await board.closeConsole(shell)
      await board.closeConsole(orchestrator)
      return notes
    }
    board.setOrchestratorDraft(orchestrator, "send \(shell.uuidString) echo sub-ok")
    let submitID = OrchestratorControl.submit(orchestrator)
    let submitAX = await AccessibilityProbe.press(
      pid: getpid(), names: [submitID, "Send orchestrator command"], actions: [kAXPressAction as String])
    notes.append("pressSubmitAX=\(submitAX)")
    var asked = await waitUntil(.seconds(2)) { board.orchestratorApprovals.first?.text == "echo sub-ok" }
    if !asked, let content = LaunchSnapshot.boardWindow()?.contentView,
      let button = ControlFinder.button(identifier: submitID, in: content) {
      board.setOrchestratorDraft(orchestrator, "send \(shell.uuidString) echo sub-ok")
      button.performClick(nil)
      notes.append("pressSubmit=performClick")
      asked = await waitUntil(.seconds(2)) { board.orchestratorApprovals.first?.text == "echo sub-ok" }
    }
    let approval = board.orchestratorApprovals.first
    notes.append("asked=\(asked)")
    notes.append("approvalTarget=\(approval?.targetTitle ?? "none")")
    notes.append("approvalText=\(approval?.text ?? "none")")
    let quiet = board.recentConsoleOutput(shell, maxBytes: 12_000)?.contains("sub-ok") != true
    notes.append("unsent=\(quiet)")
    try? await Task.sleep(for: .milliseconds(250))
    await LaunchSnapshot.write(board: board, to: directory, notes: prior + notes, imageName: "approval.png")
    guard approval != nil else {
      notes.append("reported=false")
      await board.closeConsole(shell)
      await board.closeConsole(orchestrator)
      return notes
    }
    let approveAX = await AccessibilityProbe.press(
      pid: getpid(), names: [OrchestratorControl.approve, "Approve send to Shell"],
      actions: [kAXPressAction as String])
    notes.append("pressApproveAX=\(approveAX)")
    var approved = await waitUntil(.seconds(2)) { board.orchestratorApprovals.isEmpty }
    if !approved, let content = LaunchSnapshot.boardWindow()?.contentView,
      let button = ControlFinder.button(identifier: OrchestratorControl.approve, in: content) {
      button.performClick(nil)
      notes.append("pressApprove=performClick")
      approved = await waitUntil(.seconds(2)) { board.orchestratorApprovals.isEmpty }
    }
    notes.append("approved=\(approved)")
    let reported = await waitUntil(.seconds(12)) {
      let transcript = board.orchestratorTranscripts[orchestrator] ?? ""
      let output = board.recentConsoleOutput(shell, maxBytes: 12_000) ?? ""
      return transcript.contains("sub-ok") && output.contains("sub-ok")
    }
    notes.append("reported=\(reported)")
    let link = board.orchestratorLinks.first { $0.targetID == shell }
    notes.append("link=\(link?.status.rawValue ?? "none")")
    try? await Task.sleep(for: .milliseconds(300))
    await LaunchSnapshot.write(board: board, to: directory, notes: prior + notes, imageName: "orchestrator.png")
    await board.closeConsole(shell)
    await board.closeConsole(orchestrator)
    return notes
  }

  /// Opens Loops, creates a one-shot idle loop, and checks the idle shell runs it.
  private static func exerciseLoops(board: BoardViewModel, consoleID: UUID, directory: URL) async -> [String] {
    var notes = ["flow=loops"]
    func flush() {
      try? notes.joined(separator: "\n").appending("\n").write(
        to: directory.appendingPathComponent("loop-log.txt"), atomically: true, encoding: .utf8)
    }
    guard board.sessions[consoleID]?.isRunning == true else {
      notes.append("loopEcho=false")
      return notes
    }
    if let window = LaunchSnapshot.boardWindow() {
      window.setContentSize(NSSize(width: 1200, height: 800))
      window.makeKeyAndOrderFront(nil)
      window.layoutIfNeeded()
    }
    board.select(consoleID)
    let idleReady = await waitStatus(.idle, board: board, consoleID: consoleID, timeout: .seconds(6))
    notes.append("loopIdle=\(idleReady)")
    flush()
    let opened = await pressAnywhere("toolbar.showLoops", timeout: .seconds(3))
    notes.append("loopPanelPress=\(opened)")
    let marker = await waitMarker("panel.marker.loops")
    notes.append("loopPanel=\(marker)")
    flush()
    guard marker else {
      notes.append("loopEcho=false")
      return notes
    }
    notes.append("loopAdd=\(await pressAnywhere("loops.add", timeout: .seconds(3)))")
    let fields = await waitUntil(.seconds(2)) {
      MarkedFieldRegistry.hasCommit("loops.prompt") && MarkedFieldRegistry.hasCommit("loops.max")
    }
    notes.append("loopFields=\(fields)")
    flush()
    guard fields else {
      notes.append("loopEcho=false")
      return notes
    }
    let prompt = "echo lanebay-loop-ok"
    notes.append("loopMax=\(fillIdentifier("loops.max", text: "1"))")
    try? await Task.sleep(for: .milliseconds(200))
    notes.append("loopPrompt=\(fillIdentifier("loops.prompt", text: prompt))")
    try? await Task.sleep(for: .milliseconds(200))
    notes.append("loopCreate=\(await pressAnywhere("loops.create", timeout: .seconds(3)))")
    let created = await waitUntil(.seconds(3)) {
      board.workspace?.loops.contains { $0.prompt == prompt && $0.maxIterations == 1 } == true
    }
    notes.append("loopCreated=\(created)")
    flush()
    if let runaway = board.workspace?.loops.first(where: { $0.prompt == prompt && $0.maxIterations != 1 }) {
      board.stopLoop(runaway.id)
      notes.append("loopEcho=false")
      flush()
      return notes
    }
    let echoed = await waitUntil(.seconds(8)) {
      let loop = board.workspace?.loops.first { $0.prompt == prompt }
      return loop?.iterations == 1 && outputContains("lanebay-loop-ok", board: board, consoleID: consoleID)
    }
    notes.append("loopEcho=\(echoed)")
    if let loop = board.workspace?.loops.first(where: { $0.prompt == prompt }) {
      notes.append("loopIterations=\(loop.iterations)")
      notes.append("loopEnabled=\(loop.isEnabled)")
      if loop.isEnabled { board.stopLoop(loop.id) }
    }
    place(consoleID, on: board, screenX: 24, screenY: 48, width: 520, height: 280)
    let settled = await waitStatus(.idle, board: board, consoleID: consoleID, timeout: .seconds(6))
    notes.append("loopSettled=\(settled)")
    notes.append("loopStatus=\(statusLabel(board: board, consoleID: consoleID))")
    try? await Task.sleep(for: .milliseconds(200))
    await LaunchSnapshot.write(
      board: board, to: directory, notes: notes, imageName: "loops.png", probeAccessibility: false)
    notes.append(contentsOf: await exerciseOtherLoopTriggers(
      board: board, consoleID: consoleID, directory: directory))
    flush()
    _ = await pressAnywhere("toolbar.showLoops", timeout: .seconds(2))
    _ = await waitUntil(.seconds(2)) {
      guard let content = LaunchSnapshot.boardWindow()?.contentView else { return false }
      return ControlFinder.view(identifier: "panel.marker.loops", in: content) == nil
    }
    flush()
    return notes
  }

  /// Output match, schedule, and goal check each send once to the same idle shell.
  private static func exerciseOtherLoopTriggers(
    board: BoardViewModel, consoleID: UUID, directory: URL
  ) async -> [String] {
    var notes: [String] = ["flow=loop-triggers"]
    func flush() {
      try? notes.joined(separator: "\n").appending("\n").write(
        to: directory.appendingPathComponent("trigger-log.txt"), atomically: true, encoding: .utf8)
    }
    func stopEnabled() {
      for loop in board.workspace?.loops ?? [] where loop.isEnabled { board.stopLoop(loop.id) }
    }

    let idleReady = await waitStatus(.idle, board: board, consoleID: consoleID, timeout: .seconds(8))
    notes.append("triggerIdle=\(idleReady)")
    flush()
    guard idleReady else {
      notes.append("outputEcho=false")
      notes.append("scheduleEcho=false")
      notes.append("goalEcho=false")
      stopEnabled()
      return notes
    }

    let matchPrompt = "echo lanebay-match-ok"
    notes.append("outputForm=\(await fillLoopForm(trigger: "loops.trigger.output", fields: [("loops.pattern", "lanebay-match-marker")], prompt: matchPrompt, max: "1"))")
    let match = board.workspace?.loops.first { $0.prompt == matchPrompt }
    let matchReady = match?.maxIterations == 1 && match?.iterations == 0
      && match?.trigger == .outputMatch(pattern: "lanebay-match-marker")
    notes.append("outputHeld=\(match?.iterations == 0)")
    notes.append("outputReady=\(matchReady)")
    flush()
    if matchReady {
      notes.append("outputWrote=\(board.writeToConsole("printf 'lanebay-match-marker\\n'\r", nodeID: consoleID))")
      let echoed = await waitUntil(.seconds(8)) {
        let loop = board.workspace?.loops.first { $0.prompt == matchPrompt }
        return loop?.iterations == 1 && outputContains("lanebay-match-ok", board: board, consoleID: consoleID)
      }
      notes.append("outputEcho=\(echoed)")
    } else {
      notes.append("outputEcho=false")
    }
    if let loop = board.workspace?.loops.first(where: { $0.prompt == matchPrompt }) {
      notes.append("outputIterations=\(loop.iterations)")
      notes.append("outputEnabled=\(loop.isEnabled)")
      if loop.isEnabled { board.stopLoop(loop.id) }
    }
    place(consoleID, on: board, screenX: 24, screenY: 48, width: 520, height: 280)
    try? await Task.sleep(for: .milliseconds(200))
    await LaunchSnapshot.write(
      board: board, to: directory, notes: notes, imageName: "loop-output.png", probeAccessibility: false)
    let matchSettled = await waitStatus(.idle, board: board, consoleID: consoleID, timeout: .seconds(8))
    notes.append("outputSettled=\(matchSettled)")
    flush()

    let schedulePrompt = "echo lanebay-schedule-ok"
    notes.append("scheduleForm=\(await fillLoopForm(trigger: "loops.trigger.schedule", fields: [("loops.interval", "1")], prompt: schedulePrompt, max: "1"))")
    let schedule = board.workspace?.loops.first { $0.prompt == schedulePrompt }
    let scheduleReady = schedule?.maxIterations == 1 && schedule?.iterations == 0
      && schedule?.trigger == .schedule(intervalSeconds: 1)
    notes.append("scheduleHeld=\(schedule?.iterations == 0)")
    notes.append("scheduleReady=\(scheduleReady)")
    flush()
    if scheduleReady {
      let echoed = await waitUntil(.seconds(6)) {
        let loop = board.workspace?.loops.first { $0.prompt == schedulePrompt }
        return loop?.iterations == 1 && outputContains("lanebay-schedule-ok", board: board, consoleID: consoleID)
      }
      notes.append("scheduleEcho=\(echoed)")
    } else {
      if let schedule { board.stopLoop(schedule.id) }
      notes.append("scheduleEcho=false")
    }
    if let loop = board.workspace?.loops.first(where: { $0.prompt == schedulePrompt }) {
      notes.append("scheduleIterations=\(loop.iterations)")
      notes.append("scheduleEnabled=\(loop.isEnabled)")
      if loop.isEnabled { board.stopLoop(loop.id) }
    }
    try? await Task.sleep(for: .milliseconds(200))
    await LaunchSnapshot.write(
      board: board, to: directory, notes: notes, imageName: "loop-schedule.png", probeAccessibility: false)
    let scheduleSettled = await waitStatus(.idle, board: board, consoleID: consoleID, timeout: .seconds(8))
    notes.append("scheduleSettled=\(scheduleSettled)")
    flush()

    let goalPrompt = "echo lanebay-goal-sent lanebay-goal-done"
    notes.append("goalForm=\(await fillLoopForm(trigger: "loops.trigger.goal", fields: [("loops.interval", "2"), ("loops.goal", "lanebay-goal-done")], prompt: goalPrompt, max: "3"))")
    let goal = board.workspace?.loops.first { $0.prompt == goalPrompt }
    let goalReady = goal?.maxIterations == 3 && goal?.iterations == 0
      && goal?.trigger == .goalCheck(intervalSeconds: 2, goal: "lanebay-goal-done")
    notes.append("goalHeld=\(goal?.iterations == 0)")
    notes.append("goalReady=\(goalReady)")
    flush()
    if goalReady {
      // The cap is 3. The marker printed by the first send must stop the loop at 1.
      let echoed = await waitUntil(.seconds(8)) {
        let loop = board.workspace?.loops.first { $0.prompt == goalPrompt }
        return loop?.iterations == 1 && loop?.isEnabled == false
          && outputContains("lanebay-goal-sent", board: board, consoleID: consoleID)
          && outputContains("lanebay-goal-done", board: board, consoleID: consoleID)
      }
      notes.append("goalEcho=\(echoed)")
    } else {
      if let goal { board.stopLoop(goal.id) }
      notes.append("goalEcho=false")
    }
    if let loop = board.workspace?.loops.first(where: { $0.prompt == goalPrompt }) {
      notes.append("goalIterations=\(loop.iterations)")
      notes.append("goalEnabled=\(loop.isEnabled)")
      notes.append("goalStopped=\(loop.iterations == 1 && !loop.isEnabled)")
      if loop.isEnabled { board.stopLoop(loop.id) }
    }
    try? await Task.sleep(for: .milliseconds(200))
    await LaunchSnapshot.write(
      board: board, to: directory, notes: notes, imageName: "loop-goal.png", probeAccessibility: false)
    stopEnabled()
    flush()
    return notes
  }

  /// Opens the loop editor, selects a trigger, and commits the fields the running app can see.
  private static func fillLoopForm(
    trigger: String, fields: [(String, String)], prompt: String, max: String
  ) async -> String {
    if ControlFinder.buttonAnywhere("loops.create") == nil {
      let add = await pressAnywhere("loops.add", timeout: .seconds(3))
      if add != "performClick" { return "add=\(add)" }
    }
    let editor = await waitUntil(.seconds(2)) {
      MarkedFieldRegistry.hasCommit("loops.prompt") && MarkedFieldRegistry.hasCommit("loops.max")
    }
    guard editor else { return "editor-missing" }
    let pressed = await pressAnywhere(trigger, timeout: .seconds(2))
    let selected = await waitUntil(.seconds(2)) {
      (ControlFinder.buttonAnywhere(trigger)?.accessibilityValue() as? String) == "selected"
        && fields.allSatisfy { MarkedFieldRegistry.hasCommit($0.0) }
    }
    guard selected else { return "trigger=\(pressed)" }
    guard fillIdentifier("loops.max", text: max) == "commit" else { return "max-missing" }
    try? await Task.sleep(for: .milliseconds(200))
    for (identifier, text) in fields {
      guard fillIdentifier(identifier, text: text) == "commit" else { return "\(identifier)-missing" }
      try? await Task.sleep(for: .milliseconds(200))
    }
    guard fillIdentifier("loops.prompt", text: prompt) == "commit" else { return "prompt-missing" }
    try? await Task.sleep(for: .milliseconds(200))
    for (identifier, text) in fields {
      guard fillIdentifier(identifier, text: text) == "commit" else { return "\(identifier)-reset" }
    }
    guard fillIdentifier("loops.max", text: max) == "commit" else { return "max-reset" }
    guard fillIdentifier("loops.prompt", text: prompt) == "commit" else { return "prompt-reset" }
    try? await Task.sleep(for: .milliseconds(200))
    return await pressAnywhere("loops.create", timeout: .seconds(3))
  }

  /// A second shell joins the group, one console becomes lead, and both kinds of send are checked.
  private static func exerciseCrew(board: BoardViewModel, leaderID: UUID, directory: URL) async -> [String] {
    var notes = ["flow=crew"]
    guard board.workspace?.groups.isEmpty == false else {
      notes.append("crew=no-group")
      return notes
    }
    let spawned = await startAnotherShell(on: board)
    notes.append(contentsOf: spawned.notes)
    guard let memberID = spawned.id else {
      notes.append("crewEcho=false")
      notes.append("leadEcho=false")
      return notes
    }
    let manage = await pressIdentifier(
      "rail.manageGroups", names: ["rail.manageGroups", "Manage groups"])
    notes.append("crewManage=\(manage)")
    let opened = await waitUntil(.seconds(2)) { manageSheetVisible() }
    notes.append("crewSheet=\(opened)")
    guard opened else {
      notes.append("crewEcho=false")
      notes.append("leadEcho=false")
      return notes
    }
    _ = await pressAnywhere("groups.member.\(memberID.uuidString)")
    _ = await pressAnywhere("groups.lead.\(leaderID.uuidString)")
    let marked = await waitUntil(.seconds(2)) {
      (ControlFinder.buttonAnywhere("groups.lead.\(leaderID.uuidString)")?.accessibilityValue() as? String) == "lead"
    }
    notes.append("leadMarked=\(marked)")
    if let sheet = manageWindow() {
      LaunchSnapshot.writeWindow(sheet, to: directory.appendingPathComponent("groups-lead.png"))
    }
    _ = await pressAnywhere("groups.save")
    let saved = await waitUntil(.seconds(2)) {
      let group = board.workspace?.groups.first
      return group?.leadNodeID == leaderID
        && Set(group?.nodeIDs ?? []).isSuperset(of: [leaderID, memberID])
    }
    notes.append("leadSaved=\(saved)")
    notes.append("crewMembers=\(board.workspace?.groups.first?.nodeIDs.count ?? 0)")
    flushCrew(notes, to: directory)
    let bothIdle = await waitUntil(.seconds(12)) {
      board.idleConsoleIDs.isSuperset(of: [leaderID, memberID])
    }
    notes.append("crewIdle=\(bothIdle)")
    flushCrew(notes, to: directory)
    notes.append("crewField=\(MarkedFieldRegistry.hasCommit("groups.message"))")
    flushCrew(notes, to: directory)
    notes.append("crewMessage=\(fillIdentifier("groups.message", text: "echo lanebay-crew-ok"))")
    flushCrew(notes, to: directory)
    try? await Task.sleep(for: .milliseconds(200))
    if let sheet = manageWindow() {
      LaunchSnapshot.writeWindow(sheet, to: directory.appendingPathComponent("groups-message.png"))
    }
    let broadcast = await pressAnywhere("groups.broadcast", timeout: .seconds(5))
    notes.append("crewBroadcast=\(broadcast)")
    flushCrew(notes, to: directory)
    let crewEcho = await waitUntil(.seconds(6)) {
      outputContains("lanebay-crew-ok", board: board, consoleID: leaderID)
        && outputContains("lanebay-crew-ok", board: board, consoleID: memberID)
    }
    notes.append("crewEcho=\(crewEcho)")
    flushCrew(notes, to: directory)
    let leaderIdle = await waitUntil(.seconds(8)) { board.idleConsoleIDs.contains(leaderID) }
    notes.append("leaderIdle=\(leaderIdle)")
    notes.append("leadMessage=\(fillIdentifier("groups.message", text: "echo lanebay-lead-ok"))")
    let leadSend = await pressAnywhere("groups.sendLead", timeout: .seconds(5))
    notes.append("leadSend=\(leadSend)")
    let leadEcho = await waitUntil(.seconds(6)) {
      outputContains("lanebay-lead-ok", board: board, consoleID: leaderID)
    }
    try? await Task.sleep(for: .milliseconds(500))
    let memberMissed = !outputContains("lanebay-lead-ok", board: board, consoleID: memberID)
    notes.append("leadEcho=\(leadEcho)")
    notes.append("memberMissedLead=\(memberMissed)")
    flushCrew(notes, to: directory)
    dismissManage()
    _ = await waitUntil(.seconds(2)) { !manageSheetVisible() }
    if manageSheetVisible() {
      for window in NSApp.windows where window != LaunchSnapshot.boardWindow() {
        guard let root = window.contentView,
          ControlFinder.view(identifier: "groups.manage", in: root) != nil
        else { continue }
        window.orderOut(nil)
        window.close()
      }
    }
    place(leaderID, on: board, screenX: 24, screenY: 72, width: 520, height: 260)
    place(memberID, on: board, screenX: 580, screenY: 72, width: 480, height: 260)
    try? await Task.sleep(for: .milliseconds(350))
    notes.append("groupLead=\(statusLabel(board: board, consoleID: leaderID))")
    notes.append("groupMember=\(statusLabel(board: board, consoleID: memberID))")
    await LaunchSnapshot.write(
      board: board, to: directory, notes: notes, imageName: "group-map.png", probeAccessibility: false)
    await board.closeConsole(memberID)
    notes.append("memberClosed=\(board.workspace?.nodes.contains { $0.id == memberID } == false)")
    return notes
  }

  private static func flushCrew(_ notes: [String], to directory: URL) {
    try? notes.joined(separator: "\n").appending("\n").write(
      to: directory.appendingPathComponent("crew-log.txt"), atomically: true, encoding: .utf8)
  }

  private static func startAnotherShell(on board: BoardViewModel) async -> (id: UUID?, notes: [String]) {
    var notes: [String] = []
    let before = Set((board.workspace?.nodes ?? []).filter { $0.agentID == "shell" }.map(\.id))
    notes.append("crewAdd=\(await pressIdentifier("rail.addConsole", names: ["rail.addConsole", "Add console"]))")
    let opened = await waitUntil(.seconds(2)) { pickerVisible() }
    notes.append("crewPicker=\(opened)")
    guard opened else { return (nil, notes) }
    notes.append("crewShell=\(await pressIdentifier("agent.shell", names: ["agent.shell", "Shell"]))")
    if pickerVisible() {
      _ = await pressIdentifier("rail.addConsole", names: ["rail.addConsole", "Add console"])
    }
    _ = await waitUntil(.seconds(3)) {
      (board.workspace?.nodes ?? []).contains { $0.agentID == "shell" && !before.contains($0.id) }
    }
    guard let id = (board.workspace?.nodes ?? []).first(where: { $0.agentID == "shell" && !before.contains($0.id) })?.id
    else {
      notes.append("crewSpawned=false")
      return (nil, notes)
    }
    notes.append("crewSpawned=true")
    let running = await waitUntil(.seconds(8)) { board.sessions[id]?.isRunning == true }
    notes.append("crewRunning=\(running)")
    return (running ? id : nil, notes)
  }

  private static func place(
    _ id: UUID, on board: BoardViewModel, screenX: Double, screenY: Double, width: Double, height: Double
  ) {
    let zoom = board.zoom == 0 ? 1 : board.zoom
    board.moveNode(id, x: (screenX - board.panX) / zoom, y: (screenY - board.panY) / zoom)
    board.resizeNode(id, width: width, height: height)
  }

  private static func outputContains(_ token: String, board: BoardViewModel, consoleID: UUID) -> Bool {
    board.recentConsoleOutput(consoleID, maxBytes: 8_000)?.contains(token) == true
  }

  private static func manageWindow() -> NSWindow? {
    NSApp.windows.first { window in
      guard let root = window.contentView else { return false }
      return ControlFinder.view(identifier: "groups.manage", in: root) != nil
    }
  }

  @discardableResult
  private static func pressAnywhere(_ identifier: String, timeout: Duration = .seconds(2)) async -> String {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if let button = ControlFinder.buttonAnywhere(identifier), button.isEnabled {
        if let target = button.target as? NSObject, let action = button.action {
          _ = target.perform(action, with: button)
        } else {
          button.performClick(nil)
        }
        return "performClick"
      }
      try? await Task.sleep(for: .milliseconds(40))
    }
    guard let button = ControlFinder.buttonAnywhere(identifier) else { return "missing" }
    return button.isEnabled ? "late" : "disabled"
  }

  private static func fillIdentifier(_ identifier: String, text: String) -> String {
    MarkedFieldRegistry.commit(identifier: identifier, text: text) ? "commit" : "missing"
  }

  private static func title(for agent: String) -> String {
    switch agent {
    case "codex": "Codex"
    case "claude": "Claude Code"
    case "cursor-agent": "Cursor Agent"
    case "the-bins": "The Bins"
    default: agent
    }
  }
}

@MainActor
private final class FloodObservation {
  var stop = false
  func finish() { stop = true }
}

@MainActor
private enum ControlFinder {
  static func button(identifier: String, in view: NSView) -> NSButton? {
    if let button = view as? NSButton, button.accessibilityIdentifier() == identifier { return button }
    for child in view.subviews {
      if let found = button(identifier: identifier, in: child) { return found }
    }
    return nil
  }

  static func buttonAnywhere(_ identifier: String) -> NSButton? {
    for window in NSApp.windows {
      if let content = window.contentView, let button = button(identifier: identifier, in: content) {
        return button
      }
      for sheet in window.sheets {
        if let content = sheet.contentView, let button = button(identifier: identifier, in: content) {
          return button
        }
      }
    }
    return nil
  }

  static func textField(identifier: String, in view: NSView) -> NSTextField? {
    // Match the AppKit identifier only. accessibilityIdentifier() on a SwiftUI text field
    // updates that field off the main actor and traps, which stalls the rest of the flow.
    if let field = view as? NSTextField, field.identifier?.rawValue == identifier {
      return field
    }
    for child in view.subviews {
      if let found = textField(identifier: identifier, in: child) { return found }
    }
    return nil
  }

  static func textFieldAnywhere(_ identifier: String) -> NSTextField? {
    for window in NSApp.windows {
      if let content = window.contentView, let field = textField(identifier: identifier, in: content) {
        return field
      }
      for sheet in window.sheets {
        if let content = sheet.contentView, let field = textField(identifier: identifier, in: content) {
          return field
        }
      }
    }
    return nil
  }

  static func buttons(in view: NSView) -> [NSButton] {
    var found: [NSButton] = []
    if let button = view as? NSButton { found.append(button) }
    for child in view.subviews { found.append(contentsOf: buttons(in: child)) }
    return found
  }

  static func button(title: String, in view: NSView) -> NSButton? {
    if let button = view as? NSButton,
      button.title == title || button.accessibilityLabel() == title {
      return button
    }
    for child in view.subviews {
      if let found = button(title: title, in: child) { return found }
    }
    return nil
  }

  static func textField(in view: NSView) -> NSTextField? {
    if let field = view as? NSTextField, field.isEditable { return field }
    for child in view.subviews {
      if let found = textField(in: child) { return found }
    }
    return nil
  }

  static func buttonTitles(in view: NSView) -> [String] {
    var titles: [String] = []
    if let button = view as? NSButton {
      let title = button.title.isEmpty ? (button.accessibilityLabel() ?? "") : button.title
      if !title.isEmpty { titles.append(title) }
    }
    for child in view.subviews { titles.append(contentsOf: buttonTitles(in: child)) }
    return titles
  }

  static func view(identifier: String, in view: NSView) -> NSView? {
    if view.accessibilityIdentifier() == identifier { return view }
    for child in view.subviews {
      if let found = self.view(identifier: identifier, in: child) { return found }
    }
    return nil
  }
}

@MainActor
private enum TerminalFinder {
  static func find(in view: NSView) -> NSView? {
    if String(describing: type(of: view)).contains("FocusTerminalView") { return view }
    for child in view.subviews {
      if let found = find(in: child) { return found }
    }
    return nil
  }
}
