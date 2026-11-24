import SwiftUI

@main
struct MangaReaderApp: App {

    @StateObject private var env = AppEnv.shared
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        SourceStore.shared.seedIfNeeded()
        ImageCache.shared.trimIfNeeded()
        configureAppearance()
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(env)
                .preferredColorScheme(.light)
                .onAppear { env.reloadSources() }
        }
    }

    private func configureAppearance() {
        // 顶栏白字
        let nav = UINavigationBarAppearance()
        nav.configureWithOpaqueBackground()
        nav.backgroundColor = UIColor(Theme.blue)
        nav.titleTextAttributes = [.foregroundColor: UIColor.white]
        UINavigationBar.appearance().standardAppearance = nav
        UINavigationBar.appearance().scrollEdgeAppearance = nav
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // 保持屏幕常亮只在阅读器里开启
        return true
    }

    func application(_ app: UIApplication,
                     open url: URL,
                     options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        // 支持 mangareader://import?url=...
        guard url.scheme == "mangareader" else { return false }
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if let target = comps?.queryItems?.first(where: { $0.name == "url" })?.value {
            NotificationCenter.default.post(name: .importSourceURL,
                                            object: nil, userInfo: ["url": target])
        }
        return true
    }
}

extension Notification.Name {
    static let importSourceURL = Notification.Name("importSourceURL")
}
