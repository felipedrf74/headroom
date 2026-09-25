import SwiftUI

struct AlertsSettingsView: View {
    @Bindable var store: MobileStore

    var body: some View {
        Form {
            Section {
                ForEach(AlertPreferences.supportedThresholds, id: \.self) { level in
                    Toggle("\(level)% used", isOn: threshold(level))
                }
                Toggle("A busy window resets", isOn: $store.alertPreferences.resets)
                Toggle("Banked resets", isOn: $store.alertPreferences.banked)
            } header: {
                Text("Notify me when")
            } footer: {
                Text("Once per window, whichever device notices first. \"A busy window resets\" means one that reached 80%. Banked resets alert when one is added and before it expires.")
            }

            Section {
                Toggle("Quiet Hours", isOn: $store.alertPreferences.quietHours)
                if store.alertPreferences.quietHours {
                    Picker("From", selection: $store.alertPreferences.quietStartHour) {
                        ForEach(0..<24, id: \.self) { Text(hourText($0)).tag($0) }
                    }
                    Picker("To", selection: $store.alertPreferences.quietEndHour) {
                        ForEach(0..<24, id: \.self) { Text(hourText($0)).tag($0) }
                    }
                }
            } footer: {
                Text("During quiet hours only 95% and banked resets about to expire come through. Your Macs follow these hours too.")
            }
        }
        .navigationTitle("Alerts")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func threshold(_ level: Int) -> Binding<Bool> {
        Binding(
            get: { store.alertPreferences.thresholds.contains(level) },
            set: { isOn in
                var levels = Set(store.alertPreferences.thresholds)
                if isOn { levels.insert(level) } else { levels.remove(level) }
                store.alertPreferences.thresholds = levels.sorted()
            }
        )
    }

    private func hourText(_ hour: Int) -> String {
        Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now)?.formatted(date: .omitted, time: .shortened) ?? "\(hour):00"
    }
}
