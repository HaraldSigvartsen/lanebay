import LanebayCore
import XCTest

@testable import LanebayUI

final class ProviderStyleTests: XCTestCase {
  func testEveryFeaturedAgentHasASymbolOrMonogram() {
    for id in NewTerminalDraft.featuredAgentIDs {
      let style = ProviderStyle.style(for: id)
      XCTAssertTrue(
        style.symbol != nil || style.monogram != nil,
        "\(id) has neither an SF Symbol nor a monogram")
      XCTAssertFalse(style.colors.isEmpty, "\(id) has no badge colors")
    }
  }

  func testKnownProvidersUseTheirOwnStyle() {
    let claude = ProviderStyle.style(for: "claude")
    XCTAssertEqual(claude.symbol, "sparkle")
    XCTAssertEqual(claude.colors, [0xD97757, 0xB4532A])

    let freebuff = ProviderStyle.style(for: "freebuff")
    XCTAssertNil(freebuff.symbol)
    XCTAssertEqual(freebuff.monogram, "FB")
    XCTAssertEqual(freebuff.colors, [0x22C55E, 0x0EA5E9])
  }

  func testUnknownAgentFallsBackToCustomStyle() {
    let custom = ProviderStyle.style(for: "my-custom-agent")
    XCTAssertEqual(custom.symbol, "gearshape.2")
    XCTAssertNil(custom.monogram)
    XCTAssertEqual(custom.colors, [0x64748B, 0x475569])
    XCTAssertEqual(custom.colors.count, ProviderStyle.style(for: "").colors.count)
  }
}
