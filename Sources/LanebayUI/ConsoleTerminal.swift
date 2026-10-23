import AppKit
import LanebayCore
import Observation
import SwiftTerm
import SwiftUI

/// Accepts PTY bytes off the main thread so a redraw storm cannot stall the read that lets the child finish.
private final class OutputPump: @unchecked Sendable {
  private let lock = NSLock()
  private var pending = Data()
  private var notify: (@Sendable () -> Void)?
  private var notifyArmed = false
  private let limit: Int
  private let tailBytes: Int

  init(limit: Int, tailBytes: Int) {
    self.limit = limit
    self.tailBytes = tailBytes
  }

  func arm(_ notify: @escaping @Sendable () -> Void) {
    lock.lock()
    self.notify = notify
    lock.unlock()
  }

  func append(_ data: Data) {
    guard !data.isEmpty else { return }
    lock.lock()
    if pending.count >= limit {
      pending = Data(pending.suffix(tailBytes))
    }
    pending.append(data)
    if pending.count > limit {
      pending = Data(pending.suffix(limit))
    }
    let shouldNotify = !notifyArmed
    if shouldNotify { notifyArmed = true }
    let notify = shouldNotify ? self.notify : nil
    lock.unlock()
    notify?()
  }

  func take() -> Data {
    lock.lock()
    let data = pending
    pending.removeAll(keepingCapacity: true)
    lock.unlock()
    return data
  }

  /// Pulls a late burst. Nil means the pump is empty and the next append must wake the UI.
  func takeOrDisarm() -> Data? {
    lock.lock()
    defer { lock.unlock() }
    if !pending.isEmpty {
      let data = pending
      pending.removeAll(keepingCapacity: true)
      return data
    }
    notifyArmed = false
    return nil
  }

  var hasPending: Bool {
    lock.lock()
    defer { lock.unlock() }
    return !pending.isEmpty
  }
}

/// A session outlives its representable, preserving the emulator when tabs change.
@MainActor @Observable
public final class ConsoleSession: NSObject, TerminalViewDelegate {
  public private(set) var sessionID: SessionID?
  public private(set) var status: AgentStatus = .running
  /// Shell exit status once the process has been reaped. Nil while it is still running.
  public private(set) var exitCode: Int32?
  public private(set) var isRunning = false
  /// Directory passed to the process. Empty until start, and unchanged if the shell later moves.
  public private(set) var launchedWorkingDirectory: String?
  public private(set) var failureMessage: String?
  public private(set) var hasFinished = false
  @ObservationIgnored var onSelect: ((Bool) -> Void)?
  @ObservationIgnored var onFocus: ((Bool) -> Void)?
  @ObservationIgnored var onStatusTransition: ((AgentStatus) -> Void)?
  @ObservationIgnored var onOutput: ((String) -> Void)?
  @ObservationIgnored private let supervisor: ProcessSupervisor
  @ObservationIgnored private var terminal: FocusTerminalView?
  @ObservationIgnored private var pendingOutput = Data()
  @ObservationIgnored private var launchTask: Task<Void, Never>?
  @ObservationIgnored private var eventTask: Task<Void, Never>?
  @ObservationIgnored private var writeTask: Task<Void, Never>?
  @ObservationIgnored private var terminalFlushTask: Task<Void, Never>?
  @ObservationIgnored private var terminalFlushGeneration = 0
  /// Bytes waiting for status, loops, and the recent-output tail. Separate from the view so a card can attach late.
  @ObservationIgnored private var publishBacklog = Data()
  /// Bytes waiting for SwiftTerm. Capped so a redraw storm cannot be parsed a megabyte at a time.
  @ObservationIgnored private var terminalFeedBacklog = Data()
  @ObservationIgnored private var closed = false
  @ObservationIgnored private var statusHeuristics = StatusHeuristics()
  /// Command text submitted with Enter. While the current row still shows it, the shell is running that command.
  @ObservationIgnored private var blockingCommand: String?
  @ObservationIgnored private var outputText = ""
  /// Total bytes seen. The retained tail is capped, so this is the signal that new output arrived.
  @ObservationIgnored private(set) var outputByteCount = 0
  var recentOutput: Data { Data(outputText.utf8) }
  @ObservationIgnored private var idleTask: Task<Void, Never>?
  @ObservationIgnored private(set) var hookSessionID: String?
  @ObservationIgnored private var ptyColumns: UInt16?
  @ObservationIgnored private var ptyRows: UInt16?
  @ObservationIgnored private var ptyResizeGeneration = 0
  @ObservationIgnored private var didSendPtySize = false
  private let terminalFlushInterval: Duration = .milliseconds(16)
  /// One frame of parsing. A larger slice of line-heavy output stalls the main thread inside SwiftTerm.
  private let terminalFlushBatchBytes = 4_096
  /// `yes` is one newline per two bytes. Cap those so a frame scrolls about one screen, not thousands of lines.
  private let terminalFlushMaxNewlines = 24
  /// One coalesced PTY chunk is 16 KiB. At or above this, the card jumps to the newest screen instead of replaying the burst.
  private let terminalLiveTailBytes = 8_192
  /// Hard cap so a burst cannot retain an unbounded queue between frames.
  private let terminalFeedBacklogLimit = 262_144
  @ObservationIgnored private let outputPump = OutputPump(limit: 262_144, tailBytes: 4_096)

