import Foundation

/// Links widgets, notifications, and the Watch open in the iPhone app:
/// `tokenroom://provider/<id>`, `tokenroom://news`, `tokenroom://settings`, `tokenroom://keys`,
/// and `tokenroom://alerts`.
enum DeepLink: Equatable, Sendable {
    case provider(String)
    case news
    case settings
    case keys
    case alerts

    static let scheme = "tokenroom"

    init?(_ url: URL) {
        guard url.scheme == Self.scheme else { return nil }
        switch url.host() {
        case "provider":
            guard let id = url.pathComponents.dropFirst().first, !id.isEmpty else { return nil }
            self = .provider(id)
        case "news":
            self = .news
        case "settings":
            self = .settings
        case "keys":
            self = .keys
        case "alerts":
            self = .alerts
        default:
            return nil
        }
    }

    var url: URL {
        switch self {
        case .provider(let id):
            URL(string: "\(Self.scheme)://provider/\(id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id)")!
        case .news:
            URL(string: "\(Self.scheme)://news")!
        case .settings:
            URL(string: "\(Self.scheme)://settings")!
        case .keys:
            URL(string: "\(Self.scheme)://keys")!
        case .alerts:
            URL(string: "\(Self.scheme)://alerts")!
        }
    }
}
