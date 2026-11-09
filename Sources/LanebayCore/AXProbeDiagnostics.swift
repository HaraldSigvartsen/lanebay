import Foundation

/// Evidence line for the flow self-test: what an accessibility press saw.
/// Pure formatting so the report shape stays pinned by unit tests.
public enum AXProbeDiagnostics {
  public struct Sample: Sendable, Equatable {
    public var target: String
    public var childrenError: Int
    public var windowsError: Int
    public var windowCount: Int
    public var walked: Int
    public var matched: Bool
    public var actionStatuses: [Int]
    public var trace: [String]
    /// Whether the walk ran on the main thread. A same-process AX attribute
    /// fetch executes inline on the calling thread, and SwiftUI/AppKit
    /// accessibility nodes are main-thread-confined, so an off-main walk
    /// races the main thread's node teardown — the 2026-10-28 crash class
    /// (SIGSEGV, pointer-authentication failure inside
    /// AccessibilityNode.accessibilityIdentifier). `main=0` is that
    /// regression signature and always carries the element trace.
    public var mainThread: Bool

    public init(
      target: String,
      childrenError: Int,
      windowsError: Int,
      windowCount: Int,
      walked: Int,
      matched: Bool,
      actionStatuses: [Int],
      trace: [String],
      mainThread: Bool
    ) {
      self.target = target
      self.childrenError = childrenError
      self.windowsError = windowsError
      self.windowCount = windowCount
      self.walked = walked
      self.matched = matched
      self.actionStatuses = actionStatuses
      self.trace = trace
      self.mainThread = mainThread
    }

    public var pressed: Bool { actionStatuses.contains(0) }

    /// Whether this sample needs the element trace: an off-main walk (the
    /// crash class above), a structural outage (children/windows error,
    /// empty walk, no match), or an action failure the chronic rail quirk
    /// cannot explain. The chronic quirk reports
    /// kAXErrorActionFailed (-25205) while the picker still opens, so a
    /// matched -25205 is healthy and stays scalar-only.
    var traceWarranted: Bool {
      if !mainThread { return true }
      if !matched || walked == 0 || childrenError != 0 || windowsError != 0 { return true }
      return !pressed && actionStatuses != [-25205]
    }

    /// Scalars always; the element trace only for off-main walks, outages,
    /// and unexplained action failures, so healthy baselines — including
    /// the chronic -25205 rail quirk — stay free of per-run UUID noise.
    public var reportLine: String {
      var parts: [String] = [
        "ax.state(\(target))",
        "childrenErr=\(childrenError)",
        "windowsErr=\(windowsError)",
        "windows=\(windowCount)",
        "seen=\(walked)",
        "match=\(matched ? 1 : 0)",
        "actions=\(actionStatuses.map(String.init).joined(separator: ","))",
        "main=\(mainThread ? 1 : 0)",
      ]
      if traceWarranted {
        parts.append("trace=\(trace.prefix(12).joined(separator: "|"))")
      }
      return parts.joined(separator: " ")
    }
  }
}