  init(supervisor: ProcessSupervisor) {
    self.supervisor = supervisor
    super.init()
    outputPump.arm { [weak self] in
      Task { @MainActor in
        self?.scheduleTerminalFlush()
      }
    }
  }

  var isClosed: Bool { closed }

  func receive(hook event: AgentEvent) {
    guard isRunning, event.agent == agentID,
      event.sessionID == nil || hookSessionID == nil || event.sessionID == hookSessionID
    else { return }
    if let id = event.sessionID { hookSessionID = id }
    idleTask?.cancel()
    switch event.event {
    case .sessionStart, .preToolUse, .postToolUse, .postToolUseFailure:
      setStatus(.running)
    case .permissionRequest, .notification:
      setStatus(.waitingForInput)
    case .stop, .sessionEnd:
      setStatus(.idle)
    case .subagentStop:
      break
    }
  }
  private var agentID: String { sessionAgentID ?? "" }
  @ObservationIgnored private var sessionAgentID: String?
  @ObservationIgnored private var sessionCWD: String?
  func matches(hook event: AgentEvent) -> Bool {
    guard isRunning, event.agent == agentID else { return false }
    if let eventSessionID = event.sessionID, let hookSessionID, eventSessionID != hookSessionID { return false }
    if let cwd = event.cwd, URL(fileURLWithPath: cwd).standardizedFileURL.path != sessionCWD { return false }
    return true
  }

  func start(spec: ProcessSpec) async {
    sessionAgentID = URL(fileURLWithPath: spec.executable).lastPathComponent
    let directory = spec.workingDirectory.standardizedFileURL.path
    sessionCWD = directory
    launchedWorkingDirectory = directory
    launchTask = Task { [weak self, supervisor] in
      do {
        let started = try await supervisor.start(spec: spec)
        guard let self else {
          await supervisor.terminate(started.id, gracePeriod: .zero)
          for await _ in started.events {}
          await supervisor.discardScrollback(for: started.id)
          return
        }
        self.connect(started)
      } catch {
        self?.failureMessage = error.localizedDescription
        self?.setStatus(.error)
        self?.hasFinished = true
      }
    }
    await launchTask?.value
  }

  private func connect(_ session: StartedProcessSession) {
    sessionID = session.id
    isRunning = true
    exitCode = nil
    if let terminal { pushTerminalSize(of: terminal, coalesce: false) }
    let pump = outputPump
    let supervisor = supervisor
    let sessionID = session.id
    // Output is copied into the pump without hopping to the main actor. Painting stays on the frame timer.
    eventTask = Task.detached { [weak self] in
      for await event in session.events {
        switch event {
        case .output(let data):
          pump.append(data)
        case .failed, .exited:
          await self?.receive(event)
        }
      }
      let discard = await self?.noteEventStreamEnded() ?? true
      if discard { await supervisor.discardScrollback(for: sessionID) }
    }
  }

