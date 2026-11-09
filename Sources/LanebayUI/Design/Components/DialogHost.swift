import SwiftUI

/// Size of a centered dialog: wide enough to breathe, never wider than the window allows.
public enum DialogLayout {
    public static let minWidth: CGFloat = 720
    public static let maxWidth: CGFloat = 860
    public static let heightFraction: CGFloat = 0.8
    public static let windowMargin: CGFloat = 32

    public static func size(preferredWidth: CGFloat, in container: CGSize) -> CGSize {
        let clamped = min(max(preferredWidth, minWidth), maxWidth)
        let width = max(min(clamped, container.width - windowMargin * 2), 320)
        let height = max(min(container.height * heightFraction, container.height - windowMargin * 2), 240)
        return CGSize(width: width, height: height)
    }
}

/// A modal dialog centered over the window: dimmed, blurred backdrop, glass card, spring scale and fade.
/// Esc or a click on the backdrop closes it.
public struct DialogOverlay<Content: View>: View {
    public let isPresented: Bool
    public let preferredWidth: CGFloat
    public let onClose: () -> Void
    @ViewBuilder public let content: Content
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        isPresented: Bool, preferredWidth: CGFloat, onClose: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.isPresented = isPresented
        self.preferredWidth = preferredWidth
        self.onClose = onClose
        self.content = content()
    }

    public var body: some View {
        GeometryReader { proxy in
            let size = DialogLayout.size(preferredWidth: preferredWidth, in: proxy.size)
            ZStack {
                if isPresented {
                    backdrop
                        .transition(.opacity)
                    content
                        .frame(width: size.width, height: size.height)
                        .elevation(DS.Elevation.floating)
                        .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.18), radius: 48, y: 24)
                        .transition(.scale(scale: 0.94).combined(with: .opacity))
                        .zIndex(1)
                    Button("Lukk", action: onClose)
                        .keyboardShortcut(.cancelAction)
                        .opacity(0)
                        .frame(width: 0, height: 0)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .animation(DS.Motion.animation(DS.Motion.smooth, reduceMotion: reduceMotion), value: isPresented)
        .allowsHitTesting(isPresented)
    }

    private var backdrop: some View {
        // A plain dim keeps the board readable behind the dialog; a material blur here washed it out entirely.
        Rectangle().fill(Color.black.opacity(colorScheme == .dark ? 0.5 : 0.28))
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture(perform: onClose)
        .accessibilityElement()
        .accessibilityLabel("Lukk dialog")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onClose() }
    }
}
