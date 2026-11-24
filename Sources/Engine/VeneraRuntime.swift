import Foundation
import JavaScriptCore
import CryptoKit

/// Venera（venera-app/venera）源运行时。
///
/// Venera 源全部是 `async` 函数，靠 Promise 驱动。JavaScriptCore 没有内建 event loop，
/// 但只要 Promise 已经在 JS 里被 resolve，下一次进入 JS（JSContext 的任意 API 调用）
/// 就会把整条微任务队列排干。于是这里用「触发一次 → 反复问 done → 取结果」的泵模型：
/// HTTP 由同步桥 `__httpFull` 完成，源的 `await` 只是把后续代码推迟一个微任务，
/// 一次 `evaluateScript` 就能把它跑完。
final class VeneraRuntime {

    struct Meta {
        var name = ""
        var key = ""
        var version = ""
        var url = ""
        var hasSearch = false
        var hasComic = false
        var hasExplore = false
        var exploreTitles: [String] = []
    }

    let source: MangaSource
    private(set) var meta = Meta()

    private let context: JSContext
    private let queue: DispatchQueue
    private var detailCache: [String: (Manga, [Chapter])] = [:]

    // MARK: - 初始化

    init?(source: MangaSource) {
        guard let script = source.script, !script.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        guard let ctx = JSContext() else { return nil }
        self.source = source
        self.context = ctx
        self.queue = DispatchQueue(label: "venera.runtime.\(source.id)", qos: .userInitiated)

        let base = source.effectiveHeaders
        installBridge(baseHeaders: base)

        ctx.evaluateScript(VeneraLib.bootstrap)
        ctx.evaluateScript(VeneraRuntime.helpers)

        // 源里可能声明 `let` / `class`，包一层立即执行函数避免污染判断
        ctx.evaluateScript(script)
        if let e = ctx.exception {
            ctx.exception = nil
            NSLog("[Venera] 源脚本执行异常 %@: %@", source.id, e.toString() ?? "")
            return nil
        }

        let entry = VeneraRuntime.entryClassName(in: script)
        let activateCode = entry.map { "__veneraActivate(typeof \($0) === 'function' ? \($0) : null)" }
            ?? "__veneraActivate(null)"
        guard let activated = ctx.evaluateScript(activateCode), activated.toBool() else {
            NSLog("[Venera] 源里没有找到 ComicSource 子类: %@", source.id)
            return nil
        }
        readMeta()
    }

    /// 源入口类名：`class Xxx extends ComicSource`。
    /// class 是词法声明，拿不到 globalThis，所以由宿主把类名带回 JS 里取值。
    private static func entryClassName(in script: String) -> String? {
        let pattern = #"class\s+([A-Za-z_$][\w$]*)\s+extends\s+ComicSource"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(script.startIndex..<script.endIndex, in: script)
        let matches = re.matches(in: script, range: range)
        guard let last = matches.last, last.numberOfRanges > 1,
              let r = Range(last.range(at: 1), in: script) else { return nil }
        return String(script[r])
    }

    private func readMeta() {
        guard let raw = context.evaluateScript("__veneraMeta()")?.toString(),
              let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        var m = Meta()
        m.name = obj["name"] as? String ?? ""
        m.key = obj["key"] as? String ?? ""
        m.version = obj["version"] as? String ?? ""
        m.url = obj["url"] as? String ?? ""
        m.hasSearch = obj["hasSearch"] as? Bool ?? false
        m.hasComic = obj["hasComic"] as? Bool ?? false
        m.hasExplore = obj["hasExplore"] as? Bool ?? false
        if let t = obj["exploreTitles"] as? [Any] {
            m.exploreTitles = t.compactMap { $0 as? String }
        }
        meta = m
    }

    // MARK: - 桥

