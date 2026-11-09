import LanebayCore
import SwiftUI
import XCTest

@testable import LanebayUI

final class OnboardingCardTests: XCTestCase {
  func testShowsWithoutAWorkspace() {
    XCTAssertTrue(OnboardingCard.shouldShow(workspace: nil))
  }

  func testShowsForAWorkspaceWithoutNodes() {
    XCTAssertTrue(OnboardingCard.shouldShow(workspace: Workspace(name: "Empty")))
  }

  func testHidesOnceTheBoardHasANode() {
    let node = Node(
      kind: .console, agentID: "shell", cwd: URL(fileURLWithPath: "/tmp"),
      frame: NodeFrame(x: 0, y: 0, w: 480, h: 320), title: "Shell")
    XCTAssertFalse(
      OnboardingCard.shouldShow(workspace: Workspace(name: "Working", nodes: [node])))
  }

  func testCardStatusUsesTheStatusKindMapping() {
    XCTAssertEqual(AgentStatus.running.statusKind, .running)
    XCTAssertEqual(AgentStatus.waitingForInput.statusKind, .waiting)
    XCTAssertEqual(AgentStatus.idle.statusKind, .done)
    XCTAssertEqual(AgentStatus.stopped.statusKind, .stopped)
    XCTAssertEqual(AgentStatus.finished.statusKind, .done)
    XCTAssertEqual(AgentStatus.error.statusKind, .error)
  }

  func testCardTintFollowsTheDesignSystemStatusColours() {
    for status in AgentStatus.allCases where status != .idle {
      XCTAssertEqual(
        srgb(CardStatusStyle.tint(for: status)), srgb(DS.Color.status(status.statusKind)),
        "\(status) should use its design-system status colour")
    }
  }

  private func srgb(_ color: Color) -> String {
    guard let resolved = NSColor(color).usingColorSpace(.sRGB) else { return "unresolved" }
    return "\(resolved.redComponent)/\(resolved.greenComponent)/\(resolved.blueComponent)"
  }
}
