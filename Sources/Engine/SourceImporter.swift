import Foundation

/// 源导入：支持 URL / 文本 / GitHub 仓库批量
final class SourceImporter {

    static let shared = SourceImporter()

    // MARK: - 从 URL

    func importFromURL(_ raw: String) async throws -> Int {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ImportError.badURL }

        // GitHub 仓库 / 目录：走 API 批量拉取
        if let gh = GitHubTarget.parse(trimmed) {
            let files = try await fetchGitHubFiles(gh)
            var total = 0
            for (name, text) in files {
                total += (try? importFromText(text, fallbackName: name)) ?? 0
            }
            if total == 0 { throw ImportError.noSourceFound }
            return total
        }

        // 普通链接
        let url = normalizeRawURL(trimmed)
        let (data, _) = try await HTTPClient.shared.get(url)
        guard let text = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1) else {
            throw ImportError.decodeFailed
        }

        // Venera 的源清单（index.json）：数组，每项 {name, url|filename, version}
        if let d = text.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: d),
           let entries = indexEntries(obj), !entries.isEmpty {
            let baseDir = url.contains("/") ? String(url[..<url.range(of: "/", options: .backwards)!.lowerBound]) : ""
            var total = 0
            for e in entries {
                let full: String
                if e.path.hasPrefix("http://") || e.path.hasPrefix("https://") {
                    full = e.path
                } else if e.path.hasPrefix("/") {
                    full = (URL(string: url)?.scheme ?? "https") + "://" + (URL(string: url)?.host ?? "") + e.path
                } else {
                    full = baseDir + "/" + e.path
                }
                guard let (fd, _) = try? await HTTPClient.shared.get(full) else { continue }
                guard let ft = String(data: fd, encoding: .utf8) else { continue }
                total += (try? importFromText(ft, fallbackName: e.name)) ?? 0
            }
            if total == 0 { throw ImportError.noSourceFound }
            return total
        }

        let fallback = URL(string: url)?.deletingPathExtension().lastPathComponent
        let count = try importFromText(text, fallbackName: fallback)
        if count == 0 { throw ImportError.noSourceFound }
        return count
    }

    /// 识别 Venera 源清单：`[{name, url|filename, version, description}]`
    private func indexEntries(_ obj: Any) -> [(name: String, path: String)]? {
        guard let arr = obj as? [Any], !arr.isEmpty else { return nil }
        var out: [(String, String)] = []
        for item in arr {
            guard let d = item as? [String: Any] else { return nil }
            guard d["script"] == nil, d["rules"] == nil else { return nil }
            let name = (d["name"] as? String) ?? ""
            let path = (d["url"] as? String)
                ?? (d["fileName"] as? String)
                ?? (d["filename"] as? String)
                ?? ""
            guard !name.isEmpty, !path.isEmpty else { return nil }
            out.append((name, path))
        }
        return out.isEmpty ? nil : out
    }

    /// github.com/u/r/blob/main/a.json → raw.githubusercontent.com/...
    private func normalizeRawURL(_ s: String) -> String {
        if s.contains("github.com"), s.contains("/blob/") {
            return s.replacingOccurrences(of: "https://github.com/",
                                          with: "https://raw.githubusercontent.com/")
                .replacingOccurrences(of: "/blob/", with: "/")
        }
        return s
    }

    // MARK: - 从文本

    @discardableResult
    func importFromText(_ text: String, fallbackName: String? = nil) throws -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ImportError.empty }

        // 1) JSON
        if let data = trimmed.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) {
            let sources = parseJSON(obj, fallbackName: fallbackName)
            if !sources.isEmpty {
                for s in sources { SourceStore.shared.save(s) }
                return sources.count
            }
        }

        // 2) Venera 格式的源：class Xxx extends ComicSource
        if looksLikeVenera(trimmed) {
            let src = makeVeneraSource(from: trimmed, fallbackName: fallbackName)
            SourceStore.shared.save(src)
            return 1
        }

        // 3) 纯 JS：当作单文件脚本源
        if looksLikeJS(trimmed) {
            let name = fallbackName ?? detectName(in: trimmed) ?? "自定义源-\(Int(Date().timeIntervalSince1970) % 10000)"
            var src = MangaSource(id: "custom-" + slug(name), name: name)
            src.kind = .js
            src.script = trimmed
            src.baseURL = detectBase(in: trimmed) ?? ""
            src.version = "1.0.0"
            SourceStore.shared.save(src)
            return 1
        }

        throw ImportError.unknownFormat
    }

    // MARK: - JSON 解析（宽松）

    private func parseJSON(_ obj: Any, fallbackName: String?) -> [MangaSource] {
        var out: [MangaSource] = []

        if let arr = obj as? [Any] {
            for item in arr { out.append(contentsOf: parseJSON(item, fallbackName: fallbackName)) }
            return out
        }

        guard let dict = obj as? [String: Any] else { return [] }

        // 容器字段
        for key in ["sources", "data", "list", "items", "extensions"] {
            if let inner = dict[key] {
                let sub = parseJSON(inner, fallbackName: fallbackName)
                if !sub.isEmpty { return sub }
            }
        }

        // 单个源
        if let name = pickString(dict, ["name", "title", "源名称", "sourceName"]),
           !name.isEmpty {
            if let s = makeSource(from: dict, name: name, fallbackName: fallbackName) {
                out.append(s)
            }
            return out
        }

        // name -> source 映射
        for (k, v) in dict {
            guard let sub = v as? [String: Any] else { continue }
            if let s = makeSource(from: sub, name: k, fallbackName: fallbackName) {
                out.append(s)
            }
        }
        return out
    }

    private func makeSource(from d: [String: Any],
                            name: String,
                            fallbackName: String?) -> MangaSource? {
        let base = pickString(d, ["url", "baseUrl", "base_url", "base", "site",
                                  "homepage", "host", "域名"]) ?? ""
        let script = pickString(d, ["script", "js", "code", "源码", "body"])
        var rules: SourceRules?

        if let r = d["rules"] as? [String: Any] {
            rules = decodeRules(r)
        } else if let r = d["config"] as? [String: Any] {
            rules = decodeRules(r)
        } else if let s = d["search"] as? [String: Any] {
            // 兼容 { search: {...}, detail: {...} } 结构
            var rr = SourceRules.empty
            rr.searchURL = (s["url"] as? String) ?? ""
            rr.searchList = (s["list"] as? String) ?? ""
            rules = rr
        }

        guard !base.isEmpty || script != nil || rules != nil else { return nil }

        let rawID = pickString(d, ["id", "key", "packageName", "package"]) 
            ?? MangaSource.makeID(from: base.isEmpty ? name : base)
        var src = MangaSource(id: rawID.isEmpty ? "src-" + slug(name) : slug(rawID),
                              name: name)
        src.baseURL = base
        src.version = pickString(d, ["version", "ver"]) ?? "1.0.0"
        src.iconURL = pickString(d, ["icon", "iconUrl", "logo"])
        src.author = pickString(d, ["author", "by", "作者"])
        src.desc = pickString(d, ["desc", "description", "简介"])

        let langStr = pickString(d, ["lang", "language", "locale"]) ?? "zh"
        src.lang = mapLang(langStr, isNovel: pickString(d, ["type", "kind"]) == "novel")

        if let script = script, !script.isEmpty {
            src.kind = .js
            src.script = script
        } else if let rules = rules {
            src.kind = .json
            src.rules = rules
        } else {
            // 只有域名：生成启发式探索脚本
            src.kind = .js
            src.script = SourceImporter.genericScript(base: base)
        }

        if let headers = d["headers"] as? [String: String] {
            src.headers = headers
        }
        return src
    }

    private func decodeRules(_ d: [String: Any]) -> SourceRules {
        var r = SourceRules.empty
        r.searchURL = (d["searchURL"] as? String) ?? (d["searchUrl"] as? String) ?? ""
        r.searchMethod = (d["searchMethod"] as? String) ?? "GET"
        r.searchBody = d["searchBody"] as? String
        r.searchList = (d["searchList"] as? String) ?? ""
        r.searchTitle = (d["searchTitle"] as? String) ?? ""
        r.searchCover = (d["searchCover"] as? String) ?? ""
        r.searchLink = (d["searchLink"] as? String) ?? ""
        r.searchAuthor = (d["searchAuthor"] as? String) ?? ""
        r.detailTitle = (d["detailTitle"] as? String) ?? ""
        r.detailCover = (d["detailCover"] as? String) ?? ""
        r.detailAuthor = (d["detailAuthor"] as? String) ?? ""
        r.detailDesc = (d["detailDesc"] as? String) ?? ""
        r.detailGenre = (d["detailGenre"] as? String) ?? ""
        r.detailStatus = (d["detailStatus"] as? String) ?? ""
        r.chapterList = (d["chapterList"] as? String) ?? ""
        r.chapterName = (d["chapterName"] as? String) ?? ""
        r.chapterLink = (d["chapterLink"] as? String) ?? ""
        r.chapterReverse = (d["chapterReverse"] as? Bool) ?? false
        r.imageList = (d["imageList"] as? String) ?? ""
        r.imageAttr = (d["imageAttr"] as? String) ?? "src"
        r.imageReferer = (d["imageReferer"] as? String) ?? ""
        r.categoryURL = (d["categoryURL"] as? String) ?? ""
        r.categoryList = (d["categoryList"] as? String) ?? ""
        r.categoryName = (d["categoryName"] as? String) ?? ""
        return r
    }

    private func mapLang(_ s: String, isNovel: Bool) -> SourceLang {
        let lower = s.lowercased()
        let en = lower.hasPrefix("en") || lower.contains("english")
        if isNovel || lower.contains("novel") || lower.contains("小说") {
            return en ? .enNovel : .zhNovel
        }
        return en ? .en : .zh
    }

    // MARK: - GitHub

    struct GitHubTarget {
        var owner: String
        var repo: String
        var path: String
        var branch: String?

        static func parse(_ url: String) -> GitHubTarget? {
            guard url.contains("github.com") else { return nil }
            var s = url
            for prefix in ["https://", "http://"] {
                if s.hasPrefix(prefix) { s = String(s.dropFirst(prefix.count)) }
            }
            let comps = s.split(separator: "/").map(String.init)
            guard comps.count >= 3, comps[0].contains("github.com") else { return nil }
            var owner = comps[1]
            var repo = comps[2]
            if repo.hasSuffix(".git") { repo = String(repo.dropLast(4)) }
            var path = ""
            var branch: String?
            if comps.count >= 5, comps[3] == "tree" || comps[3] == "blob" {
                branch = comps[4]
                path = comps.dropFirst(5).joined(separator: "/")
            }
            if owner.isEmpty || repo.isEmpty { return nil }
            return GitHubTarget(owner: owner, repo: repo, path: path, branch: branch)
        }
    }

    private func fetchGitHubFiles(_ t: GitHubTarget) async throws -> [(String, String)] {
        var branch = t.branch
        if branch == nil {
            branch = try await defaultBranch(owner: t.owner, repo: t.repo)
        }
        let api = "https://api.github.com/repos/\(t.owner)/\(t.repo)/contents/\(t.path)?ref=\(branch ?? "main")"
        let (data, _) = try await HTTPClient.shared.get(api, headers: [
            "Accept": "application/vnd.github+json",
            "User-Agent": "MangaReader"
        ])
        guard let obj = try? JSONSerialization.jsonObject(with: data) else {
            throw ImportError.githubFailed
        }

        var results: [(String, String)] = []

        if let arr = obj as? [[String: Any]] {
            // 目录：挑 json / js
            let wanted = arr.filter { item in
                let n = (item["name"] as? String) ?? ""
                return n.hasSuffix(".json") || n.hasSuffix(".js")
            }.prefix(40)
            for item in wanted {
                guard let dl = item["download_url"] as? String else { continue }
                let name = ((item["name"] as? String) ?? "source").replacingOccurrences(of: ".json", with: "")
                if let (d, _) = try? await HTTPClient.shared.get(dl),
                   let text = String(data: d, encoding: .utf8) {
                    results.append((name, text))
                }
            }
        } else if let dict = obj as? [String: Any], let dl = dict["download_url"] as? String {
            if let (d, _) = try? await HTTPClient.shared.get(dl),
               let text = String(data: d, encoding: .utf8) {
                results.append((t.repo, text))
            }
        }

        if results.isEmpty { throw ImportError.githubEmpty }
        return results
    }

    private func defaultBranch(owner: String, repo: String) async throws -> String {
        let api = "https://api.github.com/repos/\(owner)/\(repo)"
        guard let (data, _) = try? await HTTPClient.shared.get(api, headers: [
            "Accept": "application/vnd.github+json"
        ]), let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let b = obj["default_branch"] as? String else {
            return "main"
        }
        return b
    }

    // MARK: - 启发式

    private func looksLikeJS(_ s: String) -> Bool {
        s.contains("function ") && (s.contains("search") || s.contains("chapters") || s.contains("images"))
    }

    /// Venera 源：`class Xxx extends ComicSource { ... }`
    private func looksLikeVenera(_ s: String) -> Bool {
        s.contains("extends ComicSource") || s.contains("new ComicSource")
    }

    /// 从 Venera 源文本里抽出 name / key / version / baseUrl，生成一条源记录。
    private func makeVeneraSource(from js: String, fallbackName: String?) -> MangaSource {
        let name = firstMatch(js, #"\bname\s*[:=]\s*["'`]([^"'`\n]+)["'`]"#)
            ?? fallbackName
            ?? "Venera 源"
        let key = firstMatch(js, #"\bkey\s*[:=]\s*["'`]([^"'`\n]+)["'`]"#) ?? slug(name)
        let version = firstMatch(js, #"\bversion\s*[:=]\s*["'`]([^"'`\n]+)["'`]"#) ?? "1.0.0"
        let base = firstMatch(js, #"\bbaseUrl\s*[:=]\s*["'`]([^"'`\n]+)["'`]"#)
            ?? detectBase(in: js)
            ?? ""

        var src = MangaSource(id: "venera-" + slug(key), name: name)
        src.kind = .venera
        src.script = js
        src.version = version
        src.baseURL = base
        src.desc = "Venera 兼容源"
        if let author = firstMatch(js, #"\bauthor\s*[:=]\s*["'`]([^"'`\n]+)["'`]"#) {
            src.author = author
        }
        return src
    }

    private func firstMatch(_ s: String, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(s.startIndex..<s.endIndex, in: s)
        guard let m = re.firstMatch(in: s, range: range), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        let v = String(s[r]).trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    private func detectName(in js: String) -> String? {
        for marker in ["// name:", "//name:", "/* name:", "var NAME"] {
            if let r = js.range(of: marker) {
                let rest = js[r.upperBound...].prefix(40)
                let line = rest.split(separator: "\n").first.map(String.init) ?? String(rest)
                let cleaned = line.replacingOccurrences(of: "*/", with: "")
                    .trimmingCharacters(in: CharacterSet(charactersIn: " ='\"\t"))
                if !cleaned.isEmpty { return cleaned }
            }
        }
        return nil
    }

    private func detectBase(in js: String) -> String? {
        let pattern = #"https?://[a-zA-Z0-9\.\-]+"#
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(js.startIndex..<js.endIndex, in: js)
        guard let m = re.firstMatch(in: js, range: range),
              let r = Range(m.range, in: js) else { return nil }
        return String(js[r])
    }

    private func slug(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let mapped = s.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let out = String(mapped).replacingOccurrences(of: "--", with: "-")
        return out.isEmpty ? "src-\(Int(Date().timeIntervalSince1970))" : out.lowercased()
    }

    private func pickString(_ d: [String: Any], _ keys: [String]) -> String? {
        for k in keys {
            if let v = d[k] as? String, !v.isEmpty { return v }
        }
        return nil
    }

    // MARK: - 通用脚本模板

    /// 只给域名时用的探索式脚本：抓搜索页 + 首页，按链接特征猜详情页
    static func genericScript(base: String) -> String {
        #"""
function __pairs(){
  return [
    { search: '/search?keyword={q}', list: 'a[href]' },
    { search: '/search?q={q}', list: 'a[href]' },
    { search: '/s?q={q}', list: 'a[href]' },
    { search: '/index.php?m=vod-search&wd={q}', list: 'a[href]' }
  ];
}

function __looksDetail(href){
  if (!href) return false;
  var h = String(href).toLowerCase();
  if (h.indexOf('javascript') === 0 || h === '#') return false;
  if (/\/(comic|book|manga|manhua|detail|info|series|cartoon)\//.test(h)) return true;
  if (/\/\d{2,}\/?$/.test(h)) return true;
  return false;
}

function __harvest(html, base){
  var out = [];
  doc(html).find('a[href]').each(function(i, el){
    var href = el.attr('href');
    if (!__looksDetail(href)) return;
    var t = el.text() || el.attr('title');
    if (!t || t.length < 2) return;
    var img = el.find('img').attr('src') || el.find('img').attr('data-src');
    out.push(item(abs(href, base), t, img));
  });
  return dedup(out);
}

function search(q, page){
  page = page || 1;
  var ps = __pairs();
  for (var i = 0; i < ps.length; i++) {
    try {
      var u = abs(ps[i].search.replace('{q}', encodeURIComponent(q)).replace('{page}', page));
      var html = get(u, null, BASE);
      var list = __harvest(html, u);
      if (list.length) return list;
    } catch(e) {}
  }
  return [];
}

function detail(url){
  var html = get(url, null, url);
  var d = doc(html);
  var title = d.find('h1').first().text() || d.find('title').first().text();
  var cover = d.find('meta[property="og:image"]').attr('content') || d.find('img').first().attr('src');
  var author = d.find('.author').first().text() || '';
  var desc = d.find('meta[name="description"]').attr('content') || d.find('.intro').first().text() || '';
  return { url: url, title: __norm(title).split('_')[0].split('|')[0], cover: fixImg(cover, url),
           author: author, desc: desc, genre: '', status: '' };
}

function chapters(url){
  var html = get(url, null, url);
  var out = [];
  doc(html).find('a[href]').each(function(i, el){
    var href = el.attr('href');
    if (!href) return;
    if (!/(chapter|chap|read|episode|\/c\/|\/\d+\.html)/i.test(href)) return;
    var t = el.text();
    if (!t || t.length > 60) return;
    out.push({ url: abs(href, url), name: __norm(t), index: i });
  });
  var seen = {}, res = [];
  for (var k = 0; k < out.length; k++) {
    if (seen[out[k].url]) continue;
    seen[out[k].url] = 1;
    res.push(out[k]);
  }
  return res;
}

function images(chapterUrl){
  var html = get(chapterUrl, null, chapterUrl);
  var out = [];
  doc(html).find('img').each(function(i, el){
    var u = el.attr('src') || el.attr('data-src') || el.attr('data-original') || el.attr('data-lazy-src');
    u = fixImg(u, chapterUrl);
    if (!u) return;
    if (u.indexOf('data:') === 0) return;
    if (u.length < 16) return;
    if (/logo|icon|avatar|banner|placeholder|loading/i.test(u)) return;
    out.push({ url: u, referer: chapterUrl });
  });
  // 去重并保留顺序
  var seen = {}, res = [];
  for (var k = 0; k < out.length; k++) {
    if (seen[out[k].url]) continue;
    seen[out[k].url] = 1;
    res.push(out[k]);
  }
  return res;
}
"""#
    }
}

enum ImportError: LocalizedError {
    case badURL
    case empty
    case decodeFailed
    case unknownFormat
    case noSourceFound
    case githubFailed
    case githubEmpty

    var errorDescription: String? {
        switch self {
        case .badURL: return "链接不合法"
        case .empty: return "内容为空"
        case .decodeFailed: return "内容解码失败"
        case .unknownFormat: return "识别不出源格式（需要 JSON 或含 search() 的 JS）"
        case .noSourceFound: return "没有解析到任何源"
        case .githubFailed: return "GitHub 接口返回异常"
        case .githubEmpty: return "仓库里没有 .json / .js 源文件"
        }
    }
}

// MARK: - 导出

enum SourceExporter {
    static func export(_ s: MangaSource) -> String {
        var d: [String: Any] = [
            "id": s.id,
            "name": s.name,
            "version": s.version,
            "lang": s.lang.rawValue,
            "kind": s.kind.rawValue,
            "url": s.baseURL
        ]
        if let script = s.script { d["script"] = script }
        if let r = s.rules, let data = try? JSONEncoder().encode(r),
           let obj = try? JSONSerialization.jsonObject(with: data) {
            d["rules"] = obj
        }
        if let h = s.headers { d["headers"] = h }
        if let icon = s.iconURL { d["icon"] = icon }
        if let a = s.author { d["author"] = a }
        if let desc = s.desc { d["desc"] = desc }
        guard let out = try? JSONSerialization.data(withJSONObject: d,
                                                   options: [.prettyPrinted, .sortedKeys]),
              let s2 = String(data: out, encoding: .utf8) else { return "{}" }
        return s2
    }
}

// MARK: - 格式说明

enum SourceFormatDoc {
    static let text = #"""
{
  "id": "my-source",
  "name": "我的源",
  "version": "1.0.0",
  "lang": "zh",
  "url": "https://example.com",
  "kind": "js",
  "script": "function search(q,p){ ... }"
}

JS 源必须导出 4 个函数（同步返回）：
  search(keyword, page) -> [{url,title,cover,author}]
  detail(url)           -> {title,cover,author,desc,genre,status}
  chapters(url)         -> [{url,name}]
  images(chapterUrl)    -> [{url,referer}]
可选：
  category(param,page)  -> 同 search
  ranking(key,page)     -> 同 search

可用内置函数：
  get(url[,headers,referer])   post(url,body[,...])
  getJSON(url)  postJSON(url,body)
  doc(html).find(sel).each(fn) .attr() .text() .html()
  $('.sel')  abs(u)  fixImg(u)  stripTags(s)  md5(s)  b64(s)

──────────── Venera 源 ────────────
和 Venera / Miru 用同一套规范：单个 .js 文件，里面写

  class MySource extends ComicSource {
      name = "我的源"; key = "my"; version = "1.0.0"
      baseUrl = "https://example.com"
      search = { load: async (keyword, options, page) => ({ comics: [...], maxPage: 1 }) }
      comic = {
          loadInfo: async (id) => new ComicDetails({ title, cover, tags,
                        chapters: new Map([[chapterId, "第 1 话"]]) }),
          loadEp: async (comicId, epId) => ({ images: ["https://.../1.jpg"] })
      }
  }

可用：Network.get/post/sendRequest/fetchBytes、fetch()、new HtmlDocument(html)
      .querySelector(sel)、Convert.md5/sha256/base64、新的 Comic / ComicDetails、
      UI.showMessage、log()、createUuid()、setTimeout、Map/Set/class 字段语法

导入方式：粘贴 js 内容、填单个源的 CDN 链接、或导入
https://cdn.jsdelivr.net/gh/venera-app/venera-configs@main/index.json
（上面的「Venera 源」按钮会一次拉取整套官方源）
"""#
}
