import Foundation

public enum SparkleConfiguration {
    public static func isConfigured(info: [String: Any]) -> Bool {
        guard
            let feedString = info["SUFeedURL"] as? String,
            let feedURL = URL(string: feedString),
            let components = URLComponents(url: feedURL, resolvingAgainstBaseURL: false),
            components.scheme == "https",
            let host = components.host,
            !host.isEmpty,
            !host.lowercased().hasSuffix(".invalid"),
            host.lowercased() != "example.com",
            !host.lowercased().hasSuffix(".example.com"),
            let publicKey = info["SUPublicEDKey"] as? String,
            let keyData = Data(base64Encoded: publicKey),
            keyData.count == 32
        else { return false }
        return true
    }
}
