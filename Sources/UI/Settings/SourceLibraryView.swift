import SwiftUI
import UniformTypeIdentifiers

struct SourceLibraryView: View {
    @EnvironmentObject private var env: AppEnv
    @Environment(\.dismiss) private var dismiss

    @State private var keyword = ""
    @State private var showImport = false
    @State private var editing: MangaSource?
    @State private var toast: String?
    @State private var confirmRestore = false

    private func group(_ lang: SourceLang) -> [MangaSource] {
        var list = env.sources.filter { $0.lang == lang }
        if !keyword.isEmpty {
            list = list.filter { $0.name.localizedCaseInsensitiveContains(keyword) }
        }
        return list
    }

    var body: some View {
        VStack(spacing: 0) {
            BlueNavBar(title: "资源列表",
                       leading: { NavBack { dismiss() } },
                       trailing: {
                           NavIcon(systemName: "plus") { showImport = true }
                       })

            SearchRow(text: $keyword,
                      placeholder: "请输入资源名称",
                      onSubmit: {},
                      onClear: { keyword = "" })
            HairLine()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if keyword.isEmpty && env.sources.isEmpty {
                        emptyHint
                    }
                    ForEach(SourceLang.allCases, id: \.self) { lang in
                        let list = group(lang)
                        if !list.isEmpty {
                            section(lang, list)
                        }
                    }
                    if !keyword.isEmpty && group(.zh).isEmpty && group(.en).isEmpty
                        && group(.zhNovel).isEmpty && group(.enNovel).isEmpty {
                        EmptyStateView(icon: "magnifyingglass",
                                       title: "没有匹配的资源",
                                       subtitle: "换个关键词，或点右上角 + 导入新的源")
                    }
                    Color.clear.frame(height: 40)
                }
                .padding(.top, 12)
            }
            .background(Theme.bg)
        }
        .background(Theme.bg)
        .toolbar(.hidden, for: .navigationBar)
        .sheet(isPresented: $showImport) {
            SourceImportSheet { msg in
                env.reloadSources()
                toast = msg
            }
        }
        .sheet(item: $editing) { src in
            SourceEditorSheet(source: src) { saved in
                SourceStore.shared.save(saved)
                env.reloadSources()
                env.showToast("已保存「\(saved.name)」")
            }
        }
        .confirmationDialog("恢复内置源将覆盖同名源，确定继续？",
                            isPresented: $confirmRestore,
                            titleVisibility: .visible) {
            Button("恢复", role: .destructive) {
                SourceStore.shared.restoreBuiltins()
                env.reloadSources()
                env.showToast("已恢复内置源")
            }
            Button("取消", role: .cancel) {}
        }
        .toolbar {
            ToolbarItem(placement: .bottomBar) { EmptyView() }
        }
        .overlay(alignment: .bottom) {
            if let t = toast {
                ToastView(text: t)
                    .padding(.bottom, 30)
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
                            withAnimation { toast = nil }
                        }
                    }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .importSourceURL)) { note in
            guard let target = note.userInfo?["url"] as? String, !target.isEmpty else { return }
            Task {
                do {
                    let n = try await SourceImporter.shared.importFromURL(target)
                    env.reloadSources()
                    toast = "已导入 \(n) 个源"
                } catch {
                    toast = "导入失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("还没有任何源")
                .font(.system(size: 16, weight: .medium))
            Text("点右上角 + 可以：\n• 从 GitHub 链接导入开源源\n• 粘贴源 JSON / JS\n• 从「文件」App 导入 .json")
                .font(.system(size: 13))
                .foregroundColor(Theme.textSecondary)
                .lineSpacing(3)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.chipBG)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 12)
    }

    private func section(_ lang: SourceLang, _ list: [MangaSource]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("\(lang.isNovel ? "小说" : "漫画")资源-\(lang == .zh || lang == .zhNovel ? "中文" : "英文")")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(Theme.textPrimary)
                Text("\(list.count)")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textTertiary)
                Spacer()
                Button {
                    confirmRestore = true
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.textTertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)

            LazyVGrid(columns: GridLayout.sourceColumns, spacing: 8) {
                ForEach(list) { src in
                    sourceCell(src)
                }
            }
            .padding(.horizontal, 12)
        }
    }

    private func sourceCell(_ src: MangaSource) -> some View {
        Button {
            if !src.enabled {
                SourceStore.shared.setEnabled(src.id, true)
                env.reloadSources()
                env.showToast("已启用「\(src.name)」")
                return
            }
            UserDefaults.standard.set(src.id, forKey: "currentSourceID")
            env.showToast("已切换到「\(src.name)」")
        } label: {
            Text(src.name)
                .font(.system(size: 14.5))
                .foregroundColor(src.enabled ? Theme.textPrimary : Theme.textTertiary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(src.enabled ? Color.white : Color.white.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(src.enabled ? Color.clear : Theme.separator, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                SourceStore.shared.setEnabled(src.id, !src.enabled)
                env.reloadSources()
            } label: {
                Label(src.enabled ? "停用" : "启用",
                      systemImage: src.enabled ? "pause.circle" : "play.circle")
            }
            Button {
                editing = src
            } label: { Label("编辑", systemImage: "pencil") }

            Button {
                UIPasteboard.general.string = SourceExporter.export(src)
                env.showToast("源配置已复制")
            } label: { Label("复制配置", systemImage: "doc.on.doc") }

            if !src.builtin {
                Button(role: .destructive) {
                    SourceStore.shared.delete(src.id)
                    env.reloadSources()
                    env.showToast("已删除「\(src.name)」")
                } label: { Label("删除", systemImage: "trash") }
            }
        }
    }
}

// MARK: - 导入面板

struct SourceImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var urlText = ""
    @State private var pasted = ""
    @State private var busy = false
    @State private var message: String?
    @State private var showFileImporter = false

    var onDone: (String) -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    block(title: "从 GitHub / 任意链接导入") {
                        HStack(spacing: 8) {
                            TextField("https://raw.githubusercontent.com/.../source.json",
                                      text: $urlText)
                                .font(.system(size: 13, design: .monospaced))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .padding(10)
                                .background(Theme.chipBG)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            Button("导入") { importFromURL() }
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .background(Theme.blue)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .disabled(busy)
                        }
                        Text("支持：单文件 JSON / JS 源、GitHub 仓库 raw 链接、GitHub API 目录批量导入")
                            .font(.system(size: 11.5))
                            .foregroundColor(Theme.textTertiary)
                    }

                    block(title: "Venera 源（一键导入）") {
                        Button {
                            importVeneraIndex()
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "shippingbox")
                                    .font(.system(size: 15))
                                    .foregroundColor(Theme.blue)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("导入 Venera 官方源列表")
                                        .font(.system(size: 14))
                                        .foregroundColor(Theme.textPrimary)
                                    Text("一次拉取 30+ 个 Venera 兼容源")
                                        .font(.system(size: 11.5))
                                        .foregroundColor(Theme.textTertiary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(Theme.textTertiary)
                            }
                            .padding(12)
                            .background(Theme.chipBG)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                        .disabled(busy)

                        Text("Venera 源是单个 .js 文件（内含 class XXX extends ComicSource），和 Venera / Miru 用的是同一套规范，可直接粘贴或填 CDN 链接。")
                            .font(.system(size: 11.5))
                            .foregroundColor(Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    block(title: "粘贴 JSON / JS") {
                        TextEditor(text: $pasted)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(height: 160)
                            .padding(8)
                            .background(Theme.chipBG)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Theme.separator, lineWidth: 0.5)
                            )
                        HStack(spacing: 10) {
                            Button("从剪贴板粘贴") {
                                pasted = UIPasteboard.general.string ?? ""
                            }
                            .font(.system(size: 13))
                            .foregroundColor(Theme.blue)

                            Spacer()

                            Button("导入这段内容") { importFromText() }
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.white)
                                .padding(.horizontal, 14)
                                .padding(.vertical, 9)
                                .background(Theme.blue)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .disabled(pasted.isEmpty || busy)
                        }
                    }

                    block(title: "从文件导入") {
                        Button {
                            showFileImporter = true
                        } label: {
                            HStack {
                                Image(systemName: "folder")
                                Text("选择 .json / .js 文件")
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(Theme.textTertiary)
                            }
                            .font(.system(size: 14))
                            .foregroundColor(Theme.textPrimary)
                            .padding(12)
                            .background(Theme.chipBG)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }

                    block(title: "源格式说明") {
                        Text(SourceFormatDoc.text)
                            .font(.system(size: 11.5, design: .monospaced))
                            .foregroundColor(Theme.textSecondary)
                            .lineSpacing(3)
                    }

                    if let m = message {
                        Text(m)
                            .font(.system(size: 13))
                            .foregroundColor(m.contains("失败") ? Theme.accentRed : Color(hex: 0x2DBE60))
                    }
                }
                .padding(16)
            }
            .background(Color.white)
            .navigationTitle("导入源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                if busy {
                    ToolbarItem(placement: .topBarTrailing) {
                        ProgressView().scaleEffect(0.8)
                    }
                }
            }
            .fileImporter(isPresented: $showFileImporter,
                          allowedContentTypes: [.json, .plainText, .text, .data],
                          allowsMultipleSelection: true) { result in
                handleFileResult(result)
            }
        }
    }

    private func block<C: View>(title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundColor(Theme.textPrimary)
            content()
        }
    }

    // MARK: - 行为

    /// Venera 官方源清单（index.json），导入后逐个下载其内的 .js 源
    private static let veneraIndexURL =
        "https://cdn.jsdelivr.net/gh/venera-app/venera-configs@main/index.json"

    private func importVeneraIndex() {
        urlText = Self.veneraIndexURL
        importFromURL()
    }

    private func importFromURL() {
        let url = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else { return }
        busy = true
        message = nil
        Task {
            do {
                let n = try await SourceImporter.shared.importFromURL(url)
                await MainActor.run {
                    busy = false
                    message = "成功导入 \(n) 个源"
                    onDone("成功导入 \(n) 个源")
                    if n > 0 { dismiss() }
                }
            } catch {
                await MainActor.run {
                    busy = false
                    message = "导入失败：\(error.localizedDescription)"
                }
            }
        }
    }

    private func importFromText() {
        busy = true
        message = nil
        do {
            let n = try SourceImporter.shared.importFromText(pasted)
            busy = false
            message = "成功导入 \(n) 个源"
            onDone("成功导入 \(n) 个源")
            if n > 0 { dismiss() }
        } catch {
            busy = false
            message = "导入失败：\(error.localizedDescription)"
        }
    }

    private func handleFileResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            var total = 0
            for u in urls {
                guard u.startAccessingSecurityScopedResource() else { continue }
                defer { u.stopAccessingSecurityScopedResource() }
                if let data = try? Data(contentsOf: u),
                   let text = String(data: data, encoding: .utf8) {
                    total += (try? SourceImporter.shared.importFromText(
                        text,
                        fallbackName: u.deletingPathExtension().lastPathComponent)) ?? 0
                }
            }
            message = total > 0 ? "成功导入 \(total) 个源" : "没有可识别的源"
            if total > 0 {
                onDone("成功导入 \(total) 个源")
                dismiss()
            }
        case .failure(let e):
            message = "读取文件失败：\(e.localizedDescription)"
        }
    }
}

