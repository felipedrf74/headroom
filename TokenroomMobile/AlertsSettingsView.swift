import SwiftUI
import UserNotifications

struct AlertsSettingsView: View {
    @Bindable var store: MobileStore
    @State private var permission: UNAuthorizationStatus?
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            if let permission, permission != .authorized, permission != .provisional, permission != .ephemeral {
                Section {
                    Label(permission == .denied ? "Notifications are off for Tokenroom" : "Notifications aren't on yet", systemImage: "bell.slash")
                    Button(permission == .denied ? "Open Settings" : "Turn On Notifications") {
                        if permission == .denied {
                            if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                                openURL(url)
                            }
                        } else {
                            Task {
                                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                                await checkPermission()
                            }
                        }
                    }
                } footer: {
                    Text("Tokenroom can't alert you until notifications are allowed.")
                }
            }

            Section {
                ForEach(AlertPreferences.supportedThresholds, id: \.self) { level in
                    Toggle("\(level)% of a limit is used", isOn: threshold(level))
                }
                Toggle("A busy window resets", isOn: $store.alertPreferences.resets)
                Toggle("Banked resets", isOn: $store.alertPreferences.banked)
                Toggle("A balance or budget runs low", isOn: $store.alertPreferences.lowBalance)
                Toggle("New models from labs you follow", isOn: $store.alertPreferences.newModels)
            } header: {
                Text("Notify me when")
            } footer: {
                Text("Once per window, whichever device notices first. \"A busy window resets\" means one that reached 80%. Banked resets alert when one is added and before it expires. Low balance needs a reference or budget in API Keys. Your Macs share these choices through iCloud; a change on either applies to both.")
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
                Text("During quiet hours only 95% alerts and banked resets about to expire come through; the rest arrive when quiet hours end. Your Macs follow these hours too.")
            }
        }
        .navigationTitle("Alerts")
        .navigationBarTitleDisplayMode(.inline)
        .task { await checkPermission() }
        .onChange(of: scenePhase) { _, phase in
            // Back from Settings with notifications turned on.
            if phase == .active {
                Task { await checkPermission() }
            }
        }
    }

    private func checkPermission() async {
        permission = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
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
