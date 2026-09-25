import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

struct SessionActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SessionActivityAttributes.self) { context in
            SessionLockScreenView(attributes: context.attributes, state: context.state)
                .widgetURL(DeepLink.provider(context.attributes.providerID).url)
        } dynamicIsland: { context in
            let attributes = context.attributes
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 8) {
                        MonogramMark(text: attributes.monogram, tint: Color(hex: attributes.tint), size: 28)
                        Text(attributes.shortName)
                            .font(.headline)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(state.percentText)
                        .font(.system(.title2, design: .rounded, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(TokenroomTokens.usageColor(usedPercent: state.used, isStale: state.isStale))
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: min(max(state.used, 0), 100), total: 100)
                            .tint(TokenroomTokens.usageColor(usedPercent: state.used, isStale: state.isStale))
                        HStack {
                            Text(attributes.windowTitle)
                            Spacer()
                            Countdown(resetsAt: state.resetsAt)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Text(attributes.monogram)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color(hex: attributes.tint))
            } compactTrailing: {
                Text(state.percentText)
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(TokenroomTokens.usageColor(usedPercent: state.used, isStale: state.isStale))
            } minimal: {
                Gauge(value: min(max(state.used, 0), 100), in: 0...100) {
                    Text(attributes.monogram)
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .tint(TokenroomTokens.usageColor(usedPercent: state.used, isStale: state.isStale))
            }
            .widgetURL(DeepLink.provider(attributes.providerID).url)
            .keylineTint(Color(hex: attributes.tint))
        }
        .supplementalActivityFamilies([.small])
    }
}

/// A Control Center and Lock Screen control that follows the most urgent window.
struct FollowUsageControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "app.tokenroom.follow") {
            ControlWidgetButton(action: FollowUsageIntent()) {
                Label("Follow Usage", systemImage: "gauge.with.dots.needle.67percent")
            }
        }
        .displayName("Follow Usage")
        .description("Shows your most urgent limit on the Lock Screen until it resets.")
    }
}
