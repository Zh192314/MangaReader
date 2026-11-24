import SwiftUI

struct RootTabView: View {
    @EnvironmentObject private var env: AppEnv
    @State private var selection: Int = 0

    private let items: [(icon: String, title: String)] = [
        ("star.fill", "书架"),
        ("square.grid.2x2.fill", "分类"),
        ("crown.fill", "榜单"),
        ("gearshape.fill", "设置")
    ]

    var body: some View {
        ZStack(alignment: .bottom) {
            TabView(selection: $selection) {
                BookshelfView().tag(0)
                CategoryView().tag(1)
                RankingView().tag(2)
                SettingsView().tag(3)
            }
            .toolbar(.hidden, for: .tabBar)
            .ignoresSafeArea(.keyboard)

            FloatingTabBar(selection: $selection, items: items)
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .overlay(ToastHost(env: env))
        .onReceive(NotificationCenter.default.publisher(for: .switchToCategory)) { _ in
            withAnimation(.easeInOut(duration: 0.2)) { selection = 1 }
        }
    }
}