  private func noteEventStreamEnded() -> Bool {
    isRunning = false
    hasFinished = true
    return closed
  }

  private func receive(_ event: ProcessEvent) {
    switch event {
    case .output(let data):
      // Keep this path to byte copies. String decoding and SwiftTerm parsing run on the frame timer.
      appendCapped(data, to: &publishBacklog, limit: terminalFeedBacklogLimit)
      if terminal == nil {
        appendCapped(data, to: &pendingOutput, limit: terminalFeedBacklogLimit)
      } else {
        appendCapped(data, to: &terminalFeedBacklog, limit: terminalFeedBacklogLimit)
      }
      scheduleTerminalFlush()
    case .failed(let message):
      failureMessage = message
      idleTask?.cancel()
      setStatus(.error)
    case .exited(let code, _):
      isRunning = false
      exitCode = code
      idleTask?.cancel()
      if failureMessage == nil { setStatus(code == 0 ? .finished : .error) }
    }
  }

  private func appendHeuristicText(_ data: Data) {
    outputByteCount += data.count
    outputText.append(String(decoding: data, as: UTF8.self))
    if outputText.count > 16_384 { outputText = String(outputText.suffix(16_384)) }
  }

  private func scheduleIdleCheck() {
    idleTask?.cancel()
    idleTask = Task { [weak self] in
      // A hair past the heuristic quiet period so the timer cannot wake early and leave the light stuck on Working.
      try? await Task.sleep(for: .milliseconds(2200))
      guard !Task.isCancelled, let self, self.isRunning, self.exitCode == nil else { return }
      self.applyInferredStatus()
    }
  }

  private func appendCapped(_ data: Data, to buffer: inout Data, limit: Int) {
    guard limit > 0, !data.isEmpty else { return }
    // Already at the cap: keep one frame of the tail, then this chunk. Copying the whole queue on every read would stall the main thread.
    if buffer.count >= limit {
      buffer = Data(buffer.suffix(terminalFlushBatchBytes))
    }
    buffer.append(data)
    if buffer.count > limit {
      buffer = Data(buffer.suffix(limit))
    }
  }

  private var hasPendingTerminalWork: Bool {
    !publishBacklog.isEmpty || !terminalFeedBacklog.isEmpty || (terminal != nil && !pendingOutput.isEmpty)
  }

  private func scheduleTerminalFlush() {
    guard terminalFlushTask == nil else { return }
    terminalFlushGeneration += 1
    let generation = terminalFlushGeneration
    terminalFlushTask = Task { @MainActor [weak self] in
      guard let self else { return }
      while !Task.isCancelled, !self.closed {
        self.flushTerminalBatch()
        if self.hasPendingTerminalWork {
          // One slice per frame, then let input and drawing run before the next parse.
          try? await Task.sleep(for: self.terminalFlushInterval)
          await Task.yield()
          continue
        }
        if let late = self.outputPump.takeOrDisarm() {
          self.absorb(late)
          continue
        }
        break
      }
      // Append can arm while this task still owns the slot, so that wake is ignored.
      // Release the slot, then start again if those bytes are already waiting.
      guard self.terminalFlushGeneration == generation else { return }
      self.terminalFlushTask = nil
      if !self.closed, self.outputPump.hasPending {
        self.scheduleTerminalFlush()
      }
    }
  }

  private func flushTerminalBatch() {
    absorb(outputPump.take())
    publishNext(&publishBacklog)
    guard let terminal else { return }
    if !pendingOutput.isEmpty {
      appendCapped(pendingOutput, to: &terminalFeedBacklog, limit: terminalFeedBacklogLimit)
      pendingOutput.removeAll(keepingCapacity: false)
    }
    let batch = nextFrame(&terminalFeedBacklog)
    guard !batch.isEmpty else { return }
    terminal.feed(byteArray: [UInt8](batch)[...])
  }

