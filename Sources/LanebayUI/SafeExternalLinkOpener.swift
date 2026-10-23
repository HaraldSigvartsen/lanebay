import Foundation

public enum SafeExternalLinkOpener {
    public static func open(_ url: URL, using opener: (URL) -> Void) {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil else { return }
        opener(url)
    }
}
