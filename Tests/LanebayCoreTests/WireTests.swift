import XCTest
@testable import LanebayCore

final class WireTests: XCTestCase {
  private let a = UUID(), b = UUID(), c = UUID()

  func testWireRoundTripsAndOldWorkspaceFilesStillOpen() throws {
    let wire = Wire(from: a, to: b, direction: .twoWay, mode: .everyReply, instruction: "se over", enabled: false)
    let workspace = Workspace(name: "W", wires: [wire])
    let data = try JSONEncoder().encode(workspace)
    let decoded = try JSONDecoder().decode(Workspace.self, from: data)
    XCTAssertEqual(decoded.wires, [wire])

    var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object.removeValue(forKey: "wires")
    let legacy = try JSONDecoder().decode(Workspace.self, from: JSONSerialization.data(withJSONObject: object))
    XCTAssertEqual(legacy.wires, [])
    XCTAssertEqual(legacy.name, "W")
  }

  func testWireWithOnlyEndsDecodesWithDefaults() throws {
    let json = #"{"id":"\#(UUID().uuidString)","from":"\#(a.uuidString)","to":"\#(b.uuidString)"}"#
    let wire = try JSONDecoder().decode(Wire.self, from: Data(json.utf8))
    XCTAssertEqual(wire.direction, .oneWay)
    XCTAssertEqual(wire.mode, .handoff)
    XCTAssertTrue(wire.enabled)
  }

  func testRulesRejectSelfLoopsDuplicatesAndUnknownCards() {
    let ids: Set<UUID> = [a, b, c]
    let existing = [Wire(from: a, to: b)]
    XCTAssertEqual(WireRules.validate(Wire(from: a, to: a), existing: existing, nodeIDs: ids), .sameCard)
    XCTAssertEqual(WireRules.validate(Wire(from: b, to: a), existing: existing, nodeIDs: ids), .duplicate)
    XCTAssertEqual(WireRules.validate(Wire(from: a, to: UUID()), existing: existing, nodeIDs: ids), .unknownCard)
    XCTAssertNil(WireRules.validate(Wire(from: a, to: c), existing: existing, nodeIDs: ids))
    XCTAssertEqual(WireRules.pruned(existing + [Wire(from: a, to: UUID())], nodeIDs: ids), existing)
  }

  func testMessageHasHeaderInstructionAndStaysInsideTheLimit() {
    let short = WireMessage.compose(fromTitle: "Planlegger", instruction: "Implementer", body: "Plan: gjør X")
    XCTAssertEqual(short, "[Fra Planlegger] Implementer\nPlan: gjør X")
    let long = WireMessage.compose(fromTitle: "A", instruction: "", body: String(repeating: "x", count: 5_000))
    XCTAssertLessThanOrEqual(long.count, WireMessage.maxCharacters)
    XCTAssertTrue(long.hasPrefix("[Fra A]\n"))
    XCTAssertTrue(long.hasSuffix("…"))
    let shell = WireMessage.forShell("[Fra A]\nhei")
    XCTAssertTrue(shell.hasPrefix(": <<'LANEBAY_MSG'\n"))
    XCTAssertTrue(shell.hasSuffix("\nLANEBAY_MSG"))
  }

  func testRouterFansOutAndRespectsDirectionModeAndPause() {
    var router = WireRouter()
    let wires = [
      Wire(from: a, to: b), Wire(from: a, to: c),
      Wire(from: c, to: b, mode: .everyReply),
      Wire(from: b, to: a, enabled: false),
    ]
    let now = Date()
    let fanOut = router.route(from: a, mode: .handoff, wires: wires, now: now)
    XCTAssertEqual(Set(fanOut.deliveries.map(\.target)), [b, c])
    // b only sends along its own wires; b → a is paused, and one-way a → b does not send back.
    let fromB = router.route(from: b, mode: .handoff, wires: wires, now: now)
    XCTAssertTrue(fromB.deliveries.isEmpty)
    XCTAssertEqual(fromB.skipped.map(\.1), [.paused])
    // c → b carries replies only.
    XCTAssertTrue(router.route(from: c, mode: .handoff, wires: wires, now: now).deliveries.isEmpty)
    XCTAssertEqual(router.route(from: c, mode: .everyReply, wires: wires, now: now).deliveries.map(\.target), [b])
  }

