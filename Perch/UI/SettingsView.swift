import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var mobile: MobileReceiver
    /// Read by `UpdateCheck.automaticChecksEnabled`; defaults to on.
    @AppStorage("automaticUpdateChecks") private var automaticUpdateChecks = true
    @ObservedObject private var update: UpdateCheck = .shared
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
                Button("Open Login Items & Extensions…") {
                    openFinderExtensionSettings()
                }
                // macOS has no anchor that lands on the Extensions section, so
                // the button opens the top of a long pane. Name every step of
                // the walk instead — and name the row it hides behind, which is
                // "System Services", not "Perch".
                Text("“Add to Perch Shelf” is normally on already; it appears in Finder’s Quick Actions whenever files or folders are selected. If it goes missing, scroll that pane to Extensions, click ⓘ next to System Services, and tick “Add to Perch Shelf” there.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    private func openFinderExtensionSettings() {
        // Tahoe places extensions under General › Login Items & Extensions,
        // and this is as close as macOS lets an app land: the pane opens at
        // its top, above Open at Login and the whole background-activity list,
        // with Extensions far below. Verified on 26.6 that there is no anchor
        // for that section — com.apple.ExtensionsPreferences (with and without
        // ?extensionPointIdentifier=com.apple.services) and ?extension-points
        // all open the same pane at the same top. The caption above walks the
        // rest of the way; don't "fix" this URL without re-testing the anchors.
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
