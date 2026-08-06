import SwiftUI

@main
struct PerchMobileApp: App {
    @StateObject private var model = MobileAppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ShelfListView(model: model)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        // A share may have staged items while we were away;
                        // the disk is the truth.
                        model.becameActive()
                    } else if phase == .background {
                        model.becameInactive()
                    }
                }
        }
    }
}
