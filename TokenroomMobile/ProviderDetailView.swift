import Charts
import SwiftUI

struct ProviderDetailView: View {
    var reading: MobileStore.Reading
    @State private var followError: String?

    private var provider: RelayProvider { reading.provider }

    /// The window the provider leads with, then the rest.
    private var orderedWindows: [RelayWindow] {
        guard let primary = provider.primaryWindow else { return provider.windows }
        return [primary] + provider.windows.filter { $0.id != primary.id }
    }

    var body: some View {
        List {
            Section {
                header
            }
            ForEach(Array(orderedWindows.enumerated()), id: \.element.id) { index, window in
                Section(window.title) {
                    WindowDetail(
                        window: window,
                        history: reading.history[window.id],
                        isStale: !provider.isLive,
                        tint: Color(hex: provider.tint)
                    )
                }
                if index == 0, let candidate = LiveActivities.candidate(in: provider) {
                    Section {
                        FollowButton(provider: provider) { followError = $0 }
                    } footer: {
                        Text(followError ?? "Shows a countdown to the \(candidate.title.lowercased()) reset on the Lock Screen and in the Dynamic Island until it resets.")
                    }
                }
            }
            if let banked = provider.banked, banked.available > 0 {
                Section {
                    Text(ReadingText.banked(banked))
                    ForEach(banked.expiries.filter { $0 > .now }.sorted(), id: \.self) { expiry in
                        LabeledContent("Expires", value: expiry.formatted(date: .abbreviated, time: .shortened))
                    }
                } header: {
                    Text("Banked resets")
                } footer: {
                    Text("A banked reset clears a limit early. Use one from \(provider.shortName) when a limit runs out; Tokenroom only shows them.")
                }
            }
            if let extra = provider.extra, let text = ReadingText.extra(extra) {
                Section("Beyond the plan") {
                    Text(text)
                }
            }
            Section {
                LabeledContent("From", value: reading.source)
                if let checked = provider.checkedAt ?? provider.fetchedAt {
                    LabeledContent("Checked", value: RelativeTime.ago(checked))
                }
            } footer: {
                Text("The line on each meter marks an even pace: where usage would be if spread evenly across the window. Tokenroom isn't affiliated with \(provider.name).")
            }
        }
        .navigationTitle(provider.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        HStack(spacing: 14) {
            MonogramMark(provider: provider, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                if let plan = provider.plan {
                    Text(plan)
                        .font(.headline)
                } else {
                    Text(provider.name)
                        .font(.headline)
                }
                if !provider.isLive, let message = provider.message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if let checked = provider.checkedAt ?? provider.fetchedAt {
                    Text("Checked \(RelativeTime.ago(checked))")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

private struct WindowDetail: View {
    var window: RelayWindow
    var history: UsageHistory?
    var isStale: Bool
    var tint: Color

    private var pace: Pace? {
        window.isMetered ? UsageRanking.pace(for: window, isStale: isStale, history: history) : nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(ReadingText.headline(window))
                    .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(window.isMetered ? TokenroomTokens.ink(remaining: 100 - window.used, isStale: isStale) : .primary)
                if window.isMetered {
                    Text("used")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let amount = window.amount, let detail = ReadingText.amountDetail(amount), detail != ReadingText.headline(window) {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            if window.isMetered {
                MeterTrack(usedPercent: window.used, remaining: 100 - window.used, isStale: isStale, paceMark: pace?.elapsedFraction, height: 10)
            }
            if let pace {
                Text(pace.caption())
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(PaceStyle.color(pace.severity))
            }
            if let forecast = Forecast.text(for: window, history: history) {
                Text(forecast)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)

        if let resetsAt = window.resetsAt {
            LabeledContent("Resets") {
                VStack(alignment: .trailing) {
                    Text(resetsAt.formatted(date: .abbreviated, time: .shortened))
                    if let relative = RelativeTime.resets(resetsAt) {
                        Text(relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        if let history, !history.isEmpty, window.isMetered {
            VStack(alignment: .leading, spacing: 6) {
                Text("Last 7 days")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HistoryChart(history: history, tint: tint)
                    .frame(height: 120)
            }
            .padding(.vertical, 4)
        }
    }
}

private struct HistoryChart: View {
    var history: UsageHistory
    var tint: Color

    private struct Point: Identifiable {
        var date: Date
        var used: Double
        var id: Date { date }
    }

    var body: some View {
        let points = history.points.map { Point(date: $0.date, used: $0.used) }
        Chart {
            ForEach(points) { point in
                AreaMark(x: .value("Hour", point.date), y: .value("Used", point.used))
                    .foregroundStyle(LinearGradient(colors: [tint.opacity(0.3), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Hour", point.date), y: .value("Used", point.used))
                    .foregroundStyle(tint)
                    .interpolationMethod(.monotone)
            }
            // When the window reset during the week.
            ForEach(history.resets ?? [], id: \.self) { reset in
                RuleMark(x: .value("Reset", reset))
                    .foregroundStyle(.secondary.opacity(0.6))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .accessibilityLabel("Reset")
                    .accessibilityValue(reset.formatted(date: .abbreviated, time: .shortened))
            }
        }
        .chartYScale(domain: 0...100)
        .chartYAxis {
            AxisMarks(values: [0, 50, 100]) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let percent = value.as(Int.self) {
                        Text("\(percent)%")
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.weekday(.narrow))
            }
        }
        .accessibilityLabel("Usage over the last 7 days")
    }
}
