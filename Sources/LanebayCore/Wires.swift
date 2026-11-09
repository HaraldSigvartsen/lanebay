import Foundation

/// The side of a board card a wire leaves or enters.
public enum CardSide: String, Codable, Sendable, CaseIterable {
    case top, right, bottom, left
}

/// One-way sends source → target only; two-way also sends back.
public enum WireDirection: String, Codable, Sendable, CaseIterable {
    case oneWay, twoWay

    public var label: String { self == .oneWay ? "Én vei" : "Begge veier" }
}

/// What travels along a wire: the handoff note when a task ends, or every reply the agent finishes.
public enum WireMode: String, Codable, Sendable, CaseIterable {
    case handoff, everyReply

    public var label: String { self == .handoff ? "Når oppgaven er ferdig" : "Hvert svar" }
    public var shortLabel: String { self == .handoff ? "Ferdig" : "Hvert svar" }
}

/// A user-drawn connection between two board cards so their agents can talk.
public struct Wire: Codable, Identifiable, Sendable, Equatable {
    public var id: UUID
    public var from: UUID
    public var to: UUID
    public var fromSide: CardSide
    public var toSide: CardSide
    public var direction: WireDirection
    public var mode: WireMode
    public var instruction: String
    public var enabled: Bool

    public init(
        id: UUID = UUID(), from: UUID, to: UUID, fromSide: CardSide = .right, toSide: CardSide = .left,
        direction: WireDirection = .oneWay, mode: WireMode = .handoff, instruction: String = "", enabled: Bool = true
    ) {
        self.id = id; self.from = from; self.to = to; self.fromSide = fromSide; self.toSide = toSide
        self.direction = direction; self.mode = mode; self.instruction = instruction; self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, from, to, fromSide, toSide, direction, mode, instruction, enabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        from = try c.decode(UUID.self, forKey: .from)
        to = try c.decode(UUID.self, forKey: .to)
        fromSide = (try? c.decodeIfPresent(CardSide.self, forKey: .fromSide)) ?? .right
        toSide = (try? c.decodeIfPresent(CardSide.self, forKey: .toSide)) ?? .left
        direction = (try? c.decodeIfPresent(WireDirection.self, forKey: .direction)) ?? .oneWay
        mode = (try? c.decodeIfPresent(WireMode.self, forKey: .mode)) ?? .handoff
        instruction = (try? c.decodeIfPresent(String.self, forKey: .instruction)) ?? ""
        enabled = (try? c.decodeIfPresent(Bool.self, forKey: .enabled)) ?? true
    }

    /// The card at the other end, if `node` may send along this wire.
    public func target(sending node: UUID) -> UUID? {
        if node == from { return to }
        if direction == .twoWay, node == to { return from }
        return nil
    }

    public func connects(_ a: UUID, _ b: UUID) -> Bool {
        (from == a && to == b) || (from == b && to == a)
    }
}

/// Rules for adding wires: no self-loops, no duplicate between the same two cards.
public enum WireRules {
    public enum AddError: Error, Equatable, LocalizedError {
        case sameCard, duplicate, unknownCard

        public var errorDescription: String? {
            switch self {
            case .sameCard: "En tråd må gå mellom to forskjellige kort."
            case .duplicate: "Det finnes allerede en tråd mellom disse kortene."
            case .unknownCard: "Fant ikke kortet."
            }
        }
    }

    public static func validate(_ wire: Wire, existing: [Wire], nodeIDs: Set<UUID>) -> AddError? {
        guard nodeIDs.contains(wire.from), nodeIDs.contains(wire.to) else { return .unknownCard }
        if wire.from == wire.to { return .sameCard }
        if existing.contains(where: { $0.connects(wire.from, wire.to) }) { return .duplicate }
        return nil
    }

    /// Wires that still point at cards on the board.
    public static func pruned(_ wires: [Wire], nodeIDs: Set<UUID>) -> [Wire] {
        wires.filter { nodeIDs.contains($0.from) && nodeIDs.contains($0.to) }
    }
}

/// The text a target receives: a short header, the optional instruction, then the trimmed body.
public enum WireMessage {
    /// FreeBuff has a small context; keep each message well inside one task's limit.
    public static let maxCharacters = 1_500

