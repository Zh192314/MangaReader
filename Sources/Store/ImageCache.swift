import UIKit
import CryptoKit

/// 图片缓存：内存 LRU + 磁盘 LRU，支持 Referer（很多源站拒绝无 referer 的图片请求）
final class ImageCache {

    static let shared = ImageCache()

    private let memory = NSCache<NSString, UIImage>()
    private let io = DispatchQueue(label: "image.cache.io", qos: .utility, attributes: .concurrent)
    private var inflight: [String: [((UIImage?) -> Void)]] = [:]
    private let lock = NSLock()

    private let diskURL: URL
    private let maxDiskBytes: Int = 220 * 1024 * 1024

    private init() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MangaReaderImages", isDirectory: true)
        diskURL = dir
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        memory.countLimit = 260
        memory.totalCostLimit = 160 * 1024 * 1024
        // 磁盘缓存放在 Caches 下，系统可回收；同时 App 内提供「清除图片缓存」
    }

    // MARK: - 对外

    func image(for url: String, referer: String? = nil) async -> UIImage? {
        await withCheckedContinuation { cont in
            load(url: url, referer: referer) { img in
                cont.resume(returning: img)
            }
        }
    }

    func load(url: String, referer: String? = nil, completion: @escaping (UIImage?) -> Void) {
        guard !url.isEmpty else { completion(nil); return }
        let key = cacheKey(url)

        if let img = memory.object(forKey: key as NSString) {
            completion(img); return
        }

        lock.lock()
        if var waiters = inflight[url] {
            waiters.append(completion)
            inflight[url] = waiters
            lock.unlock()
            return
        }
        inflight[url] = [completion]
        lock.unlock()

        io.async {
            // 磁盘
            let file = self.diskURL.appendingPathComponent(key)
            if let data = try? Data(contentsOf: file), let img = UIImage(data: data) {
                self.memory.setObject(img, forKey: key as NSString, cost: data.count)
                self.finish(url: url, image: img)
                try? FileManager.default.setAttributes(
                    [.modificationDate: Date()], ofItemAtPath: file.path)
                return
            }

            self.download(url: url, referer: referer) { img, data in
                if let img = img, let data = data {
                    self.memory.setObject(img, forKey: key as NSString, cost: data.count)
                    try? data.write(to: file, options: .atomic)
                }
                self.finish(url: url, image: img)
            }
        }
    }

    private func finish(url: String, image: UIImage?) {
        lock.lock()
        let waiters = inflight[url] ?? []
        inflight[url] = nil
        lock.unlock()
        DispatchQueue.main.async {
            waiters.forEach { $0(image) }
        }
    }

    // MARK: - 下载

    private func download(url: String, referer: String?, completion: @escaping (UIImage?, Data?) -> Void) {
        guard let u = URL(string: url) else { completion(nil, nil); return }
        var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 25)
        req.setValue(HTTPClient.mobileUA, forHTTPHeaderField: "User-Agent")
        req.setValue("image/webp,image/apng,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        if let ref = referer, !ref.isEmpty {
            req.setValue(ref, forHTTPHeaderField: "Referer")
        }
        // 部分图床要求跨站 referrer
        req.setValue("no-referrer-when-downgrade", forHTTPHeaderField: "Referrer-Policy")

        URLSession.shared.dataTask(with: req) { data, resp, _ in
            guard let data = data, !data.isEmpty else {
                completion(nil, nil); return
            }
            if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
                completion(nil, nil); return
            }
            if let img = UIImage(data: data) {
                completion(img, data)
            } else {
                // 可能是 webp 或加密图，交给系统再试一次
                completion(nil, nil)
            }
        }.resume()
    }

    // MARK: - 维护

    /// 同步取内存缓存（View 首帧用，避免闪一下占位图）
    func memoryImage(for url: String) -> UIImage? {
        memory.object(forKey: cacheKey(url) as NSString)
    }

    private func cacheKey(_ url: String) -> String {
        let digest = SHA256.hash(data: Data(url.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    func clearMemory() {
        memory.removeAllObjects()
    }

    /// 返回清理掉的字节数
    @discardableResult
    func clearDisk() -> Int64 {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: diskURL,
                                                      includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var freed: Int64 = 0
        for f in files {
            let size = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            try? fm.removeItem(at: f)
            freed += Int64(size)
        }
        memory.removeAllObjects()
        return freed
    }

    func diskSize() -> Int64 {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: diskURL,
                                                      includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for f in files {
            total += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// 超限时按修改时间淘汰
    func trimIfNeeded() {
        io.async(flags: .barrier) {
            let fm = FileManager.default
            guard let files = try? fm.contentsOfDirectory(at: self.diskURL,
                                                          includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) else { return }
            var infos: [(URL, Int, Date)] = files.map { f in
                let v = try? f.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                return (f, v?.fileSize ?? 0, v?.contentModificationDate ?? .distantPast)
            }
            var total = infos.reduce(0) { $0 + $1.1 }
            guard total > self.maxDiskBytes else { return }
            infos.sort { $0.2 < $1.2 }
            for info in infos {
                if total <= self.maxDiskBytes / 2 { break }
                try? fm.removeItem(at: info.0)
                total -= info.1
            }
        }
    }

    static func formattedSize(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1024 / 1024
        if mb >= 1 { return String(format: "%.1fM", mb) }
        return String(format: "%.0fK", Double(bytes) / 1024)
    }
}
