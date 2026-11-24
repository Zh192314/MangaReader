import SwiftUI

struct MangaDetailView: View {
    @EnvironmentObject private var env: AppEnv
    @Environment(\.dismiss) private var dismiss

    @State private var manga: Manga
    @State private var chapters: [Chapter] = []
    @State private var state: LoadState = .idle
    @State private var ascending = true
    @State private var expandedDesc = false
    @State private var inLibrary = false
    @State private var readerIndex: Int?
    @State private var showReader = false

    init(manga: Manga) {
        _manga = State(initialValue: manga)
    }

    private var source: MangaSource? { env.source(id: manga.sourceID) }

    private var ordered: [Chapter] {
        ascending ? chapters : Array(chapters.reversed())
    }

    private var lastReadIndex: Int? {
        guard let entry = LibraryStore.shared.allLibrary().first(where: { $0.manga.key == manga.key }),
              !entry.lastReadChapterURL.isEmpty else { return nil }
        return chapters.firstIndex { $0.url == entry.lastReadChapterURL }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.bg.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    headerCard
                    infoSection
                    chapterSection
                    Color.clear.frame(height: 110)
                }
            }

            bottomBar
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .task { await load() }
        .fullScreenCover(isPresented: $showReader) {
            if let idx = readerIndex {
                ReaderView(manga: manga,
                           chapters: chapters,
                           startIndex: idx,
                           source: source)
            }
        }
    }

    // MARK: - 头部

    private var headerCard: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [Theme.blue, Theme.blueTop],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 150 + UIScreen.safeAreaTop)

            VStack(spacing: 0) {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                    }
                    Spacer()
                    Text(manga.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 8)
                    Spacer()
                    Menu {
                        Button(inLibrary ? "移出书架" : "加入书架") { toggleLibrary() }
                        Button("刷新章节") { Task { await load(force: true) } }
                        Button("复制详情链接") {
                            UIPasteboard.general.string = manga.url
                            env.showToast("已复制")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                    }
                }
                .padding(.top, UIScreen.safeAreaTop)
                .padding(.horizontal, 4)
                Spacer()
            }
            .frame(height: 44 + UIScreen.safeAreaTop)
        }
        .frame(height: 150 + UIScreen.safeAreaTop)
    }

    // MARK: - 信息

    private var infoSection: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                RemoteImage(url: manga.cover, referer: source?.baseURL,
                            cornerRadius: 8)
                    .frame(width: 106, height: 142)
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 4)

                VStack(alignment: .leading, spacing: 6) {
                    Text(manga.title)
                        .font(.system(size: 19, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(3)

                    if !manga.author.isEmpty {
                        Text(manga.author)
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }

                    HStack(spacing: 6) {
                        if !manga.status.isEmpty {
                            BadgeText(text: manga.status, color: Theme.blue, fontSize: 10)
                        }
                        if !manga.genre.isEmpty {
                            BadgeText(text: manga.genre.components(separatedBy: " / ").first ?? "",
                                      color: Theme.textSecondary, fontSize: 10)
                        }
                    }

                    Spacer(minLength: 0)

                    Button {
                        toggleLibrary()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: inLibrary ? "checkmark" : "plus")
                                .font(.system(size: 12, weight: .bold))
                            Text(inLibrary ? "已在书架" : "加入书架")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(inLibrary ? Theme.textSecondary : Theme.blue)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(
                            Capsule().stroke(inLibrary ? Theme.separator : Theme.blue.opacity(0.5),
                                             lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)
                }
                .frame(height: 142, alignment: .top)
            }
            .padding(.horizontal, 16)

            if !manga.desc.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text(manga.desc)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .lineSpacing(3)
                        .lineLimit(expandedDesc ? nil : 3)

                    Button(expandedDesc ? "收起" : "展开全部") {
                        withAnimation(.easeInOut(duration: 0.2)) { expandedDesc.toggle() }
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.blue)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 14)
            }
        }
        .padding(.top, 14)
    }

    // MARK: - 章节

    private var chapterSection: some View {
        VStack(spacing: 0) {
            HStack {
                Text("章节")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                Text("共 \(chapters.count) 话")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { ascending.toggle() }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: ascending ? "arrow.up" : "arrow.down")
                            .font(.system(size: 10, weight: .bold))
                        Text(ascending ? "正序" : "倒序")
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(Theme.textSecondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .frame(height: 46)

            switch state {
            case .idle, .loading:
                if chapters.isEmpty { loadingBlock } else { chapterList }
            case .failed(let msg):
                if chapters.isEmpty {
                    errorBlock(msg)
                } else {
                    chapterList
                }
            case .loaded:
                chapterList
            }
        }
        .padding(.top, 10)
    }

    private var loadingBlock: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("正在加载章节…")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var chapterList: some View {
        LazyVStack(spacing: 0) {
            ForEach(ordered, id: \.url) { ch in
                chapterRow(ch)
            }
            if chapters.isEmpty {
                EmptyStateView(icon: "list.bullet",
                               title: "暂无章节",
                               subtitle: "换个源或稍后再试")
            }
        }
    }

    private func errorBlock(_ msg: String) -> some View {
        EmptyStateView(icon: "exclamationmark.triangle",
                       title: "章节加载失败",
                       subtitle: msg,
                       actionTitle: "重试") {
            Task { await load(force: true) }
        }
    }

    private func chapterRow(_ ch: Chapter) -> some View {
        Button {
            open(ch)
        } label: {
            HStack(spacing: 8) {
                Text(ch.name)
                    .font(.system(size: 14))
                    .foregroundStyle(ch.read ? Theme.textTertiary : Theme.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: 6)

                if ch.read {
                    Text("已读")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Theme.chipBG)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.textTertiary.opacity(0.6))
            }
            .padding(.horizontal, 16)
            .frame(height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) {
            HairLine(inset: 16)
        }
    }

    // MARK: - 底部

    private var bottomBar: some View {
        VStack(spacing: 0) {
            Divider().overlay(Theme.separator)
            Button {
                if let idx = lastReadIndex {
                    readerIndex = idx
                } else if !chapters.isEmpty {
                    readerIndex = 0
                } else {
                    env.showToast("还没有章节")
                    return
                }
                showReader = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "book.fill").font(.system(size: 14))
                    Text(continueTitle)
                        .font(.system(size: 16, weight: .semibold))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .background(Theme.blue)
                .clipShape(RoundedRectangle(cornerRadius: 23))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, UIScreen.safeAreaBottom > 0 ? 10 : 14)
        }
        .background(.ultraThinMaterial)
    }

    private var continueTitle: String {
        if let idx = lastReadIndex, idx < chapters.count {
            return "继续阅读 · \(chapters[idx].name)"
        }
        return "开始阅读"
    }

    // MARK: - 行为

    private func toggleLibrary() {
        if inLibrary {
            LibraryStore.shared.removeFromLibrary(manga.key)
            env.showToast("已移出书架")
        } else {
            LibraryStore.shared.addToLibrary(manga)
            env.showToast("已加入书架")
        }
        inLibrary.toggle()
        env.bumpShelf()
    }

    private func open(_ ch: Chapter) {
        guard let idx = chapters.firstIndex(where: { $0.url == ch.url }) else { return }
        readerIndex = idx
        showReader = true
    }

    private func load(force: Bool = false) async {
        inLibrary = LibraryStore.shared.isInLibrary(manga.key)

        // 本地已读状态先垫上
        let local = LibraryStore.shared.chapters(for: manga.key)
        if !local.isEmpty {
            chapters = local
            state = .loaded
        }
        if state == .loaded && !force && !local.isEmpty { return }

        guard let src = source else {
            state = .failed("源已被删除或禁用")
            return
        }

        state = .loading
        let runtime = SourceRuntimePool.shared.runtime(for: src)

        do {
            if manga.title.isEmpty || manga.cover.isEmpty || manga.desc.isEmpty {
                if let full = try? await runtime.detail(manga.url) {
                    manga = full
                }
            }
            let list = try await runtime.chapters(manga.url)
            guard !list.isEmpty else {
                state = .failed("该源没有返回章节")
                return
            }
            // 合并本地已读
            let readSet = Set(LibraryStore.shared.chapters(for: manga.key)
                .filter { $0.read }.map { $0.url })
            var merged = list.enumerated().map { i, c -> Chapter in
                var c = c
                c.index = i
                c.read = readSet.contains(c.url)
                return c
            }
            if merged.isEmpty { merged = list }
            chapters = merged
            LibraryStore.shared.saveChapters(merged, for: manga.key)
            if inLibrary {
                LibraryStore.shared.touchLibrary(manga.key)
            }
            state = .loaded
        } catch {
            if chapters.isEmpty {
                state = .failed(error.localizedDescription)
            }
        }
    }
}