    public static func compose(fromTitle: String, instruction: String, body: String, limit: Int = maxCharacters) -> String {
        let trimmedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        var header = "[Fra \(fromTitle)]"
        if !trimmedInstruction.isEmpty { header += " \(trimmedInstruction)" }
        let cleanBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let room = max(0, limit - header.count - 1)
        let bodyPart: String
        if cleanBody.count <= room {
            bodyPart = cleanBody
        } else {
            bodyPart = String(cleanBody.prefix(max(0, room - 1))) + "…"
        }
        return bodyPart.isEmpty ? header : "\(header)\n\(bodyPart)"
    }

    /// Shell targets get the message as a no-op heredoc so it shows in the terminal without running anything.
    public static func forShell(_ message: String) -> String {
        let safe = message.replacingOccurrences(of: "\nLANEBAY_MSG", with: "\n LANEBAY_MSG")
        return ": <<'LANEBAY_MSG'\n\(safe)\nLANEBAY_MSG"
    }
}

/// Decides which wires carry a message, with a loop guard: a hop limit and a per-wire cooldown.
public struct WireRouter: Sendable {
    public struct Delivery: Equatable, Sendable {
        public let wireID: UUID
        public let target: UUID
        public let hop: Int
    }

    public enum Skip: Equatable, Sendable {
        case paused, wrongMode, tooManyHops, coolingDown
    }

    public var maxHops: Int
    public var cooldown: TimeInterval
    /// The hop count a card's next message carries: 0 for a task a person gave it.
    public private(set) var hops: [UUID: Int] = [:]
    private var hopSetAt: [UUID: Date] = [:]
    private var lastSent: [UUID: Date] = [:]
    /// A chain that has been quiet this long starts over, so an old loop does not block new work forever.
    public var hopMemory: TimeInterval

    public init(maxHops: Int = 4, cooldown: TimeInterval = 20, hopMemory: TimeInterval = 600) {
        self.maxHops = maxHops
        self.cooldown = cooldown
        self.hopMemory = hopMemory
    }

    /// A person (or the CLI) gave this card new work, so the chain starts over.
    public mutating func resetHops(for node: UUID) { hops[node] = 0; hopSetAt[node] = nil }

    public func currentHop(_ node: UUID, now: Date) -> Int {
        guard let set = hopSetAt[node], now.timeIntervalSince(set) < hopMemory else { return 0 }
        return hops[node] ?? 0
    }

    /// Routes one message from `source`. Returns deliveries and the wires that were skipped, with why.
    public mutating func route(
        from source: UUID, mode: WireMode, wires: [Wire], now: Date
    ) -> (deliveries: [Delivery], skipped: [(UUID, Skip)]) {
        var deliveries: [Delivery] = []
        var skipped: [(UUID, Skip)] = []
        let hop = currentHop(source, now: now) + 1
        for wire in wires {
            guard let target = wire.target(sending: source) else { continue }
            guard wire.enabled else { skipped.append((wire.id, .paused)); continue }
            guard wire.mode == mode else { skipped.append((wire.id, .wrongMode)); continue }
            guard hop <= maxHops else { skipped.append((wire.id, .tooManyHops)); continue }
            if let last = lastSent[wire.id], now.timeIntervalSince(last) < cooldown {
                skipped.append((wire.id, .coolingDown)); continue
            }
            lastSent[wire.id] = now
            hops[target] = hop
            hopSetAt[target] = now
            deliveries.append(Delivery(wireID: wire.id, target: target, hop: hop))
        }
        return (deliveries, skipped)
    }
}

