import SwiftUI

public struct CommandBar: View {
    @Binding private var text: String
    @FocusState private var isCommandFieldFocused: Bool
    private let placeholder: String
    private let onSubmit: (String) -> Void
    private let destination: String?
    private let canSubmit: Bool
    private let onBroadcastToIdle: ((String) -> Bool)?
    private let hasIdleRecipients: Bool
    private let isVoiceRecording: Bool
    private let onPushToTalkPressChanged: ((Bool) -> Void)?
    private let voiceStatus: String?
    private let voiceError: String?

    public init(text: Binding<String>, placeholder: String = "Command your agents…", destination: String? = nil, canSubmit: Bool = true, hasIdleRecipients: Bool = false, onBroadcastToIdle: ((String) -> Bool)? = nil, isVoiceRecording: Bool = false, voiceStatus: String? = nil, voiceError: String? = nil, onPushToTalkPressChanged: ((Bool) -> Void)? = nil, onSubmit: @escaping (String) -> Void) {
        _text = text
        self.placeholder = placeholder
        self.onSubmit = onSubmit
        self.destination = destination
        self.canSubmit = canSubmit
        self.onBroadcastToIdle = onBroadcastToIdle
        self.hasIdleRecipients = hasIdleRecipients
        self.isVoiceRecording = isVoiceRecording
        self.onPushToTalkPressChanged = onPushToTalkPressChanged
        self.voiceStatus = voiceStatus
        self.voiceError = voiceError
    }

    public var body: some View {
        HStack(spacing: Spacing.sm) {
            Icon.command.image.foregroundStyle(Palette.accent)
            if let destination { Text(destination).font(Typography.caption).foregroundStyle(Palette.accent).lineLimit(1).padding(.horizontal, Spacing.xs).padding(.vertical, Spacing.xxs).background(Palette.accentSoft, in: RoundedRectangle(cornerRadius: Spacing.radiusSmall)) }
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain).font(Typography.body).foregroundStyle(Palette.ink)
                .focused($isCommandFieldFocused)
                .onSubmit(submit)
            Button(action: submit) { Icon.send.image.foregroundStyle(Palette.surface).frame(width: 28, height: 28).contentShape(Rectangle()).background(Palette.accent, in: RoundedRectangle(cornerRadius: Spacing.radiusSmall)) }
                .buttonStyle(.plain).disabled(!isSubmittable).opacity(isSubmittable ? 1 : 0.5)
                .accessibilityLabel("Send command")
            if let onBroadcastToIdle {
                Button { if onBroadcastToIdle(text) { text = "" } } label: { Image(systemName: "arrow.trianglehead.2.clockwise.rotate.90") }
                    .buttonStyle(.plain).disabled(!Self.isBroadcastEnabled(hasIdleRecipients: hasIdleRecipients, text: text)).help("Send to idle consoles")
                    .accessibilityLabel("Send to idle consoles")
            }
            if let onPushToTalkPressChanged {
                Image(systemName: isVoiceRecording ? "waveform.circle.fill" : "mic.circle")
                    .font(.title3)
                    .foregroundStyle(isVoiceRecording ? Palette.accent : Palette.secondaryInk)
                    .help("Hold to talk (Option+Space)")
                    .accessibilityLabel("Push to talk")
                    .onLongPressGesture(minimumDuration: .infinity, pressing: { pressing in
                        onPushToTalkPressChanged(pressing)
                    }, perform: {})
            }
        }
        .padding(.horizontal, Spacing.md).frame(height: 48)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: Spacing.radiusMedium))
        .overlay(RoundedRectangle(cornerRadius: Spacing.radiusMedium).stroke(Palette.border, lineWidth: 1))
        .overlay {
            if isCommandFieldFocused {
                RoundedRectangle(cornerRadius: Spacing.radiusMedium)
                    .stroke(Palette.focus, lineWidth: 2)
                    .padding(1)
                    .allowsHitTesting(false)
            }
        }
        .shadow(color: Spacing.elevationRaised.color, radius: Spacing.elevationRaised.radius, y: Spacing.elevationRaised.y)
        .overlay(alignment: .bottomLeading) {
            if let voiceError {
                Text(voiceError).font(Typography.caption).foregroundStyle(Palette.status(.error))
                    .lineLimit(1).padding(.leading, Spacing.md).padding(.bottom, -22)
            } else if let voiceStatus {
                Text(voiceStatus).font(Typography.caption).foregroundStyle(Palette.secondaryInk)
                    .lineLimit(1).padding(.leading, Spacing.md).padding(.bottom, -22)
            }
        }
    }

    private func submit() {
        guard isSubmittable else { return }
        onSubmit(text)
    }

    private var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var isSubmittable: Bool { canSubmit && hasText }

    static func isBroadcastEnabled(hasIdleRecipients: Bool, text: String) -> Bool {
        hasIdleRecipients && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

#Preview { CommandBar(text: .constant(""), destination: "Claude Code") { _ in }.frame(width: 520).padding().background(Palette.canvas) }