  private func publishNext(_ buffer: inout Data) {
    let batch = nextFrame(&buffer)
    guard !batch.isEmpty else { return }
    publishOutput(batch)
  }

  /// Returns the next slice to draw. A backlog past one burst jumps to its newest screen so the prompt is not stuck behind old lines.
  private func nextFrame(_ buffer: inout Data) -> Data {
    guard !buffer.isEmpty else { return Data() }
    if buffer.count >= terminalLiveTailBytes {
      let tail = liveTail(buffer)
      buffer.removeAll(keepingCapacity: true)
      return tail
    }
    let count = frameByteCount(buffer)
    let batch = Data(buffer.prefix(count))
    buffer.removeFirst(count)
    return batch
  }

  private func liveTail(_ data: Data) -> Data {
    let rowBudget = min(max(terminal?.terminalDimensions.rows ?? terminalFlushMaxNewlines, 1), 48)
    let bytes = [UInt8](data.suffix(terminalFlushBatchBytes))
    guard !bytes.isEmpty else { return Data() }
    var newlines = 0
    var start = 0
    var index = bytes.count
    while index > 0 {
      index -= 1
      if bytes[index] == 10 {
        newlines += 1
        if newlines > rowBudget {
          start = index + 1
          break
        }
      }
    }
    // A cursor-addressed redraw has no newlines. Start at ESC so the parser is not mid-sequence.
    if newlines == 0, let escape = bytes.lastIndex(of: 0x1b) {
      start = escape
    }
    return Data(bytes[start...])
  }

  private func frameByteCount(_ data: Data) -> Int {
    let limit = min(terminalFlushBatchBytes, data.count)
    var newlines = 0
    var index = 0
    for byte in data.prefix(limit) {
      index += 1
      if byte == 10 {
        newlines += 1
        if newlines >= terminalFlushMaxNewlines { return index }
      }
    }
    return max(index, limit == 0 ? 0 : limit)
  }

  private func absorb(_ data: Data) {
    guard !data.isEmpty else { return }
    appendCapped(data, to: &publishBacklog, limit: terminalFeedBacklogLimit)
    if terminal == nil {
      appendCapped(data, to: &pendingOutput, limit: terminalFeedBacklogLimit)
    } else {
      appendCapped(data, to: &terminalFeedBacklog, limit: terminalFeedBacklogLimit)
    }
  }

  private func publishOutput(_ data: Data) {
    appendHeuristicText(data)
    onOutput?(String(decoding: data, as: UTF8.self))
    // Trailing bytes can arrive after the exit event. They must not paint a dead process as Working.
    guard isRunning, exitCode == nil else { return }
    statusHeuristics.receivedOutput()
    applyInferredStatus()
    if status == .running {
      scheduleIdleCheck()
    } else {
      idleTask?.cancel()
    }
  }

  private func applyInferredStatus() {
    guard isRunning, exitCode == nil else { return }
    switch statusHeuristics.infer(from: outputText, blockingCommand: blockingCommand) {
    case .running: setStatus(.running)
    case .waitingForInput: setStatus(.waitingForInput)
    case .idle:
      blockingCommand = nil
      setStatus(.idle)
    }
  }

