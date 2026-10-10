import Foundation

/// The one gate for deleting a recording folder. [DATA]
///
/// History rows can point at folders Parrot does not own (an imported
/// Superwhisper recording is referenced in place). A folder is removed only
/// when it sits directly inside Parrot's recordings folder and has a
/// recording folder name (all digits). Everything else is left alone.
enum RecordingFolders {

    /// A recording folder name: whole unix seconds, digits only.
    static func isRecordingFolderName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// True when `folder` is a recording folder directly inside `root`.
    static func isOwned(_ folder: URL, root: URL) -> Bool {
        let folder = folder.standardizedFileURL
        guard isRecordingFolderName(folder.lastPathComponent) else { return false }
        let parent = folder.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        return parent == rootPath
    }

    /// Removes `folder` when it is owned. Returns true when it was removed
    /// or was already gone; false when it is not Parrot's or removal failed.
    @discardableResult
    static func removeIfOwned(_ folder: URL, root: URL, fileManager: FileManager = .default) -> Bool {
        guard isOwned(folder, root: root) else { return false }
        guard fileManager.fileExists(atPath: folder.path) else { return true }
        do {
            try fileManager.removeItem(at: folder)
            return true
        } catch {
            diagLog("[Parrot:History] Could not delete recording \(folder.lastPathComponent): \(error)")
            return false
        }
    }
}
