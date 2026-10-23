import AppKit
import ApplicationServices
import LanebayUI
import SwiftUI
import LanebayCore
import UserNotifications
import Sparkle

@main
struct LanebayApp: App {
  @State private var board = BoardViewModel.live(
    homeDirectory: LaunchIsolation.homeDirectory(),
    statusSpeaker: AppleVoiceStatusSpeaker()
  )
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  var body: some Scene {
    Window("Lanebay", id: "board") {
      BoardView(model: board)
        .frame(minWidth: 800, minHeight: 500)
        .onAppear {
          appDelegate.board = board
          NewTerminalShortcut.board = board
        }
    }
    .defaultSize(width: 1200, height: 800)
    .commands {
      CommandMenu("Terminal") {
        Button("New Terminal") { board.beginNewTerminal() }
          .keyboardShortcut("t", modifiers: .command)
      }
      CommandMenu("Canvas") {
        Button("Zoom In") { board.setZoom(board.zoom * 1.1) }
          .keyboardShortcut("+", modifiers: .command)
        Button("Zoom In") { board.setZoom(board.zoom * 1.1) }
          .keyboardShortcut("=", modifiers: .command)
        Button("Zoom Out") { board.setZoom(board.zoom / 1.1) }
          .keyboardShortcut("-", modifiers: .command)
        Button("Actual Size") { board.setZoom(1) }
          .keyboardShortcut("0", modifiers: .command)
      }
      if let updaterController = appDelegate.updaterController {
        CommandGroup(after: .appInfo) {
          Button("Check for Updates…") {
            updaterController.checkForUpdates(nil)
          }
          .disabled(!updaterController.updater.canCheckForUpdates)
        }
      }
    }
  }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  var board: BoardViewModel?
  let updaterController: SPUStandardUpdaterController?
  private var hookServer: HookServer?
  private var hookTask: Task<Void, Never>?

  override init() {
    if SparkleConfiguration.isConfigured(info: Bundle.main.infoDictionary ?? [:]) {
      updaterController = SPUStandardUpdaterController(
        startingUpdater: true,
        updaterDelegate: nil,
        userDriverDelegate: nil
      )
    } else {
      updaterController = nil
    }
    super.init()
  }

  func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
    guard let board else { return .terminateNow }
    // A later reply never runs: terminate's nested event loop does not drain the main actor.
    // Save synchronously and exit. Closing the process hangs up the console PTYs.
    do { try board.saveNow() } catch { return .terminateCancel }
    return .terminateNow
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    NewTerminalShortcut.install()
    NewTerminalShortcut.board = board
    if let snapshotDirectory = LaunchIsolation.pendingFlowDirectory, LaunchIsolation.root != nil {
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(700))
        NSApp.activate(ignoringOtherApps: true)
        if let window = LaunchSnapshot.boardWindow() {
          window.setContentSize(NSSize(width: 1200, height: 800))
          window.makeKeyAndOrderFront(nil)
        }
        try? await Task.sleep(for: .milliseconds(500))
        if let board = self.board {
          await ConsoleFlowSelfTest.run(board: board, directory: snapshotDirectory)
        }
        // terminate() runs a nested event loop. Calling it from this task blocks the
        // main actor, so the shutdown task in applicationShouldTerminate never starts.
        DispatchQueue.main.async { NSApp.terminate(nil) }
      }
      return
    }
    if let snapshotDirectory = LaunchSnapshot.consumeRequest() {
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(800))
        NSApp.activate(ignoringOtherApps: true)
        if let window = LaunchSnapshot.boardWindow() {
          window.setContentSize(NSSize(width: 1200, height: 800))
          window.makeKeyAndOrderFront(nil)
        }
        try? await Task.sleep(for: .milliseconds(700))
        await LaunchSnapshot.write(board: self.board, to: snapshotDirectory)
        DispatchQueue.main.async { NSApp.terminate(nil) }
      }
    }
    Task { @MainActor in
      _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
      do {
        let server = try HookServer()
        try server.writeRuntime(to: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".lanebay/hooks", isDirectory: true))
        hookServer = server
        hookTask = Task { [weak self] in
          for await event in server.events { self?.board?.receive(hook: event) }
        }
      } catch {
        board?.errorMessage = "Agent status hooks unavailable: \(error.localizedDescription)"
      }
    }
  }
}

