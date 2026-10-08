import Foundation

public enum RecordKind: String, Sendable, Codable {
    case location
    case event
}

public struct QueuedRecord: Sendable, Hashable, Identifiable {
    public let id: Int64
    public let kind: RecordKind
    public let createdAt: Date
    /// The serialized JSON record.
    public let payload: Data
}

public struct QueueCounts: Sendable, Hashable {
    public var locations: Int
    public var events: Int

    public init(locations: Int = 0, events: Int = 0) {
        self.locations = locations
        self.events = events
    }

    public var total: Int { locations + events }
}

/// One HTTP exchange, kept for the request inspector.
public struct RequestLogEntry: Sendable, Hashable, Identifiable {
    public var id: Int64
    public var date: Date
    public var method: String
    public var url: String
    public var statusCode: Int?
    public var duration: TimeInterval
    public var requestBytes: Int
    public var recordCount: Int
    public var success: Bool
    public var error: String?
    public var requestHeaders: String
    public var requestPreview: String
    public var responsePreview: String

    public init(
        id: Int64 = 0,
        date: Date,
        method: String,
        url: String,
        statusCode: Int?,
        duration: TimeInterval,
        requestBytes: Int,
        recordCount: Int,
        success: Bool,
        error: String?,
        requestHeaders: String,
        requestPreview: String,
        responsePreview: String
    ) {
        self.id = id
        self.date = date
        self.method = method
        self.url = url
        self.statusCode = statusCode
        self.duration = duration
        self.requestBytes = requestBytes
        self.recordCount = recordCount
        self.success = success
        self.error = error
        self.requestHeaders = requestHeaders
        self.requestPreview = requestPreview
        self.responsePreview = responsePreview
    }
}

