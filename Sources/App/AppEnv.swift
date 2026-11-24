import SwiftUI

/// 全局环境：源列表、刷新信号、Toast
final class AppEnv: ObservableObject {

    static let shared = AppEnv()

    @Published var sources: [MangaSource] = []
    @Published var shelfVersion = 0
    @Published var historyVersion = 0
    @Published var toast: ToastData?
    /// 搜索页默认带入的关键词
    @Published var pendingSearchKeyword: String = ""

    private var toastTask: DispatchWorkItem?

    private init() {
        reloadSources()
    }

    // MARK: - 源

    func reloadSources() {
        sources = SourceStore.shared.all()
    }

    var enabledSources: [MangaSource] {
        sources.filter { $0.enabled }
    }

    func sources(for lang: SourceLang) -> [MangaSource] {
        sources.filter { $0.lang == lang }
    }

    func groupedSources() -> [(lang: SourceLang, list: [MangaSource])] {
        SourceLang.allCases.compactMap { lang in
            let part = sources.filter { $0.lang == lang }
            return part.isEmpty ? nil : (lang, part)
        }
    }

    var enabledCount: Int { sources.filter { $0.enabled }.count }

    func source(id: String) -> MangaSource? {
        sources.first { $0.id == id }
    }

    // MARK: - 刷新信号

    func bumpShelf() {
        shelfVersion += 1
    }

    func bumpHistory() {
        historyVersion += 1
    }

    // MARK: - Toast

    func showToast(_ text: String, duration: TimeInterval = 1.6) {
        toastTask?.cancel()
        let data = ToastData(text: text)
        withAnimation(.easeOut(duration: 0.18)) { toast = data }
        let task = DispatchWorkItem { [weak self] in
            withAnimation(.easeIn(duration: 0.2)) {
                if self?.toast?.id == data.id { self?.toast = nil }
            }
        }
        toastTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + duration, execute: task)
    }
}

/// Toast 浮层
struct ToastHost: View {
    @ObservedObject var env: AppEnv

    var body: some View {
        VStack {
            Spacer()
            if let t = env.toast {
                ToastView(text: t.text)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
                    .padding(.bottom, 200)
            }
            Spacer()
        }
        .allowsHitTesting(false)
    }
}