/// Command-T opens New terminal even when a console is focused.
@MainActor
enum NewTerminalShortcut {
  private static var installed = false
  static weak var board: BoardViewModel?

  static func install() {
    guard !installed else { return }
    installed = true
    NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      handle(event)
    }
  }

  static func handle(_ event: NSEvent) -> NSEvent? {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard event.keyCode == 17, flags == .command else { return event }
    board?.beginNewTerminal()
    return nil
  }
}

/// A `.flow` marker isolates this launch under a temp home and runs the console self-test.
@MainActor
enum LaunchIsolation {
  private(set) static var root: URL?
  private(set) static var pendingFlowDirectory: URL?
  /// `arrange` saves a layout and quits. `verify` checks that layout after a new process starts.
  private(set) static var phase: String?
  private static var didReadMarker = false

  static func homeDirectory() -> URL {
    if !didReadMarker {
      didReadMarker = true
      pendingFlowDirectory = takeFlowMarker()
      if pendingFlowDirectory != nil {
        phase = takePhase()
        if let reused = takeReusedHome() {
          root = reused
        } else {
          let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("lanebay-flow-\(UUID().uuidString)", isDirectory: true)
          if (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil {
            root = directory
          } else {
            pendingFlowDirectory = nil
            phase = nil
          }
        }
      }
    }
    return root ?? FileManager.default.homeDirectoryForCurrentUser
  }

  private static func markerURL(_ name: String) -> URL {
    Bundle.main.bundleURL
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("agent/screens/\(name)")
  }

  private static func takePhase() -> String? {
    let marker = markerURL(".flow-phase")
    guard let raw = try? String(contentsOf: marker, encoding: .utf8) else { return nil }
    try? FileManager.default.removeItem(at: marker)
    let phase = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    switch phase {
    case "arrange", "verify": return phase
    default: return nil
    }
  }

  private static func takeReusedHome() -> URL? {
    let marker = markerURL(".flow-home")
    guard let raw = try? String(contentsOf: marker, encoding: .utf8) else { return nil }
    try? FileManager.default.removeItem(at: marker)
    return FlowLaunchHome.accepted(path: raw, temporaryDirectory: FileManager.default.temporaryDirectory)
  }

  private static func takeFlowMarker() -> URL? {
    let marker = Bundle.main.bundleURL
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("agent/screens/.flow")
    guard FileManager.default.fileExists(atPath: marker.path) else { return nil }
    let raw = (try? String(contentsOf: marker, encoding: .utf8)) ?? ""
    try? FileManager.default.removeItem(at: marker)
    return SnapshotCapturePath.destination(bundleURL: Bundle.main.bundleURL, markerContents: raw)
  }
}

/// Writes an in-window PNG when `dist/Lanebay.app` is launched with `agent/screens/.capture`.
@MainActor
enum LaunchSnapshot {
  static func consumeRequest() -> URL? {
    let marker = Bundle.main.bundleURL
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("agent/screens/.capture")
    guard FileManager.default.fileExists(atPath: marker.path),
      let raw = try? String(contentsOf: marker, encoding: .utf8)
    else { return nil }
    try? FileManager.default.removeItem(at: marker)
    return SnapshotCapturePath.destination(bundleURL: Bundle.main.bundleURL, markerContents: raw)
  }

  static func writeWindow(_ window: NSWindow, to file: URL) {
    guard let view = window.contentView else { return }
    window.layoutIfNeeded()
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()
    guard let data = pngData(from: view) else { return }
    try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: file, options: .atomic)
  }

  static func boardWindow() -> NSWindow? {
    if let titled = NSApp.windows.first(where: { $0.title == "Lanebay" && $0.contentView != nil }) {
      return titled
    }
    return NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first { $0.contentView != nil }
  }

