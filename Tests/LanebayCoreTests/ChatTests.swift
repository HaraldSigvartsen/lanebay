import XCTest
@testable import LanebayCore

final class ChatTests: XCTestCase {
  private let a = UUID(), b = UUID(), c = UUID()

  func testSlugFoldsNordicLettersAndDiacritics() {
    XCTAssertEqual(TerminalHandle.slug("Utvikler"), "utvikler")
    XCTAssertEqual(TerminalHandle.slug("Kode Ørn 2"), "kode-orn-2")
    XCTAssertEqual(TerminalHandle.slug("  Blåbærsyltetøy  "), "blabaersyltetoy")
    XCTAssertEqual(TerminalHandle.slug("Café – déjà vu"), "cafe-deja-vu")
    XCTAssertEqual(TerminalHandle.slug("---"), "terminal")
    XCTAssertEqual(TerminalHandle.slug(""), "terminal")
  }

  func testUniqueNamesAppendNumbersUntilTheHandleIsFree() {
    XCTAssertEqual(TerminalNames.unique("  Utvikler  ", existing: []), "Utvikler")
    XCTAssertEqual(TerminalNames.unique("", existing: ["a"]), "Terminal")
    XCTAssertEqual(TerminalNames.unique("Kode Ørn 2", existing: ["Kode Ørn 2"]), "Kode Ørn 2 2")
    // Handles, not titles, decide a clash.
    XCTAssertEqual(TerminalNames.unique("Kode-Ørn", existing: ["kode orn"]), "Kode-Ørn 2")
    XCTAssertEqual(TerminalNames.unique("Plan", existing: ["Plan", "Plan 2", "plan-3"]), "Plan 4")
  }

  func testParseRemovesKnownHandlesAndKeepsTargetOrder() {
    let handles = ["utvikler": a, "plan": b, "kode-orn-2": c]
    let result = ChatMentions.parse("@Plan og @utvikler: se på @plan og @Kode Ørn 2", handles: handles)
    // "@Kode" is not a handle; "Ørn 2" are plain words.
    XCTAssertEqual(result.targets, [b, a])
    XCTAssertEqual(result.body, "og : se på og @Kode Ørn 2")
    XCTAssertEqual(result.unknown, ["kode"])
    XCTAssertFalse(result.all)

    let single = ChatMentions.parse("Hei @utvikler, kjør testene", handles: handles)
    XCTAssertEqual(single.targets, [a])
    XCTAssertEqual(single.body, "Hei , kjør testene")

    let dotted = ChatMentions.parse("se @kode-orn-2", handles: handles)
    XCTAssertEqual(dotted.targets, [c])
    XCTAssertEqual(dotted.body, "se")
  }

  func testParseHandlesAllUnknownAndEmbeddedAt() {
    let handles = ["utvikler": a, "plan": b]
    let all = ChatMentions.parse("@alle: status?", handles: handles)
    XCTAssertTrue(all.all)
    XCTAssertEqual(all.targets, [])
    XCTAssertEqual(all.body, ": status?")

    XCTAssertTrue(ChatMentions.parse("@all status", handles: handles).all)

    let unknown = ChatMentions.parse("hei @spøkelse og @Utvikler", handles: handles)
    XCTAssertEqual(unknown.targets, [a])
    XCTAssertEqual(unknown.unknown, ["spokelse"])
    XCTAssertTrue(unknown.body.contains("@spøkelse"))
    XCTAssertTrue(unknown.body.contains("og"))

    // An @ inside a word is an address, not a mention.
    let email = ChatMentions.parse("send til e-mail@x.no", handles: handles)
    XCTAssertEqual(email.targets, [])
    XCTAssertEqual(email.unknown, [])
    XCTAssertEqual(email.body, "send til e-mail@x.no")

    // Duplicates target once and are all removed.
    let duplicate = ChatMentions.parse("@utvikler og @Utvikler", handles: handles)
    XCTAssertEqual(duplicate.targets, [a])
    XCTAssertEqual(duplicate.body, "og")
  }

