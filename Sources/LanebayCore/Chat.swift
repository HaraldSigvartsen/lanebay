import Foundation

/// Terminal titles become URL- and mention-friendly handles (`@utvikler`).
public enum TerminalHandle {
  /// Lowercases, folds Nordic letters and other diacritics, turns any run of
  /// other characters into one `-`, and never returns an empty handle.
  public static func slug(_ title: String) -> String {
    var text = title.lowercased()
    text = text
      .replacingOccurrences(of: "æ", with: "ae")
      .replacingOccurrences(of: "ø", with: "o")
      .replacingOccurrences(of: "å", with: "a")
    text = text.folding(options: [.diacriticInsensitive], locale: nil)

    var slug = ""
    var pendingSeparator = false
    for scalar in text.unicodeScalars {
      let allowed = (scalar.value >= 0x61 && scalar.value <= 0x7A) || (scalar.value >= 0x30 && scalar.value <= 0x39)
      if allowed {
        if pendingSeparator, !slug.isEmpty { slug.append("-") }
        pendingSeparator = false
        slug.unicodeScalars.append(scalar)
      } else {
        pendingSeparator = true
      }
    }
    return slug.isEmpty ? "terminal" : slug
  }
}

/// Picks a display name whose handle is not already taken.
public enum TerminalNames {
  /// Trims the desired name, falls back to "Terminal", then appends " 2", " 3", …
  /// until the handle is free. Comparison is by handle, not by exact title.
  public static func unique(_ desired: String, existing: [String]) -> String {
    let trimmed = desired.trimmingCharacters(in: .whitespaces)
    let base = trimmed.isEmpty ? "Terminal" : trimmed
    let taken = Set(existing.map { TerminalHandle.slug($0) })
    guard taken.contains(TerminalHandle.slug(base)) else { return base }
    var index = 2
    while taken.contains(TerminalHandle.slug("\(base) \(index)")) { index += 1 }
    return "\(base) \(index)"
  }
}

/// What a chat line resolves to: who it goes to, what is left to type, what went unrecognised.
public struct ChatMentionResult: Equatable, Sendable {
  /// Explicit `@handle` targets, first mention first, no duplicates.
  public var targets: [UUID]
  /// True when `@alle`/`@all` was mentioned; the sender should broadcast.
  public var all: Bool
  /// The text with known mentions removed and spacing tidied.
  public var body: String
  /// Handles that matched nothing, slugged, first mention first.
  public var unknown: [String]

  public init(targets: [UUID] = [], all: Bool = false, body: String = "", unknown: [String] = []) {
    self.targets = targets
    self.all = all
    self.body = body
    self.unknown = unknown
  }
}

/// Parses and completes `@handle` mentions in chat input.
public enum ChatMentions {
  /// Handles that address every terminal in the workspace.
  public static let allHandles: Set<String> = ["alle", "all"]

  /// Finds `@word` tokens (only at the start of the text or after whitespace),
  /// removes the ones that resolve, and reports the rest.
  public static func parse(_ text: String, handles: [String: UUID]) -> ChatMentionResult {
    let characters = Array(text)
    var targets: [UUID] = []
    var seenTargets = Set<UUID>()
    var unknown: [String] = []
    var seenUnknown = Set<String>()
    var all = false
    var removed = [Bool](repeating: false, count: characters.count)

    var index = 0
    while index < characters.count {
      guard characters[index] == "@" else {
        index += 1
        continue
      }
      // An address in the middle of a word (`e-mail@x.no`) is not a mention.
      guard index == 0 || characters[index - 1].isWhitespace else {
        index += 1
        continue
      }
      let wordStart = index + 1
      var wordEnd = wordStart
      while wordEnd < characters.count, isHandleCharacter(characters[wordEnd]) { wordEnd += 1 }
      guard wordEnd > wordStart else {
        index += 1
        continue
      }

      let slug = TerminalHandle.slug(String(characters[wordStart..<wordEnd]))
      if allHandles.contains(slug) {
        all = true
      } else if let id = handles[slug] {
        if seenTargets.insert(id).inserted { targets.append(id) }
      } else {
        // Unknown handles stay in the text so nothing the user typed is lost.
        if seenUnknown.insert(slug).inserted { unknown.append(slug) }
        index = wordEnd
        continue
      }

      for position in index..<wordEnd { removed[position] = true }
      index = wordEnd
    }

    var body = String(characters.enumerated().filter { !removed[$0.offset] }.map { $0.element })
    while body.contains("  ") { body = body.replacingOccurrences(of: "  ", with: " ") }
    return ChatMentionResult(
      targets: targets,
      all: all,
      body: body.trimmingCharacters(in: .whitespacesAndNewlines),
      unknown: unknown
    )
  }