  static func windowContaining(identifier: String) -> NSWindow? {
    for window in NSApp.windows {
      guard let content = window.contentView, view(identifier: identifier, in: content) != nil else { continue }
      return window
    }
    return nil
  }

  static func writeIdentifier(_ identifier: String, to directory: URL, imageName: String) -> String {
    guard let window = windowContaining(identifier: identifier), let view = window.contentView else {
      return "missing"
    }
    window.layoutIfNeeded()
    view.layoutSubtreeIfNeeded()
    view.displayIfNeeded()
    guard let data = pngData(from: view) else { return "png-failed" }
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      try data.write(to: directory.appendingPathComponent(imageName), options: .atomic)
      return "wrote \(data.count)"
    } catch {
      return "png-failed"
    }
  }

  private static func view(identifier: String, in view: NSView) -> NSView? {
    if view.accessibilityIdentifier() == identifier { return view }
    for child in view.subviews {
      if let found = self.view(identifier: identifier, in: child) { return found }
    }
    return nil
  }

  static func write(
    board: BoardViewModel?, to directory: URL, notes: [String] = [], imageName: String = "board.png",
    contentSize: NSSize? = nil, probeAccessibility: Bool = true
  ) async {
    var lines: [String] = notes
    let window = boardWindow()
    if let window, let view = window.contentView {
      window.setContentSize(contentSize ?? NSSize(width: 1200, height: 800))
      window.makeKeyAndOrderFront(nil)
      window.layoutIfNeeded()
      view.layoutSubtreeIfNeeded()
      view.displayIfNeeded()
      lines.append("window=\(Int(view.bounds.width))x\(Int(view.bounds.height))")
      if let data = pngData(from: view) {
        do {
          try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
          try data.write(to: directory.appendingPathComponent(imageName), options: .atomic)
          lines.append("png=\(imageName) bytes=\(data.count)")
        } catch {
          lines.append("png=failed")
        }
      } else {
        lines.append("png=failed")
      }
      if probeAccessibility {
        let probe = await AccessibilityProbe.hits(pid: getpid())
        let identifiers = probe.hits.map(\.name).filter { !$0.isEmpty }
        lines.append("ids=\(identifiers.prefix(40).joined(separator: ","))")
        if probe.timedOut { lines.append("ax=timeout") }
        if probe.hits.isEmpty { lines.append("ax=empty") }
        let windowFrame = window.frame
        let wanted: [(String, [String])] = [
          ("rail.addConsole", ["rail.addConsole", "Add console"]),
          ("rail.createGroup", ["rail.createGroup", "Create group"]),
          ("rail.manageGroups", ["rail.manageGroups", "Manage groups"]),
        ]
        for (key, names) in wanted {
          let frames = probe.hits.filter { names.contains($0.name) }.map(\.frame)
          if frames.isEmpty {
            lines.append("\(key)=missing")
          } else if frames.contains(where: { isInside($0, windowFrame: windowFrame) }) {
            lines.append("\(key)=inside")
          } else {
            lines.append("\(key)=outside")
          }
        }
      } else {
        lines.append("ax=skipped")
      }
    } else {
      lines.append("window=missing")
    }
    if let board {
      let tops = (board.workspace?.nodes ?? [])
        .filter { $0.kind == .console }
        .map { $0.frame.y * board.zoom + board.panY }
      lines.append(String(format: "pan=%.1f,%.1f", board.panX, board.panY))
      if let minTop = tops.min() {
        lines.append(String(format: "minScreenY=%.1f", minTop))
        lines.append("headersInside=\(minTop >= -0.5)")
      } else {
        lines.append("cards=0")
      }
    } else {
      lines.append("board=missing")
    }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try? lines.joined(separator: "\n").appending("\n").write(
      to: directory.appendingPathComponent("report.txt"), atomically: true, encoding: .utf8)
  }

  private static func isInside(_ frame: NSRect, windowFrame: NSRect) -> Bool {
    guard frame.width > 1, frame.height > 1, !frame.isNull, !frame.isInfinite else { return false }
    return windowFrame.contains(NSPoint(x: frame.midX, y: frame.midY))
  }

  private static func pngData(from view: NSView) -> Data? {
    let bounds = view.bounds
    guard bounds.width >= 2, bounds.height >= 2 else { return nil }
    if let cached = view.bitmapImageRepForCachingDisplay(in: bounds) {
      view.cacheDisplay(in: bounds, to: cached)
      if !isMostlyClear(cached), let data = cached.representation(using: .png, properties: [:]) {
        return data
      }
    }
    let scale = view.window?.backingScaleFactor ?? 2
    let pixelsWide = max(1, Int((bounds.width * scale).rounded()))
    let pixelsHigh = max(1, Int((bounds.height * scale).rounded()))
    guard let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: pixelsWide,
      pixelsHigh: pixelsHigh,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    ) else { return nil }
    rep.size = bounds.size
    if let layer = view.layer, let context = NSGraphicsContext(bitmapImageRep: rep) {
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = context
      layer.render(in: context.cgContext)
      NSGraphicsContext.restoreGraphicsState()
    } else {
      view.cacheDisplay(in: bounds, to: rep)
    }
    return rep.representation(using: .png, properties: [:])
  }

  private static func isMostlyClear(_ rep: NSBitmapImageRep) -> Bool {
    let points = [
      (x: 0, y: 0),
      (x: max(0, rep.pixelsWide / 2), y: max(0, rep.pixelsHigh / 2)),
      (x: max(0, rep.pixelsWide - 1), y: max(0, rep.pixelsHigh - 1)),
    ]
    var opaque = 0
    for point in points {
      guard let color = rep.colorAt(x: point.x, y: point.y) else { continue }
      if color.alphaComponent > 0.05 { opaque += 1 }
    }
    return opaque == 0
  }
}