  /// Text of the command just submitted. A bare Enter uses the row already on screen.
  private func submittedCommand(in bytes: Data) -> String {
    let text = String(decoding: bytes, as: UTF8.self)
    let piece = text.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).first.map(String.init) ?? ""
    let typed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
    if !typed.isEmpty { return String(typed.prefix(200)) }
    let line = StatusHeuristics.visibleTailLine(outputText).trimmingCharacters(in: .whitespacesAndNewlines)
    return String(line.prefix(200))
  }

  func setStatus(_ newStatus: AgentStatus) {
    guard status != newStatus else { return }
    let oldStatus = status
    status = newStatus
    onStatusTransition?(oldStatus)
  }

  func setRunningForTesting(_ running: Bool) { isRunning = running }

  func terminalView() -> FocusTerminalView {
    TerminalPasteShortcuts.install()
    if let terminal { return terminal }
    let view = FocusTerminalView(
      frame: NSRect(x: 0, y: 0, width: 480, height: 279),
      font: Typography.terminalNSFont)
    view.terminalDelegate = self
    view.onFocus = { [weak self] in self?.onFocus?($0) }
    view.onSelect = { [weak self] in self?.onSelect?($0) }
    view.applyPalette()
    if !pendingOutput.isEmpty {
      appendCapped(pendingOutput, to: &terminalFeedBacklog, limit: terminalFeedBacklogLimit)
      pendingOutput.removeAll(keepingCapacity: false)
    }
    terminal = view
    if hasPendingTerminalWork {
      scheduleTerminalFlush()
    }
    // The view sized its grid during init, before this delegate existed.
    // The PTY is still the launch size until we tell it.
    pushTerminalSize(of: view, coalesce: false)
    return view
  }

  func currentGrid() -> (columns: Int, rows: Int)? {
    guard let terminal else { return nil }
    let size = terminal.terminalDimensions
    guard size.cols > 0, size.rows > 0 else { return nil }
    return (size.cols, size.rows)
  }

  public func send(_ bytes: Data) {
    guard isRunning, let id = sessionID else { return }
    if bytes.contains(0x0d) || bytes.contains(0x0a) {
      blockingCommand = submittedCommand(in: bytes)
    }
    idleTask?.cancel()
    setStatus(.running)
    let previous = writeTask
    writeTask = Task { [weak self, supervisor] in
      await previous?.value
      do { try await supervisor.write(bytes, to: id) } catch {
        guard self?.isRunning == true else { return }
        self?.failureMessage = error.localizedDescription
        self?.setStatus(.error)
      }
    }
  }

  func close() async {
    closed = true
    idleTask?.cancel()
    terminalFlushTask?.cancel()
    await launchTask?.value
    guard let id = sessionID else { return }
    await supervisor.terminate(id)
    await eventTask?.value
    await supervisor.discardScrollback(for: id)
  }

  public func send(source: SwiftTerm.TerminalView, data: ArraySlice<UInt8>) { send(Data(data)) }
  public func sizeChanged(source: SwiftTerm.TerminalView, newCols: Int, newRows: Int) {
    // A card drag is not a window live-resize, so SwiftTerm reports every step.
    // The first size is applied immediately; later steps collapse to the latest grid.
    noteTerminalSize(columns: newCols, rows: newRows, coalesce: true)
  }

  private func pushTerminalSize(of view: FocusTerminalView, coalesce: Bool) {
    let size = view.terminalDimensions
    noteTerminalSize(columns: size.cols, rows: size.rows, coalesce: coalesce)
  }

  private func noteTerminalSize(columns: Int, rows: Int, coalesce: Bool) {
    guard let id = sessionID, isRunning, columns > 0, rows > 0 else { return }
    let cols = UInt16(clamping: columns)
    let rowCount = UInt16(clamping: rows)
    guard ptyColumns != cols || ptyRows != rowCount else { return }
    ptyColumns = cols
    ptyRows = rowCount
    ptyResizeGeneration += 1
    let generation = ptyResizeGeneration
    let wait = coalesce && didSendPtySize
    didSendPtySize = true
    Task { [weak self, supervisor] in
      if wait { try? await Task.sleep(for: .milliseconds(40)) }
      guard let self, generation == self.ptyResizeGeneration, self.isRunning, !self.closed else { return }
      do {
        try await supervisor.resize(cols, rowCount, for: id)
      } catch {
        guard generation == self.ptyResizeGeneration, self.isRunning, !self.closed else { return }
        if self.ptyColumns == cols, self.ptyRows == rowCount {
          self.ptyColumns = nil
          self.ptyRows = nil
        }
        self.failureMessage = error.localizedDescription
      }
    }
  }
  public func setTerminalTitle(source: SwiftTerm.TerminalView, title: String) {}
  public func hostCurrentDirectoryUpdate(source: SwiftTerm.TerminalView, directory: String?) {}
  public func scrolled(source: SwiftTerm.TerminalView, position: Double) {}
  public func rangeChanged(source: SwiftTerm.TerminalView, startY: Int, endY: Int) {}
}

