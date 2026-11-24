import SwiftUI

struct ReaderView: View {
    let manga: Manga
    let chapters: [Chapter]
    let source: MangaSource?

    @Environment(\.dismiss) private var dismiss

    @State private var index: Int
    @State private var images: [(url: String, referer: String?)] = []
    @State private var state: LoadState = .idle
    @State private var showOverlay = true
    @State private var currentPage = 1
    @State private var horizontal = false

    init(manga: Manga, chapters: [Chapter], startIndex: Int, source: MangaSource?) {
        self.manga = manga
        self.chapters = chapters
        self.source = source
        _index = State(initialValue: max(0, min(startIndex, max(0, chapters.count - 1))))
    }

    private var chapter: Chapter {
        guard index < chapters.count else {
            return Chapter(url: manga.url, name: "正文", index: 0)
        }
        return chapters[index]
    }

    var body: some View {
        ZStack {
            Color(hex: 0x111114).ignoresSafeArea()

            content

            if showOverlay {
                overlay
                    .transition(.opacity)
            }
        }
        .statusBarHidden(!showOverlay)
        .task(id: index) { await load() }
        .onDisappear { save() }
    }

    // MARK: - 内容

    @ViewBuilder
    private var content: some View {
        switch state {
        case .idle, .loading:
            VStack(spacing: 12) {
                ProgressView().tint(.white)
                Text("加载中…")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.6))
            }

        case .failed(let msg):
            VStack(spacing: 14) {
                Image(systemName: "photo.badge.exclamationmark")
                    .font(.system(size: 40))
                    .foregroundStyle(.white.opacity(0.5))
                Text(msg)
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
                Button("重试") { Task { await load(force: true) } }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 22)
                    .frame(height: 38)
                    .background(Theme.blue)
                    .clipShape(Capsule())
            }

        case .loaded:
            if images.isEmpty {
                Text("本话没有图片")
                    .font(.system(size: 14))
                    .foregroundStyle(.white.opacity(0.6))
            } else {
                pages
            }
        }
    }

    private var pages: some View {
        Group {
            if horizontal {
                TabView(selection: $currentPage) {
                    ForEach(Array(images.enumerated()), id: \.offset) { i, img in
                        pageView(img, index: i)
                            .tag(i + 1)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .ignoresSafeArea()
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(images.enumerated()), id: \.offset) { i, img in
                                pageView(img, index: i)
                                    .id(i)
                                    .onAppear {
                                        if abs(currentPage - (i + 1)) > 0 {
                                            currentPage = i + 1
                                        }
                                    }
                            }
                        }
                    }
                    .onAppear {
                        if let saved = savedPage(), saved > 0, saved < images.count {
                            currentPage = saved + 1
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                proxy.scrollTo(saved, anchor: .top)
                            }
                        }
                    }
                }
                .id(index)
            }
        }
    }

    private func pageView(_ img: (url: String, referer: String?), index i: Int) -> some View {
        Group {
            if horizontal {
                RemoteImage(url: img.url,
                            referer: img.referer ?? source?.baseURL,
                            contentMode: .fit,
                            cornerRadius: 0,
                            placeholderColor: Color(hex: 0x1C1C20))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.vertical, 8)
            } else {
                RemoteImage(url: img.url,
                            referer: img.referer ?? source?.baseURL,
                            contentMode: .fit,
                            cornerRadius: 0,
                            placeholderColor: Color(hex: 0x1C1C20))
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 220)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.18)) { showOverlay.toggle() }
        }
    }

    // MARK: - 浮层

    private var overlay: some View {
        VStack {
            topBar
            Spacer()
            bottomBar
        }
        .background(
            LinearGradient(colors: [.black.opacity(0.55), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 160)
                .frame(maxHeight: .infinity, alignment: .top)
                .allowsHitTesting(false)
                .ignoresSafeArea()
        )
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.6)],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 180)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .allowsHitTesting(false)
                .ignoresSafeArea()
        )
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(manga.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(chapter.name)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.65))
                    .lineLimit(1)
            }

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.2)) { horizontal.toggle() }
            } label: {
                Image(systemName: horizontal ? "rectangle.grid.1x2" : "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
            }
        }
        .padding(.horizontal, 6)
        .padding(.top, UIScreen.safeAreaTop)
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            // 章节进度
            GeometryReader { geo in
                let total = max(chapters.count, 1)
                let ratio = CGFloat(index + 1) / CGFloat(total)
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18))
                    Capsule().fill(Theme.blue)
                        .frame(width: geo.size.width * ratio)
                }
            }
            .frame(height: 3)
            .padding(.horizontal, 16)

            HStack {
                Button {
                    jump(-1)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.system(size: 12, weight: .bold))
                        Text("上一话").font(.system(size: 13))
                    }
                    .foregroundStyle(index > 0 ? .white : .white.opacity(0.3))
                    .frame(height: 34)
                }
                .disabled(index <= 0)

                Spacer()

                VStack(spacing: 1) {
                    Text("\(currentPage)/\(max(images.count, 1))")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                    Text("\(index + 1)/\(max(chapters.count, 1)) 话")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.45))
                }

                Spacer()

                Button {
                    jump(1)
                } label: {
                    HStack(spacing: 3) {
                        Text("下一话").font(.system(size: 13))
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold))
                    }
                    .foregroundStyle(index < chapters.count - 1 ? .white : .white.opacity(0.3))
                    .frame(height: 34)
                }
                .disabled(index >= chapters.count - 1)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, UIScreen.safeAreaBottom > 0 ? 4 : 14)
        }
        .padding(.bottom, 4)
    }

    // MARK: - 行为

    private func jump(_ delta: Int) {
        let next = index + delta
        guard next >= 0, next < chapters.count else { return }
        save()
        index = next
        currentPage = 1
    }

    private func savedPage() -> Int? {
        let entry = LibraryStore.shared.allLibrary().first { $0.manga.key == manga.key }
        guard let e = entry, e.lastReadChapterURL == chapter.url else { return nil }
        return e.lastReadPage
    }

    private func save() {
        guard !images.isEmpty else { return }
        LibraryStore.shared.saveProgress(manga: manga, chapter: chapter, page: currentPage - 1)
        LibraryStore.shared.markRead(manga.key, chapterURL: chapter.url, isRead: true)
    }

    private func load(force: Bool = false) async {
        if state == .loaded && !force { return }
        guard let src = source else {
            state = .failed("源已被删除或禁用")
            return
        }
        state = .loading
        images = []
        let runtime = SourceRuntimePool.shared.runtime(for: src)
        do {
            let list = try await runtime.images(chapter.url)
            guard !list.isEmpty else {
                state = .failed("没有解析到图片")
                return
            }
            images = list
            state = .loaded
            save()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
}