  func testLoopGuardStopsPingPongAndCooldownBlocksRapidResends() {
    var router = WireRouter(maxHops: 3, cooldown: 0)
    let wires = [Wire(from: a, to: b, direction: .twoWay, mode: .everyReply)]
    var now = Date()
    var sender = a
    var delivered = 0
    for _ in 0..<10 {
      let result = router.route(from: sender, mode: .everyReply, wires: wires, now: now)
      guard let delivery = result.deliveries.first else {
        XCTAssertEqual(result.skipped.first?.1, .tooManyHops)
        break
      }
      delivered += 1
      sender = delivery.target
      now += 1
    }
    XCTAssertEqual(delivered, 3)
    router.resetHops(for: sender)
    XCTAssertEqual(router.route(from: sender, mode: .everyReply, wires: wires, now: now).deliveries.count, 1)

    var cooling = WireRouter(maxHops: 10, cooldown: 20)
    let one = [Wire(from: a, to: b)]
    let start = Date()
    XCTAssertEqual(cooling.route(from: a, mode: .handoff, wires: one, now: start).deliveries.count, 1)
    XCTAssertEqual(cooling.route(from: a, mode: .handoff, wires: one, now: start + 5).skipped.map(\.1), [.coolingDown])
    XCTAssertEqual(cooling.route(from: a, mode: .handoff, wires: one, now: start + 25).deliveries.count, 1)
  }

  func testOldChainsAreForgottenAfterAQuietPeriod() {
    var router = WireRouter(maxHops: 1, cooldown: 0, hopMemory: 60)
    let wires = [Wire(from: a, to: b), Wire(from: b, to: c)]
    let now = Date()
    XCTAssertEqual(router.route(from: a, mode: .handoff, wires: wires, now: now).deliveries.count, 1)
    XCTAssertEqual(router.route(from: b, mode: .handoff, wires: wires, now: now).skipped.map(\.1), [.tooManyHops])
    XCTAssertEqual(router.route(from: b, mode: .handoff, wires: wires, now: now + 120).deliveries.count, 1)
  }

  func testGeometryPicksFacingSidesAndFindsCardsUnderThePointer() {
    let frame = NodeFrame(x: 0, y: 0, w: 200, h: 100)
    XCTAssertEqual(WireGeometry.facingSide(frame, toward: .init(x: 500, y: 50)), .right)
    XCTAssertEqual(WireGeometry.facingSide(frame, toward: .init(x: -300, y: 60)), .left)
    XCTAssertEqual(WireGeometry.facingSide(frame, toward: .init(x: 100, y: 400)), .bottom)
    XCTAssertEqual(WireGeometry.anchor(frame, side: .top), .init(x: 100, y: 0))
    let other = NodeFrame(x: 400, y: 0, w: 200, h: 100)
    XCTAssertEqual(WireGeometry.card(at: .init(x: 450, y: 50), in: [(a, frame), (b, other)]), b)
    XCTAssertNil(WireGeometry.card(at: .init(x: 300, y: 50), in: [(a, frame), (b, other)]))
    let (c1, _) = WireGeometry.curve(from: .init(x: 200, y: 50), side: .right, to: .init(x: 400, y: 50), side: .left)
    XCTAssertGreaterThan(c1.x, 200)
  }

  func testTemplatesWireTheirCards() {
    let ids = [a, b, c, UUID()]
    XCTAssertEqual(WireTemplate.pipeline.wires(for: Array(ids.prefix(3))).map(\.to), [b, c])
    let fan = WireTemplate.leadWorkers.wires(for: ids)
    XCTAssertEqual(fan.count, 3)
    XCTAssertTrue(fan.allSatisfy { $0.from == a && $0.direction == .twoWay })
  }
}

extension WireTests {
  func testStoreDropsWiresToMissingCardsOnLoad() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = WorkspaceStore(rootURL: root)
    let a = Node(kind: .console, agentID: "shell", cwd: root, frame: NodeFrame(x: 0, y: 0, w: 480, h: 320), title: "K")
    let b = Node(kind: .console, agentID: "shell", cwd: root, frame: NodeFrame(x: 600, y: 0, w: 480, h: 320), title: "K")
    let keep = Wire(from: a.id, to: b.id)
    let dangling = Wire(from: a.id, to: UUID())
    let workspace = Workspace(name: "W", nodes: [a, b], wires: [keep, dangling])
    try store.save(workspace)
    let loaded = try store.load(id: workspace.id)
    let ids: [UUID] = loaded.wires.map { $0.id }
    XCTAssertEqual(ids, [keep.id])
  }
}

extension WireTests {
  func testLiveSidesFollowCardsAfterTheyMove() {
    let a = NodeFrame(x: 0, y: 0, w: 480, h: 320)
    XCTAssertTrue(WireGeometry.liveSides(from: a, to: NodeFrame(x: 700, y: 0, w: 480, h: 320)) == (.right, .left))
    XCTAssertTrue(WireGeometry.liveSides(from: a, to: NodeFrame(x: 0, y: 600, w: 480, h: 320)) == (.bottom, .top))
    XCTAssertTrue(WireGeometry.liveSides(from: a, to: NodeFrame(x: -700, y: 40, w: 480, h: 320)) == (.left, .right))
  }
}
