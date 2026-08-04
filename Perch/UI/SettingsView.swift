import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    /// Read by `UpdateCheck.automaticChecksEnabled`; defaults to on.
    @AppStorage("automaticUpdateChecks") private var automaticUpdateChecks = true
    @ObservedObject private var update: UpdateCheck = .shared
    @ObservedObject private var license: LicenseStore = .shared

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

            // Everything licensing, in one place and in plain words: what this
            // Mac is entitled to, which builds the entitlement covers, and the
            // two buttons (import, remove) that move a seat between machines.
            // No account, no sign-in, no "activate" — the license file IS the
            // account, and it verifies offline.
            // Hidden entirely on a build that can't honour a license (no public
            // key baked in yet — see LicenseStore.canSell). A pane offering to
            // sell something the store can't yet take money for is worse than
            // no pane at all.
            if license.canSell {
            Section("License") {
                Text(license.stateDescription)
                    .font(.callout)
                    .foregroundStyle(.primary)
                HStack {
                    Button("Import License…", action: importLicense)
                    if license.state.license != nil {
                        Button("Remove", role: .destructive) {
                            license.removeLicense()
                        }
                    } else {
                        Link("Buy Perch — $19", destination: LicenseStore.purchaseURL)
                    }
                }
                if let note = license.importNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                Text("Your license is a signed file — import it here, or just drop it on the shelf. Perch verifies it on this Mac and never sends it anywhere; there is no activation server and nothing to sign in to. It covers every build released within a year of your purchase and keeps working on those builds forever.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        .frame(width: 470, height: 660)
        .navigationTitle("Perch Settings")
    }

    /// The standard picker — a file the user chose is inside the sandbox's
    /// `user-selected.read-write` grant, so importing needs no new entitlement.
    private func importLicense() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Import"
        panel.message = "Choose your Perch license file."
        if let type = UTType(filenameExtension: License.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        license.importLicense(from: url)
    }
}
