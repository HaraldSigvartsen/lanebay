import Foundation
import LanebayCore

/// Pure board layout helpers: overlap detection and a masonry "tidy" that keeps card sizes.
public enum BoardLayout {
  /// Height a stopped, unselected card is drawn at on the board (header, one line and Start).
  public static let compactHeight: Double = 128
  /// Narrowest console card: about 60 terminal columns, so prompts and agent output do not wrap mid-word.
  public static let minimumConsoleWidth: Double = 420
  public static let minimumConsoleHeight: Double = 200

  /// Stopped (idle) cards draw as a compact strip, so starting one is the only thing that grows it.
  public static func isCompact(idle: Bool) -> Bool { idle }

  public struct Item: Equatable, Sendable {
    public var id: UUID
    public var frame: NodeFrame
    /// Height used for placement; a compact card occupies less than its stored frame.
    public var layoutHeight: Double

    public init(id: UUID, frame: NodeFrame, layoutHeight: Double? = nil) {
      self.id = id
      self.frame = frame
      self.layoutHeight = layoutHeight ?? frame.h
    }
  }

  /// True when any two frames intersect by more than a hairline.
  public static func overlaps(_ frames: [NodeFrame], tolerance: Double = 4) -> Bool {
    for i in frames.indices {
      for j in frames.indices where j > i {
        let a = frames[i]
        let b = frames[j]
        let dx = min(a.x + a.w, b.x + b.w) - max(a.x, b.x)
        let dy = min(a.y + a.h, b.y + b.h) - max(a.y, b.y)
        if dx > tolerance && dy > tolerance { return true }
      }
    }
    return false
  }

  /// True when the cards leave clearly more empty height than a tidy pass would (e.g. cards that shrank
  /// to compact strips after a relaunch). `slack` is in board units.
  public static func isLoose(current: [NodeFrame], tidied: [NodeFrame], slack: Double = 96) -> Bool {
    guard !current.isEmpty, !tidied.isEmpty else { return false }
    let bottom = { (frames: [NodeFrame]) in frames.map { $0.y + $0.h }.max() ?? 0 }
    return bottom(current) - bottom(tidied) > slack
  }

  /// Number of masonry columns for `viewportWidth` (board units) using the median card width.
  public static func columnCount(widths: [Double], viewportWidth: Double, gap: Double = 24, margin: Double = 24) -> Int {
    guard !widths.isEmpty else { return 1 }
    let sorted = widths.sorted()
    let median = max(1, sorted[sorted.count / 2])
    let fit = Int(((viewportWidth - margin) / (median + gap)).rounded(.down))
    return max(1, min(widths.count, fit))
  }

  /// Masonry placement in `items` order: each card goes to the currently shortest column.
  /// Sizes are kept; only x/y change. Columns are as wide as the widest card placed in them.
  public static func tidy(
    _ items: [Item], viewportWidth: Double, gap: Double = 24, margin: Double = 24, topMargin: Double? = nil
  ) -> [UUID: NodeFrame] {
    guard !items.isEmpty else { return [:] }
    let columns = columnCount(
      widths: items.map(\.frame.w), viewportWidth: viewportWidth, gap: gap, margin: margin)
    var assignment: [[Item]] = Array(repeating: [], count: columns)
    var heights = Array(repeating: 0.0, count: columns)
    for item in items {
      let column = heights.indices.min { heights[$0] < heights[$1] || (heights[$0] == heights[$1] && $0 < $1) } ?? 0
      assignment[column].append(item)
      heights[column] += item.layoutHeight + gap
    }
    var result: [UUID: NodeFrame] = [:]
    var x = margin
    for column in assignment where !column.isEmpty {
      var y = topMargin ?? margin
      let width = column.map(\.frame.w).max() ?? 0
      for item in column {
        result[item.id] = NodeFrame(x: x, y: y, w: item.frame.w, h: item.frame.h)
        y += item.layoutHeight + gap
      }
      x += width + gap
    }
    return result
  }
}
