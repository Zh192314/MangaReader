import Foundation

/// 书架 + 阅读记录 + 章节进度
final class LibraryStore {

    static let shared = LibraryStore()
    private let db = Database.shared

    // MARK: - 书架

    func allLibrary() -> [LibraryEntry] {
        db.query("SELECT * FROM library ORDER BY last_read_at DESC, added_at DESC;").compactMap { row in
            let key = row.str("manga_key")
            guard !key.isEmpty else { return nil }
            var m = Manga(key: key,
                          sourceID: row.str("source_id"),
                          url: row.str("manga_url"),
                          title: row.str("title"),
                          cover: row.str("cover"))
            m.author = row.str("author")
            m.desc = row.str("desc")
            m.genre = row.str("genre")
            m.status = row.str("status")
            m.latestChapter = row.str("latest_chapter")
            m.updatedAt = row.double("updated_at")

            var e = LibraryEntry(manga: m, addedAt: row.double("added_at"))
            e.lastReadChapterName = row.str("last_read_chapter_name")
            e.lastReadChapterURL = row.str("last_read_chapter_url")
            e.lastReadAt = row.double("last_read_at")
            e.lastReadPage = row.int("last_read_page")
            e.unreadCount = row.int("unread_count")
            e.downloaded = row.bool("downloaded")
            return e
        }
    }

    func isInLibrary(_ key: String) -> Bool {
        !db.query("SELECT 1 FROM library WHERE manga_key = ? LIMIT 1;", [key]).isEmpty
    }

    func addToLibrary(_ m: Manga) {
        db.exec("""
        INSERT INTO library (manga_key,source_id,manga_url,title,cover,author,desc,genre,status,
                             latest_chapter,updated_at,added_at,unread_count)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,0)
        ON CONFLICT(manga_key) DO UPDATE SET
            title=excluded.title, cover=excluded.cover, latest_chapter=excluded.latest_chapter;
        """, [
            m.key, m.sourceID, m.url, m.title, m.cover, m.author, m.desc,
            m.genre, m.status, m.latestChapter, m.updatedAt,
            Date().timeIntervalSince1970
        ])
    }

    func removeFromLibrary(_ key: String) {
        db.exec("DELETE FROM library WHERE manga_key = ?;", [key])
    }

    func touchLibrary(_ key: String) {
        db.exec("UPDATE library SET added_at = ? WHERE manga_key = ?;",
                [Date().timeIntervalSince1970, key])
    }

    // MARK: - 章节

    func saveChapters(_ chapters: [Chapter], for key: String) {
        // 保留已读状态
        var readSet = Set<String>()
        for row in db.query("SELECT url FROM chapter WHERE manga_key = ? AND is_read = 1;", [key]) {
            readSet.insert(row.str("url"))
        }
        db.exec("DELETE FROM chapter WHERE manga_key = ?;", [key])
        db.transaction {
            for (i, c) in chapters.enumerated() {
                db.exec("INSERT OR REPLACE INTO chapter (manga_key,url,name,idx,is_read) VALUES (?,?,?,?,?);",
                        [key, c.url, c.name, i, readSet.contains(c.url)])
            }
        }
        let unread = chapters.filter { !readSet.contains($0.url) }.count
        db.exec("UPDATE library SET unread_count = ? WHERE manga_key = ?;", [unread, key])
        if let last = chapters.last {
            db.exec("UPDATE library SET latest_chapter = ? WHERE manga_key = ?;", [last.name, key])
        }
    }

    func chapters(for key: String) -> [Chapter] {
        db.query("SELECT * FROM chapter WHERE manga_key = ? ORDER BY idx ASC;", [key]).map { row in
            var c = Chapter(url: row.str("url"), name: row.str("name"))
            c.index = row.int("idx")
            c.read = row.bool("is_read")
            return c
        }
    }

    func markRead(_ key: String, chapterURL: String, isRead: Bool = true) {
        db.exec("UPDATE chapter SET is_read = ? WHERE manga_key = ? AND url = ?;",
                [isRead, key, chapterURL])
        let rows = db.query("SELECT COUNT(*) AS c FROM chapter WHERE manga_key = ? AND is_read = 0;", [key])
        let unread = rows.first?.int("c", 0) ?? 0
        db.exec("UPDATE library SET unread_count = ? WHERE manga_key = ?;", [unread, key])
    }

    func markAllRead(_ key: String) {
        db.exec("UPDATE chapter SET is_read = 1 WHERE manga_key = ?;", [key])
        db.exec("UPDATE library SET unread_count = 0 WHERE manga_key = ?;", [key])
    }

