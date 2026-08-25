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
                    subtitle: "Perch comes back in the menu bar — no window, no Dock icon.",
                    locked: settings.isDeclared(AppConfig.Key.launchAtLogin)
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
                    subtitle: "Each screen gets its own shelf at the notch. Off keeps it to your main display.",
                    locked: settings.isDeclared(AppConfig.Key.showOnAllDisplays)
                ) {
                    Toggle("Show a drop target on every display", isOn: $settings.showOnAllDisplays)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }

            SettingsDeclaredNote(
                settings: settings,
                keys: [AppConfig.Key.launchAtLogin, AppConfig.Key.showOnAllDisplays]
            )
            SettingsWriteErrorNote(settings: settings)

            if let error = settings.launchAtLoginError {
                SettingsNote(symbol: "exclamationmark.triangle.fill", tint: .orange, text: error)
            }

            SettingsCard {
                SettingsRow(
                    symbol: "contextualmenu.and.cursorarrow",
                    title: "Finder’s right-click menu",
                    subtitle: "“Add to Perch Shelf” is under Services whenever files or folders are selected."
                ) {}
            }
            // No button here on purpose. This is a classic Service, which is on
            // by default and needs no enabling — and the one place macOS lets a
            // user turn it off is a pane with no anchor that lands on it, so a
            // button would open the top of a long list and leave the same walk
            // to describe. Describe the walk and skip the button.
            SettingsFootnote(
                """
                It is on by default. If it ever goes missing, it is in System Settings ▸ \
                Keyboard ▸ Keyboard Shortcuts… ▸ Services, under Files and Folders.
                """
            )

            SettingsFootnote(
                """
                Every switch in this window is stored in \(configPath) — the file is what \
                Perch reads, so editing it by hand is the same as clicking here, and it \
                lands without a relaunch.
                """
            )
        }
    }

    /// Named, not hidden behind a button: it is the only way to find a path
    /// inside the sandbox container, where nobody would think to look.
    private var configPath: String {
        RiceFiles.abbreviate(settings.configFileURL.path)
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
                    subtitle: "Anything added longer ago than this leaves the shelf on its own. Pinned items stay.",
                    locked: settings.isDeclared(AppConfig.Key.retentionDays)
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

            SettingsDeclaredNote(settings: settings, keys: [AppConfig.Key.retentionDays])
            SettingsWriteErrorNote(settings: settings)

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

    /// Which watched folder the person meant by "my screenshots". Not a
    /// preference — a memory of the panel they clicked, so the switch below
    /// still reads as on when their captures land somewhere
    /// `screenshotsTarget` would never have guessed.
    ///
    /// The folder's ID and deliberately not its path: a watched folder lives
    /// in this app as a security bookmark precisely so no plain source path is
    /// persisted anywhere, and a convenience switch is no reason to be the one
    /// place that writes one down. Empty until the switch is used at all, and
    /// stale the moment that folder is removed — which is why it is only ever
    /// consulted against the rows that exist.
    @AppStorage("screenshotsFolderID") private var screenshotsFolderID: String = ""

    /// The rice's answer, read once when the pane appears rather than from a
    /// body accessor — same spirit as ShelfTheme re-reading the drop when the
    /// shelf opens, and no file watcher anywhere. nil until the read lands,
    /// which reads as the Desktop: macOS's own default, and right far more
    /// often than not.
    @State private var riceFolder: URL?

    var body: some View {
        SettingsPaneLayout(title: SettingsPane.folders.title, subtitle: SettingsPane.folders.summary) {
            SettingsCard {
                SettingsRow(
                    symbol: "camera.viewfinder",
                    tint: .blue,
                    title: "Shelf my screenshots",
                    subtitle: screenshotsSubtitle
                ) {
                    Toggle(
                        "Shelf my screenshots",
                        isOn: Binding(
                            get: { screenshotsRow != nil },
                            set: { wanted in setScreenshotsWatched(wanted) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
            }

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
                Every folder here is one you picked in a panel — the screenshots switch \
                above opens that same panel, already pointed at the folder your captures \
                go to.
                """
            )
        }
        // Off main: a read is small, but the pane is not the place to make an
        // exception to "blocking file work stays off the main actor".
        .task { riceFolder = await Task.detached(priority: .utility) { ScreenshotsFolder.resolve() }.value }
    }

    // MARK: Shelf my screenshots

    /// The folder the switch OFFERS when nothing is watched yet: what the
    /// desktop config named, else the Desktop.
    private var screenshotsTarget: URL {
        riceFolder ?? RiceFiles.home.appendingPathComponent("Desktop", isDirectory: true)
    }

    /// The watched folder this switch is about, if there is one: the one the
    /// person picked through it, else whichever row happens to sit on the
    /// folder we would have offered — so a folder added through "Watch a
    /// Folder…" reads as on too, rather than as a second thing to turn on.
    private var screenshotsRow: FolderWatchCenter.Row? {
        if let id = UUID(uuidString: screenshotsFolderID),
           let row = folderWatch.rows.first(where: { $0.id == id }) {
            return row
        }
        guard let id = folderWatch.watchedFolderID(for: screenshotsTarget) else { return nil }
        return folderWatch.rows.first { $0.id == id }
    }

    private var screenshotsSubtitle: String {
        guard let row = screenshotsRow else {
            return "Perch will ask for \(Self.abbreviate(screenshotsTarget.path)) once, "
                + "then new captures land on the shelf."
        }
        guard let path = row.displayPath else {
            return "Perch can no longer reach that folder."
        }
        return "New captures in \(path) land on the shelf."
    }

    /// On: the same panel as “Watch a Folder…”, already at the right folder —
    /// the grant has to come from a panel, so the most this can save is the
    /// navigating and the knowing-where. Cancelling grants nothing and the
    /// switch falls back, which is the truth: nothing is being watched.
    ///
    /// Whatever they actually pick becomes the screenshots folder, even when
    /// it isn’t the one we offered. They know where their captures go and we
    /// were guessing.
    private func setScreenshotsWatched(_ wanted: Bool) {
        guard wanted else {
            if let row = screenshotsRow { folderWatch.removeFolder(row.id) }
            screenshotsFolderID = ""
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = screenshotsTarget
        panel.prompt = "Watch"
        panel.message = "Perch will copy new screenshots from this folder onto the shelf."
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // The id comes back even when perch was already watching that folder,
        // so picking one that is in the list simply adopts it.
        if let id = folderWatch.addFolder(at: url) {
            screenshotsFolderID = id.uuidString
        }
    }

    /// `~`-abbreviated for display only, against the real home — inside the
    /// sandbox `NSHomeDirectory()` is the container (same reason
    /// `FolderWatchCenter` goes through `RiceFiles.home`).
    private static func abbreviate(_ path: String) -> String {
        let home = RiceFiles.home.path
        guard path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }

    private static func name(of displayPath: String?) -> String {
        guard let displayPath else { return "Folder unavailable" }
        let name = (displayPath as NSString).lastPathComponent
        return name.isEmpty ? displayPath : name
    }

    /// The panel is the whole permission model: the grant it returns is what
    /// the watcher keeps (as an app-scoped bookmark), so there is
    /// nothing to pre-authorize and nothing typed in by hand.
    private func addWatchedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Watch"
        panel.message = "Perch will copy new files from this folder onto the shelf."
        NSApp.activate()
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
                    subtitle: "Off tears the listener down. Pairings are remembered for when it comes back.",
                    locked: settings.isDeclared(AppConfig.Key.mobileEnabled)
                ) {
                    // Plain binding: `MobileReceiver` follows the setting's
                    // publisher, so the listener starts and stops whether the
                    // change came from this switch or from the file.
                    Toggle("Receive from paired devices", isOn: $settings.mobileEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                }
            }

            SettingsDeclaredNote(settings: settings, keys: [AppConfig.Key.mobileEnabled])
            SettingsWriteErrorNote(settings: settings)

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
    @ObservedObject var settings: AppSettings
    @ObservedObject var update: UpdateCheck

    var body: some View {
        SettingsPaneLayout(title: SettingsPane.updates.title, subtitle: SettingsPane.updates.summary) {
            SettingsCard {
                SettingsRow(
                    symbol: "arrow.clockwise",
                    title: "Check for new releases",
                    subtitle: "Perch asks GitHub for the latest tag once an hour. It is its only network call.",
                    locked: settings.isDeclared(AppConfig.Key.automaticUpdateChecks)
                ) {
                    Toggle("Check for new releases", isOn: $settings.automaticUpdateChecks)
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

            SettingsDeclaredNote(
                settings: settings, keys: [AppConfig.Key.automaticUpdateChecks]
            )
            SettingsWriteErrorNote(settings: settings)

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
