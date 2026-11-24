import Foundation

/// iCloud 备份 / 恢复（源、书架、历史、已读章节）
final class CloudBackup {

    static let shared = CloudBackup()
    private init() {}

    private static let prefix = "MangaReader-"
    private static let ext = "json"

    private lazy var stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    // MARK: - 目录

    /// iCloud Drive 下的 Documents；未登录 iCloud 时退回本机 Documents
    func containerURL() throws -> URL {
        let fm = FileManager.default
        if let base = fm.url(forUbiquityContainerIdentifier: nil) {
            let docs = base.appendingPathComponent("Documents", isDirectory: true)
            if !fm.fileExists(atPath: docs.path) {
                try? fm.createDirectory(at: docs, withIntermediateDirectories: true)
            }
            return docs
        }
        let docs = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Documents", isDirectory: true)
        if !fm.fileExists(atPath: docs.path) {
            try? fm.createDirectory(at: docs, withIntermediateDirectories: true)
        }
        return docs
    }

    var isICloudAvailable: Bool {
        FileManager.default.url(forUbiquityContainerIdentifier: nil) != nil
    }

    // MARK: - 备份

    @discardableResult
    func backup() throws -> URL {
        let dir = try containerURL()
        let name = Self.prefix + stamp.string(from: Date()) + "." + Self.ext
        let url = dir.appendingPathComponent(name)

        let backup = LibraryStore.shared.makeBackup()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        let data = try encoder.encode(backup)
        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - 恢复

    func restore() throws {
        guard let url = latestBackupURL() else { throw BackupError.noBackup }
        let data = try Data(contentsOf: url)
        let backup = try JSONDecoder().decode(LibraryStore.Backup.self, from: data)
        LibraryStore.shared.restore(backup)
    }

    /// 最近一次备份文件
    func latestBackupURL() -> URL? {
        guard let dir = try? containerURL(),
              let items = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]) else { return nil }

        return items
            .filter { $0.lastPathComponent.hasPrefix(Self.prefix) && $0.pathExtension == Self.ext }
            .sorted { a, b in
                let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return da > db
            }
            .first
    }

    /// 备份列表（备份管理页用）
    func allBackups() -> [URL] {
        guard let dir = try? containerURL(),
              let items = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]) else { return [] }
        return items
            .filter { $0.lastPathComponent.hasPrefix(Self.prefix) && $0.pathExtension == Self.ext }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    func delete(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}

enum BackupError: LocalizedError {
    case noBackup

    var errorDescription: String? {
        switch self {
        case .noBackup: return "没有找到备份文件"
        }
    }
}
