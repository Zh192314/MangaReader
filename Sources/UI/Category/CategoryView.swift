import SwiftUI

struct CategoryView: View {
    @EnvironmentObject private var env: AppEnv

    private let tags: [String] = [
        "热血", "运动", "推理", "冒险", "搞笑", "战争",
        "神魔", "竞技", "悬疑", "社会", "恋爱", "宠物",
        "吸血", "萝莉", "后宫", "御姐", "霸总", "玄幻",
        "古风", "历史", "漫改", "游戏", "穿越", "恐怖",
        "真人", "科幻", "武侠", "修真", "生活", "动作",
        "防疫", "青春", "治愈", "悬疑推理", "校园", "职场"
    ]

    @State private var selectedTag: String = "热血"
    @State private var list: [Manga] = []
    @State private var state: LoadState = .idle
    @State private var activeSourceID: String?
    @State private var showSourcePicker = false
    @State private var path = NavigationPath()
    @State private var showSearch = false
    @State private var searchKeyword = ""

    private var activeSource: MangaSource? {
        if let id = activeSourceID, let s = env.source(id: id) { return s }
        return env.enabledSources.first
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                header
                ScrollView {
                    tagCloud
                    HairLine()
                    contentGrid
                    Color.clear.frame(height: 96)
                }
                .background(Theme.bg)
            }
            .background(Theme.bg)
            .ignoresSafeArea(edges: .bottom)
            .navigationDestination(for: Manga.self) { m in
                MangaDetailView(manga: m)
            }
            .confirmationDialog("选择要浏览的源", isPresented: $showSourcePicker) {
                ForEach(env.enabledSources) { s in
                    Button(s.name) {
                        activeSourceID = s.id
                        Task { await load() }
                    }
                }
                Button("取消", role: .cancel) {}
            }
            .sheet(isPresented: $showSearch) {
                NavigationStack {
                    SearchResultsView(keyword: searchKeyword)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("关闭") { showSearch = false }
                            }
                        }
                }
            }
            .task { await load() }
            .onChange(of: env.shelfVersion) { _ in }
        }
    }

    // MARK: - 顶栏

    private var header: some View {
        ZStack {
            Theme.headerGradient.ignoresSafeArea(edges: .top)

            HStack(spacing: 0) {
                Button {
                    showSourcePicker = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "hand.point.up.left.fill")
                            .font(.system(size: 13))
                        Text("切换")
                            .font(.system(size: 14))
                    }
                    .foregroundColor(.white)
                    .frame(width: 96, alignment: .leading)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)

                Text(activeSource?.name ?? "看漫画")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                    .lineLimit(1)

                Spacer(minLength: 0)

                NavIcon(systemName: "magnifyingglass") {
                    showSearch = true
                }
                .frame(width: 96, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .frame(height: Theme.headerHeight)
            .padding(.top, UIScreen.safeAreaTop)
        }
        .frame(height: Theme.headerHeight + UIScreen.safeAreaTop)
    }

    // MARK: - 标签云

    private var tagCloud: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 6),
                  spacing: 0) {
            ForEach(tags, id: \.self) { t in
                Button {
                    guard selectedTag != t else { return }
                    selectedTag = t
                    Task { await load() }
                } label: {
                    Text(t)
                        .font(.system(size: 14.5))
                        .foregroundColor(selectedTag == t ? Theme.accentRed : Theme.textPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 6)
        .padding(.bottom, 10)
        .background(Color.white)
    }

    // MARK: - 内容

    private var contentGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(selectedTag)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.textPrimary)
                if let s = activeSource {
                    Text(s.name)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textTertiary)
                }
                Spacer()
                if state.isLoading {
                    ProgressView().scaleEffect(0.7)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 12)

            if case .failed(let msg) = state, list.isEmpty {
                VStack(spacing: 10) {
                    Text(msg)
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                    Button("重试") { Task { await load() } }
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(Theme.blue)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 50)
            } else if list.isEmpty && !state.isLoading {
                EmptyStateView(icon: "square.grid.2x2", title: "这个分类还没有内容",
                               subtitle: "换一个标签，或在「设置 → 资源管理」里多启用几个源")
            } else {
                LazyVGrid(columns: GridLayout.bookshelfColumns, spacing: 16) {
                    ForEach(list) { m in
                        Button {
                            path.append(m)
                        } label: {
                            BookGridCell(title: m.title,
                                         cover: m.cover,
                                         subtitle: m.latestChapter.isEmpty ? m.author : m.latestChapter,
                                         sourceName: env.source(id: m.sourceID)?.name)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
            }
        }
        .padding(.bottom, 20)
    }

    // MARK: - 加载

    private func load() async {
        guard let src = activeSource else {
            state = .failed("还没有启用任何源，去「设置 → 资源管理」导入或启用")
            return
        }
        state = .loading
        let runtime = SourceRuntimePool.shared.runtime(for: src)
        do {
            var result = try await runtime.category(selectedTag, page: 1)
            if result.isEmpty {
                // 源没实现分类时用搜索兜底
                result = try await runtime.search(selectedTag, page: 1)
            }
            list = result
            state = .loaded
        } catch {
            list = []
            state = .failed(error.localizedDescription)
        }
    }
}
