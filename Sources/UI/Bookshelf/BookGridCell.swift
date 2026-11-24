import SwiftUI

/// 书架 / 分类 / 榜单共用的封面格子
struct BookGridCell: View {
    let title: String
    let cover: String
    let subtitle: String?
    let sourceName: String?
    var coverHeight: CGFloat? = nil
    var showBadge: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .bottomTrailing) {
                RemoteImage(url: cover,
                            contentMode: .fill,
                            cornerRadius: Theme.cellCorner)
                    .frame(width: GridLayout.bookCellWidth,
                           height: coverHeight ?? GridLayout.bookCoverHeight)
                    .background(Theme.chipBG)

                if showBadge, let s = sourceName, !s.isEmpty {
                    BadgeText(text: s)
                        .padding(.trailing, 3)
                        .padding(.bottom, 3)
                }
            }
            .frame(width: GridLayout.bookCellWidth,
                   height: coverHeight ?? GridLayout.bookCoverHeight)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cellCorner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cellCorner, style: .continuous)
                    .stroke(Color.black.opacity(0.04), lineWidth: 0.5)
            )

            Text(title)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundColor(Theme.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(width: GridLayout.bookCellWidth, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            if let sub = subtitle, !sub.isEmpty {
                Text(sub)
                    .font(.system(size: 11.5))
                    .foregroundColor(Theme.textTertiary)
                    .lineLimit(1)
                    .frame(width: GridLayout.bookCellWidth, alignment: .leading)
            }
        }
        .frame(width: GridLayout.bookCellWidth, alignment: .leading)
    }
}

/// 列表样式（搜索结果 / 榜单右侧）
struct BookRowCell: View {
    let title: String
    let cover: String
    let subtitle: String?
    let meta: String?
    var rank: Int? = nil
    var sourceName: String?

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            ZStack(alignment: .topLeading) {
                RemoteImage(url: cover, contentMode: .fill, cornerRadius: 5)
                    .frame(width: 76, height: 101)
                    .background(Theme.chipBG)

                if let r = rank {
                    Text("\(r)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 19, height: 19)
                        .background(rankColor(r))
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .padding(3)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 15.5, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if let sub = subtitle, !sub.isEmpty {
                    Text(sub)
                        .font(.system(size: 12.5))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                Spacer(minLength: 0)

                HStack(spacing: 6) {
                    if let m = meta, !m.isEmpty {
                        Text(m)
                            .font(.system(size: 11))
                            .foregroundColor(Theme.textTertiary)
                            .lineLimit(1)
                    }
                    if let s = sourceName, !s.isEmpty {
                        Text(s)
                            .font(.system(size: 10))
                            .foregroundColor(Theme.blue)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Theme.blue.opacity(0.09))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private func rankColor(_ r: Int) -> Color {
        switch r {
        case 1: return Color(hex: 0xFF4D4F)
        case 2: return Color(hex: 0xFF8A3D)
        case 3: return Color(hex: 0xFFC53D)
        case 4: return Color(hex: 0x7FB8FF)
        default: return Color(hex: 0xC7CBD1)
        }
    }
}
