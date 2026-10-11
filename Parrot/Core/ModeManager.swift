import Foundation

/// The saved modes, their order and which one is active. [LLM]
///
/// Storage: one JSON file per mode, `<modes folder>/<key>.json`, pretty
/// printed so people can edit them; the order lives in
/// `parrot.llm.modeOrder`. On first run the old single-file list
/// (`modes.json`) is migrated: a `modes.json.bak` copy is kept, and the old
/// file stays and is rewritten on every save as a mirror, so an older Parrot
/// build still finds the modes. Nothing the user made is ever deleted:
/// removed modes move to `<modes folder>/.deleted/`.
///
/// Selection: `selectedMode` is the user's own choice
/// (`parrot.llm.lastSelectedModeKey`). `activeModeKey` is the mode in use
/// right now: auto-activation may switch it for one recording, and
/// `returnToLastSelected()` puts it back afterwards.
@Observable
final class ModeManager {

    // MARK: - State

    private(set) var modes: [Mode] = []
    /// The mode the user last chose. Dictations use it unless an app or
    /// site rule picks another.
    var selectedMode: Mode
    /// Key of the mode in use right now (see the type comment).
    private(set) var activeModeKey: String

    /// True when nothing was stored and no presets were seeded (only when
    /// `seedsPresets` is false). AppState seeds its own list when this is
    /// true, so it stays false once presets are in place.
    private(set) var isFreshInstall = false
    /// True when this launch created the built-in presets.
    private(set) var didSeedPresets = false

    // MARK: - Storage

    /// Holds one `<key>.json` per mode.
    let modesDirectory: URL
    /// The pre-migration list, kept as a mirror.
    let legacyFileURL: URL
    private let defaults: UserDefaults

    /// Bytes last written or read per key, so unchanged files are not
    /// rewritten and a removed mode's file can be found.
    @ObservationIgnored private var storedData: [String: Data] = [:]
    /// Lowercased names of mode files that could not be read. No mode takes
    /// one of these keys, so a damaged file is never overwritten.
    @ObservationIgnored private var reservedKeys: Set<String> = []
    @ObservationIgnored private var watcher: DispatchSourceFileSystemObject?
    @ObservationIgnored private var reloadWork: DispatchWorkItem?

    enum Key {
        static let activeModeKey = "parrot.llm.activeModeKey"
        static let lastSelectedModeKey = "parrot.llm.lastSelectedModeKey"
        static let modeOrder = "parrot.llm.modeOrder"
        /// Written by earlier builds; read once for migration and kept in
        /// sync so an older build restores the same selection.
        static let legacySelectedModeID = "Parrot.selectedModeID"
        /// Retired duplicate once written by AppSettings.
        static let retiredSelectedModeID = "parrot.selectedModeID"
    }

    /// The old single-file location (`.../Parrot/modes.json`).
    static var defaultStorageURL: URL {
        let dir = AppPaths.defaultRoot
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("modes.json")
    }

    // MARK: - Initialization

    /// The app's modes under `paths.modes`, migrating `paths.legacyModesFile`.
    convenience init(paths: AppPaths = AppPaths(), defaults: UserDefaults = .standard) {
        self.init(modesDirectory: paths.modes, legacyFileURL: paths.legacyModesFile, defaults: defaults)
    }

    /// Modes stored next to `storageURL`: the folder `modes/` beside it, with
    /// `storageURL` as the legacy list to migrate and mirror.
    convenience init(storageURL: URL, defaults: UserDefaults = .standard) {
        self.init(
            modesDirectory: storageURL.deletingLastPathComponent().appendingPathComponent("modes", isDirectory: true),
            legacyFileURL: storageURL,
            defaults: defaults
        )
    }

