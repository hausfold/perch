import AppKit
import SwiftUI

// MARK: - The panes

/// The sidebar's contents, in the order they appear.
///
/// The names are load-bearing: `docs/reference.md` sends people to
/// "Settings ▸ Shelf", "Settings ▸ Watched Folders" and "Settings ▸ Updates" by
/// name. Rename one here and rename it there in the same change.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case shelf
    case folders
    case devices
    case updates

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .shelf: return "Shelf"
        case .folders: return "Watched Folders"
        case .devices: return "iPhone & iPad"
        case .updates: return "Updates"
        }
    }

    /// The line under the pane's title: what this pane is for, in one breath.
    var summary: String {
        switch self {
        case .general:
            return "How Perch starts, where it shows up, and its place in Finder."
        case .shelf:
            return "What the shelf holds on to, and what letting go of it costs."
        case .folders:
            return "Folders whose new files land on the shelf without being dropped."
        case .devices:
            return "Send to this Mac from a paired iPhone or iPad, over your own network."
        case .updates:
            return "How Perch finds out that a newer release exists."
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .shelf: return "tray.full.fill"
        case .folders: return "folder.fill"
        case .devices: return "iphone"
        case .updates: return "arrow.down.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: return .gray
        case .shelf: return .green
        case .folders: return .blue
        case .devices: return .indigo
        case .updates: return .orange
        }
    }
}

// MARK: - General

