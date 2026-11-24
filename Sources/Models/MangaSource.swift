import Foundation

/// 源类型：JS 脚本源 / JSON 规则源 / 内置原生源（榜单、分类走源实现）
enum SourceKind: String, Codable, CaseIterable {
    case js      // 完整 JS 脚本，暴露 search/detail/chapters/images
    case json    // 声明式规则，编译为 JS 后执行
    case web     // 纯 WebView 抓取源（无需 JS 引擎，靠 DOM 注入）
    case venera  // Venera（venera-configs）格式的 JS 源，class Xxx extends ComicSource

    var displayName: String {
        switch self {
        case .js: return "JS 脚本"
        case .json: return "JSON 规则"
        case .web: return "网页抓取"
        case .venera: return "Venera 源"
        }
    }
}

/// 语言分组，对应书架顶部的「漫画中文 / 漫画英文 / 小说中文 / 小说英文」
enum SourceLang: String, Codable, CaseIterable {
    case zh, en, zhNovel, enNovel

    var displayName: String {
        switch self {
        case .zh: return "漫画中文"
        case .en: return "漫画英文"
        case .zhNovel: return "小说中文"
        case .enNovel: return "小说英文"
        }
    }

    var isNovel: Bool { self == .zhNovel || self == .enNovel }
}

/// 声明式规则：选择器 / 正则 / JSONPath 三种风格混用，编译期转成 JS
struct SourceRules: Codable, Equatable, Hashable {
    // 搜索
    var searchURL: String = ""              // 支持 {q} {page}
    var searchMethod: String = "GET"
    var searchBody: String?
    var searchList: String = ""             // 结果条目选择器
    var searchTitle: String = ""
    var searchCover: String = ""
    var searchLink: String = ""
    var searchAuthor: String = ""

    // 详情
    var detailTitle: String = ""
    var detailCover: String = ""
    var detailAuthor: String = ""
    var detailDesc: String = ""
    var detailGenre: String = ""
    var detailStatus: String = ""

    // 章节
    var chapterList: String = ""
    var chapterName: String = ""
    var chapterLink: String = ""
    var chapterReverse: Bool = false

    // 图片
    var imageList: String = ""
    var imageAttr: String = "src"
    var imageReferer: String = ""

    // 分类 / 榜单（可留空）
    var categoryURL: String = ""
    var categoryList: String = ""
    var categoryName: String = ""

    static let empty = SourceRules()
}

/// 一个漫画源
struct MangaSource: Codable, Identifiable, Equatable {
    var id: String                  // 稳定标识，一般是 domain 或 sha1
    var name: String                // 显示名，如「来漫画C」
    var version: String = "1.0.0"
    var lang: SourceLang = .zh
    var kind: SourceKind = .js
    var baseURL: String = ""        // 站点根，用于补全相对链接
    var iconURL: String?            // 可选图标
    var author: String?             // 源作者
    var desc: String?               // 源说明
    var script: String?             // kind == .js 时的脚本主体
    var rules: SourceRules?         // kind == .json 时的规则
    var enabled: Bool = true
    var builtin: Bool = false
    var order: Int = 0
    /// 源内部用于并发与超时的偏好
    var timeout: Double = 15
    var headers: [String: String]?  // 全局请求头

    var effectiveHeaders: [String: String] {
        var h = headers ?? [:]
        if h["User-Agent"] == nil {
            h["User-Agent"] = HTTPClient.mobileUA
        }
        return h
    }

    static func makeID(from url: String) -> String {
        let host = URL(string: url)?.host ?? url
        return host.replacingOccurrences(of: "www.", with: "")
    }
}

// MARK: - 传输模型

struct Manga: Identifiable, Hashable, Codable {
    var key: String            // "\(sourceID)::\(url)"
    var sourceID: String
    var url: String
    var title: String
    var cover: String
    var author: String = ""
    var desc: String = ""
    var genre: String = ""
    var status: String = ""
    var latestChapter: String = ""
    var updatedAt: TimeInterval = 0

    var id: String { key }

    static func makeKey(source: String, url: String) -> String { "\(source)::\(url)" }
}

struct Chapter: Identifiable, Hashable, Codable {
    var url: String
    var name: String
    var index: Int = 0
    var read: Bool = false
    var id: String { url }
}

struct LibraryEntry: Identifiable, Hashable, Codable {
    var manga: Manga
    var addedAt: TimeInterval
    var lastReadChapterName: String = ""
    var lastReadChapterURL: String = ""
    var lastReadAt: TimeInterval = 0
    var lastReadPage: Int = 0
    var unreadCount: Int = 0
    var downloaded: Bool = false

    var id: String { manga.key }
}

struct HistoryEntry: Identifiable, Hashable, Codable {
    var mangaKey: String
    var sourceID: String
    var mangaURL: String
    var title: String
    var cover: String
    var chapterName: String
    var chapterURL: String
    var page: Int
    var readAt: TimeInterval

    var id: String { mangaKey }
    var manga: Manga {
        Manga(key: mangaKey, sourceID: sourceID, url: mangaURL,
              title: title, cover: cover)
    }
}

enum LoadState: Equatable {
    case idle, loading, loaded, failed(String)
    var isLoading: Bool { self == .loading }
}