/// Durable, ordered storage for records awaiting upload, plus the request log.
///
/// Records are stored as serialized JSON so a batch can be uploaded without re-encoding.
public actor QueueStore {
    public static let maxLogEntries = 200

    private let database: SQLiteDatabase

    /// Opens or creates the store at `url`.
    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let database = try SQLiteDatabase(path: url.path(percentEncoded: false))
        try Self.migrate(database)
        self.database = database
    }

    /// An ephemeral store, for tests and previews.
    public init() throws {
        let database = try SQLiteDatabase(path: ":memory:")
        try Self.migrate(database)
        self.database = database
    }

    private static func migrate(_ database: SQLiteDatabase) throws {
        try database.executeScript("""
            PRAGMA journal_mode = WAL;
            PRAGMA synchronous = NORMAL;
            CREATE TABLE IF NOT EXISTS records (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                created_at REAL NOT NULL,
                kind TEXT NOT NULL,
                payload BLOB NOT NULL
            );
            CREATE INDEX IF NOT EXISTS records_created_at ON records (created_at);
            CREATE TABLE IF NOT EXISTS request_log (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                date REAL NOT NULL,
                method TEXT NOT NULL,
                url TEXT NOT NULL,
                status INTEGER,
                duration REAL NOT NULL,
                request_bytes INTEGER NOT NULL,
                record_count INTEGER NOT NULL,
                success INTEGER NOT NULL,
                error TEXT,
                request_headers TEXT NOT NULL,
                request_preview TEXT NOT NULL,
                response_preview TEXT NOT NULL
            );
            """)
    }

    // MARK: Records

    public func append(_ payload: Data, kind: RecordKind, at date: Date = .now) throws {
        try database.execute(
            "INSERT INTO records (created_at, kind, payload) VALUES (?, ?, ?)",
            [.double(date.timeIntervalSince1970), .text(kind.rawValue), .blob(payload)]
        )
    }

    /// Replaces all queued locations with a single one ("latest only" strategy). Events are kept.
    public func replaceLocations(with payload: Data, at date: Date = .now) throws {
        try database.transaction {
            try database.execute("DELETE FROM records WHERE kind = ?", [.text(RecordKind.location.rawValue)])
            try append(payload, kind: .location, at: date)
        }
    }

    /// The oldest `limit` records, in insertion order.
    public func oldest(limit: Int) throws -> [QueuedRecord] {
        try database.query(
            "SELECT id, kind, created_at, payload FROM records ORDER BY id LIMIT ?",
            [.int(Int64(max(limit, 0)))]
        ) { row in
            QueuedRecord(
                id: row.int64(0),
                kind: RecordKind(rawValue: row.text(1) ?? "") ?? .location,
                createdAt: Date(timeIntervalSince1970: row.double(2)),
                payload: row.blob(3)
            )
        }
    }

    public func remove(ids: [Int64]) throws {
        guard !ids.isEmpty else { return }
        // Chunk to stay well below SQLite's bound-parameter limit.
        try database.transaction {
            for chunk in stride(from: 0, to: ids.count, by: 500).map({ ids[$0..<min($0 + 500, ids.count)] }) {
                let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
                try database.execute("DELETE FROM records WHERE id IN (\(placeholders))", chunk.map { .int($0) })
            }
        }
    }

    public func counts() throws -> QueueCounts {
        let rows = try database.query("SELECT kind, COUNT(*) FROM records GROUP BY kind") { row in
            (row.text(0) ?? "", row.int(1))
        }
        var counts = QueueCounts()
        for (kind, count) in rows {
            switch RecordKind(rawValue: kind) {
            case .location: counts.locations = count
            case .event: counts.events = count
            case nil: break
            }
        }
        return counts
    }

    /// Drops the oldest records that exceed the retention limits. Returns the number removed.
    @discardableResult
    public func prune(_ retention: QueueRetention, now: Date = .now) throws -> Int {
        var removed = 0
        if let days = retention.maxAgeDays, days > 0 {
            let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
            try database.execute("DELETE FROM records WHERE created_at < ?", [.double(cutoff.timeIntervalSince1970)])
            removed += database.changes
        }
        if let maxRecords = retention.maxRecords, maxRecords >= 0 {
            try database.execute(
                "DELETE FROM records WHERE id NOT IN (SELECT id FROM records ORDER BY id DESC LIMIT ?)",
                [.int(Int64(maxRecords))]
            )
            removed += database.changes
        }
        return removed
    }

    public func removeAll() throws {
        try database.execute("DELETE FROM records")
    }

    // MARK: Request log

    public func appendLog(_ entry: RequestLogEntry) throws {
        try database.transaction {
            try database.execute(
                """
                INSERT INTO request_log (date, method, url, status, duration, request_bytes, record_count, success,
                                         error, request_headers, request_preview, response_preview)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    .double(entry.date.timeIntervalSince1970), .text(entry.method), .text(entry.url),
                    entry.statusCode.map { .int(Int64($0)) } ?? .null, .double(entry.duration),
                    .int(Int64(entry.requestBytes)), .int(Int64(entry.recordCount)), .int(entry.success ? 1 : 0),
                    entry.error.map(SQLiteValue.text) ?? .null, .text(entry.requestHeaders),
                    .text(entry.requestPreview), .text(entry.responsePreview),
                ]
            )
            try database.execute(
                "DELETE FROM request_log WHERE id NOT IN (SELECT id FROM request_log ORDER BY id DESC LIMIT ?)",
                [.int(Int64(Self.maxLogEntries))]
            )
        }
    }

    /// Most recent first.
    public func recentLogs(limit: Int = maxLogEntries) throws -> [RequestLogEntry] {
        try database.query(
            """
            SELECT id, date, method, url, status, duration, request_bytes, record_count, success, error,
                   request_headers, request_preview, response_preview
            FROM request_log ORDER BY id DESC LIMIT ?
            """,
            [.int(Int64(limit))]
        ) { row in
            RequestLogEntry(
                id: row.int64(0),
                date: Date(timeIntervalSince1970: row.double(1)),
                method: row.text(2) ?? "",
                url: row.text(3) ?? "",
                statusCode: row.isNull(4) ? nil : row.int(4),
                duration: row.double(5),
                requestBytes: row.int(6),
                recordCount: row.int(7),
                success: row.int(8) != 0,
                error: row.text(9),
                requestHeaders: row.text(10) ?? "",
                requestPreview: row.text(11) ?? "",
                responsePreview: row.text(12) ?? ""
            )
        }
    }

    public func clearLogs() throws {
        try database.execute("DELETE FROM request_log")
    }
}