/// Same-process accessibility walk. Runs off the main actor so the app can answer AX requests.
enum AccessibilityProbe {
  struct Hit: Sendable {
    var name: String
    var frame: NSRect
  }

  struct Probe: Sendable {
    var hits: [Hit]
    var timedOut: Bool
  }

  static func hits(pid: pid_t) async -> Probe {
    await Task.detached(priority: .userInitiated) {
      collect(pid: pid, deadline: Date().addingTimeInterval(2.5))
    }.value
  }

  static func press(pid: pid_t, names: [String], actions: [String] = [kAXPressAction as String, "AXShowMenu"]) async -> Bool {
    let wanted = names
    let actionNames = actions
    return await Task.detached(priority: .userInitiated) {
      let application = AXUIElementCreateApplication(pid)
      AXUIElementSetMessagingTimeout(application, 0.6)
      guard let element = findMatch(application, names: wanted, deadline: Date().addingTimeInterval(4)) else {
        return false
      }
      for action in actionNames {
        if AXUIElementPerformAction(element, action as CFString) == .success { return true }
      }
      return false
    }.value
  }

  static func adjust(pid: pid_t, names: [String], increment: Bool) async -> Bool {
    let wanted = names
    let action = increment ? kAXIncrementAction as String : kAXDecrementAction as String
    return await Task.detached(priority: .userInitiated) {
      let application = AXUIElementCreateApplication(pid)
      AXUIElementSetMessagingTimeout(application, 0.6)
      guard let element = findAction(application, names: wanted, action: action, deadline: Date().addingTimeInterval(2)) else {
        return false
      }
      return AXUIElementPerformAction(element, action as CFString) == .success
    }.value
  }

  static func names(pid: pid_t, limit: Int = 80) async -> [String] {
    let probe = await hits(pid: pid)
    return Array(probe.hits.map(\.name).prefix(limit))
  }

