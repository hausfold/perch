import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    /// Read by `UpdateCheck.automaticChecksEnabled`; defaults to on.
    @AppStorage("automaticUpdateChecks") private var automaticUpdateChecks = true
    @ObservedObject private var update: UpdateCheck = .shared

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

            Section("Updates") {
                Toggle("Check for new releases", isOn: $automaticUpdateChecks)
                HStack {
                    Button("Check Now") {
                        update.checkForUpdates(userInitiated: true)
                    }
                    if let note = update.statusNote {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    } else if let pending = update.pendingVersion {
                        Text("Perch \(pending) is available")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text("\(update.installKind.settingsNote) Perch asks GitHub for the latest tag once an hour — one request carrying nothing but an IP, and the only network call it ever makes. Being sandboxed, it never installs the update itself: the shelf hands you the command for this install instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("Perch always stages a private copy and only offers copy operations when dragging out. Dragging an item out removes it from the shelf; your original files are never moved or deleted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // Tall enough for the Updates section's explanation without the form
        // scrolling — a settings window this small should show everything at once.
        .frame(width: 470, height: 520)
        .navigationTitle("Perch Settings")
    }
}
