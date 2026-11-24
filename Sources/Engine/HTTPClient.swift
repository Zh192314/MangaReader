import Foundation

/// 统一网络层：
/// - `get` / `post` 异步（给 Swift 侧 UI 与引擎调度）
/// - `syncGet` / `syncPost` 同步阻塞（给 JavaScriptCore 里调用的 HTTP 桥）
final class HTTPClient: NSObject {

    static let shared = HTTPClient()

    static let mobileUA = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 40
        cfg.httpMaximumConnectionsPerHost = 6
        cfg.httpShouldSetCookies = true
        cfg.httpCookieAcceptPolicy = .always
        cfg.httpCookieStorage = HTTPCookieStorage.shared
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    /// 全局附加头（部分源需要 referer 才能取图）
    var globalReferer: String?

    // MARK: - 异步

    func get(_ url: String,
             headers: [String: String]? = nil,
             referer: String? = nil,
             timeout: Double = 20) async throws -> (Data, HTTPURLResponse) {
        try await request(url, method: "GET", body: nil, headers: headers,
                          referer: referer, timeout: timeout)
    }

    func post(_ url: String,
              body: String,
              headers: [String: String]? = nil,
              referer: String? = nil,
              timeout: Double = 20) async throws -> (Data, HTTPURLResponse) {
        try await request(url, method: "POST", body: body, headers: headers,
                          referer: referer, timeout: timeout)
    }

    private func request(_ urlStr: String,
                         method: String,
                         body: String?,
                         headers: [String: String]?,
                         referer: String?,
                         timeout: Double) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: urlStr.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? urlStr)
                ?? URL(string: urlStr) else {
            throw HTTPError.badURL(urlStr)
        }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                             timeoutInterval: max(5, timeout))
        req.httpMethod = method
        req.setValue(HTTPClient.mobileUA, forHTTPHeaderField: "User-Agent")
        req.setValue("*/*", forHTTPHeaderField: "Accept")
        req.setValue("zh-CN,zh;q=0.9,en;q=0.8", forHTTPHeaderField: "Accept-Language")
        if let referer = referer ?? globalReferer {
            req.setValue(referer, forHTTPHeaderField: "Referer")
        }
        headers?.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        if let body = body {
            req.httpBody = body.data(using: .utf8)
            if req.value(forHTTPHeaderField: "Content-Type") == nil {
                req.setValue("application/x-www-form-urlencoded; charset=UTF-8",
                             forHTTPHeaderField: "Content-Type")
            }
        }
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw HTTPError.badResponse }
        if http.statusCode >= 400 && data.isEmpty {
            throw HTTPError.status(http.statusCode)
        }
        return (data, http)
    }

    // MARK: - 同步（JS 桥使用）

    func syncRequest(_ urlStr: String,
                     method: String = "GET",
                     body: String? = nil,
                     headers: [String: String]? = nil,
                     referer: String? = nil,
                     timeout: Double = 15) -> String {
        let sem = DispatchSemaphore(value: 0)
        var result = ""
        Task.detached(priority: .userInitiated) {
            do {
                let (data, resp) = try await self.request(urlStr, method: method,
                                                          body: body, headers: headers,
                                                          referer: referer, timeout: timeout)
                let charset = HTTPClient.charset(from: resp)
                result = HTTPClient.decode(data, charset: charset)
            } catch {
                result = "__ERROR__:" + error.localizedDescription
            }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + timeout + 6)
        return result
    }

    // MARK: - 编码

    static func charset(from resp: HTTPURLResponse?) -> String.Encoding {
        guard let ct = resp?.value(forHTTPHeaderField: "Content-Type")?.lowercased() else {
            return .utf8
        }
        if ct.contains("gbk") || ct.contains("gb2312") || ct.contains("gb18030") {
            return String.Encoding(rawValue:
                CFStringConvertEncodingToNSStringEncoding(
                    CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        }
        if ct.contains("big5") {
            return String.Encoding(rawValue:
                CFStringConvertEncodingToNSStringEncoding(
                    CFStringEncoding(CFStringEncodings.big5.rawValue)))
        }
        return .utf8
    }

    /// 先按声明编码解，失败再退 UTF-8，再退 GB18030
    static func decode(_ data: Data, charset: String.Encoding) -> String {
        if let s = String(data: data, encoding: charset) { return s }
        if let s = String(data: data, encoding: .utf8) { return s }
        let gb = String.Encoding(rawValue:
            CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        if let s = String(data: data, encoding: gb) { return s }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }
}

extension HTTPClient: URLSessionDelegate {
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // 自签证书站点直接信任（源站常见）
        if let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

enum HTTPError: LocalizedError {
    case badURL(String)
    case badResponse
    case status(Int)

    var errorDescription: String? {
        switch self {
        case .badURL(let s): return "无效链接 \(s)"
        case .badResponse: return "响应异常"
        case .status(let c): return "HTTP \(c)"
        }
    }
}