  private static func findMatch(_ element: AXUIElement, names: [String], deadline: Date) -> AXUIElement? {
    var matches: [(element: AXUIElement, role: String)] = []
    var seen = 0
    func walk(_ element: AXUIElement, depth: Int) {
      guard Date() < deadline, depth < 30, seen < 2500 else { return }
      seen += 1
      AXUIElementSetMessagingTimeout(element, 0.4)
      let identifier = copyString(element, "AXIdentifier")
      let label = copyString(element, "AXDescription") ?? copyString(element, "AXTitle")
      let name = identifier ?? label ?? ""
      if names.contains(name) {
        matches.append((element, copyString(element, "AXRole") ?? ""))
      }
      for child in copyChildren(element) {
        walk(child, depth: depth + 1)
      }
    }
    walk(element, depth: 0)
    func supportsPress(_ element: AXUIElement) -> Bool {
      var names: CFArray?
      guard AXUIElementCopyActionNames(element, &names) == .success, let names = names as? [String] else {
        return false
      }
      return names.contains(kAXPressAction as String)
    }
    return matches.first { $0.role == "AXButton" && supportsPress($0.element) }?.element
      ?? matches.first { supportsPress($0.element) }?.element
      ?? matches.first { $0.role == "AXMenuItem" }?.element
      ?? matches.first { $0.role == "AXButton" || $0.role == "AXMenuButton" }?.element
      ?? matches.first?.element
  }

  private static func findAction(_ element: AXUIElement, names: [String], action: String, deadline: Date) -> AXUIElement? {
    var match: AXUIElement?
    var seen = 0
    func walk(_ element: AXUIElement, depth: Int) {
      guard match == nil, Date() < deadline, depth < 30, seen < 2500 else { return }
      seen += 1
      AXUIElementSetMessagingTimeout(element, 0.4)
      let identifier = copyString(element, "AXIdentifier")
      let label = copyString(element, "AXDescription") ?? copyString(element, "AXTitle")
      let name = identifier ?? label ?? ""
      if names.contains(name) {
        var actions: CFArray?
        if AXUIElementCopyActionNames(element, &actions) == .success,
          (actions as? [String])?.contains(action) == true {
          match = element
          return
        }
      }
      for child in copyChildren(element) { walk(child, depth: depth + 1) }
    }
    walk(element, depth: 0)
    return match
  }

  private static func collect(pid: pid_t, deadline: Date) -> Probe {
    let application = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(application, 0.4)
    var hits: [Hit] = []
    var seen = 0
    var timedOut = false
    func walk(_ element: AXUIElement, depth: Int) {
      guard Date() < deadline else { timedOut = true; return }
      guard depth < 30, seen < 2500 else { return }
      seen += 1
      AXUIElementSetMessagingTimeout(element, 0.4)
      let identifier = copyString(element, "AXIdentifier")
      let label = copyString(element, "AXDescription") ?? copyString(element, "AXTitle")
      if let name = identifier ?? label, !name.isEmpty, let frame = copyFrame(element) {
        hits.append(Hit(name: name, frame: frame))
      }
      for child in copyChildren(element) {
        walk(child, depth: depth + 1)
      }
    }
    walk(application, depth: 0)
    return Probe(hits: hits, timedOut: timedOut)
  }

  private static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
    return value as? String
  }

  private static func copyChildren(_ element: AXUIElement) -> [AXUIElement] {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, "AXChildren" as CFString, &value) == .success else { return [] }
    return (value as? [AXUIElement]) ?? []
  }

  private static func copyFrame(_ element: AXUIElement) -> NSRect? {
    guard let origin = copyPoint(element, "AXPosition"), let size = copySize(element, "AXSize"),
      size.width > 0, size.height > 0 else { return nil }
    return NSRect(origin: origin, size: size)
  }

  private static func copyPoint(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
    guard let axValue = copyAXValue(element, attribute), AXValueGetType(axValue) == .cgPoint else { return nil }
    var point = CGPoint.zero
    guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
    return point
  }

  private static func copySize(_ element: AXUIElement, _ attribute: String) -> CGSize? {
    guard let axValue = copyAXValue(element, attribute), AXValueGetType(axValue) == .cgSize else { return nil }
    var size = CGSize.zero
    guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
    return size
  }

  private static func copyAXValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value else { return nil }
    return unsafeDowncast(value, to: AXValue.self)
  }
}