    /// - Parameter seedsPresets: Create the built-in presets when nothing is
    ///   stored. When false an empty store gets the single default mode and
    ///   `isFreshInstall` is true.
    init(modesDirectory: URL, legacyFileURL: URL, defaults: UserDefaults, seedsPresets: Bool = true) {
        self.modesDirectory = modesDirectory
        self.legacyFileURL = legacyFileURL
        self.defaults = defaults
        self.selectedMode = Mode.defaultMode
        self.activeModeKey = ""

        defaults.removeObject(forKey: Key.retiredSelectedModeID)

        var loaded = readModeFiles()
        var needsSave = false
        if loaded.isEmpty, let legacy = readLegacyFile() {
            loaded = legacy
            needsSave = true
            backUpLegacyFile(suffix: "bak")
        }
        if loaded.isEmpty {
            if FileManager.default.fileExists(atPath: legacyFileURL.path) {
                // Unreadable: keep a copy before the mirror overwrites it.
                backUpLegacyFile(suffix: "unreadable.bak")
            }
            if seedsPresets {
                loaded = ModePresets.defaultModes
                didSeedPresets = true
            } else {
                loaded = [Mode.defaultMode]
                isFreshInstall = true
            }
            needsSave = true
        }

        let order = defaults.stringArray(forKey: Key.modeOrder) ?? loaded.map(\.key)
        modes = Self.normalized(Self.ordered(loaded, by: order), reserved: reservedKeys)

        let lastKey = defaults.string(forKey: Key.lastSelectedModeKey)
            ?? defaults.string(forKey: Key.legacySelectedModeID)
                .flatMap(UUID.init(uuidString:))
                .flatMap { id in modes.first { $0.id == id }?.key }
        selectedMode = lastKey.flatMap { mode(forKey: $0) } ?? modes[0]
        activeModeKey = selectedMode.key

        if needsSave {
            save()
        } else {
            saveOrderAndMirror()
        }
        saveSelection()
    }

    deinit {
        watcher?.cancel()
    }

    // MARK: - Lookup

    /// The mode stored under `key` (case-insensitive, like the file system).
    func mode(forKey key: String) -> Mode? {
        let wanted = key.lowercased()
        return modes.first { $0.key.lowercased() == wanted }
    }

    /// Keys in the user's order.
    var modeOrder: [String] { modes.map(\.key) }

    /// The mode in use right now.
    var activeMode: Mode { mode(forKey: activeModeKey) ?? selectedMode }

    /// Whether any mode has website rules (the browser address is read only then).
    var hasSiteRules: Bool { modes.contains { !$0.activationSites.isEmpty } }

    /// A key not used by any mode, built from `base` ("email", "email-2").
    func uniqueKey(for base: String) -> String {
        let clean = Self.sanitizedKey(base) ?? "mode"
        let taken = Set(modes.map { $0.key.lowercased() }).union(reservedKeys)
        return Self.uniqueKey(clean, taken: taken)
    }

    // MARK: - CRUD

    /// Appends a mode. A key that is empty, unsafe as a file name or already
    /// used gets a unique one; an id already used gets a new one. Returns the
    /// mode as stored.
    @discardableResult
    func addMode(_ mode: Mode) -> Mode {
        var added = mode
        let taken = Set(modes.map { $0.key.lowercased() }).union(reservedKeys)
        added.key = Self.uniqueKey(Self.sanitizedKey(mode.key) ?? Mode.defaultKey(for: mode.id), taken: taken)
        if modes.contains(where: { $0.id == added.id }) { added.id = UUID() }
        modes.append(added)
        save()
        return added
    }

    /// Creates a mode from a preset with a unique key and appends it.
    @discardableResult
    func addPreset(_ type: ModeType) -> Mode {
        var mode = ModePresets.make(type)
        mode.key = uniqueKey(for: mode.key)
        return addMode(mode)
    }

    /// Creates or updates a mode by `key` (for importers). An existing mode
    /// with that key keeps its `id` and position and takes every other field
    /// from `mode`; otherwise the mode is appended. Returns the stored mode.
    @discardableResult
    func upsertMode(_ mode: Mode) -> Mode {
        guard let key = Self.sanitizedKey(mode.key),
              let index = modes.firstIndex(where: { $0.key.lowercased() == key.lowercased() })
        else { return addMode(mode) }
        var updated = mode
        updated.id = modes[index].id
        updated.key = modes[index].key
        modes[index] = updated
        syncSelection()
        save()
        return updated
    }

