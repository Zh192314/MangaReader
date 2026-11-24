import Foundation
import SQLite3

/// SQLite 轻封装。App 只用一个库，读写都在内部串行队列上。
final class Database {

    static let shared = Database()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "db.queue")

    private init() {
        open()
        migrate()
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - 路径

    static var directory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask)[0]
            .appendingPathComponent("MangaReader", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    // MARK: - 打开

    private func open() {
        let path = Database.directory.appendingPathComponent("manga.db").path
        if sqlite3_open_v2(path, &db,
                           SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                           nil) != SQLITE_OK {
            print("[DB] open failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        sqlite3_busy_timeout(db, 3000)
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA synchronous=NORMAL;")
    }

    // MARK: - 建表

    private func migrate() {
        exec("""
        CREATE TABLE IF NOT EXISTS source (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            version TEXT NOT NULL DEFAULT '1.0.0',
            lang TEXT NOT NULL DEFAULT 'zh',
            kind TEXT NOT NULL DEFAULT 'js',
            base_url TEXT NOT NULL DEFAULT '',
            icon TEXT,
            author TEXT,
            desc TEXT,
            script TEXT,
            rules TEXT,
            enabled INTEGER NOT NULL DEFAULT 1,
            builtin INTEGER NOT NULL DEFAULT 0,
            sort INTEGER NOT NULL DEFAULT 0,
            timeout REAL NOT NULL DEFAULT 15,
            headers TEXT,
            installed_at REAL NOT NULL DEFAULT 0
        );
        """)

        exec("""
        CREATE TABLE IF NOT EXISTS library (
            manga_key TEXT PRIMARY KEY,
            source_id TEXT NOT NULL,
            manga_url TEXT NOT NULL,
            title TEXT NOT NULL,
            cover TEXT,
            author TEXT,
            desc TEXT,
            genre TEXT,
            status TEXT,
            latest_chapter TEXT,
            updated_at REAL DEFAULT 0,
            added_at REAL NOT NULL,
            last_read_chapter_name TEXT,
            last_read_chapter_url TEXT,
            last_read_at REAL DEFAULT 0,
            last_read_page INTEGER DEFAULT 0,
            unread_count INTEGER DEFAULT 0,
            downloaded INTEGER DEFAULT 0
        );
        """)

        exec("""
        CREATE TABLE IF NOT EXISTS chapter (
            manga_key TEXT NOT NULL,
            url TEXT NOT NULL,
            name TEXT NOT NULL,
            idx INTEGER NOT NULL DEFAULT 0,
            is_read INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (manga_key, url)
        );
        """)

        exec("""
        CREATE TABLE IF NOT EXISTS history (
            manga_key TEXT PRIMARY KEY,
            source_id TEXT NOT NULL,
            manga_url TEXT NOT NULL,
            title TEXT NOT NULL,
            cover TEXT,
            chapter_name TEXT,
            chapter_url TEXT,
            page INTEGER DEFAULT 0,
            read_at REAL NOT NULL
        );
        """)

        exec("CREATE INDEX IF NOT EXISTS idx_lib_added ON library(added_at DESC);")
        exec("CREATE INDEX IF NOT EXISTS idx_hist_read ON history(read_at DESC);")
        exec("CREATE INDEX IF NOT EXISTS idx_chapter_manga ON chapter(manga_key, idx);")
    }

    // MARK: - 基础执行

    @discardableResult
    func exec(_ sql: String, _ binds: [Any?] = []) -> Bool {
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                print("[DB] prepare failed: \(String(cString: sqlite3_errmsg(db))) | \(sql.prefix(120))")
                return false
            }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, binds)
            let rc = sqlite3_step(stmt)
            if rc != SQLITE_DONE && rc != SQLITE_ROW {
                print("[DB] step failed rc=\(rc): \(String(cString: sqlite3_errmsg(db)))")
                return false
            }
            return true
        }
    }

    func query(_ sql: String, _ binds: [Any?] = []) -> [[String: Any]] {
        queue.sync {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                print("[DB] prepare failed: \(String(cString: sqlite3_errmsg(db)))")
                return []
            }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, binds)
            var rows: [[String: Any]] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                var row: [String: Any] = [:]
                let count = sqlite3_column_count(stmt)
                for i in 0..<count {
                    let name = String(cString: sqlite3_column_name(stmt, i))
                    switch sqlite3_column_type(stmt, i) {
                    case SQLITE_INTEGER:
                        row[name] = Int(sqlite3_column_int64(stmt, i))
                    case SQLITE_FLOAT:
                        row[name] = sqlite3_column_double(stmt, i)
                    case SQLITE_TEXT:
                        if let c = sqlite3_column_text(stmt, i) {
                            row[name] = String(cString: c)
                        }
                    case SQLITE_NULL:
                        row[name] = NSNull()
                    default:
                        if let c = sqlite3_column_text(stmt, i) {
                            row[name] = String(cString: c)
                        }
                    }
                }
                rows.append(row)
            }
            return rows
        }
    }

    private func bind(_ stmt: OpaquePointer?, _ binds: [Any?]) {
        for (i, value) in binds.enumerated() {
            let idx = Int32(i + 1)
            switch value {
            case nil, is NSNull:
                sqlite3_bind_null(stmt, idx)
            case let v as String:
                sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            case let v as Int:
                sqlite3_bind_int64(stmt, idx, Int64(v))
            case let v as Double:
                sqlite3_bind_double(stmt, idx, v)
            case let v as Bool:
                sqlite3_bind_int(stmt, idx, v ? 1 : 0)
            case let v as Float:
                sqlite3_bind_double(stmt, idx, Double(v))
            default:
                sqlite3_bind_text(stmt, idx, String(describing: value!), -1, SQLITE_TRANSIENT)
            }
        }
    }

    func transaction(_ body: () -> Void) {
        exec("BEGIN;")
        body()
        exec("COMMIT;")
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - 行读取辅助

extension Dictionary where Key == String, Value == Any {
    func str(_ k: String, _ def: String = "") -> String {
        if let s = self[k] as? String { return s }
        if let n = self[k] as? Int { return String(n) }
        return def
    }
    func int(_ k: String, _ def: Int = 0) -> Int {
        if let n = self[k] as? Int { return n }
        if let d = self[k] as? Double { return Int(d) }
        if let s = self[k] as? String { return Int(s) ?? def }
        return def
    }
    func double(_ k: String, _ def: Double = 0) -> Double {
        if let d = self[k] as? Double { return d }
        if let n = self[k] as? Int { return Double(n) }
        if let s = self[k] as? String { return Double(s) ?? def }
        return def
    }
    func bool(_ k: String, _ def: Bool = false) -> Bool {
        if let n = self[k] as? Int { return n != 0 }
        if let b = self[k] as? Bool { return b }
        return def
    }
}
