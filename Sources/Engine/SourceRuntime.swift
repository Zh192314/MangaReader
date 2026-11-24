import Foundation

/// 单源的运行时：把 JS 调用结果转成 App 模型。
/// 两种底层引擎：
/// - `JSEngine`：本 App 自己的源格式（同步阻塞 HTTP，暴露 search/detail/chapters/images）
/// - `VeneraRuntime`：Venera（venera-configs）格式的源（async/await + ComicSource 子类）
final class SourceRuntime {
    let source: MangaSource
    private let engine: JSEngine?
    private let venera: VeneraRuntime?

    init(source: MangaSource) {
        self.source = source
        if source.kind == .venera {
            self.engine = nil
            self.venera = VeneraRuntime(source: source)
        } else {
            self.engine = JSEngine(source: source)
            self.venera = nil
        }
    }

    // MARK: - 能力查询

    private func has(_ fn: String) -> Bool {
        guard let engine = engine else { return false }
        guard let v = engine.context.objectForKeyedSubscript(fn) else { return false }
        return !v.isUndefined && !v.isNull
    }

    // MARK: - API

    func search(_ keyword: String, page: Int = 1) async throws -> [Manga] {
        if source.kind == .venera {
            return try await withVenera { try $0.search(keyword, page: page) }
        }
        let raw = try await withEngine { try $0.callJSON("search", [keyword, page]) }
        return mapList(raw)
    }

    func detail(_ url: String) async throws -> Manga {
        if source.kind == .venera {
            return try await withVenera { try $0.detail(url).0 }
        }
        let raw = try await withEngine { try $0.callJSON("detail", [url]) }
        guard let d = raw as? [String: Any] else { throw SourceError.parse("详情格式错误") }
        var m = Manga(key: Manga.makeKey(source: source.id, url: url),
                      sourceID: source.id,
                      url: url,
                      title: str(d["title"]),
                      cover: str(d["cover"]))
        m.author = str(d["author"])
        m.desc = str(d["desc"])
        m.genre = str(d["genre"])
        m.status = str(d["status"])
        if m.title.isEmpty { throw SourceError.parse("没有解析到标题") }
        return m
    }

    func chapters(_ url: String) async throws -> [Chapter] {
        if source.kind == .venera {
            return try await withVenera { try $0.chapters(url) }
        }
        let raw = try await withEngine { try $0.callJSON("chapters", [url]) }
        guard let arr = raw as? [Any] else { throw SourceError.parse("章节列表格式错误") }
        var out: [Chapter] = []
        for (i, item) in arr.enumerated() {
            guard let d = item as? [String: Any] else { continue }
            let u = str(d["url"])
            let n = str(d["name"])
            guard !u.isEmpty else { continue }
            var c = Chapter(url: u, name: n.isEmpty ? "第\(i + 1)话" : n)
            c.index = i
            out.append(c)
        }
        if out.isEmpty { throw SourceError.empty }
        return out
    }

    func images(_ chapterURL: String) async throws -> [(url: String, referer: String?)] {
        if source.kind == .venera {
            let parts = chapterURL.components(separatedBy: "||")
            let comicId = parts.count > 1 ? parts[0] : ""
            let epId = parts.count > 1 ? parts[1] : chapterURL
            return try await withVenera { try $0.images(comicId: comicId, epId: epId) }
        }
        let raw = try await withEngine { try $0.callJSON("images", [chapterURL]) }
        guard let arr = raw as? [Any] else { throw SourceError.parse("图片列表格式错误") }
        var out: [(url: String, referer: String?)] = []
        for item in arr {
            if let s = item as? String, !s.isEmpty {
                out.append((url: s, referer: chapterURL))
            } else if let d = item as? [String: Any] {
                let u = str(d["url"])
                if !u.isEmpty {
                    let ref = str(d["referer"])
                    out.append((url: u, referer: ref.isEmpty ? chapterURL : ref))
                }
            }
        }
        if out.isEmpty { throw SourceError.empty }
        return out
    }

    /// 分类/榜单（源可选实现）
    func category(_ param: String, page: Int = 1) async throws -> [Manga] {
        if source.kind == .venera {
            return try await withVenera { try $0.category(param, page: page) }
        }
        guard has("category") else { throw SourceError.empty }
        let raw = try await withEngine { try $0.callJSON("category", [param, page]) }
        return mapList(raw)
    }

    func ranking(_ key: String, page: Int = 1) async throws -> [Manga] {
        if source.kind == .venera {
            return try await withVenera { try $0.ranking(key, page: page) }
        }
        if has("ranking") {
            let raw = try await withEngine { try $0.callJSON("ranking", [key, page]) }
            return mapList(raw)
        }
        if has("category") {
            return try await category(key, page: page)
        }
        return []
    }

    // MARK: - 执行包装

    private func withEngine<T>(_ body: @escaping (JSEngine) throws -> T) async throws -> T {
        guard source.enabled else { throw SourceError.disabled }
        guard let engine = engine else { throw SourceError.script("该源需要 Venera 运行时") }
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    cont.resume(returning: try body(engine))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func withVenera<T>(_ body: @escaping (VeneraRuntime) throws -> T) async throws -> T {
        guard source.enabled else { throw SourceError.disabled }
        guard let venera = venera else { throw SourceError.script("Venera 源加载失败，请检查脚本") }
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    cont.resume(returning: try body(venera))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - 映射

    private func mapList(_ raw: Any?) -> [Manga] {
        guard let arr = raw as? [Any] else { return [] }
        var out: [Manga] = []
        var seen = Set<String>()
        for item in arr {
            guard let d = item as? [String: Any] else { continue }
            let u = str(d["url"])
            let t = str(d["title"])
            guard !u.isEmpty, !t.isEmpty else { continue }
            let key = Manga.makeKey(source: source.id, url: u)
            if seen.contains(key) { continue }
            seen.insert(key)
            var m = Manga(key: key, sourceID: source.id, url: u, title: t, cover: str(d["cover"]))
            m.author = str(d["author"])
            m.latestChapter = str(d["latest"])
            out.append(m)
        }
        return out
    }

    private func str(_ any: Any?) -> String {
        if let s = any as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let n = any as? NSNumber { return n.stringValue }
        return ""
    }
}

/// 运行时池：按 源 id + 版本 缓存，源被编辑/删除时失效
final class SourceRuntimePool {
    static let shared = SourceRuntimePool()
    private var pool: [String: SourceRuntime] = [:]
    private let lock = NSLock()

    func runtime(for source: MangaSource) -> SourceRuntime {
        let key = "\(source.id)@\(source.version)@\(source.script?.hashValue ?? 0)\(source.rules?.hashValue ?? 0)"
        lock.lock()
        defer { lock.unlock() }
        if let r = pool[key] { return r }
        let r = SourceRuntime(source: source)
        pool[key] = r
        return r
    }

    func invalidate(_ sourceID: String) {
        lock.lock()
        pool = pool.filter { !$0.key.hasPrefix(sourceID + "@") }
        lock.unlock()
    }

    func invalidateAll() {
        lock.lock(); pool.removeAll(); lock.unlock()
    }
}