    /// Replaces the mode with the same `id`. Keys never change here: the
    /// stored key is kept.
    func updateMode(_ mode: Mode) {
        guard let index = modes.firstIndex(where: { $0.id == mode.id }) else { return }
        var updated = mode
        updated.key = modes[index].key
        modes[index] = updated
        syncSelection()
        save()
    }

    /// Removes a mode (never the last one). Its file moves to `.deleted/`.
    func removeMode(id: UUID) {
        guard modes.count > 1 else { return }
        modes.removeAll { $0.id == id }
        syncSelection()
        save()
    }

    /// Replaces the whole list (used to persist UI-level edits): new modes
    /// are added, missing ones removed, the order follows the array.
    func replaceAll(_ newModes: [Mode]) {
        guard !newModes.isEmpty else { return }
        let normalized = Self.normalized(newModes, reserved: reservedKeys)
        guard normalized != modes else { return }
        modes = normalized
        syncSelection()
        save()
    }

    /// Reorders by key. Unknown keys are ignored; modes missing from `keys`
    /// keep their relative order at the end.
    func setOrder(_ keys: [String]) {
        let reordered = Self.ordered(modes, by: keys)
        guard reordered != modes else { return }
        modes = reordered
        saveOrderAndMirror()
    }

    // MARK: - Selection

    /// The user picks a mode: it becomes both the last selected and the
    /// active mode.
    func selectMode(_ mode: Mode) {
        guard let stored = modes.first(where: { $0.id == mode.id }) else { return }
        selectedMode = stored
        activeModeKey = stored.key
        saveSelection()
    }

    /// Makes `mode` active for the recording that is starting, without
    /// changing the user's selection.
    func activate(_ mode: Mode) {
        guard let stored = self.mode(forKey: mode.key), activeModeKey != stored.key else { return }
        activeModeKey = stored.key
        defaults.set(activeModeKey, forKey: Key.activeModeKey)
    }

    /// Ends an auto-activation: the active mode is the selected one again.
    func returnToLastSelected() {
        guard activeModeKey != selectedMode.key else { return }
        activeModeKey = selectedMode.key
        defaults.set(activeModeKey, forKey: Key.activeModeKey)
    }

    // MARK: - Activation

    /// First mode (in list order) that claims the given bundle id,
    /// case-insensitively. Nil for a nil or unclaimed bundle id.
    func mode(forBundleID bundleID: String?) -> Mode? {
        ModeActivation.mode(forBundleID: bundleID, in: modes)
    }

    /// The mode whose sites best match `url`, if any.
    func mode(forURL url: String?) -> Mode? {
        ModeActivation.mode(forURL: url, in: modes)
    }

    /// The mode for a dictation into `context`: a site match, then an app
    /// match, then the last selected mode. Never changes the selection.
    func resolveMode(context: DictationContext?) -> Mode {
        ModeActivation.resolve(modes: modes, context: context, fallback: selectedMode)
    }

    // MARK: - Language Models

    /// Modes that name `languageModelID` explicitly.
    func modes(usingLanguageModel languageModelID: String) -> [Mode] {
        modes.filter { $0.languageModelID == languageModelID }
    }

    /// Points every mode that uses a language model at `languageModelID`
    /// ("Use in all modes"). Voice modes are left alone.
    func useLanguageModelEverywhere(_ languageModelID: String) {
        var changed = modes
        for index in changed.indices where ModePresets.usesLanguageModel(changed[index].type) {
            changed[index].languageModelID = languageModelID
        }
        guard changed != modes else { return }
        modes = changed
        syncSelection()
        save()
    }

    /// Repoints modes off a removed model, back to the global default.
    func clearLanguageModel(_ languageModelID: String) {
        var changed = modes
        for index in changed.indices where changed[index].languageModelID == languageModelID {
            changed[index].languageModelID = ""
        }
        guard changed != modes else { return }
        modes = changed
        syncSelection()
        save()
    }

