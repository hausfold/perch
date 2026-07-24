import AppKit
import UniformTypeIdentifiers

@MainActor
final class ShelfDropHandler {
    private let store: ShelfStore

    init(store: ShelfStore) {
        self.store = store
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
            store.importFileURLs(urls)
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
