import SwiftUI

/// A new model: lab, name, context and prices. Opens OpenRouter's page for it.
struct ModelReleaseRow: View {
    var release: ModelRelease
    var isNew = false

    var body: some View {
        let row = VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(release.vendorName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if isNew {
                    NewBadge()
                }
                Spacer()
                if let expires = release.expires, expires > .now {
                    Text("Retires \(expires.formatted(.dateTime.month(.abbreviated).day()))")
                        .font(.caption)
                        .foregroundStyle(TokenroomTokens.tight)
                } else {
                    Text(release.created.formatted(.dateTime.month(.abbreviated).day()))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Text(release.shortName)
                .font(.headline)
                .foregroundStyle(.primary)
            if let details {
                Text(details)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
        if let link = release.link {
            // Links tint their labels; rows keep their own colors.
            Link(destination: link) { row }
                .foregroundStyle(.primary)
        } else {
            row
        }
    }

    /// "1M context · $4 in, $20 out per million tokens".
    private var details: String? {
        var parts: [String] = []
        if let context = release.contextLength, context > 0 {
            parts.append("\(context.formatted(.number.notation(.compactName))) context")
        }
        if let prompt = release.promptPrice, let completion = release.completionPrice {
            if prompt == 0, completion == 0 {
                parts.append("Free")
            } else {
                parts.append("\(Self.price(prompt)) in, \(Self.price(completion)) out per million tokens")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "$4", "$0.10", "$0.075".
    static func price(_ value: Double) -> String {
        // Per-token prices times a million carry float noise: 0.1 arrives as 0.0999….
        let value = (value * 1000).rounded() / 1000
        let digits = value == value.rounded() ? 0 : (value < 0.1 ? 3 : 2)
        return value.formatted(.currency(code: "USD").precision(.fractionLength(digits)))
    }
}

/// An official announcement or release: source, title, when. Opens the post.
struct AnnouncementRow: View {
    var item: FeedItem
    var isNew = false

    var body: some View {
        let row = HStack(alignment: .top, spacing: 10) {
            if let provider {
                MonogramMark(text: provider.monogram, tint: Color(hex: provider.tintHex), size: 26)
                    .padding(.top, 1)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.source)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if isNew {
                        NewBadge()
                    }
                    Spacer()
                    if let published = item.published {
                        Text(RelativeTime.ago(published))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(item.displayTitle)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 2)
        if let link = item.link {
            Link(destination: link) { row }
                .foregroundStyle(.primary)
        } else {
            row
        }
    }

    private var provider: Provider? {
        FeedSource.catalog.first { $0.name == item.source }?.provider
    }
}

/// A News section's footer: where its items come from, after any feed that couldn't be read.
struct NewsFooter: View {
    var text: String
    var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let problem {
                Text(problem)
            }
            Text(text)
        }
    }
}

/// Marks an item published since News was last opened.
struct NewBadge: View {
    var body: some View {
        Text("New")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tint)
            .accessibilityLabel("New")
    }
}
