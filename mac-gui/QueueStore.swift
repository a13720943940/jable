import Foundation
import SQLite3

enum QueueTaskState: String, Codable {
    case pending
    case checkingNAS
    case parsing
    case downloading
    case merging
    case scraping
    case organizing
    case awaitingReview
    case nasTransferring
    case completed
    case skipped
    case failed
    case cancelled
    case interrupted

    var displayName: String {
        switch self {
        case .pending: return "等待中"
        case .checkingNAS: return "检查 NAS"
        case .parsing: return "解析中"
        case .downloading: return "下载中"
        case .merging: return "合并中"
        case .scraping: return "刮削中"
        case .organizing: return "整理中"
        case .awaitingReview: return "待确认"
        case .nasTransferring: return "发送 NAS"
        case .completed: return "已完成"
        case .skipped: return "已跳过"
        case .failed: return "失败"
        case .cancelled: return "已取消"
        case .interrupted: return "已中断"
        }
    }

    var isFinished: Bool {
        [.completed, .skipped, .failed, .cancelled, .interrupted].contains(self)
    }
}

enum TaskStepResult: String, Codable {
    case pending
    case running
    case succeeded
    case failed
    case skipped

    var displayName: String {
        switch self {
        case .pending: return "等待"
        case .running: return "进行中"
        case .succeeded: return "成功"
        case .failed: return "失败"
        case .skipped: return "跳过"
        }
    }
}

enum ScraperSourceHealth: String, Codable {
    case unchecked
    case checking
    case available
    case unavailable

    var displayName: String {
        switch self {
        case .unchecked: return "未检测"
        case .checking: return "检测中"
        case .available: return "可用"
        case .unavailable: return "不可用"
        }
    }
}

struct ScraperSource: Identifiable, Codable, Equatable {
    var id: UUID
    var domain: String
    var enabled: Bool
    var health: ScraperSourceHealth
}

struct DownloadQueueItem: Identifiable, Codable, Equatable {
    var id: UUID
    var inputURL: String
    var saveDirectory: String
    var saveName: String
    var sourcePageURL: String?
    var extraArgs: String
    var catalogNumber: String
    var performerName: String
    var scraperDomain: String
    var scraperDomains: [String]?
    var previewBeforeCompletion: Bool?
    var organizeAfterDownload: Bool
    var threadCount: Int
    var allowDuplicateDownload: Bool?
    var nasEnabled: Bool
    var nasServerURL: String?
    var nasDestinationPath: String
    var nasScrapeFailureEnabled: Bool?
    var nasScrapeFailurePath: String?
    var nasLastTransferPath: String?
    var nasMoveAfterTransfer: Bool
    var downloadStepResult: TaskStepResult?
    var scrapeStepResult: TaskStepResult?
    var nasStepResult: TaskStepResult?
    var downloadedBytes: Int64?
    var totalBytes: Int64?
    var scrapeMetadataFound: Bool?
    var reviewFolderPath: String?
    var state: QueueTaskState
    var progress: Double
    var phase: String
    var resultMessage: String
    var outputPath: String
    var logText: String
    var createdAt: Date
    var startedAt: Date?
    var finishedAt: Date?

    var displayTitle: String {
        if !catalogNumber.isEmpty { return catalogNumber }
        if !saveName.isEmpty { return saveName }
        return inputURL
    }
}

struct QueueSettings: Codable {
    var downloadThreadCount: Int = 2
    var allowDuplicateDownload: Bool? = false
    var previewBeforeCompletion: Bool? = false
    var scraperSources: [ScraperSource]? = nil
    var nasEnabled: Bool = false
    var nasServerURL: String = "smb://"
    var nasDestinationPath: String = ""
    var nasScrapeFailureEnabled: Bool? = false
    var nasScrapeFailurePath: String? = ""
    var nasMoveAfterTransfer: Bool = false
}

final class QueueStore {
    private var database: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(databaseURL customDatabaseURL: URL? = nil) throws {
        let databaseURL: URL
        if let customDatabaseURL {
            databaseURL = customDatabaseURL
            try FileManager.default.createDirectory(
                at: customDatabaseURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } else {
            let supportURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("jable.tv 下载工具", isDirectory: true)
            try FileManager.default.createDirectory(at: supportURL, withIntermediateDirectories: true)
            databaseURL = supportURL.appendingPathComponent("queue.sqlite3")
        }
        guard sqlite3_open(databaseURL.path, &database) == SQLITE_OK else {
            throw StoreError.openFailed
        }
        try execute("PRAGMA journal_mode=WAL")
        try execute("CREATE TABLE IF NOT EXISTS tasks (id TEXT PRIMARY KEY, created_at REAL NOT NULL, payload BLOB NOT NULL)")
        try execute("CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, payload BLOB NOT NULL)")
    }

    deinit {
        sqlite3_close(database)
    }

    func loadTasks() throws -> [DownloadQueueItem] {
        let sql = "SELECT payload FROM tasks ORDER BY created_at ASC"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        var tasks: [DownloadQueueItem] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let bytes = sqlite3_column_blob(statement, 0) else { continue }
            let count = Int(sqlite3_column_bytes(statement, 0))
            let data = Data(bytes: bytes, count: count)
            if let task = try? decoder.decode(DownloadQueueItem.self, from: data) {
                tasks.append(task)
            }
        }
        return tasks
    }

    func saveTask(_ task: DownloadQueueItem) throws {
        let sql = "INSERT OR REPLACE INTO tasks (id, created_at, payload) VALUES (?, ?, ?)"
        let data = try encoder.encode(task)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, task.id.uuidString, -1, transient)
        sqlite3_bind_double(statement, 2, task.createdAt.timeIntervalSince1970)
        _ = data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 3, bytes.baseAddress, Int32(data.count), transient)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.writeFailed }
    }

    func deleteTask(id: UUID) throws {
        let sql = "DELETE FROM tasks WHERE id = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, id.uuidString, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.writeFailed }
    }

    func loadSettings() -> QueueSettings {
        let sql = "SELECT payload FROM settings WHERE key = 'main'"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            return QueueSettings()
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let bytes = sqlite3_column_blob(statement, 0) else { return QueueSettings() }
        let count = Int(sqlite3_column_bytes(statement, 0))
        return (try? decoder.decode(QueueSettings.self, from: Data(bytes: bytes, count: count))) ?? QueueSettings()
    }

    func saveSettings(_ settings: QueueSettings) throws {
        let sql = "INSERT OR REPLACE INTO settings (key, payload) VALUES ('main', ?)"
        let data = try encoder.encode(settings)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw StoreError.queryFailed
        }
        defer { sqlite3_finalize(statement) }
        _ = data.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 1, bytes.baseAddress, Int32(data.count), transient)
        }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw StoreError.writeFailed }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw StoreError.queryFailed
        }
    }

    enum StoreError: LocalizedError {
        case openFailed, queryFailed, writeFailed

        var errorDescription: String? {
            switch self {
            case .openFailed: return "无法打开任务队列数据库。"
            case .queryFailed: return "任务队列数据库查询失败。"
            case .writeFailed: return "任务队列数据库写入失败。"
            }
        }
    }
}
