import SwiftUI

struct BookshelfView: View {
    @EnvironmentObject private var env: AppEnv

    @State private var segment: Int = 0            // 0 收藏 1 历史 2 下载
    @State private var langTab: Int = 0            // 0..3
    @State private var keyword: String = ""
    @State private var items: [LibraryEntry] = []
    @State private var history: [HistoryEntry] = []
    @State private var sortDescending = true
    @State private var sortBy: SortKind = .recent
    @State private var editMode = false
    @State private var selected: Set<String> = []
    @State private var path = NavigationPath()
    @State private var showSearch = false

    enum SortKind: String, CaseIterable {
        case recent = "最近添加"
        case update = "最近更新"
        case name = "名称"
        case unread = "未读优先"
    }

    private var currentLang: SourceLang {
        switch langTab {
        case 1: return .en
        case 2: return .zhNovel
        case 3: return .enNovel
        default: return .zh
        }
    }

    private var filtered: [LibraryEntry] {
        var list = items.filter { entry in
            guard let s = env.source(id: entry.manga.sourceID) else { return false }
            return s.lang == currentLang
        }
        if !keyword.isEmpty {
            list = list.filter { $0.manga.title.localizedCaseInsensitiveContains(keyword) }
        }
        if segment == 2 { list = list.filter { $0.downloaded } }
        switch sortBy {
        case .recent: list.sort { $0.addedAt > $1.addedAt }
        case .update: list.sort { $0.lastReadAt > $1.lastReadAt }
        case .name: list.sort { $0.manga.title < $1.manga.title }
        case .unread: list.sort { $0.unreadCount > $1.unreadCount }
        }
        return sortDescending ? list : Array(list.reversed())
    }

