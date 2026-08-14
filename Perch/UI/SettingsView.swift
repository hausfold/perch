import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var mobile: MobileReceiver
    /// Read by `UpdateCheck.automaticChecksEnabled`; defaults to on.
    @AppStorage("automaticUpdateChecks") private var automaticUpdateChecks = true
    @ObservedObject private var update: UpdateCheck = .shared
    @ObservedObject private var license: LicenseStore = .shared
    /// Evaluated once per window, not once per redraw. See `fittingHeight()`.
    @State private var windowHeight = SettingsView.fittingHeight()

    var body: some View {
        Form {
            Section("Shelf") {
                Toggle("Show a drop target on every display", isOn: $settings.showOnAllDisplays)
                // 0 is "never", and it is where the stepper starts. See
                // AppSettings.retentionDays for why the default is off: a
                // staged copy that expires is deleted outright, and for a
                // promised file, a link or typed text it was the only copy.
                Stepper(
                    retentionDescription,
                    value: $settings.retentionDays,
                    in: 0...30
                )
                Text(retentionNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

            Section("Finder") {
                Button("Open Finder Extension Settings…") {
                    openFinderExtensionSettings()
                }
                Text("Enable “Add to Perch Shelf” once under Finder extensions; it then appears in Finder’s Quick Actions whenever files or folders are selected.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                Text("Your license is a signed file — import it here, or drop it on the shelf. It is verified on this Mac and never sent anywhere: no account, no activation server. It covers every build released within a year of your purchase, and keeps working on those builds forever.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            }

            Section("iPhone & iPad") {
                Toggle(
                    "Receive from paired devices",
                    isOn: Binding(
                        get: { settings.mobileEnabled },
                        set: { enabled in
                            settings.mobileEnabled = enabled
                            mobile.applyEnabledSetting()
                        }
                    )
                )
                Button("Pair a Device…") {
                    MobilePairingWindowController.shared.present(receiver: mobile)
                }
                .disabled(!settings.mobileEnabled)
                ForEach(mobile.pairedDevices) { device in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(device.name)
                            Text("Paired \(device.pairedAt.formatted(date: .abbreviated, time: .omitted))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Revoke", role: .destructive) {
                            mobile.revoke(device)
                        }
                        .controlSize(.small)
                    }
                }
                Text("Anything you put on Perch on a paired iPhone lands on this shelf when both are on your network — end-to-end encrypted with a key made at pairing, never through a server. Revoking a device ends it instantly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                Text("\(update.installKind.settingsNote) Perch asks GitHub for the latest tag once an hour — its only network call. Sandboxed, it never installs the update itself; the shelf hands you the command for this install instead.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("Perch always stages a private copy and only ever offers copy when you drag out. Dragging an item out removes it from the shelf; your originals are never moved or deleted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // Sized once, when the window is made — not on every body pass, or an
        // update check landing an hour later would resize the window under
        // whoever is reading it.
        .frame(width: Self.windowWidth, height: windowHeight)
        .navigationTitle(Self.windowTitle)
    }

    static let windowTitle = "Perch Settings"
    private static let windowWidth: CGFloat = 470

    /// A settings window whose last rows sit under the Dock can't be reached at
    /// all, so the height is whatever the screen can actually show, minus the
    /// title bar — `visibleFrame` has already taken out the menu bar and the
    /// Dock. The 700 ceiling is a deliberate stop short of "one screenful of
    /// everything": a pane with six sections reads better scrolled than
    /// stretched the full height of a large display. `Form` supplies the
    /// scrolling.
    private static func fittingHeight() -> CGFloat {
        let room = (NSScreen.main?.visibleFrame.height ?? 800) - 60
        return max(320, min(700, room))
    }

    private var retentionDescription: String {
        guard settings.retentionDays > 0 else { return "Never discard old items" }
        let days = settings.retentionDays
        return "Discard items older than \(days) day\(days == 1 ? "" : "s")"
    }

    /// The note says what discarding actually *does*, not that it happens.
    /// "Discard" reads like taking something off a shelf; this is a delete, and
    /// a staged copy is often the only copy there is.
    private var retentionNote: String {
        guard settings.retentionDays > 0 else {
            return "Nothing leaves the shelf until you take it out or clear it."
        }
        return """
            Discarding deletes the staged copy — it does not go to the Trash, \
            and for a dragged-in promise, a link or typed text it is the only \
            copy there is.
            """
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

    private func openFinderExtensionSettings() {
        // Tahoe places extensions under General › Login Items & Extensions.
        // Older supported releases still accept this pane identifier and land
        // close enough for the Finder extension toggle to be obvious.
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
