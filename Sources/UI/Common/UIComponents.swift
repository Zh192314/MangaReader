import SwiftUI

// MARK: - 蓝色导航栏

/// 参考稿的顶栏：蓝色渐变覆盖状态栏，白字居中标题，左右操作区
struct BlueNavBar<Leading: View, Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        ZStack {
            Theme.headerGradient
                .ignoresSafeArea(edges: .top)

            HStack(spacing: 0) {
                HStack(spacing: 14) { leading() }
                    .frame(width: 110, alignment: .leading)

                Spacer(minLength: 4)

                VStack(spacing: 1) {
                    Text(title)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundColor(.white)
                    if let subtitle = subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.75))
                    }
                }

                Spacer(minLength: 4)

                HStack(spacing: 16) { trailing() }
                    .frame(width: 110, alignment: .trailing)
            }
            .padding(.horizontal, 12)
            .frame(height: Theme.headerHeight)
            .padding(.top, UIScreen.safeAreaTop)
        }
        .frame(height: Theme.headerHeight + UIScreen.safeAreaTop)
    }
}

extension BlueNavBar where Leading == EmptyView {
    init(title: String, subtitle: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.init(title: title, subtitle: subtitle,
                  leading: { EmptyView() }, trailing: trailing)
    }
}

extension BlueNavBar where Trailing == EmptyView {
    init(title: String, subtitle: String? = nil, @ViewBuilder leading: @escaping () -> Leading) {
        self.init(title: title, subtitle: subtitle,
                  leading: leading, trailing: { EmptyView() })
    }
}

extension BlueNavBar where Leading == EmptyView, Trailing == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.init(title: title, subtitle: subtitle,
                  leading: { EmptyView() }, trailing: { EmptyView() })
    }
}

/// 顶栏上的图标按钮
struct NavIcon: View {
    let systemName: String
    var size: CGFloat = 19
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .medium))
                .foregroundColor(.white)
                .frame(width: 30, height: 30, alignment: .center)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// 返回按钮
struct NavBack: View {
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 19, weight: .semibold))
            }
            .foregroundColor(.white)
            .frame(width: 44, height: 30, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 搜索行

/// 参考稿的搜索条：灰底输入框 + 红「搜索」+ 黑「清空」
struct SearchRow: View {
    @Binding var text: String
    var placeholder: String = "请输入资源名称"
    var onSubmit: () -> Void
    var onClear: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15))
                    .foregroundColor(Theme.textTertiary)
                TextField(placeholder, text: $text)
                    .font(.system(size: 15))
                    .foregroundColor(Theme.textPrimary)
                    .focused($focused)
                    .submitLabel(.search)
                    .onSubmit { focused = false; onSubmit() }
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(Color(hex: 0xF5F5F7))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            Button {
                focused = false
                onSubmit()
            } label: {
                Text("搜索")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Theme.accentRed)
            }
            .buttonStyle(.plain)

            Button {
                text = ""
                onClear()
            } label: {
                Text("清空")
                    .font(.system(size: 15))
                    .foregroundColor(Theme.textPrimary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white)
    }
}

// MARK: - Toast

struct ToastData: Equatable {
    let text: String
    let id = UUID()
    static func == (a: ToastData, b: ToastData) -> Bool { a.id == b.id }
}

struct ToastView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundColor(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 9)
            .background(Color.black.opacity(0.78))
            .clipShape(Capsule())
            .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
    }
}

// MARK: - 空态

struct EmptyStateView: View {
    var icon: String = "books.vertical"
    var title: String
    var subtitle: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 40, weight: .light))
                .foregroundColor(Theme.textTertiary)
            Text(title)
                .font(.system(size: 15))
                .foregroundColor(Theme.textSecondary)
            if let sub = subtitle {
                Text(sub)
                    .font(.system(size: 12.5))
                    .foregroundColor(Theme.textTertiary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            if let t = actionTitle, let a = action {
                Button(action: a) {
                    Text(t)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(Theme.blue)
                        .clipShape(Capsule())
                }
                .padding(.top, 6)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }
}

// MARK: - 通用小组件

struct HairLine: View {
    var color: Color = Theme.separator
    var inset: CGFloat = 0
    var body: some View {
        Rectangle()
            .fill(color)
            .frame(height: 0.5)
            .padding(.leading, inset)
    }
}

struct BadgeText: View {
    let text: String
    var color: Color = .black.opacity(0.62)
    var fontSize: CGFloat = 9

    var body: some View {
        Text(text)
            .font(.system(size: fontSize, weight: .regular))
            .foregroundColor(.white)
            .lineLimit(1)
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .background(color.opacity(0.78))
            .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
    }
}

/// 浮动胶囊 Tab 栏（参考稿底部样式）
struct FloatingTabBar: View {
    @Binding var selection: Int
    let items: [(icon: String, title: String)]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                Button {
                    if selection != idx {
                        selection = idx
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item.icon)
                            .font(.system(size: 20, weight: selection == idx ? .semibold : .regular))
                            .foregroundColor(selection == idx ? Theme.blue : Color(hex: 0x1C1C1E))
                        Text(item.title)
                            .font(.system(size: 10.5, weight: selection == idx ? .medium : .regular))
                            .foregroundColor(selection == idx ? Theme.blue : Color(hex: 0x1C1C1E))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: Theme.tabBarHeight)
                    .background(
                        Group {
                            if selection == idx {
                                RoundedRectangle(cornerRadius: 26, style: .continuous)
                                    .fill(Theme.blue.opacity(0.10))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 2)
                            } else {
                                Color.clear
                            }
                        }
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: Theme.tabBarHeight)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(Color.black.opacity(0.05), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.07), radius: 14, y: 4)
        .padding(.horizontal, 22)
        .padding(.bottom, max(UIScreen.safeAreaBottom, 6))
    }
}