    private func installBridge(baseHeaders: [String: String]) {
        let ctx = context

        ctx.exceptionHandler = { _, exc in
            #if DEBUG
            if let exc = exc { print("[Venera JS] \(exc.toString() ?? "")") }
            #endif
        }

        // 完整 HTTP：返回 {status, headers, body} 或 {error}
        let httpFull: @convention(block) (String, String, String, String, String) -> String = {
            method, url, body, headersJSON, referer in
            VeneraRuntime.performRequest(method: method,
                                         urlString: url,
                                         body: body,
                                         headersJSON: headersJSON,
                                         referer: referer,
                                         baseHeaders: baseHeaders)
        }
        ctx.setObject(httpFull, forKeyedSubscript: "__httpFull" as NSString)

        let htmlBlock: @convention(block) (String) -> String = { html in
            HTMLParser.parse(html).jsonString()
        }
        ctx.setObject(htmlBlock, forKeyedSubscript: "__parseHTML" as NSString)

        let b64Block: @convention(block) (String) -> String = { Data($0.utf8).base64EncodedString() }
        ctx.setObject(b64Block, forKeyedSubscript: "__b64" as NSString)

        let b64DecBlock: @convention(block) (String) -> String = {
            guard let d = Data(base64Encoded: $0, options: .ignoreUnknownCharacters) else { return "" }
            return String(data: d, encoding: .utf8) ?? ""
        }
        ctx.setObject(b64DecBlock, forKeyedSubscript: "__b64decode" as NSString)

        let md5Block: @convention(block) (String) -> String = {
            Insecure.MD5.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        ctx.setObject(md5Block, forKeyedSubscript: "__md5" as NSString)

        let hashBlock: @convention(block) (String, String) -> String = { algo, text in
            let data = Data(text.utf8)
            switch algo.lowercased() {
            case "md5": return Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
            case "sha1": return Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
            case "sha256": return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            case "sha512": return SHA512.hash(data: data).map { String(format: "%02x", $0) }.joined()
            default: return ""
            }
        }
        ctx.setObject(hashBlock, forKeyedSubscript: "__hash" as NSString)

        let gbkEncoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))

        let gbkEncBlock: @convention(block) (String) -> String = { s in
            guard let d = s.data(using: gbkEncoding) else { return "" }
            return String(data: d, encoding: .isoLatin1) ?? ""
        }
        ctx.setObject(gbkEncBlock, forKeyedSubscript: "__gbkEnc" as NSString)

        let gbkDecBlock: @convention(block) (String) -> String = { s in
            guard let d = s.data(using: .isoLatin1) else { return "" }
            return String(data: d, encoding: gbkEncoding)
                ?? String(data: d, encoding: .utf8)
                ?? ""
        }
        ctx.setObject(gbkDecBlock, forKeyedSubscript: "__gbkDec" as NSString)

        let kvGetBlock: @convention(block) (String, String) -> String = { key, dataKey in
            let k = "venera.\(key).\(dataKey)"
            return UserDefaults.standard.string(forKey: k) ?? "null"
        }
        ctx.setObject(kvGetBlock, forKeyedSubscript: "__kvGet" as NSString)

        let kvSetBlock: @convention(block) (String, String, String) -> Void = { key, dataKey, value in
            UserDefaults.standard.set(value, forKey: "venera.\(key).\(dataKey)")
        }
        ctx.setObject(kvSetBlock, forKeyedSubscript: "__kvSet" as NSString)

        let kvDelBlock: @convention(block) (String, String) -> Void = { key, dataKey in
            UserDefaults.standard.removeObject(forKey: "venera.\(key).\(dataKey)")
        }
        ctx.setObject(kvDelBlock, forKeyedSubscript: "__kvDel" as NSString)

        let logBlock: @convention(block) (String) -> Void = { s in
            #if DEBUG
            print("[Venera] \(s)")
            #endif
        }
        ctx.setObject(logBlock, forKeyedSubscript: "__log" as NSString)

        let nowBlock: @convention(block) () -> Double = { Date().timeIntervalSince1970 }
        ctx.setObject(nowBlock, forKeyedSubscript: "__now" as NSString)

