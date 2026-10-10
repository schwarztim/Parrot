import AppKit

// MARK: - Snapshot

/// One pasteboard item: every type it carried, in order, with its data.
struct PasteboardItemSnapshot: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let type: String
        let data: Data
    }

    var entries: [Entry]
}

/// Everything on the pasteboard at one moment. An empty item list is a real
/// snapshot of an empty clipboard; a nil snapshot means it could not be read.
struct PasteboardSnapshot: Equatable, Sendable {
    var items: [PasteboardItemSnapshot]
}

/// Types that tell clipboard history apps (Maccy, Paste, Alfred) to skip an
/// item. See nspasteboard.org.
enum PasteboardMarker {
    static let transient = "org.nspasteboard.TransientType"
    static let concealed = "org.nspasteboard.ConcealedType"
}

// MARK: - Pasteboard

/// The general pasteboard, behind a protocol so tests use a fake. [OUT]
/// (Named `PasteboardAccess` because XCTest also exports a `Pasteboard`.)
@MainActor
protocol PasteboardAccess: AnyObject {
    /// Bumps on every write, by anyone.
    var changeCount: Int { get }
    /// Copies every item and type; nil when the pasteboard cannot be read.
    func snapshot() -> PasteboardSnapshot?
    /// Replaces the contents with plain text, plus the skip markers when
    /// `transient`.
    func writeText(_ text: String, transient: Bool)
    /// Replaces the contents with a snapshot. An empty snapshot clears.
    func restore(_ snapshot: PasteboardSnapshot)
}

/// `NSPasteboard.general`.
@MainActor
final class SystemPasteboard: PasteboardAccess {
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    var changeCount: Int { pasteboard.changeCount }

    func snapshot() -> PasteboardSnapshot? {
        guard let items = pasteboard.pasteboardItems else { return nil }
        return PasteboardSnapshot(items: items.map { item in
            PasteboardItemSnapshot(entries: item.types.compactMap { type in
                item.data(forType: type).map { PasteboardItemSnapshot.Entry(type: type.rawValue, data: $0) }
            })
        })
    }

    func writeText(_ text: String, transient: Bool) {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        if transient {
            item.setData(Data(), forType: NSPasteboard.PasteboardType(PasteboardMarker.transient))
            item.setData(Data(), forType: NSPasteboard.PasteboardType(PasteboardMarker.concealed))
        }
        pasteboard.writeObjects([item])
    }

    func restore(_ snapshot: PasteboardSnapshot) {
        pasteboard.clearContents()
        // An item that was on a pasteboard cannot be written again, so build
        // fresh ones from the saved data.
        let items = snapshot.items.map { saved -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for entry in saved.entries {
                item.setData(entry.data, forType: NSPasteboard.PasteboardType(entry.type))
            }
            return item
        }
        if !items.isEmpty {
            pasteboard.writeObjects(items)
        }
    }
}