/// Board geometry for wires, in board (unzoomed) coordinates.
public enum WireGeometry {
    public struct Point: Equatable, Sendable {
        public var x: Double
        public var y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }
    }

    public static func anchor(_ frame: NodeFrame, side: CardSide) -> Point {
        switch side {
        case .top: Point(x: frame.x + frame.w / 2, y: frame.y)
        case .bottom: Point(x: frame.x + frame.w / 2, y: frame.y + frame.h)
        case .left: Point(x: frame.x, y: frame.y + frame.h / 2)
        case .right: Point(x: frame.x + frame.w, y: frame.y + frame.h / 2)
        }
    }

    public static func normal(_ side: CardSide) -> Point {
        switch side {
        case .top: Point(x: 0, y: -1)
        case .bottom: Point(x: 0, y: 1)
        case .left: Point(x: -1, y: 0)
        case .right: Point(x: 1, y: 0)
        }
    }

    /// The side of `frame` that faces `point` best.
    /// The sides a wire is drawn between right now. Cards move (by hand or by tidy), so the wire
    /// always leaves and enters on the sides that face each other instead of the sides saved at creation.
    public static func liveSides(from a: NodeFrame, to b: NodeFrame) -> (from: CardSide, to: CardSide) {
        (facingSide(a, toward: Point(x: b.x + b.w / 2, y: b.y + b.h / 2)),
         facingSide(b, toward: Point(x: a.x + a.w / 2, y: a.y + a.h / 2)))
    }

    public static func facingSide(_ frame: NodeFrame, toward point: Point) -> CardSide {
        let cx = frame.x + frame.w / 2, cy = frame.y + frame.h / 2
        let dx = (point.x - cx) / max(frame.w, 1), dy = (point.y - cy) / max(frame.h, 1)
        if abs(dx) >= abs(dy) { return dx >= 0 ? .right : .left }
        return dy >= 0 ? .bottom : .top
    }

    /// Cubic bezier control points that leave and enter along each side's normal.
    public static func curve(from a: Point, side sa: CardSide, to b: Point, side sb: CardSide?) -> (Point, Point) {
        let distance = hypot(b.x - a.x, b.y - a.y)
        let pull = min(max(distance * 0.4, 40), 220)
        let na = normal(sa)
        let c1 = Point(x: a.x + na.x * pull, y: a.y + na.y * pull)
        let c2: Point
        if let sb {
            let nb = normal(sb)
            c2 = Point(x: b.x + nb.x * pull, y: b.y + nb.y * pull)
        } else {
            c2 = Point(x: b.x - na.x * pull * 0.5, y: b.y - na.y * pull * 0.5)
        }
        return (c1, c2)
    }

    /// A point on the cubic at `t` in 0…1.
    public static func point(on a: Point, _ c1: Point, _ c2: Point, _ b: Point, t: Double) -> Point {
        let u = 1 - t
        let x = u * u * u * a.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * b.x
        let y = u * u * u * a.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * b.y
        return Point(x: x, y: y)
    }

    /// The card under a board point, front-most last in `nodes`.
    public static func card(at point: Point, in nodes: [(UUID, NodeFrame)], padding: Double = 12) -> UUID? {
        nodes.last { _, f in
            point.x >= f.x - padding && point.x <= f.x + f.w + padding
                && point.y >= f.y - padding && point.y <= f.y + f.h + padding
        }?.0
    }
}

/// Ready-made wire layouts for the Orkestrering dialog.
public enum WireTemplate: String, CaseIterable, Sendable, Identifiable {
    case pipeline, leadWorkers

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .pipeline: "Planlegger → Utvikler → Reviewer"
        case .leadWorkers: "Én leder → flere arbeidere"
        }
    }

    public var summary: String {
        switch self {
        case .pipeline: "Tre kort på rad. Hver sender notatet sitt videre når oppgaven er ferdig."
        case .leadWorkers: "En leder deler ut arbeid til tre arbeidere, og de svarer lederen når de er ferdige."
        }
    }

    /// Card titles, in order. The first is the lead for `leadWorkers`.
    public var cardTitles: [String] {
        switch self {
        case .pipeline: ["Planlegger", "Utvikler", "Reviewer"]
        case .leadWorkers: ["Leder", "Arbeider 1", "Arbeider 2", "Arbeider 3"]
        }
    }

    /// Wires between card indexes.
    public func wires(for ids: [UUID]) -> [Wire] {
        switch self {
        case .pipeline:
            guard ids.count >= 3 else { return [] }
            return [
                Wire(from: ids[0], to: ids[1], instruction: "Implementer denne planen"),
                Wire(from: ids[1], to: ids[2], instruction: "Se over endringene og si fra om feil"),
            ]
        case .leadWorkers:
            guard ids.count >= 2 else { return [] }
            return ids.dropFirst().map {
                Wire(from: ids[0], to: $0, fromSide: .bottom, toSide: .top, direction: .twoWay, instruction: "Gjør din del")
            }
        }
    }
}
