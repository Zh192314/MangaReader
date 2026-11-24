import SwiftUI

// MARK: - 关于我们

struct AboutView: View {
    private var version: String { Bundle.main.appVersion }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 14) {
                appCard
                featureCard
                sourceCard
                legalCard
                Text("© 2026 漫阅 · 仅供个人学习使用")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 6)
                    .padding(.bottom, 30)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
        }
        .background(Theme.bg)
        .navigationTitle("关于我们")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.blue, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    private var appCard: some View {
        VStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: [Theme.blue, Theme.blueTop],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 76, height: 76)
                .overlay(
                    Image(systemName: "books.vertical.fill")
                        .font(.system(size: 32, weight: .semibold))
                        .foregroundStyle(.white)
                )
                .shadow(color: Theme.blue.opacity(0.3), radius: 10, y: 5)

            Text("漫阅")
                .font(.system(size: 19, weight: .bold))
                .foregroundStyle(Theme.textPrimary)

            Text("版本 \(version)")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)

            Text("一个干净的开源漫画阅读器：可以导入 GitHub 上的漫画源，统一搜索、阅读与追更。")
                .font(.system(size: 13))
                .foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center)
                .lineSpacing(3)
                .padding(.horizontal, 20)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var featureCard: some View {
        card(title: "能做什么") {
            VStack(spacing: 0) {
                infoRow(icon: "square.and.arrow.down", title: "导入源",
                        detail: "支持 JSON 规则源、JS 脚本源、GitHub 仓库批量导入")
                HairLine(inset: 44)
                infoRow(icon: "magnifyingglass", title: "多源并发搜索",
                        detail: "一次搜索同时命中所有启用的源，按源分组展示")
                HairLine(inset: 44)
                infoRow(icon: "book", title: "连续阅读",
                        detail: "竖向长图 / 横向翻页两种模式，自动记录进度")
                HairLine(inset: 44)
                infoRow(icon: "icloud", title: "本地优先",
                        detail: "书架、历史、已读全部存在本机，可备份到 iCloud")
            }
        }
    }

    private var sourceCard: some View {
        card(title: "关于漫画源") {
            VStack(alignment: .leading, spacing: 10) {
                Text("本 App 不内置任何漫画内容，所有内容均来自你自行导入的第三方源。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineSpacing(3)

                Text("内置的 MangaDex 源使用的是其公开 API。若发现某个源失效，可在「设置 → 资源管理」里编辑或删除，再导入社区维护的新源。")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineSpacing(3)

                HStack(spacing: 8) {
                    BadgeText(text: "JSON 规则", color: Theme.blue, fontSize: 10)
                    BadgeText(text: "JS 脚本", color: Theme.blue, fontSize: 10)
                    BadgeText(text: "GitHub 批量", color: Theme.blue, fontSize: 10)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private var legalCard: some View {
        card(title: "技术信息") {
            VStack(spacing: 0) {
                infoRow(icon: "cpu", title: "渲染引擎", detail: "JavaScriptCore + 自研 HTML 解析")
                HairLine(inset: 44)
                infoRow(icon: "internaldrive", title: "存储", detail: "SQLite3（WAL）+ 本地图片缓存")
                HairLine(inset: 44)
                infoRow(icon: "shippingbox", title: "第三方依赖", detail: "无")
            }
        }
    }

    private func card<C: View>(title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.textTertiary)
                .padding(.horizontal, 14)
                .padding(.bottom, 7)
            content()
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    private func infoRow(icon: String, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundStyle(Theme.blue)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }
}

// MARK: - 常见问题

struct FAQView: View {
    private struct Item: Identifiable {
        let id = UUID()
        let q: String
        let a: String
    }

    private let items: [Item] = [
        Item(q: "怎么导入漫画源？",
             a: "设置 → 资源管理 → 右上角「+」，有三种方式：粘贴 GitHub 链接（支持仓库/目录/单个文件）、粘贴源 JSON 或 JS 文本、从「文件」里选择 json/js 文件。导入成功后源会立刻出现在列表里。"),
        Item(q: "导入后搜索没有结果？",
             a: "先确认该源处于启用状态，再检查源里的域名是否还能访问。如果是模板源，需要把 baseURL 改成目标站域名。也可以点详情页右上角「刷新章节」重试。"),
        Item(q: "源失效了怎么办？",
             a: "资源列表里长按（或右侧箭头）进入编辑，改域名或选择器后保存；也可以删掉旧源重新导入社区维护的版本。源本质上是一段脚本，社区更新很快。"),
        Item(q: "阅读进度会丢吗？",
             a: "进度、书架、历史都存在本机 SQLite 里。想跨设备就用手动备份，备份文件会写到 iCloud Drive 的「漫阅」文件夹。"),
        Item(q: "为什么有些图片加载不出来？",
             a: "多数是防盗链导致的。源里给 imageReferer 填上正确 Referer 即可解决；App 默认会带上章节页地址作为 Referer。"),
        Item(q: "支持看小说吗？",
             a: "支持。源可以标记为小说类型，导入后会在「小说中文 / 小说英文」两个标签下出现。"),
        Item(q: "清除缓存会删掉书架吗？",
             a: "不会。清除图片缓存只删已下载的封面和章节图，书架、历史、已读状态不受影响。"),
        Item(q: "这个 App 会上传我的阅读记录吗？",
             a: "不会。App 只与你自己导入的源通信，没有任何统计或上报接口。")
    ]

    @State private var expanded: Set<UUID> = []

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 10) {
                ForEach(items) { item in
                    faqCard(item)
                }
                Text("还有问题？在「加入社群」里找到我们。")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                    .padding(.top, 8)
                    .padding(.bottom, 30)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
        }
        .background(Theme.bg)
        .navigationTitle("常见问题及解答")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.blue, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    private func faqCard(_ item: Item) -> some View {
        let isOpen = expanded.contains(item.id)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    if isOpen { expanded.remove(item.id) } else { expanded.insert(item.id) }
                }
            } label: {
                HStack(alignment: .top, spacing: 8) {
                    Text(item.q)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 6)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.textTertiary)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                        .padding(.top, 2)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 13)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                Text(item.a)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.textSecondary)
                    .lineSpacing(4)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