    private var filteredHistory: [HistoryEntry] {
        var list = history.filter { h in
            guard let s = env.source(id: h.sourceID) else { return false }
            return s.lang == currentLang
        }
        if !keyword.isEmpty {
            list = list.filter { $0.title.localizedCaseInsensitiveContains(keyword) }
        }
        return list
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                shelfHeader
                langTabBar
                SearchRow(text: $keyword,
                          placeholder: "请输入书籍名称",
                          onSubmit: { showSearch = !keyword.isEmpty },
                          onClear: { keyword = "" })
                HairLine()

                countBar

                ScrollView {
                    if segment == 0 || segment == 2 {
                        libraryGrid
                    } else {
                        historyList
                    }
                    Color.clear.frame(height: 96)
                }
                .background(Theme.bg)
                .refreshable { reload() }
            }
            .background(Theme.bg)
            .ignoresSafeArea(edges: .bottom)
            .navigationDestination(for: Manga.self) { m in
                MangaDetailView(manga: m)
            }
            .navigationDestination(for: String.self) { _ in
                SearchResultsView(keyword: keyword)
            }
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
            .onAppear { reload() }
            .onChange(of: env.shelfVersion) { _ in reload() }
            .onChange(of: langTab) { _ in selected.removeAll() }
            .onChange(of: segment) { _ in selected.removeAll() }
        }
    }

    // MARK: - 顶栏

    private var shelfHeader: some View {
        ZStack {
            Theme.headerGradient.ignoresSafeArea(edges: .top)

            HStack(spacing: 18) {
                ForEach(Array(["收藏", "历史", "下载"].enumerated()), id: \.offset) { idx, t in
                    Button {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            segment = idx
                            editMode = false
                        }
                    } label: {
                        VStack(spacing: 3) {
                            Text(t)
                                .font(.system(size: 17, weight: segment == idx ? .semibold : .regular))
                                .foregroundColor(.white.opacity(segment == idx ? 1 : 0.72))
                            Circle()
                                .fill(Color.white)
                                .frame(width: 3, height: 3)
                                .opacity(segment == idx ? 1 : 0)
                        }
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                NavIcon(systemName: "magnifyingglass") {
                    showSearch = true
                }
                NavIcon(systemName: editMode ? "checkmark" : "square.and.pencil") {
                    withAnimation { editMode.toggle(); selected.removeAll() }
                }
            }
            .padding(.horizontal, 14)
            .frame(height: Theme.headerHeight)
            .padding(.top, UIScreen.safeAreaTop)
        }
        .frame(height: Theme.headerHeight + UIScreen.safeAreaTop)
    }

    // MARK: - 语言 tab

    private var langTabBar: some View {
        HStack(spacing: 0) {
            ForEach(Array(SourceLang.allCases.enumerated()), id: \.offset) { idx, lang in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { langTab = idx }
                } label: {
                    VStack(spacing: 5) {
                        Text(lang.displayName)
                            .font(.system(size: 14.5, weight: langTab == idx ? .medium : .regular))
                            .foregroundColor(langTab == idx ? Theme.accentRed : Theme.textPrimary)
                        Rectangle()
                            .fill(Theme.accentRed)
                            .frame(width: 30, height: 2)
                            .opacity(langTab == idx ? 1 : 0)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 10)
                }
                .buttonStyle(.plain)
            }

            Menu {
                Picker("排序", selection: $sortBy) {
                    ForEach(SortKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                Button(sortDescending ? "改为正序" : "改为倒序") {
                    sortDescending.toggle()
                }
                Divider()
                Button("刷新书架") { refreshAll() }
            } label: {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 17))
                    .foregroundColor(Theme.textPrimary)
                    .frame(width: 40, height: 32)
            }

            Button {
                refreshAll()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 16))
                    .foregroundColor(Theme.textPrimary)
                    .frame(width: 40, height: 32)
            }
            .buttonStyle(.plain)
        }
        .padding(.trailing, 6)
        .background(Color.white)
    }

    // MARK: - 数量条

    private var countBar: some View {
        HStack(spacing: 10) {
            Text(segment == 1 ? "共 \(filteredHistory.count) 条" : "共 \(filtered.count) 本")
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(Theme.textPrimary)

            if editMode && !selected.isEmpty {
                Text("已选 \(selected.count)")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
            }

            Spacer()

            if editMode {
                Button("全选") {
                    selected = Set(filtered.map { $0.manga.key })
                }
                .font(.system(size: 13))
                .foregroundColor(Theme.blue)

                Button("删除") {
                    deleteSelected()
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Theme.accentRed)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Color.white)
    }

    // MARK: - 网格

    private var libraryGrid: some View {
        Group {
            if filtered.isEmpty {
                EmptyStateView(icon: "books.vertical",
                               title: segment == 2 ? "暂无下载内容" : "书架是空的",
                               subtitle: "去分类或搜索里找点漫画，点「加入书架」就会出现在这里",
                               actionTitle: "去逛逛") {
                    NotificationCenter.default.post(name: .switchToCategory, object: nil)
                }
            } else {
                LazyVGrid(columns: GridLayout.bookshelfColumns, spacing: 16) {
                    ForEach(filtered) { entry in
                        Button {
                            if editMode {
                                toggleSelect(entry.manga.key)
                            } else {
                                path.append(entry.manga)
                            }
                        } label: {
                            ZStack(alignment: .topTrailing) {
                                BookGridCell(title: entry.manga.title,
                                             cover: entry.manga.cover,
                                             subtitle: subtitleText(entry),
                                             sourceName: env.source(id: entry.manga.sourceID)?.name)
                                if editMode {
                                    Image(systemName: selected.contains(entry.manga.key)
                                          ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 18))
                                        .foregroundColor(selected.contains(entry.manga.key)
                                                         ? Theme.blue : .white)
                                        .background(Circle().fill(.white).padding(1))
                                        .padding(5)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                path.append(entry.manga)
                            } label: { Label("查看详情", systemImage: "info.circle") }

                            Button {
                                env.showToast("已标记为全部已读")
                                LibraryStore.shared.markAllRead(entry.manga.key)
                                reload()
                            } label: { Label("全部标为已读", systemImage: "checkmark.circle") }

                            Button(role: .destructive) {
                                LibraryStore.shared.removeFromLibrary(entry.manga.key)
                                reload()
                                env.showToast("已移出书架")
                            } label: { Label("移出书架", systemImage: "trash") }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 12)
            }
        }
    }

    private func subtitleText(_ e: LibraryEntry) -> String {
        if e.lastReadChapterName.isEmpty {
            return e.unreadCount > 0 ? "未读 \(e.unreadCount) 话" : "尚未开始阅读"
        }
        return "已观看至：\(e.lastReadChapterName)"
    }

    // MARK: - 历史

    private var historyList: some View {
        Group {
            if filteredHistory.isEmpty {
                EmptyStateView(icon: "clock.arrow.circlepath", title: "还没有阅读记录")
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(filteredHistory) { h in
                        HStack(spacing: 12) {
                            RemoteImage(url: h.cover, contentMode: .fill, cornerRadius: 5)
                                .frame(width: 68, height: 90)
                                .background(Theme.chipBG)

                            VStack(alignment: .leading, spacing: 5) {
                                Text(h.title)
                                    .font(.system(size: 15, weight: .medium))
                                    .foregroundColor(Theme.textPrimary)
                                    .lineLimit(2)
                                Text(h.chapterName)
                                    .font(.system(size: 12.5))
                                    .foregroundColor(Theme.textSecondary)
                                    .lineLimit(1)
                                Text(Self.relativeTime(h.readAt))
                                    .font(.system(size: 11))
                                    .foregroundColor(Theme.textTertiary)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            openHistory(h)
                        }
                        .contextMenu {
                            Button(role: .destructive) {
                                LibraryStore.shared.removeHistory(h.mangaKey)
                                reload()
                            } label: { Label("删除这条记录", systemImage: "trash") }
                        }

                        HairLine(inset: 92)
                    }
                }
                .background(Color.white)
            }
        }
    }

    // MARK: - 行为

    private func toggleSelect(_ key: String) {
        if selected.contains(key) { selected.remove(key) } else { selected.insert(key) }
    }

    private func deleteSelected() {
        guard !selected.isEmpty else { return }
        for k in selected {
            if segment == 1 {
                LibraryStore.shared.removeHistory(k)
            } else {
                LibraryStore.shared.removeFromLibrary(k)
            }
        }
        selected.removeAll()
        reload()
        env.showToast("已删除")
    }

    private func reload() {
        items = LibraryStore.shared.allLibrary()
        history = LibraryStore.shared.allHistory()
    }

    private func refreshAll() {
        env.reloadSources()
        reload()
        env.bumpShelf()
        env.showToast("书架已刷新")
    }

    private func openHistory(_ h: HistoryEntry) {
        path.append(h.manga)
    }

    static func relativeTime(_ ts: TimeInterval) -> String {
        guard ts > 0 else { return "" }
        let d = Date(timeIntervalSince1970: ts)
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        if Calendar.current.isDateInToday(d) { f.dateFormat = "今天 HH:mm" }
        else if Calendar.current.isDateInYesterday(d) { f.dateFormat = "昨天 HH:mm" }
        else { f.dateFormat = "MM-dd HH:mm" }
        return f.string(from: d)
    }
}

extension Notification.Name {
    static let switchToCategory = Notification.Name("switchToCategory")
}