        ctx.setObject(source.baseURL, forKeyedSubscript: "__BASE" as NSString)
        ctx.setObject(source.id, forKeyedSubscript: "__SOURCE_ID" as NSString)
    }

    // MARK: - HTTP

    private static func performRequest(method: String,
                                       urlString: String,
                                       body: String,
                                       headersJSON: String,
                                       referer: String,
                                       baseHeaders: [String: String]) -> String {
        func fail(_ msg: String) -> String {
            let payload: [String: Any] = ["error": msg, "status": 0, "headers": [:], "body": ""]
            guard let d = try? JSONSerialization.data(withJSONObject: payload),
                  let s = String(data: d, encoding: .utf8) else {
                return "{\"error\":\"request failed\",\"status\":0,\"headers\":{},\"body\":\"\"}"
            }
            return s
        }

        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return fail("无效链接 \(urlString)") }
        // 源里的 URL 常直接拼中文或空格（Dart 的 http 会自动编码，URLSession 不会）
        var parsed = URL(string: trimmed)
        if parsed == nil,
           let fixed = trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            parsed = URL(string: fixed)
        }
        guard let url = parsed else { return fail("无效链接 \(urlString)") }

        var req = URLRequest(url: url)
        req.httpMethod = method.isEmpty ? "GET" : method.uppercased()
        req.timeoutInterval = 25

        var headers = baseHeaders
        if let d = headersJSON.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            for (k, v) in obj {
                headers[k] = v is NSNull ? "" : "\(v)"
            }
        }
        if !referer.isEmpty && referer != "null" { headers["Referer"] = referer }
        if headers["User-Agent"] == nil { headers["User-Agent"] = HTTPClient.mobileUA }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }

        if !body.isEmpty && body != "null" && req.httpMethod != "GET" && req.httpMethod != "HEAD" {
            req.httpBody = body.data(using: .utf8)
        }

        let sem = DispatchSemaphore(value: 0)
        var data: Data?
        var response: HTTPURLResponse?
        var failure: String?
        URLSession.shared.dataTask(with: req) { d, r, e in
            data = d
            response = r as? HTTPURLResponse
            failure = e?.localizedDescription
            sem.signal()
        }.resume()

        guard sem.wait(timeout: .now() + 30) == .success else { return fail("请求超时") }
        if let failure = failure { return fail(failure) }
        guard let http = response else { return fail("无响应") }

        let encoding = HTTPClient.charset(from: http)
        let text = HTTPClient.decode(data ?? Data(), charset: encoding)

        var headerMap: [String: String] = [:]
        for (k, v) in http.allHeaderFields { headerMap["\(k)"] = "\(v)" }

        let payload: [String: Any] = ["status": http.statusCode, "headers": headerMap, "body": text]
        guard let d = try? JSONSerialization.data(withJSONObject: payload),
              let s = String(data: d, encoding: .utf8) else { return fail("响应序列化失败") }
        return s
    }

    // MARK: - 执行泵

    private func run<T>(_ body: @escaping () throws -> T) throws -> T {
        var box: Result<T, Error>!
        queue.sync { box = Result { try body() } }
        return try box.get()
    }

    private func call(_ path: String, _ args: [Any], timeout: TimeInterval = 90) throws -> Any? {
        var argsJSON = "[]"
        if let d = try? JSONSerialization.data(withJSONObject: args, options: [.fragmentsAllowed]),
           let s = String(data: d, encoding: .utf8) {
            argsJSON = s
        }
        context.setObject(path, forKeyedSubscript: "__argPath" as NSString)
        context.setObject(argsJSON, forKeyedSubscript: "__argArgs" as NSString)
        context.evaluateScript("__pumpBegin(__argPath, __argArgs)")
        if let e = context.exception {
            context.exception = nil
            throw SourceError.script(e.toString() ?? "js exception")
        }

        let deadline = Date().addingTimeInterval(timeout)
        var finished = false
        while Date() < deadline {
            if context.evaluateScript("__vsDone()")?.toBool() == true {
                finished = true
                break
            }
            Thread.sleep(forTimeInterval: 0.002)
        }
        guard finished else { throw SourceError.script("源脚本执行超时（\(path)）") }

        let raw = context.evaluateScript("__vsTake()")?.toString() ?? ""
        guard let d = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
            throw SourceError.script("源脚本返回值无法解析")
        }
        if let err = obj["error"] as? String, !err.isEmpty { throw SourceError.script(err) }
        return obj["value"]
    }

    // MARK: - 对外接口

    func search(_ keyword: String, page: Int) throws -> [Manga] {
        try run {
            if meta.hasExplore && !meta.hasSearch && meta.exploreTitles.count > 0 {
                let raw = try call("__veneraExplore", [0, page])
                return mapComics(raw)
            }
            let raw = try call("__veneraSearch", [keyword, page])
            return mapComics(raw)
        }
    }

    func detail(_ id: String) throws -> (Manga, [Chapter]) {
        try run {
            if let cached = detailCache[id] { return cached }
            let raw = try call("__veneraLoadDetail", [id])
            guard let d = raw as? [String: Any] else { throw SourceError.parse("详情返回格式错误") }

            let title = str(d["title"]).isEmpty ? str(d["subtitle"]) : str(d["title"])
            guard !title.isEmpty else { throw SourceError.parse("没有解析到标题") }

            var m = Manga(key: Manga.makeKey(source: source.id, url: id),
                          sourceID: source.id,
                          url: id,
                          title: title,
                          cover: absURL(str(d["cover"])))
            m.author = str(d["uploader"])
            m.desc = str(d["description"])
            m.status = ""
            let tags = (d["tags"] as? [Any])?.compactMap { $0 as? [Any] }.compactMap { $0.last as? String } ?? []
            m.genre = tags.joined(separator: " ")

            let chapters = parseChapters(d["chapters"]).map { ch -> Chapter in
                var c = ch
                // Venera 取图要同时给 comicId 与 epId，这里把两者编码进章节的 url
                c.url = "\(id)||\(ch.url)"
                return c
            }
            detailCache[id] = (m, chapters)
            if detailCache.count > 40 { detailCache.removeAll() }
            return (m, chapters)
        }
    }

    func chapters(_ id: String) throws -> [Chapter] {
        try detail(id).1
    }

    func images(comicId: String, epId: String) throws -> [(url: String, referer: String?)] {
        try run {
            let raw = try call("__veneraLoadImages", [comicId, epId])
            guard let arr = raw as? [Any] else { throw SourceError.parse("图片列表格式错误") }
            let ref = source.baseURL.isEmpty ? nil : source.baseURL
            var out: [(url: String, referer: String?)] = []
            for item in arr {
                guard let d = item as? [String: Any] else { continue }
                let u = absURL(str(d["url"]))
                guard !u.isEmpty else { continue }
                var r = ref
                if let h = d["headers"] as? [String: Any] {
                    for (k, v) in h where k.lowercased() == "referer" {
                        r = "\(v)"
                    }
                }
                out.append((url: u, referer: r))
            }
            if out.isEmpty { throw SourceError.empty }
            return out
        }
    }

    func category(_ tag: String, page: Int) throws -> [Manga] {
        try run {
            let raw = try call("__veneraSearch", [tag, page])
            return mapComics(raw)
        }
    }

    func ranking(_ key: String, page: Int) throws -> [Manga] {
        try run {
            let raw = try call("__veneraRanking", [key, page])
            let list = mapComics(raw)
            if !list.isEmpty { return list }
            let fallback = try call("__veneraSearch", [key, page])
            return mapComics(fallback)
        }
    }

    // MARK: - 映射

    private func parseChapters(_ raw: Any?) -> [Chapter] {
        guard let rows = raw as? [Any] else { return [] }
        var out: [Chapter] = []
        for (i, row) in rows.enumerated() {
            guard let parts = row as? [Any], parts.count >= 2 else { continue }
            let id = str(parts[0])
            let name = str(parts[1])
            guard !id.isEmpty else { continue }
            var c = Chapter(url: id, name: name.isEmpty ? "第\(i + 1)话" : name)
            c.index = i
            out.append(c)
        }
        return out
    }

    private func mapComics(_ raw: Any?) -> [Manga] {
        guard let arr = raw as? [Any] else { return [] }
        var out: [Manga] = []
        var seen = Set<String>()
        for item in arr {
            guard let d = item as? [String: Any] else { continue }
            let id = str(d["id"])
            let title = str(d["title"])
            guard !id.isEmpty, !title.isEmpty else { continue }
            let key = Manga.makeKey(source: source.id, url: id)
            if seen.contains(key) { continue }
            seen.insert(key)
            var m = Manga(key: key, sourceID: source.id, url: id,
                          title: title, cover: absURL(str(d["cover"])))
            m.author = str(d["subtitle"])
            m.desc = str(d["description"])
            if let tags = d["tags"] as? [Any] {
                m.genre = tags.compactMap { $0 as? String }.joined(separator: " ")
            }
            out.append(m)
        }
        return out
    }

    private func absURL(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "" }
        if t.hasPrefix("http://") || t.hasPrefix("https://") || t.hasPrefix("data:") { return t }
        if t.hasPrefix("//") { return "https:" + t }
        guard !source.baseURL.isEmpty else { return t }
        if t.hasPrefix("/") { return source.baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + t }
        return source.baseURL + "/" + t
    }

    private func str(_ any: Any?) -> String {
        if let s = any as? String { return s.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let n = any as? NSNumber { return n.stringValue }
        return ""
    }

    // MARK: - 辅助脚本

    /// 把 Venera 的各种返回形态（{comics,maxPage} / [{title,comics}] / Map 章节表）
    /// 规整成宿主好解析的普通结构。
    static let helpers: String = #"""
// 源声明的选项默认值。Venera 调用 `search.load(keyword, options, page)` 时，
// options 是「每项选中的 value」，未设置时为该项的 default（没有则第一项）。
// 传 null 会让源里的 `options[i] !== "any"` 判断走错分支，必须还原成真默认值。
function __veneraOptions(kind) {
  try {
    var s = __veneraSource;
    var list = (kind === 'search' && s.search) ? s.search.optionList
             : (kind === 'category' && s.categoryComics) ? s.categoryComics.optionList : null;
    if (!list || !list.length) return [];
    var out = [];
    for (var i = 0; i < list.length; i++) {
      var it = list[i] || {};
      if (it.default !== undefined && it.default !== null) { out.push(it.default); continue; }
      var opts = it.options;
      if (opts && opts.length) {
        var first = opts[0];
        if (typeof first === 'string') out.push(first.split('-')[0]);
        else if (first && typeof first === 'object') {
          out.push(first.value !== undefined ? first.value
                 : (first.key !== undefined ? first.key : first.label));
        } else out.push(null);
      } else out.push(null);
    }
    return out;
  } catch (e) { }
  return [];
}

function __veneraTags(raw) {
  var out = [];
  if (!raw) return out;
  if (typeof raw === 'object') {
    for (var k in raw) {
      var v = raw[k];
      if (Array.isArray(v)) {
        for (var i = 0; i < v.length; i++) out.push([String(k), String(v[i])]);
      } else if (v != null) {
        out.push([String(k), String(v)]);
      }
    }
  }
  return out;
}

function __veneraChapters(raw) {
  var out = [];
  if (!raw) return out;
  if (typeof Map !== 'undefined' && raw instanceof Map) {
    raw.forEach(function (v, k) {
      if (v instanceof Map) {
        v.forEach(function (v2, k2) { out.push([String(k2), String(v2), String(k)]); });
      } else {
        out.push([String(k), String(v), '']);
      }
    });
    return out;
  }
  if (typeof raw === 'object') {
    for (var k in raw) {
      var v = raw[k];
      if (v && typeof v === 'object') {
        for (var k2 in v) out.push([String(k2), String(v[k2]), String(k)]);
      } else {
        out.push([String(k), String(v), '']);
      }
    }
  }
  return out;
}

function __veneraTagList(t) {
  var out = [];
  if (!t) return out;
  if (Array.isArray(t)) {
    for (var i = 0; i < t.length; i++) {
      var v = t[i];
      if (typeof v === 'string') out.push(v);
      else if (v && typeof v === 'object') {
        var n = v.name !== undefined ? v.name : (v.title !== undefined ? v.title : v.tag);
        if (n != null) out.push(String(n));
      }
    }
    return out;
  }
  if (typeof t === 'object') {
    for (var k in t) {
      var w = t[k];
      if (Array.isArray(w)) { for (var j = 0; j < w.length; j++) out.push(String(w[j])); }
      else if (w != null) out.push(String(w));
    }
  }
  return out;
}

function __veneraComics(r) {
  var out = [];
  function push(list) {
    if (!list || !list.length) return;
    for (var i = 0; i < list.length; i++) {
      var c = list[i];
      if (!c) continue;
      var tags = __veneraTagList(c.tags);
      out.push({
        id: c.id == null ? '' : String(c.id),
        title: c.title == null ? '' : String(c.title),
        cover: c.cover == null ? '' : String(c.cover),
        subtitle: c.subtitle == null ? (c.subTitle == null ? '' : String(c.subTitle)) : String(c.subtitle),
        description: c.description == null ? '' : String(c.description),
        tags: tags
      });
    }
  }
  if (!r) return out;
  if (Array.isArray(r)) {
    var hasPart = false;
    for (var i = 0; i < r.length; i++) {
      var part = r[i];
      if (part && part.comics) { push(part.comics); hasPart = true; }
    }
    if (!hasPart) push(r);
  } else if (r.comics) {
    push(r.comics);
  }
  return out;
}

async function __veneraSearch(keyword, page) {
  var s = __veneraSource.search;
  if (!s) return [];
  var opts = __veneraOptions('search');
  var r = null;
  if (typeof s.load === 'function') {
    r = await s.load(String(keyword), opts, page || 1);
  } else if (typeof s.loadNext === 'function') {
    r = await s.loadNext(String(keyword), opts, null);
  }
  return __veneraComics(r);
}

async function __veneraExplore(index, page) {
  var ex = __veneraSource.explore;
  if (!ex || !ex[index]) return [];
  var part = ex[index];
  var r = null;
  if (typeof part.load === 'function') {
    r = await part.load(page || 1);
  } else if (typeof part.loadNext === 'function') {
    r = await part.loadNext(null);
  }
  return __veneraComics(r);
}

async function __veneraRanking(option, page) {
  var cc = __veneraSource.categoryComics;
  if (!cc || !cc.ranking || typeof cc.ranking.load !== 'function') return [];
  var r = await cc.ranking.load(option == null ? null : String(option), page || 1);
  return __veneraComics(r);
}

async function __veneraLoadDetail(id) {
  var d = await __veneraSource.comic.loadInfo(String(id));
  var out = {};
  if (d) {
    out.title = d.title;
    out.subtitle = d.subtitle;
    out.cover = d.cover;
    out.description = d.description;
    out.uploader = d.uploader;
    out.url = d.url;
    out.tags = __veneraTags(d.tags);
    out.chapters = __veneraChapters(d.chapters);
  }
  return out;
}

async function __veneraLoadImages(comicId, epId) {
  var r = await __veneraSource.comic.loadEp(String(comicId), String(epId));
  var out = [];
  if (r && r.images) {
    for (var i = 0; i < r.images.length; i++) {
      var it = r.images[i];
      if (it == null) continue;
      if (typeof it === 'string') { out.push({ url: it }); }
      else if (it.url) { out.push({ url: String(it.url), headers: it.headers || null }); }
    }
  }
  return out;
}
"""#
}
