import SwiftUI

/// 统一的网络图片视图：
/// - 内存/磁盘双层缓存
/// - 带 Referer（部分源站图片防盗链）
/// - 占位骨架 + 失败重试图标
struct RemoteImage: View {
    let url: String
    var referer: String? = nil
    var contentMode: ContentMode = .fill
    var cornerRadius: CGFloat = 0
    var placeholderColor: Color = Theme.chipBG

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        ZStack {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            } else {
                placeholderColor
                if failed {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(Theme.textTertiary)
                        .onTapGesture { reload() }
                } else {
                    ProgressView()
                        .scaleEffect(0.7)
                        .tint(Theme.textTertiary)
                }
            }
        }
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: url) { load() }
    }

    private func load() {
        guard !url.isEmpty else { failed = true; return }
        if let cached = ImageCache.shared.memoryImage(for: url) {
            image = cached
            return
        }
        ImageCache.shared.load(url: url, referer: referer) { img in
            withAnimation(.easeOut(duration: 0.18)) {
                if let img = img {
                    self.image = img
                    self.failed = false
                } else {
                    self.failed = true
                }
            }
        }
    }

    private func reload() {
        failed = false
        image = nil
        load()
    }
}
