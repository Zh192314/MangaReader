import Foundation

/// 源的持久化与导入
final class SourceStore {

    static let shared = SourceStore()
    private let db = Database.shared

    // MARK: - 读

    func all() -> [MangaSource] {
        db.query("SELECT * FROM source ORDER BY sort ASC, name ASC;").compactMap { decode($0) }
    }

    func enabled(lang: SourceLang? = nil) -> [MangaSource] {
        all().filter { s in
            guard s.enabled else { return false }
            if let l = lang { return s.lang == l }
            return true
        }
    }

    func find(_ id: String) -> MangaSource? {
        db.query("SELECT * FROM source WHERE id = ? LIMIT 1;", [id]).first.flatMap(decode)
    }

    func grouped() -> [(lang: SourceLang, list: [MangaSource])] {
        let list = all()
        return SourceLang.allCases.compactMap { lang in
            let part = list.filter { $0.lang == lang }
            return part.isEmpty ? nil : (lang, part)
        }
    }

    // MARK: - 写

    func save(_ s: MangaSource) {
        let rulesJSON: String
        if let r = s.rules, let d = try? JSONEncoder().encode(r),
           let str = String(data: d, encoding: .utf8) {
            rulesJSON = str
        } else {
            rulesJSON = ""
        }
        let headersJSON: String
        if let h = s.headers, let d = try? JSONSerialization.data(withJSONObject: h),
           let str = String(data: d, encoding: .utf8) {
            headersJSON = str
        } else {
            headersJSON = ""
        }

        db.exec("""
        INSERT INTO source (id,name,version,lang,kind,base_url,icon,author,desc,script,rules,
                            enabled,builtin,sort,timeout,headers,installed_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(id) DO UPDATE SET
            name=excluded.name, version=excluded.version, lang=excluded.lang, kind=excluded.kind,
            base_url=excluded.base_url, icon=excluded.icon, author=excluded.author,
            desc=excluded.desc, script=excluded.script, rules=excluded.rules,
            enabled=excluded.enabled, builtin=excluded.builtin, timeout=excluded.timeout,
            headers=excluded.headers;
        """, [
            s.id, s.name, s.version, s.lang.rawValue, s.kind.rawValue, s.baseURL,
            s.iconURL, s.author, s.desc, s.script, rulesJSON,
            s.enabled, s.builtin, s.order, s.timeout, headersJSON,
            Date().timeIntervalSince1970
        ])
        SourceRuntimePool.shared.invalidate(s.id)
    }

    func setEnabled(_ id: String, _ on: Bool) {
        db.exec("UPDATE source SET enabled = ? WHERE id = ?;", [on, id])
        SourceRuntimePool.shared.invalidate(id)
    }

    func setOrder(_ ids: [String]) {
        for (i, id) in ids.enumerated() {
            db.exec("UPDATE source SET sort = ? WHERE id = ?;", [i, id])
        }
    }

    func delete(_ id: String) {
        db.exec("DELETE FROM source WHERE id = ?;", [id])
        SourceRuntimePool.shared.invalidate(id)
    }

    // MARK: - 解码

    private func decode(_ row: [String: Any]) -> MangaSource? {
        let id = row.str("id")
        let name = row.str("name")
        guard !id.isEmpty, !name.isEmpty else { return nil }

        var src = MangaSource(id: id, name: name)
        src.version = row.str("version", "1.0.0")
        src.lang = SourceLang(rawValue: row.str("lang", "zh")) ?? .zh
        src.kind = SourceKind(rawValue: row.str("kind", "js")) ?? .js
        src.baseURL = row.str("base_url")
        let icon = row.str("icon")
        src.iconURL = icon.isEmpty ? nil : icon
        let author = row.str("author")
        src.author = author.isEmpty ? nil : author
        let desc = row.str("desc")
        src.desc = desc.isEmpty ? nil : desc
        let script = row.str("script")
        src.script = script.isEmpty ? nil : script
        src.enabled = row.bool("enabled", true)
        src.builtin = row.bool("builtin")
        src.order = row.int("sort")
        src.timeout = row.double("timeout", 15)

        let rulesStr = row.str("rules")
        if !rulesStr.isEmpty, let d = rulesStr.data(using: .utf8) {
            src.rules = try? JSONDecoder().decode(SourceRules.self, from: d)
        }
        let headersStr = row.str("headers")
        if !headersStr.isEmpty, let d = headersStr.data(using: .utf8) {
            src.headers = try? JSONSerialization.jsonObject(with: d) as? [String: String]
        }
        return src
    }

    // MARK: - 首次装配内置源

    func seedIfNeeded() {
        let rows = db.query("SELECT COUNT(*) AS c FROM source;")
        let count = rows.first?.int("c", 0) ?? 0
        guard count == 0 else { return }
        for (i, s) in BuiltinSources.all.enumerated() {
            var src = s
            src.order = i
            src.builtin = true
            save(src)
        }
    }

    /// 恢复内置源（不删除用户自己导入的）
    func restoreBuiltins() {
        for (i, s) in BuiltinSources.all.enumerated() {
            var src = s
            src.order = i
            src.builtin = true
            save(src)
        }
    }
}
