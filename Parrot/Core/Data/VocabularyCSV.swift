import Foundation

/// Merging rules for words and replacements (importer and CSV import).
enum VocabularyMerge {

    struct Result: Equatable {
        var entries: [VocabularyEntry]
        var wordsAdded = 0
        var replacementsAdded = 0
        /// Words turned into replacements by an incoming replacement.
        var upgraded = 0
        var duplicates = 0

        var added: Int { wordsAdded + replacementsAdded + upgraded }
    }

    /// Case-insensitive on `original` (trimmed). A replacement wins over a
    /// word; the first replacement for an original wins over later ones.
    static func merge(existing: [VocabularyEntry], incoming: [VocabularyEntry]) -> Result {
        var result = Result(entries: existing)
        var index: [String: Int] = [:]
        for (position, entry) in existing.enumerated() {
            let key = Self.key(entry.original)
            if index[key] == nil { index[key] = position }
        }

        for raw in incoming {
            let original = raw.original.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !original.isEmpty else { continue }
            var entry = raw
            entry.original = original
            if entry.isWord {
                entry.replacement = original
            }
            let key = Self.key(original)

            if let position = index[key] {
                let current = result.entries[position]
                if current.isWord && !entry.isWord {
                    result.entries[position].replacement = entry.replacement
                    result.entries[position].original = original
                    result.upgraded += 1
                } else {
                    result.duplicates += 1
                }
                continue
            }

            index[key] = result.entries.count
            result.entries.append(entry)
            if entry.isWord {
                result.wordsAdded += 1
            } else {
                result.replacementsAdded += 1
            }
        }
        return result
    }

    static func key(_ original: String) -> String {
        original.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// Vocabulary CSV import and the example file. [DATA]
///
/// Format: a header row with a required `word` column and an optional
/// `replacement` column (no others). A row with an empty replacement adds a
/// word; a row with a replacement adds a replacement for that word.
enum VocabularyCSV {

    enum ImportError: LocalizedError, Equatable {
        case unreadable
        case empty
        case missingWordHeader
        case tooManyColumns
        case nothingImported
        case notCSV
        case folder
        case multipleFiles

        var errorDescription: String? {
            switch self {
            case .unreadable: return "The file could not be read."
            case .empty: return "The CSV file is empty."
            case .missingWordHeader: return "The CSV needs a header row with a word column."
            case .tooManyColumns: return "The CSV can only have word and replacement columns."
            case .nothingImported: return "Nothing imported. The CSV has no rows with a word."
            case .notCSV: return "Choose a .csv file."
            case .folder: return "Drop a CSV file, not a folder."
            case .multipleFiles: return "Drop one CSV file at a time."
            }
        }
    }

    static let exampleFileName = "parrot-vocabulary-example.csv"

    /// The example file the "Save Example CSV" button writes.
    static let exampleCSV = """
        word,replacement
        Parrot,
        Kubernetes,
        PostgreSQL,
        my email,someone@example.com
        btw,by the way
        """ + "\n"

    /// Checks dropped or chosen files before reading.
    static func validate(_ urls: [URL]) throws -> URL {
        guard urls.count == 1, let url = urls.first else {
            throw urls.isEmpty ? ImportError.unreadable : ImportError.multipleFiles
        }
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw ImportError.folder
        }
        guard url.pathExtension.lowercased() == "csv" else { throw ImportError.notCSV }
        return url
    }

    /// Reads and parses one file.
    static func entries(fromFile url: URL) throws -> [VocabularyEntry] {
        let url = try validate([url])
        guard let data = try? Data(contentsOf: url) else { throw ImportError.unreadable }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw ImportError.unreadable
        }
        return try entries(fromCSV: text)
    }

    /// Parses CSV text into words and replacements.
    static func entries(fromCSV text: String) throws -> [VocabularyEntry] {
        var body = text
        if body.hasPrefix("\u{FEFF}") { body.removeFirst() }
        let rows = parse(body).filter { row in row.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }
        guard let header = rows.first else { throw ImportError.empty }

        let names = header.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard let wordColumn = names.firstIndex(of: "word") else { throw ImportError.missingWordHeader }
        let replacementColumn = names.firstIndex(of: "replacement")
        let known = names.filter { $0 == "word" || $0 == "replacement" }
        guard names.count == known.count, names.count <= 2 else { throw ImportError.tooManyColumns }

        var result: [VocabularyEntry] = []
        for row in rows.dropFirst() {
            guard row.count <= names.count else { throw ImportError.tooManyColumns }
            let word = wordColumn < row.count ? row[wordColumn].trimmingCharacters(in: .whitespacesAndNewlines) : ""
            guard !word.isEmpty else { continue }
            let replacement = replacementColumn.flatMap { $0 < row.count ? row[$0] : nil }?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            result.append(replacement.isEmpty ? .word(word) : VocabularyEntry(original: word, replacement: replacement))
        }
        guard !result.isEmpty else { throw ImportError.nothingImported }
        return result
    }

    /// RFC 4180 rows: commas, double-quoted fields with "" escapes, and
    /// newlines inside quotes. Accepts LF and CRLF line ends.
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = Array(text).makeIterator()
        var pending: Character? = nil

        func nextChar() -> Character? {
            if let p = pending { pending = nil; return p }
            return iterator.next()
        }

        while let c = nextChar() {
            if inQuotes {
                if c == "\"" {
                    if let n = nextChar() {
                        if n == "\"" {
                            field.append("\"")
                        } else {
                            inQuotes = false
                            pending = n
                        }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(c)
                }
                continue
            }
            switch c {
            case "\"" where field.isEmpty:
                inQuotes = true
            case ",":
                row.append(field)
                field = ""
            case "\n", "\r\n", "\r":
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            default:
                field.append(c)
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}
