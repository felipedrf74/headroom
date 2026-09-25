import Charts
import SwiftUI

struct ProviderDetailView: View {
    var reading: MobileStore.Reading
    @State private var isFollowing = false
    @State private var followError: String?

    private var provider: RelayProvider { reading.provider }

    var body: some View {
        List {
            Section {
                header
            }
            if let window = LiveActivities.candidate(in: provider) {
                Section {
                    Button(isFollowing ? "Stop Following" : "Follow on Lock Screen", systemImage: isFollowing ? "xmark.circle" : "gauge.with.dots.needle.67percent") {
                        toggleFollowing(window)
                    }
                } footer: {
                    Text(followError ?? "Shows \(window.title.lowercased()) on the Lock Screen and in the Dynamic Island until it resets.")
                }
            }
            ForEach(provider.windows) { window in
                Section(window.title) {
                    WindowDetail(
                        window: window,
                        history: reading.history[window.id],
                        isStale: !provider.isLive,
                        tint: Color(hex: provider.tint)
                    )
                }
            }
            if let banked = provider.banked, banked.available > 0 {
                Section("Banked resets") {
                    Text(ReadingText.banked(banked))
                    ForEach(banked.expiries.filter { $0 > .now }.sorted(), id: \.self) { expiry in
                        LabeledContent("Expires", value: expiry.formatted(date: .abbreviated, time: .shortened))
                    }
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
                Text("Tokenroom isn't affiliated with \(provider.name).")
            }
        }
        .navigationTitle(provider.name)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            isFollowing = LiveActivities.activity(for: provider.id) != nil
        }
    }

    private func toggleFollowing(_ window: RelayWindow) {
        if isFollowing {
            Task {
                await LiveActivities.stop(provider.id)
                isFollowing = false
            }
            return
        }
        guard LiveActivities.isEnabled else {
            followError = "Live Activities are off for Tokenroom. Turn them on in Settings › Tokenroom."
            return
        }
        do {
            isFollowing = try LiveActivities.start(provider, window: window)
            followError = nil
        } catch {
            followError = "Couldn't start the Live Activity."
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            MonogramMark(provider: provider, size: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(provider.name)
                    .font(.title3.weight(.semibold))
                if let plan = provider.plan {
                    Text(plan)
                        .foregroundStyle(.secondary)
                }
                if !provider.isLive, let message = provider.message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
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
                if let amount = window.amount, let detail = ReadingText.amountDetail(amount) {
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
        Chart(points) { point in
            AreaMark(x: .value("Hour", point.date), y: .value("Used", point.used))
                .foregroundStyle(LinearGradient(colors: [tint.opacity(0.3), tint.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                .interpolationMethod(.monotone)
            LineMark(x: .value("Hour", point.date), y: .value("Used", point.used))
                .foregroundStyle(tint)
                .interpolationMethod(.monotone)
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
