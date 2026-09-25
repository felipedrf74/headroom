import Foundation

enum TokenroomIdentity {
    static let bundleID = Bundle.main.bundleIdentifier ?? "app.tokenroom.mac"
    static let cacheFolderName = "Tokenroom"
    /// The GitHub repository still lives at its pre-rename URL; GitHub redirects after a rename.
    static let repositoryURL = URL(string: "https://github.com/felipedrf74/headroom")!

    /// Headroom 1.x, which Tokenroom replaces.
    static let legacyBundleID = "app.headroom.mac"
    static let legacyCacheFolderName = "Headroom"

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// Honest User-Agent for every provider call (Claude's usage call overrides it).
    static var userAgent: String {
        "Tokenroom/\(version) (+\(repositoryURL.absoluteString))"
    }
}
