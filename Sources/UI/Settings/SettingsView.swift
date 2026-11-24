import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var env: AppEnv

    @State private var cacheSize: String = "0K"
    @State private var path = NavigationPath()
    @State private var showSearch = false
    @State private var keyword = ""
    @State private var showVIP = false
    @State private var showCommunity = false

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(spacing: 10) {
                        group1
                        group2
                        group3
                        footer
                    }
                    .padding(.top, 10)
                    Color.clear.frame(height: 100)
                }
                .background(Theme.bg)
            }
            .background(Theme.bg)
            .ignoresSafeArea(edges: .bottom)
            .navigationDestination(for: String.self) { dest in
                switch dest {
                case "sources": SourceLibraryView()
                case "about": AboutView()
                case "faq": FAQView()
                default: EmptyView()
                }
            }
            .sheet(isPresented: $showVIP) { VIPView() }
            .sheet(isPresented: $showCommunity) { CommunityView() }
            .sheet(isPresented: $showSearch) {
                NavigationStack {
                    SearchResultsView(keyword: keyword)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("关闭") { showSearch = false }
                            }
                        }
                }
            }
            .onAppear { updateCacheSize() }
        }
    }

    private var header: some View {
        ZStack {
            Theme.headerGradient.ignoresSafeArea(edges: .top)
            HStack {
                Spacer()
                Text("设置")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
            }
            .overlay(alignment: .trailing) {
                NavIcon(systemName: "magnifyingglass") { showSearch = true }
                    .padding(.trailing, 14)
            }
            .frame(height: Theme.headerHeight)
            .padding(.top, UIScreen.safeAreaTop)
        }
        .frame(height: Theme.headerHeight + UIScreen.safeAreaTop)
    }

    // MARK: - 分组

    private var group1: some View {
        VStack(spacing: 0) {
            row(title: "开通会员", chevron: true) { showVIP = true }
            HairLine()
            row(title: "资源管理", chevron: true) { path.append("sources") }
        }
        .background(Color.white)
    }

    private var group2: some View {
        VStack(spacing: 0) {
            row(title: "关于我们", chevron: true) { path.append("about") }
            HairLine(inset: 16)
            row(title: "加入社群", chevron: true) { showCommunity = true }
            HairLine(inset: 16)
            row(title: "常见问题及解答", chevron: true) { path.append("faq") }
        }
        .background(Color.white)
    }

    private var group3: some View {
        VStack(spacing: 0) {
            row(title: "iCloud备份阅读记录", chevron: true) { backupToiCloud() }
            HairLine(inset: 16)
            row(title: "iCloud恢复阅读记录", chevron: true) { restoreFromiCloud() }
            HairLine()
            row(title: "清除图片缓存",
                value: cacheSize,
                chevron: false) { clearCache() }
            HairLine(inset: 16)
            row(title: "去评分", chevron: true) { rateApp() }
            HairLine(inset: 16)
            row(title: "多语言", value: "简体中文", chevron: true) { env.showToast("暂只提供简体中文") }
        }
        .background(Color.white)
    }

    private var footer: some View {
        VStack(spacing: 4) {
            Text("漫阅 \(Bundle.main.appVersion)")
                .font(.system(size: 12))
                .foregroundColor(Theme.textTertiary)
            Text("已启用 \(env.enabledCount) / \(env.sources.count) 个源")
                .font(.system(size: 11))
                .foregroundColor(Theme.textTertiary)
        }
        .padding(.top, 18)
    }

    // MARK: - 行

    @ViewBuilder
    private func row(title: String,
                     value: String? = nil,
                     chevron: Bool,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 15.5))
                    .foregroundColor(Theme.textPrimary)
                Spacer()
                if let v = value {
                    Text(v)
                        .font(.system(size: 14))
                        .foregroundColor(Theme.textSecondary)
                }
                if chevron {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.textTertiary)
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 行为

    private func updateCacheSize() {
        let bytes = ImageCache.shared.diskSize()
        cacheSize = ImageCache.formattedSize(bytes)
    }

    private func clearCache() {
        let freed = ImageCache.shared.clearDisk()
        updateCacheSize()
        env.showToast("已清除 \(ImageCache.formattedSize(freed))")
    }

    private func backupToiCloud() {
        do {
            let url = try CloudBackup.shared.backup()
            env.showToast("已备份到 \(url.lastPathComponent)")
        } catch {
            env.showToast("备份失败：\(error.localizedDescription)")
        }
    }

    private func restoreFromiCloud() {
        do {
            try CloudBackup.shared.restore()
            env.reloadSources()
            env.bumpShelf()
            env.showToast("阅读记录已恢复")
        } catch {
            env.showToast("恢复失败：\(error.localizedDescription)")
        }
    }

    private func rateApp() {
        if let url = URL(string: "https://apps.apple.com/app/id0000000000?action=write-review") {
            UIApplication.shared.open(url)
        }
    }
}

extension Bundle {
    var appVersion: String {
        let v = infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "v\(v) (\(b))"
    }
}
