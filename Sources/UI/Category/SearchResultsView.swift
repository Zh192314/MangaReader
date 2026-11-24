import SwiftUI

struct SearchResultsView: View {
    @EnvironmentObject private var env: AppEnv
    @Environment(\.dismiss) private var dismiss

    @State private var keyword: String
    @State private var groups: [SourceGroup] = []
    @State private var loading = false
    @State private var errorText: String?
    @State private var emptyText = "换个关键词，或在「资源管理」里多开几个源"
    @State private var selected: Manga?
    @FocusState private var focused: Bool

    struct SourceGroup: Identifiable {
        var source: MangaSource
        var items: [Manga]
        var id: String { source.id }
    }

    init(keyword: String) {
        _keyword = State(initialValue: keyword)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            resultBar

            ScrollView(showsIndicators: false) {
                VStack(spacing: 0) {
                    if loading && groups.isEmpty {
                        loadingBlock
                    } else if let e = errorText, groups.isEmpty {
                        EmptyStateView(icon: "exclamationmark.triangle",
                                       title: "搜索失败",
                                       subtitle: e,
                                       actionTitle: "重试") {
                            Task { await run() }
                        }
                    } else if groups.isEmpty {
                        EmptyStateView(icon: "magnifyingglass",
                                       title: "没有找到结果",
                                       subtitle: emptyText,
                                       actionTitle: nil)
                    } else {
                        ForEach(groups) { g in
                            groupSection(g)
                        }
                    }
                    Color.clear.frame(height: 40)
                }
            }
        }
        .background(Theme.bg)
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .task {
            if groups.isEmpty { await run() }
        }
        .sheet(item: $selected) { m in
            NavigationStack {
                MangaDetailView(manga: m)
            }
        }
    }

    // MARK: - 顶部

    private var header: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Button { dismissSelf() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 30, height: 36)
                }

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textTertiary)
                    TextField("搜索漫画", text: $keyword)
                        .font(.system(size: 14))
                        .focused($focused)
                        .submitLabel(.search)
                        .onSubmit { Task { await run() } }
                    if !keyword.isEmpty {
                        Button {
                            keyword = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundStyle(Theme.textTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
                .background(.white)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Button("搜索") { Task { await run() } }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 34)
            }
            .padding(.horizontal, 10)
        }
        .padding(.top, UIScreen.safeAreaTop + 4)
        .padding(.bottom, 10)
        .background(LinearGradient(colors: [Theme.blue, Theme.blueTop],
                                   startPoint: .top, endPoint: .bottom))
    }

    private var resultBar: some View {
        HStack {
            if loading {
                ProgressView().scaleEffect(0.7)
                Text("正在搜索 \(env.enabledSources.filter { !$0.lang.isNovel }.count) 个源…")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            } else if !groups.isEmpty {
                Text("命中 \(groups.count) 个源 · \(groups.reduce(0) { $0 + $1.items.count }) 部作品")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                Text("关键词：\(keyword)")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textTertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
    }

    private var loadingBlock: some View {
        VStack(spacing: 10) {
            ProgressView()
            Text("正在搜索…")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }

    // MARK: - 结果

    private func groupSection(_ g: SourceGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.blue)
                    .frame(width: 3, height: 12)
                Text(g.source.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("\(g.items.count)")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textTertiary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: GridLayout.bookCellWidth - 12),
                                         spacing: Theme.gridSpacing)],
                      alignment: .leading,
                      spacing: 14) {
                ForEach(g.items) { m in
                    Button { selected = m } label: {
                        BookGridCell(title: m.title,
                                     cover: m.cover,
                                     subtitle: m.author.isEmpty ? m.status : m.author,
                                     sourceName: g.source.name,
                                     coverHeight: (GridLayout.bookCellWidth - 12) * 4 / 3,
                                     showBadge: true)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
        }
    }

    // MARK: - 行为

    private func dismissSelf() {
        hideKeyboard()
        dismiss()
    }

    @MainActor
    private func run() async {
        let kw = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !kw.isEmpty else { return }
        hideKeyboard()

        let list = env.enabledSources.filter { !$0.lang.isNovel }
        guard !list.isEmpty else {
            errorText = "还没有启用任何源，去「设置 → 资源管理」添加"
            groups = []
            return
        }

        loading = true
        errorText = nil
        groups = []

        let results: [(MangaSource, [Manga])] = await withTaskGroup(
            of: (MangaSource, [Manga]).self,
            returning: [(MangaSource, [Manga])].self
        ) { group in
            for s in list.prefix(10) {
                group.addTask {
                    let rt = SourceRuntimePool.shared.runtime(for: s)
                    let items = (try? await rt.search(kw, page: 1)) ?? []
                    return (s, items)
                }
            }
            var acc: [(MangaSource, [Manga])] = []
            for await r in group { acc.append(r) }
            return acc
        }

        var fresh: [SourceGroup] = []
        for (s, items) in results where !items.isEmpty {
            fresh.append(SourceGroup(source: s, items: items))
        }
        fresh.sort { $0.source.order < $1.source.order }
        groups = fresh
        if fresh.isEmpty {
            emptyText = list.count <= 1
                ? "当前只启用了 \(list.count) 个源，去「资源管理」里多开几个"
                : "没有搜到「\(kw)」，换个关键词试试"
        }
        loading = false
    }
}
