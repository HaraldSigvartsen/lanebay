import SwiftUI
import XCTest

@testable import LanebayUI

final class CardStatusStyleTests: XCTestCase {
  func testRunningPulsesAndGlows() {
    XCTAssertTrue(CardStatusStyle.pulses(.running))
    XCTAssertTrue(CardStatusStyle.glows(.running))
  }

  func testStoppedNeitherPulsesNorGlows() {
    XCTAssertFalse(CardStatusStyle.pulses(.stopped))
    XCTAssertFalse(CardStatusStyle.glows(.stopped))
    XCTAssertFalse(CardStatusStyle.pulses(.finished))
    XCTAssertFalse(CardStatusStyle.pulses(.waitingForInput))
    XCTAssertFalse(CardStatusStyle.pulses(.error))
    XCTAssertTrue(CardStatusStyle.glows(.error))
  }

  func testEveryStatusHasATint() {
    var seen = Set<String>()
    for status in AgentStatus.allCases {
      let color = NSColor(CardStatusStyle.tint(for: status)).usingColorSpace(.sRGB)
      XCTAssertNotNil(color, "\(status) has no tint")
      seen.insert("\(color?.redComponent ?? -1)/\(color?.greenComponent ?? -1)/\(color?.blueComponent ?? -1)")
    }
    XCTAssertEqual(seen.count, AgentStatus.allCases.count, "every status should read as its own tint")
  }
}