    // MARK: - Live Reload

    /// Watches the modes folder and reloads after outside edits (a text
    /// editor, a sync tool). Parrot's own writes reload to the same list,
    /// which changes nothing.
    func startWatching() {
        guard watcher == nil else { return }
        try? FileManager.default.createDirectory(at: modesDirectory, withIntermediateDirectories: true)
        let descriptor = open(modesDirectory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main
        )
        source.setEventHandler { [weak self] in self?.scheduleReload() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }

    func stopWatching() {
        watcher?.cancel()
        watcher = nil
    }

    /// Re-reads every mode file. An emptied folder is ignored (the list in
    /// memory is kept and written again on the next save). A selected mode
    /// whose file disappeared falls back to the first mode.
    func reloadFromDisk() {
        let loaded = readModeFiles()
        guard !loaded.isEmpty else { return }
        let reloaded = Self.normalized(Self.ordered(loaded, by: modeOrder), reserved: reservedKeys)
        guard reloaded != modes else { return }
        modes = reloaded
        syncSelection()
        saveOrderAndMirror()
    }

    private func scheduleReload() {
        reloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.reloadFromDisk() }
        reloadWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    // MARK: - Persistence

    private func save() {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: modesDirectory, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var written: [String: Data] = [:]
        for mode in modes {
            guard let data = try? encoder.encode(mode) else { continue }
            written[mode.key] = data
            if storedData[mode.key] != data {
                try? data.write(to: fileURL(for: mode.key), options: .atomic)
            }
        }

        // Files of modes no longer in the list move aside, never deleted.
        let current = Set(written.keys.map { $0.lowercased() })
        for key in storedData.keys where !current.contains(key.lowercased()) {
            moveToDeleted(key: key)
        }
        storedData = written

        saveOrderAndMirror()
        saveSelection()
    }

    private func saveOrderAndMirror() {
        let order = modeOrder
        if defaults.stringArray(forKey: Key.modeOrder) != order {
            defaults.set(order, forKey: Key.modeOrder)
        }
        if let data = try? JSONEncoder().encode(modes),
           (try? Data(contentsOf: legacyFileURL)) != data
        {
            try? FileManager.default.createDirectory(
                at: legacyFileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try? data.write(to: legacyFileURL, options: .atomic)
        }
    }

    private func saveSelection() {
        setIfChanged(selectedMode.key, forKey: Key.lastSelectedModeKey)
        setIfChanged(activeModeKey, forKey: Key.activeModeKey)
        setIfChanged(selectedMode.id.uuidString, forKey: Key.legacySelectedModeID)
    }

    private func setIfChanged(_ value: String, forKey key: String) {
        if defaults.string(forKey: key) != value {
            defaults.set(value, forKey: key)
        }
    }

    /// Keeps `selectedMode` and `activeModeKey` pointing at stored modes.
    private func syncSelection() {
        if let match = modes.first(where: { $0.id == selectedMode.id }) ?? mode(forKey: selectedMode.key) {
            selectedMode = match
        } else {
            selectedMode = modes[0]
        }
        if mode(forKey: activeModeKey) == nil {
            activeModeKey = selectedMode.key
        }
        saveSelection()
    }

    private func fileURL(for key: String) -> URL {
        modesDirectory.appendingPathComponent(key + ".json")
    }

    private func moveToDeleted(key: String) {
        let fileManager = FileManager.default
        let source = fileURL(for: key)
        guard fileManager.fileExists(atPath: source.path) else { return }
        let trash = modesDirectory.appendingPathComponent(".deleted", isDirectory: true)
        try? fileManager.createDirectory(at: trash, withIntermediateDirectories: true)
        let stamp = Int(Date().timeIntervalSince1970)
        let target = trash.appendingPathComponent("\(key)-\(stamp)-\(UUID().uuidString.prefix(8)).json")
        try? fileManager.moveItem(at: source, to: target)
    }

    /// Every `*.json` directly in the modes folder, keyed by file name.
    private func readModeFiles() -> [Mode] {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: modesDirectory.path) else { return [] }
        var loaded: [Mode] = []
        var data: [String: Data] = [:]
        var unreadable: Set<String> = []
        for name in names.sorted() where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let key = String(name.dropLast(5))
            guard !key.isEmpty else { continue }
            guard let bytes = try? Data(contentsOf: modesDirectory.appendingPathComponent(name)),
                  var mode = try? JSONDecoder().decode(Mode.self, from: bytes)
            else {
                unreadable.insert(key.lowercased())
                continue
            }
            // The file name is the key, even if the file says otherwise.
            mode.key = key
            loaded.append(mode)
            data[key] = bytes
        }
        storedData = data
        reservedKeys = unreadable
        return loaded
    }