  /// The `@query` being typed right before the cursor, as Character offsets.
  public static func activeQuery(in text: String, cursor: Int) -> (range: Range<Int>, query: String)? {
    let characters = Array(text)
    guard cursor >= 0, cursor <= characters.count else { return nil }
    var start = cursor
    while start > 0, isHandleCharacter(characters[start - 1]) { start -= 1 }
    let at = start - 1
    guard at >= 0, characters[at] == "@" else { return nil }
    guard at == 0 || characters[at - 1].isWhitespace else { return nil }
    return (at..<cursor, String(characters[start..<cursor]))
  }

  /// Replaces the character range of the in-progress mention with a finished `@handle `.
  public static func complete(_ text: String, range: Range<Int>, handle: String) -> String {
    let characters = Array(text)
    let lower = min(max(0, range.lowerBound), characters.count)
    let upper = min(max(lower, range.upperBound), characters.count)
    return String(characters[..<lower]) + "@\(handle) " + String(characters[upper...])
  }

  /// `[A-Za-z0-9æøåÆØÅ_-]`, as the spec defines a mention word.
  static func isHandleCharacter(_ character: Character) -> Bool {
    if character.isASCII { return character.isLetter || character.isNumber || character == "_" || character == "-" }
    return "æøåÆØÅ".contains(character)
  }
}

/// A short summary of terminal output for a chat bubble: notable steps plus the tail.
public struct OutputDigest: Equatable, Sendable {
  /// Action-looking lines, oldest first, at most the last 12.
  public var steps: [String]
  /// The last non-step lines joined by newlines.
  public var reply: String
  /// True when the reply dropped earlier lines to fit `maxReplyLines`.
  public var truncated: Bool
  public init(steps: [String] = [], reply: String = "", truncated: Bool = false) {
    self.steps = steps
    self.reply = reply
    self.truncated = truncated
  }

  public static let maximumSteps = 12
  public static let maximumStepCharacters = 120

  public static func make(raw: String, sent: String? = nil, maxReplyLines: Int = 40) -> OutputDigest {
    let sentLine = sent?.trimmingCharacters(in: .whitespacesAndNewlines)
    var steps: [String] = []
    var replyLines: [String] = []

    var echoed = false
    for rawLine in AgentTaskContract.plainText(raw).components(separatedBy: "\n") {
      // A carriage return redraws the line; only the last pass is what the terminal shows.
      var line = rawLine.components(separatedBy: "\r").last(where: { !$0.isEmpty }) ?? ""
      // An escape cut in half by the output window leaves "39m" or "0;32m" behind.
      line = line.replacingOccurrences(of: "^[0-9;]{1,8}m", with: "", options: .regularExpression)
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty else { continue }
      guard !isNoise(trimmed, sent: sentLine) else { continue }
      if let sentLine, !sentLine.isEmpty, isEcho(trimmed, of: sentLine) {
        if !echoed, let first = sentLine.components(separatedBy: "\n").first {
          echoed = true
          steps.append("$ " + String(first.prefix(maximumStepCharacters - 2)))
        }
        continue
      }

      if let step = stepText(trimmed) {
        let clipped = step.count > maximumStepCharacters
          ? String(step.prefix(maximumStepCharacters - 1)) + "…"
          : step
        if steps.last != clipped { steps.append(clipped) }
      } else {
        replyLines.append(line.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression))
      }
    }

