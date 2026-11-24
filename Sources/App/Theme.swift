import SwiftUI

/// 全局视觉常量：全部对齐参考稿
enum Theme {

    // MARK: 主色
    /// 顶栏蓝：#3F9BFF 附近，参考图上沿略亮
    static let blue = Color(hex: 0x3E9BFF)
    static let blueTop = Color(hex: 0x54AAFF)
    static let blueBottom = Color(hex: 0x3E9BFF)

    static let accentRed = Color(hex: 0xF4442E)
    static let textPrimary = Color(hex: 0x111111)
    static let textSecondary = Color(hex: 0x8A8A8E)
    static let textTertiary = Color(hex: 0xB0B0B5)
    static let bg = Color(hex: 0xF2F2F6)
    static let card = Color.white
    static let separator = Color(hex: 0xEDEDF0)
    static let chipBG = Color(hex: 0xF7F7F9)

    // MARK: 尺寸
    static let headerHeight: CGFloat = 44
    static let tabBarHeight: CGFloat = 58
    static let corner: CGFloat = 12
    static let cellCorner: CGFloat = 6
    static let gridSpacing: CGFloat = 9

    // MARK: 渐变顶栏
    static var headerGradient: LinearGradient {
        LinearGradient(colors: [blueTop, blueBottom],
                       startPoint: .top, endPoint: .bottom)
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        let r = Double((hex >> 16) & 0xFF) / 255
        let g = Double((hex >> 8) & 0xFF) / 255
        let b = Double(hex & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }
}

extension UIScreen {
    static var width: CGFloat { UIScreen.main.bounds.width }
    static var height: CGFloat { UIScreen.main.bounds.height }
    /// iPhone X 类带刘海设备
    static var hasNotch: Bool { safeAreaTop > 24 }
    static var safeAreaTop: CGFloat {
        (UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first?.safeAreaInsets.top) ?? 20
    }
    static var safeAreaBottom: CGFloat {
        (UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows.first?.safeAreaInsets.bottom) ?? 0
    }
}

/// 网格列定义：书架 / 分类 / 榜单共用 3 列
enum GridLayout {
    static let bookshelfColumns = Array(
        repeating: GridItem(.flexible(), spacing: Theme.gridSpacing),
        count: 3
    )
    static var bookCellWidth: CGFloat {
        let total = UIScreen.width - 12 * 2 - Theme.gridSpacing * 2
        return floor(total / 3)
    }
    static let bookCoverHeight: CGFloat = bookCellWidth * 4 / 3

    /// 资源列表页：4 列
    static let sourceColumns = Array(
        repeating: GridItem(.flexible(), spacing: 8),
        count: 4
    )
}

extension View {
    func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder),
                                        to: nil, from: nil, for: nil)
    }
}