  func testActiveQueryAndComplete() throws {
    let text = "hei @utv"
    let active = try XCTUnwrap(ChatMentions.activeQuery(in: text, cursor: text.count))
    XCTAssertEqual(active.range, 4..<8)
    XCTAssertEqual(active.query, "utv")

    let bare = try XCTUnwrap(ChatMentions.activeQuery(in: "hei @", cursor: 5))
    XCTAssertEqual(bare.range, 4..<5)
    XCTAssertEqual(bare.query, "")

    XCTAssertNil(ChatMentions.activeQuery(in: "hei @utv", cursor: 3))
    XCTAssertNil(ChatMentions.activeQuery(in: "e-post@x", cursor: 8))
    XCTAssertNil(ChatMentions.activeQuery(in: "hei", cursor: 3))

    XCTAssertEqual(ChatMentions.complete(text, range: active.range, handle: "utvikler"), "hei @utvikler ")
    XCTAssertEqual(ChatMentions.complete("a @p b", range: 2..<4, handle: "plan"), "a @plan  b")
  }

  func testOutputDigestStripsANSIAndShellNoiseAndExtractsSteps() {
    let raw = """
      \u{1B}[32mexport PAGER=cat GIT_PAGER=cat; clear\u{1B}[0m
      __lb_hook arming precmd_functions
      export PAGER=cat GIT_PAGER=cat; make test

      \u{1B}[1m❯ swift test\u{1B}[0m
      Building for debugging...
      Ran 12 tests
      \u{1B}[32m✓ 12 tests passed\u{1B}[0m
      Edited Sources/Foo.swift
      All green.
      """
    let digest = OutputDigest.make(raw: raw, sent: "export PAGER=cat GIT_PAGER=cat; make test")
    XCTAssertEqual(digest.steps, ["swift test", "Ran 12 tests", "12 tests passed", "Edited Sources/Foo.swift"])
    XCTAssertFalse(digest.steps.joined().contains("\u{1B}"))
    XCTAssertEqual(digest.reply, "Building for debugging...\nAll green.")
    XCTAssertFalse(digest.truncated)
  }

  func testOutputDigestTruncatesAndDropsPromptChrome() {
    let raw = """
      ~/Code/lanebay -> ❯
      line one
      line two
      line three
      line four
      """
    let digest = OutputDigest.make(raw: raw, maxReplyLines: 2)
    XCTAssertEqual(digest.steps, [])
    XCTAssertEqual(digest.reply, "line three\nline four")
    XCTAssertTrue(digest.truncated)
  }

  func testOutputDigestCapsStepLengthAndCount() {
    let long = "$ " + String(repeating: "x", count: 200)
    let raw = (0..<15).map { "Ran step \($0)" }.joined(separator: "\n") + "\n" + long
    let digest = OutputDigest.make(raw: raw)
    XCTAssertEqual(digest.steps.count, 12)
    XCTAssertEqual(digest.steps.last?.count, 120)
    XCTAssertTrue(digest.steps.last?.hasSuffix("…") ?? false)
    XCTAssertEqual(digest.reply, "")
  }

  func testChatEntryDecodesLegacyJSONAndRoundTrips() throws {
    let id = UUID()
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let json = """
      {"id":"\(id.uuidString)","date":\(date.timeIntervalSinceReferenceDate),"kind":"user","text":"hei"}
      """
    let entry = try JSONDecoder().decode(ChatEntry.self, from: Data(json.utf8))
    XCTAssertEqual(entry.id, id)
    XCTAssertEqual(entry.kind, .user)
    XCTAssertEqual(entry.text, "hei")
    XCTAssertEqual(entry.targets, [])
    XCTAssertNil(entry.from)
    XCTAssertNil(entry.to)
    XCTAssertEqual(entry.steps, [])
    XCTAssertFalse(entry.truncated)

    let full = ChatEntry(kind: .wire, text: "svar", targets: [a], from: a, to: b, steps: ["Ran ls"], truncated: true)
    let decoded = try JSONDecoder().decode(ChatEntry.self, from: JSONEncoder().encode(full))
    XCTAssertEqual(decoded, full)
  }

  func testDigestDropsPromptRedrawsAndEchoedCommand() {
    let raw = "%\r\n❯ ~=) ~) ~echo status ok>\r\n39mstatus ok>\r\nstatus ok\r\n%\r\n❯ ~=) ~) ~\r\n"
    let digest = OutputDigest.make(raw: raw, sent: "echo status ok")
    XCTAssertEqual(digest.reply, "status ok")
    XCTAssertEqual(digest.steps, ["$ echo status ok"])
  }
}