/// Command-V is delivered to SwiftUI commands before an embedded terminal can see it.
/// A focused terminal pastes here, and only when the program has not claimed the Command key.
@MainActor
enum TerminalPasteShortcuts {
  private static var installed = false

  static func install() {
    guard !installed else { return }
    installed = true
    NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
      handle(event)
    }
  }

  /// Pastes when this event is Command-V aimed at a focused terminal that has not claimed Command.
  /// Returns nil when the event was consumed.
  static func handle(_ event: NSEvent) -> NSEvent? {
    guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
      event.charactersIgnoringModifiers?.lowercased() == "v",
      let window = event.window,
      let terminal = window.firstResponder as? FocusTerminalView,
      terminal.keyboardEnhancementFlags.isEmpty
    else { return event }
    terminal.paste(terminal)
    return nil
  }
}

final class FocusTerminalView: SwiftTerm.TerminalView {
  var onFocus: ((Bool) -> Void)?
  var onSelect: ((Bool) -> Void)?
  override func mouseDown(with event: NSEvent) {
    let extending = event.modifierFlags.contains(.shift)
    onSelect?(extending)
    if extending {
      window?.makeFirstResponder(self)
    } else {
      super.mouseDown(with: event)
    }
  }
  override var hasFocus: Bool {
    get { super.hasFocus }
    set {
      super.hasFocus = newValue
      onFocus?(newValue)
    }
  }
  func applyPalette() {
    nativeBackgroundColor = NSColor(Palette.surface)
    nativeForegroundColor = NSColor(Palette.ink)
  }
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    applyPalette()
  }
}

struct ConsoleTerminal: NSViewRepresentable {
  let session: ConsoleSession
  func makeNSView(context: Context) -> TerminalHostView {
    TerminalHostView(terminal: session.terminalView())
  }
  func updateNSView(_ host: TerminalHostView, context: Context) {
    host.show(session.terminalView())
    host.syncTerminalFrame()
  }
  func sizeThatFits(_ proposal: ProposedViewSize, nsView: TerminalHostView, context: Context) -> CGSize? {
    let width = proposal.width ?? nsView.bounds.width
    let height = proposal.height ?? nsView.bounds.height
    guard width.isFinite, height.isFinite, width > 1, height > 1 else { return nil }
    return CGSize(width: width, height: height)
  }
}

/// SwiftUI sizes this host. The terminal fills it, which is what changes the PTY grid.
final class TerminalHostView: NSView {
  private(set) var terminal: FocusTerminalView

  init(terminal: FocusTerminalView) {
    self.terminal = terminal
    super.init(frame: terminal.frame)
    terminal.autoresizingMask = [.width, .height]
    addSubview(terminal)
  }

  /// A restarted session owns a new terminal. Swap it in when SwiftUI reuses this host.
  func show(_ terminal: FocusTerminalView) {
    guard terminal !== self.terminal else { return }
    self.terminal.removeFromSuperview()
    terminal.autoresizingMask = [.width, .height]
    addSubview(terminal)
    self.terminal = terminal
    needsLayout = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { nil }

  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
  }

  override func layout() {
    super.layout()
    syncTerminalFrame()
  }

  func syncTerminalFrame() {
    let size = bounds.size
    guard size.width > 1, size.height > 1 else { return }
    guard abs(terminal.frame.width - size.width) > 0.5 || abs(terminal.frame.height - size.height) > 0.5 else { return }
    terminal.setFrameSize(size)
  }
}