    // MARK: - 阅读进度

    func saveProgress(manga: Manga, chapter: Chapter, page: Int) {
        let now = Date().timeIntervalSince1970
        db.exec("""
        UPDATE library SET last_read_chapter_name = ?, last_read_chapter_url = ?,
                           last_read_at = ?, last_read_page = ?, added_at = ?
        WHERE manga_key = ?;
        """, [chapter.name, chapter.url, now, page, now, manga.key])
        markRead(manga.key, chapterURL: chapter.url)

        db.exec("""
        INSERT INTO history (manga_key,source_id,manga_url,title,cover,chapter_name,chapter_url,page,read_at)
        VALUES (?,?,?,?,?,?,?,?,?)
        ON CONFLICT(manga_key) DO UPDATE SET
            chapter_name=excluded.chapter_name, chapter_url=excluded.chapter_url,
            page=excluded.page, read_at=excluded.read_at, cover=excluded.cover,
            title=excluded.title, manga_url=excluded.manga_url;
        """, [manga.key, manga.sourceID, manga.url, manga.title, manga.cover,
              chapter.name, chapter.url, page, now])
    }

    // MARK: - 历史

    func allHistory() -> [HistoryEntry] {
        db.query("SELECT * FROM history ORDER BY read_at DESC LIMIT 500;").compactMap { row in
            let key = row.str("manga_key")
            guard !key.isEmpty else { return nil }
            return HistoryEntry(mangaKey: key,
                                sourceID: row.str("source_id"),
                                mangaURL: row.str("manga_url"),
                                title: row.str("title"),
                                cover: row.str("cover"),
                                chapterName: row.str("chapter_name"),
                                chapterURL: row.str("chapter_url"),
                                page: row.int("page"),
                                readAt: row.double("read_at"))
        }
    }

    func removeHistory(_ key: String) {
        db.exec("DELETE FROM history WHERE manga_key = ?;", [key])
    }

    func clearHistory() {
        db.exec("DELETE FROM history;")
    }

    // MARK: - 统计

    var libraryCount: Int {
        db.query("SELECT COUNT(*) AS c FROM library;").first?.int("c", 0) ?? 0
    }

    var historyCount: Int {
        db.query("SELECT COUNT(*) AS c FROM history;").first?.int("c", 0) ?? 0
    }

    var totalReadChapters: Int {
        db.query("SELECT COUNT(*) AS c FROM chapter WHERE is_read = 1;").first?.int("c", 0) ?? 0
    }

    // MARK: - 备份 / 恢复（iCloud 与本地共用同一份 JSON）

    struct Backup: Codable {
        var version: Int = 1
        var exportedAt: Double = Date().timeIntervalSince1970
        var sources: [MangaSource]
        var library: [LibraryEntry]
        var history: [HistoryEntry]
        var chapters: [String: [Chapter]]
    }

    func makeBackup() -> Backup {
        let lib = allLibrary()
        var chapterMap: [String: [Chapter]] = [:]
        for e in lib {
            let cs = chapters(for: e.manga.key)
            if !cs.isEmpty { chapterMap[e.manga.key] = cs }
        }
        return Backup(sources: SourceStore.shared.all(),
                      library: lib,
                      history: allHistory(),
                      chapters: chapterMap)
    }

    func restore(_ b: Backup) {
        for s in b.sources where !s.builtin {
            SourceStore.shared.save(s)
        }
        for e in b.library {
            addToLibrary(e.manga)
            if let cs = b.chapters[e.manga.key], !cs.isEmpty {
                saveChapters(cs, for: e.manga.key)
            }
            db.exec("""
            UPDATE library SET last_read_chapter_name=?, last_read_chapter_url=?,
                               last_read_at=?, last_read_page=?, unread_count=?, added_at=?
            WHERE manga_key=?;
            """, [e.lastReadChapterName, e.lastReadChapterURL, e.lastReadAt,
                  e.lastReadPage, e.unreadCount, e.addedAt, e.manga.key])
        }
        for h in b.history {
            db.exec("""
            INSERT OR REPLACE INTO history (manga_key,source_id,manga_url,title,cover,
                                            chapter_name,chapter_url,page,read_at)
            VALUES (?,?,?,?,?,?,?,?,?);
            """, [h.mangaKey, h.sourceID, h.mangaURL, h.title, h.cover,
                  h.chapterName, h.chapterURL, h.page, h.readAt])
        }
    }
}
