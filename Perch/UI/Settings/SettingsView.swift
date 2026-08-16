import AppKit
import SwiftUI

/// The Settings window: a sidebar of panes on the left, one scrolling pane on
/// the right.
///
/// **Why a sidebar.** Six sections in one column meant a window as tall as the
/// tallest section — which, on a laptop, was taller than the screen, with the
/// last rows parked under the Dock and no way to resize down to them. A pane at
/// a time is short enough that the window opens small, and every pane scrolls
/// on its own if it needs to.
struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var mobile: MobileReceiver
    @ObservedObject var folderWatch: FolderWatchCenter
    @ObservedObject private var update: UpdateCheck = .shared
    /// Which pane the window comes back to. Persisted, like every mac settings
    /// window: reopening lands where you left off, not on the first tab.
    @AppStorage("settingsSelectedPane") private var selectedPaneID = SettingsPane.general.rawValue

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: selection) { pane in
                Label {
                    Text(pane.title)
                        .padding(.leading, 2)
                } icon: {
                    SettingsPaneChip(symbol: pane.symbol, tint: pane.tint)
                }
                .padding(.vertical, 3)
            }
            // Nothing to toggle: a settings window with a collapsible sidebar
            // is a settings window you can hide the navigation of.
            .toolbar(removing: .sidebarToggle)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                SettingsSidebarFooter(version: update.perchVersion)
            }
            // Outermost, and fixed: this is the width that has to hold
            // "Watched Folders" without an ellipsis, and a settings sidebar has
            // no reason to be draggable.
            .navigationSplitViewColumnWidth(210)
        } detail: {
            pane
                .frame(minWidth: 460, idealWidth: 520)
        }
        // A range, not a fixed size. The minimum is what
        // `.windowResizability(.contentMinSize)` hands the window as its floor;
        // the open end is what lets a dragged corner grow it. The size it
        // *opens* at is the configurator's business, below — SwiftUI ignores an
        // ideal here and sizes a split view its own way.
        .frame(
            minWidth: 670, maxWidth: .infinity,
            minHeight: 400, maxHeight: .infinity
        )
        .background(SettingsWindowConfigurator(defaultSize: Self.defaultWindowSize))
        .navigationTitle(Self.windowTitle)
    }

    static let windowTitle = "Perch Settings"
    /// What the window opens at the first time, before anyone has resized it.
    private static let defaultWindowSize = NSSize(width: 770, height: 560)

    @ViewBuilder
    private var pane: some View {
        switch SettingsPane(rawValue: selectedPaneID) ?? .general {
        case .general:
            GeneralPane(settings: settings)
        case .shelf:
            ShelfPane(settings: settings)
        case .folders:
            WatchedFoldersPane(folderWatch: folderWatch)
        case .devices:
            DevicesPane(settings: settings, mobile: mobile)
        case .updates:
            UpdatesPane(update: update)
        }
    }

    /// `List` selects by element ID, and a pane's ID is its raw value — so the
    /// stored default *is* the selection. A nil set (clicking the sidebar's
    /// empty space) is dropped: there is always a pane on screen.
    private var selection: Binding<String?> {
        Binding(
            get: { selectedPaneID },
            set: { newValue in
                guard let newValue else { return }
                selectedPaneID = newValue
            }
        )
    }
}

/// Gives the Settings window a resize control, and a size to open at.
///
/// A `Settings` scene's window is built **without** `.resizable` in its style
/// mask, and `.windowResizability` does not put it back — that modifier only
/// sets the content min/max, which is why the old window could be 700pt tall
/// with its last rows under the Dock and no handle anywhere to drag it smaller.
/// One `insert` is the whole fix.
///
/// The frame is autosaved under Perch's own name rather than SwiftUI's: the
/// fixed-size window left a 470×732 frame behind under the SwiftUI key, and
/// restoring that would reopen this window in the shape of the bug.
private struct SettingsWindowConfigurator: NSViewRepresentable {
    let defaultSize: NSSize

    private static let autosaveName = "PerchSettingsWindow"

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // One runloop turn later: the view has no window until SwiftUI has
        // installed it, and SwiftUI sizes the window from the content first.
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    // Again on every update pass, not only at make: on a cold open the view can
    // reach `makeNSView` before SwiftUI has put it in a window, and a single
    // missed turn would leave this window unresizable for the whole session —
    // the exact bug this exists to fix. `configure` is idempotent.
    func updateNSView(_ nsView: NSView, context: Context) {
        configure(nsView.window)
    }

    private func configure(_ window: NSWindow?) {
        // The style mask doubles as the "already done" marker: a settings
        // window that is resizable is one this has already run against.
        guard let window, !window.styleMask.contains(.resizable) else { return }
        window.styleMask.insert(.resizable)
        _ = window.setFrameAutosaveName(Self.autosaveName)
        guard !window.setFrameUsingName(Self.autosaveName) else { return }
        window.setContentSize(defaultSize)
        window.center()
    }
}

/// The sidebar's foot: which perch this is, in the place every mac app puts it.
private struct SettingsSidebarFooter: View {
    let version: String

    var body: some View {
        VStack(spacing: 0) {
            Divider()
                .opacity(0.6)
            HStack(spacing: 9) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .frame(width: 30, height: 30)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Perch")
                        .font(.system(size: 12, weight: .semibold))
                    Text(version)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
    }
}