    if steps.count > maximumSteps { steps = Array(steps.suffix(maximumSteps)) }
    let limit = max(0, maxReplyLines)
    let truncated = replyLines.count > limit
    if truncated { replyLines = Array(replyLines.suffix(limit)) }
    return OutputDigest(steps: steps, reply: replyLines.joined(separator: "\n"), truncated: truncated)
  }

  /// The terminal echoing what was typed (possibly with prompt chrome in front or a `>` continuation).
  static func isEcho(_ trimmed: String, of sent: String) -> Bool {
    let head = String(sent.prefix(16))
    if head.count >= 4, trimmed.contains(head) { return true }
    var bare = trimmed
    while bare.hasSuffix(">") { bare.removeLast() }
    bare = bare.trimmingCharacters(in: .whitespaces)
    return bare.count >= 4 && sent.contains(bare) && trimmed.hasSuffix(">")
  }

  /// Shell noise: hook plumbing, the echoed task, prompt chrome.
  public static func isNoise(_ trimmed: String, sent: String? = nil) -> Bool {
    // A bare prompt: only prompt glyphs, arrows, tildes and brackets.
    let chrome = CharacterSet(charactersIn: "%$#>❯➜→~=()[]-:./ ")
    if trimmed.unicodeScalars.allSatisfy({ chrome.contains($0) }) { return true }
    if trimmed.contains("__lb_hook") || trimmed.contains("precmd_functions") || trimmed.contains("LANEBAY_MSG") {
      return true
    }
    if trimmed.contains("export PAGER=cat") { return true }
    // Right-side prompt redraws like "❯ m6=❯ m6❯ m6": two or more prompt arrows with only short words between.
    if trimmed.filter({ $0 == "❯" }).count >= 2,
      trimmed.split(whereSeparator: { "❯=% ".contains($0) }).allSatisfy({ $0.count <= 24 })
    { return true }
    if let sent, trimmed == sent { return true }
    let promptTail = trimmed.hasSuffix("$") || trimmed.hasSuffix("❯") || trimmed.hasSuffix("%")
    if promptTail, trimmed.count < 60, trimmed.contains("->") || trimmed.hasPrefix("❯") { return true }
    return false
  }

  /// The step text for an action-looking line, or nil. Prompt symbols are stripped;
  /// word prefixes such as `Ran` stay so the step still reads as an action.
  private static func stepText(_ trimmed: String) -> String? {
    // (match, characters to drop from the front)
    let rules: [(String, Int)] = [
      ("$ ", 2), ("❯ ", 2), ("> ", 2), ("• Ran ", 2),
      ("Ran ", 0), ("⏺ ", 2), ("● ", 2), ("✓ ", 2), ("✔ ", 2),
      ("Running ", 0), ("Edited ", 0), ("Read ", 0), ("Wrote ", 0),
      ("Created ", 0), ("Updated ", 0),
    ]
    for (prefix, drop) in rules where trimmed.hasPrefix(prefix) {
      let step = String(trimmed.dropFirst(drop)).trimmingCharacters(in: .whitespaces)
      return step.isEmpty ? nil : step
    }
    return nil
  }
}

public enum ChatEntryKind: String, Codable, Sendable, Equatable {
  case user, reply, wire, system
}

/// Where a reply block is: still working, finished, or failed.
public enum ChatEntryStatus: String, Codable, Sendable, Equatable {
  case working, done, failed
}

/// One line in the chat panel, persisted with the workspace.
public struct ChatEntry: Codable, Equatable, Sendable, Identifiable {
  public var id: UUID
  public var date: Date
  public var kind: ChatEntryKind
  public var text: String
  /// Terminals an `@handle` line was sent to.
  public var targets: [UUID]
  /// The sending card, for wire deliveries.
  public var from: UUID?
  /// The receiving card, for wire deliveries.
  public var to: UUID?
  /// Output steps shown above a reply.
  public var steps: [String]
  /// True when the reply was shortened before being stored.
  public var truncated: Bool
  /// Whether this reply is still being written.
  public var status: ChatEntryStatus
  /// When the reply finished, nil while it is still working.
  public var finished: Date?

  public init(
    id: UUID = UUID(),
    date: Date = Date(),
    kind: ChatEntryKind,
    text: String,
    targets: [UUID] = [],
    from: UUID? = nil,
    to: UUID? = nil,
    steps: [String] = [],
    truncated: Bool = false,
    status: ChatEntryStatus = .done,
    finished: Date? = nil
  ) {
    self.id = id
    self.date = date
    self.kind = kind
    self.text = text
    self.targets = targets
    self.from = from
    self.to = to
    self.steps = steps
    self.truncated = truncated
    self.status = status
    self.finished = finished
  }

  private enum CodingKeys: String, CodingKey {
    case id, date, kind, text, targets, from, to, steps, truncated, status, finished
  }

  /// Transcripts written before mentions, steps or truncation still open.
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    date = try container.decode(Date.self, forKey: .date)
    kind = try container.decode(ChatEntryKind.self, forKey: .kind)
    text = try container.decode(String.self, forKey: .text)
    targets = try container.decodeIfPresent([UUID].self, forKey: .targets) ?? []
    from = try container.decodeIfPresent(UUID.self, forKey: .from)
    to = try container.decodeIfPresent(UUID.self, forKey: .to)
    steps = try container.decodeIfPresent([String].self, forKey: .steps) ?? []
    truncated = try container.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    // A reply saved mid-work can never finish after a relaunch.
    let saved = try container.decodeIfPresent(ChatEntryStatus.self, forKey: .status) ?? .done
    status = saved == .working ? .done : saved
    finished = try container.decodeIfPresent(Date.self, forKey: .finished)
  }
}
