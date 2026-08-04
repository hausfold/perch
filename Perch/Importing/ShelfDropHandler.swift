import AppKit
import UniformTypeIdentifiers

@MainActor
final class ShelfDropHandler {
    private let store: ShelfStore
    private let license: LicenseStore

    init(store: ShelfStore, license: LicenseStore = .shared) {
        self.store = store
        self.license = license
    }

    var registeredTypes: [NSPasteboard.PasteboardType] {
        var types: [NSPasteboard.PasteboardType] =
            NSFilePromiseReceiver.readableDraggedTypes.map {
                NSPasteboard.PasteboardType($0)
            }
        types.append(contentsOf: [
            NSPasteboard.PasteboardType.fileURL,
            NSPasteboard.PasteboardType.URL,
            NSPasteboard.PasteboardType.string,
            NSPasteboard.PasteboardType.tiff,
            NSPasteboard.PasteboardType.png,
        ])
        return Array(Set(types))
    }

    func canAccept(_ info: NSDraggingInfo) -> Bool {
        let pasteboard = info.draggingPasteboard
        return pasteboard.canReadObject(forClasses: [NSFilePromiseReceiver.self], options: nil)
            || pasteboard.canReadObject(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            )
            || pasteboard.canReadObject(forClasses: [NSImage.self, NSURL.self, NSString.self], options: nil)
    }

    func accept(_ info: NSDraggingInfo) -> Bool {
        accept(info.draggingPasteboard)
    }

    func accept(_ pasteboard: NSPasteboard) -> Bool {

        if let promises = pasteboard.readObjects(
            forClasses: [NSFilePromiseReceiver.self],
            options: nil
        ) as? [NSFilePromiseReceiver], !promises.isEmpty {
            store.beginPromisedImports(promises)
            return true
        }

        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            // Activating perch by dropping your license on the shelf is the
            // most perch way imaginable to activate perch — and it is
            // sandbox-legal, because a dropped file is a file the user handed
            // us. A license is consumed, never staged: it is a key, not cargo.
            let licenses = urls.filter(LicenseStore.isLicenseFile)
            for url in licenses {
                license.importLicense(from: url)
            }
            let cargo = urls.filter { !LicenseStore.isLicenseFile($0) }
            if !cargo.isEmpty {
                store.importFileURLs(cargo)
            }
            return true
        }

        if let images = pasteboard.readObjects(forClasses: [NSImage.self], options: nil)
            as? [NSImage], let image = images.first {
            store.importImage(image)
            return true
        }

        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: nil)
            as? [URL], let url = urls.first {
            store.importText(url.absoluteString, suggestedName: "Link.webloc.txt")
            return true
        }

        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            store.importText(text)
            return true
        }

        return false
    }
}