    /// Decodes the legacy list. Modes written before context toggles existed
    /// get application and selection context on: back then destination
    /// context applied to every mode, so this keeps what they sent.
    private func readLegacyFile() -> [Mode]? {
        guard let data = try? Data(contentsOf: legacyFileURL),
              var decoded = try? JSONDecoder().decode([Mode].self, from: data),
              !decoded.isEmpty
        else { return nil }
        let objects = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        for index in decoded.indices where index < objects.count {
            if objects[index]["contextFromActiveApplication"] == nil {
                decoded[index].contextFromActiveApplication = true
            }
            if objects[index]["contextFromSelection"] == nil {
                decoded[index].contextFromSelection = true
            }
        }
        return decoded
    }

    private func backUpLegacyFile(suffix: String) {
        let backup = legacyFileURL.appendingPathExtension(suffix)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: legacyFileURL.path),
              !fileManager.fileExists(atPath: backup.path)
        else { return }
        try? fileManager.copyItem(at: legacyFileURL, to: backup)
    }

    // MARK: - Helpers

    /// `modes` sorted by `keys`; modes missing from `keys` follow in their
    /// current order.
    private static func ordered(_ modes: [Mode], by keys: [String]) -> [Mode] {
        var rank: [String: Int] = [:]
        for (index, key) in keys.enumerated() where rank[key.lowercased()] == nil {
            rank[key.lowercased()] = index
        }
        return modes.enumerated()
            .sorted { lhs, rhs in
                let l = rank[lhs.element.key.lowercased()] ?? (keys.count + lhs.offset)
                let r = rank[rhs.element.key.lowercased()] ?? (keys.count + rhs.offset)
                return l < r
            }
            .map(\.element)
    }

    /// Makes every key safe and unique (case-insensitively, like the file
    /// system) and every id unique.
    private static func normalized(_ modes: [Mode], reserved: Set<String>) -> [Mode] {
        var result: [Mode] = []
        var keys = reserved
        var ids = Set<UUID>()
        for var mode in modes {
            if ids.contains(mode.id) { mode.id = UUID() }
            ids.insert(mode.id)
            let base = sanitizedKey(mode.key) ?? Mode.defaultKey(for: mode.id)
            mode.key = uniqueKey(base, taken: keys)
            keys.insert(mode.key.lowercased())
            result.append(mode)
        }
        return result
    }

    private static func uniqueKey(_ base: String, taken: Set<String>) -> String {
        guard taken.contains(base.lowercased()) else { return base }
        var suffix = 2
        while taken.contains("\(base)-\(suffix)".lowercased()) { suffix += 1 }
        return "\(base)-\(suffix)"
    }

    /// A key usable as a file name: no slashes, colons or control
    /// characters, no leading dot, at most 100 characters. Nil when nothing
    /// usable is left.
    static func sanitizedKey(_ raw: String) -> String? {
        var key = String(raw.unicodeScalars.map { scalar -> Character in
            if scalar == "/" || scalar == ":" || scalar == "\\" || CharacterSet.controlCharacters.contains(scalar) {
                return "-"
            }
            return Character(scalar)
        })
        key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        while key.hasPrefix(".") { key.removeFirst() }
        key = String(key.prefix(100))
        return key.isEmpty ? nil : key
    }
}
