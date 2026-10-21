import CSQLite
import Foundation

public actor HistoryStore {
    private let database: SQLiteConnection
    private var limits: HistoryLimits

    public init(directory: URL, limits: HistoryLimits = HistoryLimits()) throws {
        self.limits = limits
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let path = directory.appendingPathComponent("history.sqlite3").path
        let database = try SQLiteConnection(path: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        try database.execute("PRAGMA journal_mode=WAL")
        try database.execute("PRAGMA secure_delete=ON")
        let version = try database.rows("PRAGMA user_version") { sqlite3_column_int($0, 0) }.first ?? 0
        guard version <= 1 else { throw HistoryError.unsupportedVersion }
        try database.transaction {
            try database.execute("""
                CREATE TABLE IF NOT EXISTS clips (
                    id TEXT PRIMARY KEY, fingerprint TEXT NOT NULL UNIQUE, copied_at REAL NOT NULL,
                    text TEXT NOT NULL, kind TEXT NOT NULL, source_name TEXT NOT NULL,
                    search_text TEXT NOT NULL, pinned INTEGER NOT NULL DEFAULT 0,
                    byte_count INTEGER NOT NULL, payload BLOB NOT NULL, thumbnail BLOB
                )
                """)
            try database.execute("CREATE INDEX IF NOT EXISTS clips_recent ON clips(copied_at DESC)")
            try database.execute("CREATE VIRTUAL TABLE IF NOT EXISTS clip_search USING fts5(item_id UNINDEXED, search_text, tokenize='trigram')")
            try database.execute("""
                CREATE TRIGGER IF NOT EXISTS clips_insert AFTER INSERT ON clips BEGIN
                    INSERT INTO clip_search(item_id,search_text) VALUES(new.id,new.search_text);
                END
                """)
            try database.execute("""
                CREATE TRIGGER IF NOT EXISTS clips_delete AFTER DELETE ON clips BEGIN
                    DELETE FROM clip_search WHERE item_id=old.id;
                END
                """)
            try database.execute("""
                CREATE TRIGGER IF NOT EXISTS clips_update AFTER UPDATE OF search_text ON clips BEGIN
                    DELETE FROM clip_search WHERE item_id=old.id;
                    INSERT INTO clip_search(item_id,search_text) VALUES(new.id,new.search_text);
                END
                """)
            try database.execute("PRAGMA user_version=1")
        }
        self.database = database
    }

    @discardableResult
    public func record(_ content: ClipboardContent, at date: Date = Date()) throws -> String {
        try content.validate(maximumBytes: limits.maximumItemBytes)
        return try database.transaction {
            let identity = try upsert(content, at: date)
            try prune(now: date, preserving: identity)
            return identity
        }
    }

    private func upsert(_ content: ClipboardContent, at date: Date) throws -> String {
        let payload = try JSONEncoder().encode(content)
        let hash = content.fingerprint
        let existing = try database.rows("SELECT id FROM clips WHERE fingerprint=?", [.text(hash)]) {
            SQLiteConnection.text($0, 0)
        }.first
        let identity = existing ?? UUID().uuidString
        let searchText = normalize(content.text + "\n" + content.sourceName)
        if existing != nil {
            try database.execute("""
                UPDATE clips SET copied_at=?,text=?,source_name=?,search_text=?,payload=?,thumbnail=?,byte_count=? WHERE id=?
                """, [.real(date.timeIntervalSince1970), .text(content.text), .text(content.sourceName),
                       .text(searchText), .blob(payload), content.thumbnail.map(SQLValue.blob) ?? .null,
                       .integer(Int64(payload.count + (content.thumbnail?.count ?? 0))), .text(identity)])
        } else {
            try database.execute("INSERT INTO clips VALUES(?,?,?,?,?,?,?,0,?,?,?)", [
                .text(identity), .text(hash), .real(date.timeIntervalSince1970), .text(content.text),
                .text(content.kind.rawValue), .text(content.sourceName), .text(searchText),
                .integer(Int64(payload.count + (content.thumbnail?.count ?? 0))), .blob(payload), content.thumbnail.map(SQLValue.blob) ?? .null
            ])
        }
        return identity
    }

    public func search(_ query: String = "", pinnedOnly: Bool = false, limit: Int = 200) throws -> [ClipSummary] {
        let query = normalize(query.trimmingCharacters(in: .whitespacesAndNewlines))
        var sql = "SELECT clips.id,text,kind,source_name,copied_at,pinned,thumbnail FROM clips"
        var bindings: [SQLValue] = []
        if query.count >= 3 {
            sql += " JOIN clip_search ON clip_search.item_id=clips.id WHERE clip_search MATCH ?"
            bindings.append(.text("\"" + query.replacingOccurrences(of: "\"", with: "\"\"") + "\""))
        } else if !query.isEmpty {
            sql += " WHERE instr(search_text,?)>0"
            bindings.append(.text(query))
        } else {
            sql += " WHERE 1=1"
        }
        if pinnedOnly { sql += " AND pinned=1" }
        sql += " ORDER BY copied_at DESC, clips.rowid DESC LIMIT ?"
        bindings.append(.integer(Int64(max(1, min(limit, 2_000)))))
        return try database.rows(sql, bindings) { statement in
            ClipSummary(id: SQLiteConnection.text(statement, 0), text: SQLiteConnection.text(statement, 1),
                        kind: ClipKind(rawValue: SQLiteConnection.text(statement, 2)) ?? .text,
                        sourceName: SQLiteConnection.text(statement, 3),
                        copiedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                        isPinned: sqlite3_column_int(statement, 5) != 0,
                        thumbnail: SQLiteConnection.data(statement, 6))
        }
    }

    public func content(for identity: String) throws -> ClipboardContent? {
        try database.rows("SELECT payload FROM clips WHERE id=?", [.text(identity)]) { statement in
            guard let payload = SQLiteConnection.data(statement, 0) else { throw HistoryError.invalidContent }
            return try JSONDecoder().decode(ClipboardContent.self, from: payload)
        }.first
    }

    public func setPinned(_ pinned: Bool, for identity: String) throws {
        try database.transaction {
            try database.execute("UPDATE clips SET pinned=? WHERE id=?", [.integer(pinned ? 1 : 0), .text(identity)])
            try prune(now: Date(), preserving: nil)
        }
    }

    public func delete(_ identity: String) throws {
        try database.execute("DELETE FROM clips WHERE id=?", [.text(identity)])
    }

    public func clearUnpinned() throws {
        try database.execute("DELETE FROM clips WHERE pinned=0")
        try database.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    public func pruneExpired(now: Date = Date()) throws {
        try database.transaction { try prune(now: now, preserving: nil) }
    }

    public func setRetention(maximumItems: Int, retentionDays: Int) throws {
        guard (100...50_000).contains(maximumItems), (1...365).contains(retentionDays) else { throw HistoryError.invalidContent }
        let previous = limits
        limits.maximumItems = maximumItems
        limits.retentionDays = retentionDays
        do { try database.transaction { try prune(now: Date(), preserving: nil) } }
        catch { limits = previous; throw error }
    }

    public func exportArchive() throws -> Data {
        let entries = try database.rows("SELECT payload,copied_at,pinned FROM clips ORDER BY copied_at", []) { statement in
            guard let payload = SQLiteConnection.data(statement, 0) else { throw HistoryError.invalidContent }
            return Archive.Entry(content: try JSONDecoder().decode(ClipboardContent.self, from: payload),
                                 copiedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                                 pinned: sqlite3_column_int(statement, 2) != 0)
        }
        return try JSONEncoder().encode(Archive(version: 1, entries: entries))
    }

    public func importArchive(from url: URL, excludedApplications: Set<String>) throws -> Int {
        let maximumArchiveBytes = 384 * 1024 * 1024
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        guard let data = try handle.read(upToCount: maximumArchiveBytes + 1), data.count <= maximumArchiveBytes else {
            throw HistoryError.invalidContent
        }
        let archive: Archive
        do { archive = try JSONDecoder().decode(Archive.self, from: data) }
        catch { throw HistoryError.invalidContent }
        guard archive.version == 1 else { throw HistoryError.unsupportedVersion }
        guard archive.entries.count <= 20_000 else { throw HistoryError.invalidContent }
        let entries = archive.entries.filter { entry in
            CapturePolicy.allows(types: Set(entry.content.fragments.flatMap(\.representations).map(\.type)),
                                 sourceBundleID: entry.content.sourceBundleID,
                                 excludedApplications: excludedApplications, paused: false)
        }
        for entry in entries {
            try entry.content.validate(maximumBytes: limits.maximumItemBytes)
            guard entry.copiedAt.timeIntervalSince1970.isFinite,
                  entry.copiedAt <= Date().addingTimeInterval(300) else { throw HistoryError.invalidContent }
        }
        return try database.transaction {
            for entry in entries {
                let identity = try upsert(entry.content, at: entry.copiedAt)
                if entry.pinned { try database.execute("UPDATE clips SET pinned=1 WHERE id=?", [.text(identity)]) }
            }
            try prune(now: Date(), preserving: nil)
            return entries.count
        }
    }

    private func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private func prune(now: Date, preserving identity: String?) throws {
        let cutoff = now.addingTimeInterval(-Double(limits.retentionDays) * 86_400).timeIntervalSince1970
        try database.execute("DELETE FROM clips WHERE pinned=0 AND copied_at<? AND id!=?",
                             [.real(cutoff), .text(identity ?? "")])
        let unpinned = try database.rows("SELECT id FROM clips WHERE pinned=0 ORDER BY copied_at DESC,rowid DESC") {
            SQLiteConnection.text($0, 0)
        }
        for stale in unpinned.dropFirst(max(1, limits.maximumItems)) where stale != identity {
            try database.execute("DELETE FROM clips WHERE id=?", [.text(stale)])
        }
        var total = try database.rows("SELECT COALESCE(SUM(byte_count),0) FROM clips") { sqlite3_column_int64($0, 0) }.first ?? 0
        let removable = try database.rows("SELECT id,byte_count FROM clips WHERE pinned=0 AND id!=? ORDER BY copied_at,rowid",
                                          [.text(identity ?? "")]) { (SQLiteConnection.text($0, 0), sqlite3_column_int64($0, 1)) }
        for (stale, size) in removable where total > limits.maximumBytes {
            try database.execute("DELETE FROM clips WHERE id=?", [.text(stale)])
            total -= size
        }
        guard total <= limits.maximumBytes else { throw HistoryError.capacityReached }
    }
}

private struct Archive: Codable {
    struct Entry: Codable {
        let content: ClipboardContent
        let copiedAt: Date
        let pinned: Bool
    }
    let version: Int
    let entries: [Entry]
}