struct GeneralPane: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        SettingsPaneLayout(title: SettingsPane.general.title, subtitle: SettingsPane.general.summary) {
            SettingsCard {
                SettingsRow(
                    symbol: "power",
                    title: "Launch Perch at login",
                    subtitle: "Perch comes back in the menu bar — no window, no Dock icon."
                ) {
                    Toggle(
                        "Launch Perch at login",
                        isOn: Binding(
                            get: { settings.launchAtLogin },
                            set: { enabled in settings.setLaunchAtLogin(enabled) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                SettingsDivider()
                SettingsRow(
                    symbol: "menubar.dock.rectangle",
                    title: "Show a drop target on every display",
                    subtitle: "Each screen gets its own shelf at the notch. Off keeps it to one."
                ) {
                    Toggle("Show a drop target on every display", isOn: $settings.showOnAllDisplays)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }

            if let error = settings.launchAtLoginError {
                SettingsNote(symbol: "exclamationmark.triangle.fill", tint: .orange, text: error)
            }

            SettingsCard {
                SettingsRow(
                    symbol: "puzzlepiece.extension.fill",
                    title: "Finder Quick Action",
                    subtitle: "“Add to Perch Shelf” appears whenever files or folders are selected."
                ) {
                    Button("Open Login Items…") {
                        openFinderExtensionSettings()
                    }
                }
            }
            // macOS has no anchor that lands on the Extensions section, so the
            // button opens the top of a long pane. Name every step of the walk
            // instead — and name the row it hides behind, which is "System
            // Services", not "Perch".
            SettingsFootnote(
                """
                The Quick Action is normally on already. If it goes missing, scroll that \
                pane to Extensions, click ⓘ next to System Services, and tick \
                “Add to Perch Shelf” there.
                """
            )
        }
    }

    private func openFinderExtensionSettings() {
        // Tahoe places extensions under General › Login Items & Extensions,
        // and this is as close as macOS lets an app land: the pane opens at
        // its top, above Open at Login and the whole background-activity list,
        // with Extensions far below. Verified on 26.6 that there is no anchor
        // for that section — com.apple.ExtensionsPreferences (with and without
        // ?extensionPointIdentifier=com.apple.services) and ?extension-points
        // all open the same pane at the same top. The footnote above walks the
        // rest of the way; don't "fix" this URL without re-testing the anchors.
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Shelf

struct ShelfPane: View {
    @ObservedObject var settings: AppSettings

    /// The offered expiries. 0 is "never", and it is the default — see
    /// `AppSettings.retentionDays` for why a staged copy that expires is often
    /// the only copy there was.
    private static let choices = [0, 1, 3, 7, 14, 30]

    var body: some View {
        SettingsPaneLayout(title: SettingsPane.shelf.title, subtitle: SettingsPane.shelf.summary) {
            SettingsCard {
                SettingsRow(
                    symbol: "clock.arrow.circlepath",
                    title: "Discard items after",
                    subtitle: "Anything untouched for this long leaves the shelf on its own."
                ) {
                    Picker("Discard items after", selection: $settings.retentionDays) {
                        ForEach(offeredChoices, id: \.self) { days in
                            Text(Self.label(for: days)).tag(days)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 128)
                }
            }
            SettingsFootnote(retentionNote)

            SettingsNote(
                symbol: "lock.shield.fill",
                tint: .green,
                text: """
                    Perch always stages a private copy and only ever offers copy when you \
                    drag out. Dragging an item off the shelf removes it from the shelf; \
                    your originals are never moved or deleted.
                    """
            )
        }
    }

    /// A value stored by an older build (or by hand) has to stay selectable, or
    /// the menu would show blank and the first click would silently change it.
    private var offeredChoices: [Int] {
        Self.choices.contains(settings.retentionDays)
            ? Self.choices
            : (Self.choices + [settings.retentionDays]).sorted()
    }

    private static func label(for days: Int) -> String {
        switch days {
        case 0: return "Never"
        case 1: return "1 day"
        default: return "\(days) days"
        }
    }

    /// The note says what discarding actually *does*, not that it happens.
    /// "Discard" reads like taking something off a shelf; this is a delete, and
    /// a staged copy is often the only copy there is.
    private var retentionNote: String {
        guard settings.retentionDays > 0 else {
            return "Nothing leaves the shelf until you take it out or clear it."
        }
        return """
            Discarding deletes the staged copy — it does not go to the Trash, and for a \
            dragged-in promise, a link or typed text it is the only copy there is.
            """
    }
}

// MARK: - Watched folders

struct WatchedFoldersPane: View {
    @ObservedObject var folderWatch: FolderWatchCenter

    var body: some View {
        SettingsPaneLayout(title: SettingsPane.folders.title, subtitle: SettingsPane.folders.summary) {
            SettingsCard {
                if folderWatch.rows.isEmpty {
                    SettingsPlaceholderRow(text: "No folders watched yet.")
                } else {
                    ForEach(Array(folderWatch.rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { SettingsDivider() }
                        SettingsRow(
                            symbol: row.displayPath == nil ? "exclamationmark.triangle.fill" : "folder.fill",
                            tint: row.displayPath == nil ? .orange : .blue,
                            title: Self.name(of: row.displayPath),
                            subtitle: row.displayPath ?? "Perch can no longer reach this folder."
                        ) {
                            Button("Stop Watching") {
                                folderWatch.removeFolder(row.id)
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }

            HStack {
                Button("Watch a Folder…") {
                    addWatchedFolder()
                }
                Spacer()
            }
            .padding(.top, -8)

            SettingsFootnote(
                """
                New files that land in a watched folder are copied onto the shelf. The \
                originals never move, and taking a tile off the shelf never touches them. \
                macOS won’t tell Perch where screenshots are saved — to catch them, pick \
                that folder here.
                """
            )
        }
    }

    private static func name(of displayPath: String?) -> String {
        guard let displayPath else { return "Folder unavailable" }
        let name = (displayPath as NSString).lastPathComponent
        return name.isEmpty ? displayPath : name
    }

    /// The panel is the whole permission model: the grant it returns is what
    /// the watcher keeps (as an app-scoped bookmark — ADR 0010), so there is
    /// nothing to pre-authorize and nothing typed in by hand.
    private func addWatchedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Watch"
        panel.message = "Perch will copy new files from this folder onto the shelf."
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            folderWatch.addFolder(at: url)
        }
    }
}

// MARK: - Devices

struct DevicesPane: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var mobile: MobileReceiver

    var body: some View {
        SettingsPaneLayout(title: SettingsPane.devices.title, subtitle: SettingsPane.devices.summary) {
            SettingsCard {
                SettingsRow(
                    symbol: "antenna.radiowaves.left.and.right",
                    title: "Receive from paired devices",
                    subtitle: "Off tears the listener down. Pairings are remembered for when it comes back."
                ) {
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
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
            }

            SettingsCard {
                if mobile.pairedDevices.isEmpty {
                    SettingsPlaceholderRow(text: "No devices paired yet.")
                } else {
                    ForEach(Array(mobile.pairedDevices.enumerated()), id: \.element.id) { index, device in
                        if index > 0 { SettingsDivider() }
                        SettingsRow(
                            symbol: "iphone",
                            tint: .indigo,
                            title: device.name,
                            subtitle: "Paired \(device.pairedAt.formatted(date: .abbreviated, time: .omitted))"
                        ) {
                            Button("Revoke", role: .destructive) {
                                mobile.revoke(device)
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }

            HStack {
                Button("Pair a Device…") {
                    MobilePairingWindowController.shared.present(receiver: mobile)
                }
                .disabled(!settings.mobileEnabled)
                Spacer()
            }
            .padding(.top, -8)

            SettingsFootnote(
                """
                Anything you put on Perch on a paired iPhone lands on this shelf when both \
                are on your network — end-to-end encrypted with a key made at pairing, \
                never through a server. Revoking a device ends it instantly.
                """
            )
        }
    }
}

// MARK: - Updates

struct UpdatesPane: View {
    @ObservedObject var update: UpdateCheck
    /// Read by `UpdateCheck.automaticChecksEnabled`; defaults to on.
    @AppStorage("automaticUpdateChecks") private var automaticUpdateChecks = true

    var body: some View {
        SettingsPaneLayout(title: SettingsPane.updates.title, subtitle: SettingsPane.updates.summary) {
            SettingsCard {
                SettingsRow(
                    symbol: "arrow.clockwise",
                    title: "Check for new releases",
                    subtitle: "Perch asks GitHub for the latest tag once an hour. It is its only network call."
                ) {
                    Toggle("Check for new releases", isOn: $automaticUpdateChecks)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
                SettingsDivider()
                SettingsRow(
                    symbol: pendingVersion == nil ? "checkmark.seal.fill" : "sparkles",
                    tint: pendingVersion == nil ? .secondary : .orange,
                    title: versionTitle,
                    subtitle: versionSubtitle
                ) {
                    // Check Now stays whatever the answer was: an update taken
                    // outside the app (a `brew upgrade` in another window) is
                    // only cleared by another check, and waiting out the hourly
                    // timer is not an answer.
                    HStack(spacing: 8) {
                        Button("Check Now") {
                            update.checkForUpdates(userInitiated: true)
                        }
                        if pendingVersion != nil {
                            Button(update.installKind.buttonLabel) {
                                update.performUpdate()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                }
            }

            SettingsFootnote(
                """
                \(update.installKind.settingsNote) Sandboxed, Perch never installs the \
                update itself; it hands you the command for this install instead.
                """
            )
        }
    }

    private var pendingVersion: String? { update.pendingVersion }

    private var versionTitle: String {
        if let pending = pendingVersion {
            return "Perch \(pending) is available"
        }
        return "Perch \(update.perchVersion)"
    }

    /// A user-initiated check's answer wins the line while it lasts — it is the
    /// only feedback the button gives.
    private var versionSubtitle: String {
        if let note = update.statusNote { return note }
        if pendingVersion != nil { return update.installKind.actionHint }
        return "The version running on this Mac."
    }
}
