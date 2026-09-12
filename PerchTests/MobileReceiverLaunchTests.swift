import XCTest

@testable import Perch

/// The launch gate that keeps a clean Mac off the local network.
///
/// Advertising `_perch._tcp` is what makes macOS put up the Local Network
/// prompt, and `AppRuntime.start()` used to bring the listener up on every
/// launch — so the prompt met someone who installed a file shelf before any
/// pairing was possible. The gate is now `startForLaunch`: no paired devices,
/// no listener, until the person asks for the feature by name. These tests
/// pin both sides of that decision on a `PairedDeviceStore` of its own, so
/// they read and write nothing the machine's real pairings own.
@MainActor
final class MobileReceiverLaunchTests: XCTestCase {
    private var defaultsName = ""
    private var shelfRoot: URL!
    private var deviceService = ""

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaultsName = "PerchMobileLaunch-\(UUID().uuidString)"
        shelfRoot = FileManager.default.temporaryDirectory
            .appending(path: "PerchMobileLaunch-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: shelfRoot, withIntermediateDirectories: true)
        deviceService = "com.hausfold.perch.tests.launch.\(UUID().uuidString)"
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: shelfRoot)
        UserDefaults().removePersistentDomain(forName: defaultsName)
        try await super.tearDown()
    }

    /// The shape of a first launch: the receive toggle is at its compiled-in
    /// default (on), nothing is paired, and the machine stays quiet.
    func testACleanMacStartsNoListenerAtLaunch() throws {
        let receiver = try makeReceiver()
        XCTAssertTrue(receiver.pairedDevices.isEmpty)
        XCTAssertTrue(AppConfig().mobileEnabled, "the gate is pairings, not the toggle's default")
        receiver.startForLaunch()
        XCTAssertFalse(receiver.isListening, "launch must not start the listener on an empty pairing store")
    }

    /// The one case launch does start for: a pairing remembered from before,
    /// where the prompt was already answered at pairing time.
    func testAPairedMacStartsItsListenerAtLaunchAndStopsCleanly() throws {
        let store = PairedDeviceStore(service: deviceService)
        let peer = PairedPeer(id: UUID(), name: "Test iPhone", deviceKey: Data([1, 2, 3]))
        try store.store(peer)
        addTeardownBlock { [deviceService] in
            PairedDeviceStore(service: deviceService).all().forEach { PairedDeviceStore(service: deviceService).revoke($0.id) }
        }

        let receiver = try makeReceiver()
        XCTAssertEqual(receiver.pairedDevices.map(\.id), [peer.id])
        receiver.startForLaunch()
        XCTAssertTrue(receiver.isListening)
        receiver.stop()
        XCTAssertFalse(receiver.isListening)
    }

    private func makeReceiver() throws -> MobileReceiver {
        let settings = AppSettings(
            store: TransientSettings.store(),
            defaults: try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        )
        return MobileReceiver(
            store: ShelfStore(
                repository: try StagingRepository(rootURL: shelfRoot),
                settings: settings
            ),
            settings: settings,
            devices: PairedDeviceStore(service: deviceService)
        )
    }
}