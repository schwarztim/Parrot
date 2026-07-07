import Foundation

/// Manages a list of transcription modes with CRUD operations and persistence.
///
/// Uses the `Mode` struct defined in `Models/Mode.swift`.
@Observable
final class ModeManager {

    // MARK: - State

    private(set) var modes: [Mode] = []
    var selectedMode: Mode

    /// True when no persisted mode file existed at init (first launch).
    private(set) var isFreshInstall = false

    // MARK: - Persistence

    private static var storageURL: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let dir = appSupport.appendingPathComponent("Parrot", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("modes.json")
    }

    // MARK: - Initialization

    init() {
        // Temporary assignment; will be replaced by load() or default.
        self.selectedMode = Mode.defaultMode
        load()

        // Ensure there is always at least the default mode.
        if modes.isEmpty {
            isFreshInstall = true
            modes = [Mode.defaultMode]
            save()
        }

        // Restore selected mode or fall back to the first available.
        if let savedSelectedID = loadSelectedModeID(),
           let match = modes.first(where: { $0.id == savedSelectedID })
        {
            selectedMode = match
        } else {
            selectedMode = modes[0]
        }
    }

    // MARK: - CRUD

    func addMode(_ mode: Mode) {
        modes.append(mode)
        save()
    }

    func updateMode(_ mode: Mode) {
        guard let index = modes.firstIndex(where: { $0.id == mode.id }) else { return }
        modes[index] = mode

        // Keep selectedMode in sync if it was the one updated.
        if selectedMode.id == mode.id {
            selectedMode = mode
        }
        save()
    }

    func removeMode(id: UUID) {
        // Prevent deleting the last remaining mode.
        guard modes.count > 1 else { return }
        modes.removeAll { $0.id == id }

        if selectedMode.id == id {
            selectedMode = modes[0]
        }
        save()
    }

    /// Replaces the whole mode list (used to persist UI-level edits) and
    /// keeps the selection valid.
    func replaceAll(_ newModes: [Mode]) {
        guard !newModes.isEmpty else { return }
        modes = newModes
        if let match = newModes.first(where: { $0.id == selectedMode.id }) {
            selectedMode = match
        } else {
            selectedMode = newModes[0]
        }
        save()
    }

    func selectMode(_ mode: Mode) {
        guard modes.contains(where: { $0.id == mode.id }) else { return }
        selectedMode = mode
        saveSelectedModeID(mode.id)
    }

    // MARK: - Persistence Helpers

    private func save() {
        do {
            let data = try JSONEncoder().encode(modes)
            try data.write(to: Self.storageURL, options: .atomic)
        } catch {
            // Non-fatal.
        }
        saveSelectedModeID(selectedMode.id)
    }

    private func load() {
        let url = Self.storageURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        do {
            let data = try Data(contentsOf: url)
            modes = try JSONDecoder().decode([Mode].self, from: data)
        } catch {
            modes = []
        }
    }

    private static let selectedModeKey = "Parrot.selectedModeID"

    private func saveSelectedModeID(_ id: UUID) {
        UserDefaults.standard.set(id.uuidString, forKey: Self.selectedModeKey)
    }

    private func loadSelectedModeID() -> UUID? {
        guard let string = UserDefaults.standard.string(forKey: Self.selectedModeKey) else {
            return nil
        }
        return UUID(uuidString: string)
    }
}
