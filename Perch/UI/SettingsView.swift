import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Shelf") {
                Toggle("Show a drop target on every display", isOn: $settings.showOnAllDisplays)
                Stepper(
                    "Discard items older than \(settings.retentionDays) day\(settings.retentionDays == 1 ? "" : "s")",
                    value: $settings.retentionDays,
                    in: 1...30
                )
            }

            Section("System") {
                Toggle(
                    "Launch Perch at login",
                    isOn: Binding(
                        get: { settings.launchAtLogin },
                        set: { enabled in settings.setLaunchAtLogin(enabled) }
                    )
                )
                if let error = settings.launchAtLoginError {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section {
                Text("Perch always stages a private copy and only offers copy operations when dragging out. Dragging an item out removes it from the shelf; your original files are never moved or deleted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 470, height: 330)
        .navigationTitle("Perch Settings")
    }
}