// MARK: - 编辑面板

struct SourceEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State var source: MangaSource
    var onSave: (MangaSource) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("基本信息") {
                    TextField("名称", text: $source.name)
                    TextField("站点根地址", text: $source.baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("版本", text: $source.version)
                    Picker("语言", selection: $source.lang) {
                        ForEach(SourceLang.allCases, id: \.self) { l in
                            Text(l.displayName).tag(l)
                        }
                    }
                    Toggle("启用", isOn: $source.enabled)
                }

                if source.kind == .js {
                    Section("脚本") {
                        TextEditor(text: Binding(
                            get: { source.script ?? "" },
                            set: { source.script = $0 }))
                            .font(.system(size: 11.5, design: .monospaced))
                            .frame(minHeight: 240)
                    }
                }

                Section {
                    Text("源 ID：\(source.id)")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textSecondary)
                }
            }
            .navigationTitle("编辑源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存") {
                        onSave(source)
                        dismiss()
                    }
                    .fontWeight(.medium)
                }
            }
        }
    }
}

// MARK: - 会员 / 社群（占位页）

struct VIPView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "crown.fill")
                    .font(.system(size: 44))
                    .foregroundColor(Color(hex: 0xF5B942))
                Text("漫阅 VIP")
                    .font(.system(size: 20, weight: .semibold))
                Text("去除广告、云端同步书架、批量下载、\n源自动更新与私有源托管。")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)

                VStack(spacing: 10) {
                    payRow("月度会员", "¥6", "自动续订")
                    payRow("年度会员", "¥45", "立省 37%")
                    payRow("永久会员", "¥98", "一次买断")
                }
                .padding(.top, 8)
                .padding(.horizontal, 24)

                Text("当前为自签名版本，内购不可用；\n所有功能默认全开。")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textTertiary)
                    .multilineTextAlignment(.center)

                Spacer()
            }
            .padding(.top, 40)
            .navigationTitle("开通会员")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("关闭") { dismiss() } }
            }
        }
    }

    private func payRow(_ t: String, _ p: String, _ n: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(t).font(.system(size: 15, weight: .medium))
                Text(n).font(.system(size: 11)).foregroundColor(Theme.textTertiary)
            }
            Spacer()
            Text(p)
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(Color(hex: 0xE8971F))
        }
        .padding(14)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.separator, lineWidth: 0.5))
    }
}

struct CommunityView: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            VStack(spacing: 14) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 40))
                    .foregroundColor(Theme.blue)
                Text("加入社群")
                    .font(.system(size: 19, weight: .semibold))
                Text("源更新、失效反馈、自签答疑都在群里。")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.textSecondary)
                Text("（此处放你的群二维码 / TG 链接）")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textTertiary)
                Spacer()
            }
            .padding(.top, 50)
            .navigationTitle("加入社群")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("关闭") { dismiss() } }
            }
        }
    }
}
