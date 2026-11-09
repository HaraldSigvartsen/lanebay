import SwiftUI

/// Per-provider badge styling. Brand hues are Lanebay's own approximations; no trademark assets ship.
enum ProviderStyle {
  /// A symbol or monogram drawn white on a two-color gradient.
  static func style(for agentID: String) -> (symbol: String?, monogram: String?, colors: [UInt]) {
    switch agentID {
    case "shell":
      return ("terminal", nil, [0x4B5563, 0x1F2937])
    case "orchestrator":
      return ("point.3.connected.trianglepath.dotted", nil, [0x7C3AED, 0x4F46E5])
    case "freebuff":
      return (nil, "FB", [0x22C55E, 0x0EA5E9])
    case "opencode":
      return ("chevron.left.forwardslash.chevron.right", nil, [0x111827, 0x374151])
    case "codex":
      return (nil, "Cx", [0x10A37F, 0x0B7A5E])
    case "claude":
      return ("sparkle", nil, [0xD97757, 0xB4532A])
    case "cursor-agent":
      return ("cursorarrow.rays", nil, [0x0F172A, 0x334155])
    default:
      return ("gearshape.2", nil, [0x64748B, 0x475569])
    }
  }
}

/// Rounded-square agent badge for lists and the new-terminal sheet.
struct ProviderBadge: View {
  var agentID: String
  var size: CGFloat = 22

  var body: some View {
    let style = ProviderStyle.style(for: agentID)
    RoundedRectangle(cornerRadius: Spacing.radiusSmall)
      .fill(
        LinearGradient(
          colors: style.colors.map(providerColor),
          startPoint: .topLeading,
          endPoint: .bottomTrailing))
      .frame(width: size, height: size)
      .overlay {
        if let symbol = style.symbol {
          Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
        } else if let monogram = style.monogram {
          Text(monogram)
            .font(.system(size: size * 0.42, weight: .bold))
            .foregroundStyle(.white)
        }
      }
      .accessibilityHidden(true)
  }
}

private func providerColor(_ rgb: UInt) -> Color {
  Color(
    .sRGB,
    red: Double((rgb >> 16) & 0xFF) / 255,
    green: Double((rgb >> 8) & 0xFF) / 255,
    blue: Double(rgb & 0xFF) / 255,
    opacity: 1)
}
