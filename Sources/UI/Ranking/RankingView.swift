import SwiftUI

struct RankingView: View {
    @EnvironmentObject private var env: AppEnv

    private let boards: [String] = [
        "新作榜·男", "新作榜·女", "人气榜·男", "人气榜·女",
        "飙升榜", "畅销榜", "韩漫榜", "日漫榜", "投稿榜", "完结榜"
    ]

    /// 传给源的 key（英文更通用，源里对不上会退回中文）
    private let boardKeys: [String: String] = [
        "新作榜·男": "new-male",
        "新作榜·女": "new-female",
        "人气榜·男": "hot-male",
        "人气榜·女": "hot-female",
        "飙升榜": "rising",
        "畅销榜": "bestseller",
        "韩漫榜": "korean",
        "日漫榜": "japanese",
        "投稿榜": "submission",
        "完结榜": "completed"
    ]

    @State private var board: String = "新作榜·男"
    @State private var list: [Manga] = []
    @State private var state: LoadState = .idle
    @State private var path = NavigationPath()
    @State private var showSearch = false
    @State private var keyword = ""
    @State private var showSourcePicker = false
    @State private var activeSourceID: String?

    private var activeSource: MangaSource? {
        if let id = activeSourceID, let s = env.source(id: id) { return s }
        return env.enabledSources.first
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                header
                HStack(spacing: 0) {
                    sidebar
                    Rectangle()
                        .fill(Theme.separator)
                        .frame(width: 0.5)
                    content
                }
                .background(Color.white)
                .ignoresSafeArea(edges: .bottom)
            }
            .background(Theme.bg)
            .navigationDestination(for: Manga.self) { m in
                MangaDetailView(manga: m)
            }
            .confirmationDialog("选择榜单来源", isPresented: $showSourcePicker) {
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
                    SearchResultsView(keyword: keyword)
                        .toolbar {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("关闭") { showSearch = false }
                            }
                        }
                }
            }
            .task { await load() }
        }
    }

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
                        Text("切换").font(.system(size: 14))
                    }
                    .foregroundColor(.white)
                    .frame(width: 96, alignment: .leading)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)
                Text("快看漫画榜单")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white)
                Spacer(minLength: 0)

                NavIcon(systemName: "magnifyingglass") { showSearch = true }
                    .frame(width: 96, alignment: .trailing)
            }
            .padding(.horizontal, 14)
            .frame(height: Theme.headerHeight)
            .padding(.top, UIScreen.safeAreaTop)
        }
        .frame(height: Theme.headerHeight + UIScreen.safeAreaTop)
    }

    private var sidebar: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(boards, id: \.self) { b in
                    Button {
                        guard board != b else { return }
                        board = b
                        Task { await load() }
                    } label: {
                        HStack {
                            Text(b)
                                .font(.system(size: 14.5,
                                              weight: board == b ? .medium : .regular))
                                .foregroundColor(board == b ? Theme.textPrimary : Theme.textSecondary)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 58)
                        .background(board == b ? Theme.bg : Color.white)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Color.clear.frame(height: 90)
            }
        }
        .frame(width: UIScreen.width * 0.29)
        .background(Color(hex: 0xFBFBFC))
    }

    private var content: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if case .failed(let msg) = state, list.isEmpty {
                    VStack(spacing: 10) {
                        Text(msg)
                            .font(.system(size: 13))
                            .foregroundColor(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                        Button("重试") { Task { await load() } }
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(Theme.blue)
                    }
                    .padding(.vertical, 60)
                } else if list.isEmpty && !state.isLoading {
                    EmptyStateView(icon: "crown", title: "榜单暂无内容")
                } else {
                    ForEach(Array(list.enumerated()), id: \.element.key) { idx, m in
                        Button {
                            path.append(m)
                        } label: {
                            BookRowCell(title: m.title,
                                        cover: m.cover,
                                        subtitle: m.desc.isEmpty ? m.latestChapter : m.desc,
                                        meta: m.author,
                                        rank: idx + 1,
                                        sourceName: env.source(id: m.sourceID)?.name)
                            .padding(.horizontal, 10)
                        }
                        .buttonStyle(.plain)

                        HairLine(inset: 10)
                    }
                }
                if state.isLoading {
                    ProgressView()
                        .padding(.vertical, 24)
                }
                Color.clear.frame(height: 90)
            }
        }
    }

    private func load() async {
        guard let src = activeSource else {
            state = .failed("还没有启用任何源，去「设置 → 资源管理」导入或启用")
            return
        }
        state = .loading
        let runtime = SourceRuntimePool.shared.runtime(for: src)
        let key = boardKeys[board] ?? board
        do {
            var result = try await runtime.ranking(key, page: 1)
            if result.isEmpty, key != board {
                result = try await runtime.ranking(board, page: 1)
            }
            list = result
            state = .loaded
        } catch {
            list = []
            state = .failed(error.localizedDescription)
        }
    }
}
