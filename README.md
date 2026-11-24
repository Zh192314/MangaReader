# 漫阅 MangaReader

一个原生 SwiftUI 漫画阅读器：**自己导入源、自己管书架、自己签 IPA**。
不内置任何漫画内容，全部内容来自你导入的第三方源（JSON 规则源 / JS 脚本源 / GitHub 仓库）。

界面按参考稿 1:1 还原：蓝色渐变顶栏、浮动胶囊 TabBar、三段书架、四语言切换、
六列标签分类、十项榜单侧栏、设置分组列表、四列资源格子。

---

## 一、环境要求

| 项目 | 版本 |
|---|---|
| macOS | 13+ |
| Xcode | 15.0+（Swift 5.9） |
| XcodeGen | 2.38+（`brew install xcodegen`） |
| 真机 / 模拟器 | iOS 16.0+ |

不需要 CocoaPods、不需要 SPM 解析，全部系统框架：

- `SwiftUI` / `UIKit`
- `SQLite3`（`-lsqlite3`）
- `JavaScriptCore`（跑源脚本）
- `WebKit`（源内可用，预留给网页兜底）

## 二、编译

```bash
cd MangaReader
xcodegen generate
open MangaReader.xcodeproj
```

选中 `MangaReader` scheme → 真机 → Run。

> `project.yml` 里默认 `CODE_SIGNING_ALLOWED=NO`，模拟器直接能跑；
> 真机运行需要你在 Xcode 的 Signing & Capabilities 里选一个 Team（或按 `SIGNING.md` 走自签）。

## 三、打包 IPA + 自签

一行命令出未签名 IPA（macOS 上执行）：

```bash
bash build.sh          # 产物：build/MangaReader.ipa
```

脚本内部做的事就是：`xcodegen generate` → `xcodebuild archive`（真机 SDK、不签名）→
把 `.app` 塞进 `Payload/` → `zip` 成 ipa。

拿到 ipa 后按 [`SIGNING.md`](SIGNING.md) 签名安装，含 Sideloadly / AltStore / TrollStore / 自有证书四条路线。

### 没有 Mac？用 GitHub 云编译

`.github/workflows/build.yml` 已经写好：推到 GitHub 就自动出 ipa，打 tag 会直接建 Release。
完整操作（含可选的自有证书签名）见 [`CI.md`](CI.md)。

```bash
git init -b main && git add -A && git commit -m "init"
gh repo create MangaReader --private --source=. --push   # 或手动建仓后 git push
git tag v1.4.0 && git push origin v1.4.0                 # 打 tag → 出 Release 附件
```

## 四、目录结构

```
MangaReader/
├── project.yml                    XcodeGen 工程定义
├── build.sh                       一键出未签名 IPA（macOS 本地）
├── CI.md                          GitHub Actions 云编译说明
├── .github/workflows/build.yml    云编译流水线（未签名 / 可选签名 / Release）
├── tools/make_icon.py             生成 1024 图标的脚本
├── Resources/
│   ├── Info.plist                 ATS 全开、文件共享、mangareader:// Scheme
│   └── Assets.xcassets            AppIcon / 启动底色
└── Sources/
    ├── App/
    │   ├── MangaReaderApp.swift   @main、AppDelegate（mangareader:// 导入）
    │   ├── RootTabView.swift      TabView + 浮动 TabBar
    │   ├── AppEnv.swift           全局状态（源、书架版本、Toast）
    │   └── Theme.swift            配色、栅格、屏幕尺寸
    ├── Models/
    │   └── MangaSource.swift      MangaSource / SourceRules / Manga / Chapter / ...
    ├── Engine/
    │   ├── HTTPClient.swift       async + 同步桥（GBK 识别、自签证书放行）
    │   ├── HTMLParser.swift       手写容错 HTML → HNode 树
    │   ├── JSEngine.swift         JavaScriptCore + jQuery 风格 DOM 桥
    │   ├── JSONSourceCompiler.swift  声明式规则 → JS
    │   ├── SourceRuntime.swift    源执行器 + 运行时池
    │   ├── VeneraLib.swift        Venera 源 JS 运行时（Network / HtmlDocument / ComicSource）
    │   ├── VeneraRuntime.swift    Venera 源宿主（JSContext + 同步桥 + 微任务泵）
    │   └── SourceImporter.swift   URL / 文本 / GitHub 批量 / Venera 清单导入、导出、格式说明
    ├── Store/
    │   ├── Database.swift         SQLite3 WAL，四张表
    │   ├── SourceStore.swift      源 CRUD + 首次种子
    │   ├── LibraryStore.swift     书架 / 章节 / 历史 / 备份结构
    │   ├── ImageCache.swift       内存 + 磁盘双层缓存（220MB 上限）
    │   ├── CloudBackup.swift      iCloud Drive 备份与恢复
    │   └── BuiltinSources.swift   内置源（MangaDex + 三个模板）
    └── UI/
        ├── Common/                RemoteImage、导航栏、搜索行、Toast、空态、TabBar
        ├── Bookshelf/             BookGridCell、BookRowCell、BookshelfView
        ├── Category/              CategoryView、SearchResultsView
        ├── Ranking/               RankingView
        ├── Detail/                MangaDetailView
        ├── Reader/                ReaderView（竖向连续 / 横向翻页）
        └── Settings/              SettingsView、SourceLibraryView、AboutView、FAQView
```

## 五、漫画源格式

### 5.1 最小可用的 JS 源

```js
// name: 我的源
var BASE = 'https://example.com';

function search(q, page) {          // → [{url,title,cover,author}]
  var html = get(BASE + '/search?q=' + encodeURIComponent(q));
  var out = [];
  doc(html).find('.item').each(function (i, el) {
    out.push({
      url: abs(el.find('a').attr('href'), BASE),
      title: el.find('h3').text(),
      cover: fixImg(el.find('img').attr('src'), BASE)
    });
  });
  return out;
}

function detail(url) {              // → {title,cover,author,desc,genre,status}
  var d = doc(get(url));
  return {
    url: url,
    title: d.find('h1').first().text(),
    cover: fixImg(d.find('.cover img').attr('src'), url),
    desc: d.find('.intro').first().text()
  };
}

function chapters(url) {            // → [{url,name}]
  var out = [];
  doc(get(url)).find('#list a').each(function (i, el) {
    out.push({ url: abs(el.attr('href'), url), name: el.text(), index: i });
  });
  return out;
}

function images(chapterUrl) {       // → [{url,referer}]
  var out = [];
  doc(get(chapterUrl)).find('#images img').each(function (i, el) {
    out.push({ url: fixImg(el.attr('data-src'), chapterUrl), referer: chapterUrl });
  });
  return out;
}
```

**四个函数必须同步返回**（内部已用信号量把网络请求变成阻塞式），不需要写 `async/await`、不需要 Promise。

### 5.2 内置函数

| 名称 | 说明 |
|---|---|
| `get(url[, headers, referer])` | 同步 GET，返回字符串（自动识别 GBK） |
| `post(url, body[, headers, referer])` | 同步 POST |
| `getJSON(url)` / `postJSON(url, body)` | 自动 `JSON.parse` |
| `doc(html)` | 解析 HTML，返回 jQuery 风格对象 |
| `$(selector \| html \| node)` | 同上，简写 |
| `.find() .each() .attr() .text() .html() .parent() .next() .children()` | DOM 操作 |
| `abs(url, base)` | 相对链接转绝对 |
| `fixImg(url, base)` | 去 `//` 前缀、补 base |
| `stripTags(s)` / `txt(x)` / `num(x)` | 文本处理 |
| `md5(s)` / `b64(s)` | 常见签名与编码 |
| `sleep(ms)` | 阻塞等待（限速用） |

选择器支持：`tag`、`.class`、`#id`、`[attr]`、`[attr=val]`、`[attr*=val]`、`a, b`、
`a > b`、`:first`、`:last`、`:eq(n)`、`:contains(text)`。

### 5.3 声明式 JSON 源

不想写 JS 就填选择器，App 会在运行时编译成 JS：

```json
{
  "name": "声明式源",
  "url": "https://example.com",
  "kind": "json",
  "rules": {
    "searchURL": "{base}/search?keyword={keyword}&page={page}",
    "searchList": ".book-list .item",
    "searchTitle": "h3@title",
    "searchCover": "img@data-src",
    "searchLink": "a@href",
    "chapterList": "#chapter-list a",
    "chapterLink": "@href",
    "chapterReverse": true,
    "imageList": "#images img",
    "imageAttr": "data-original",
    "imageReferer": "{chapterURL}"
  }
}
```

字段语法：`"selector"` 取文本、`"sel@attr"` 取属性、`"@attr"` 取条目自身属性。
占位符：`{base}` `{keyword}` `{page}` `{chapterURL}`。

### 5.4 Venera 源（与 Venera / Miru 通用）

直接兼容 [venera-configs](https://github.com/venera-app/venera-configs) 的源格式：
一个 `.js` 文件就是一个源，**末尾不需要任何注册代码**，类名随意。

```js
class MySource extends ComicSource {
    name = "我的源"
    key = "my_source"
    version = "1.0.0"
    baseUrl = "https://example.com"

    search = {
        load: async (keyword, options, page) => {
            const res = await Network.get(`${this.baseUrl}/search?q=${encodeURIComponent(keyword)}`)
            const doc = new HtmlDocument(res.body)
            const comics = doc.querySelectorAll('.item').map(e => new Comic({
                id: e.querySelector('a').attributes['href'],
                title: e.querySelector('h3').text,
                cover: e.querySelector('img').attributes['src'],
            }))
            return { comics, maxPage: 1 }
        }
    }

    comic = {
        loadInfo: async (id) => {
            const res = await Network.get(`${this.baseUrl}/book/${id}`)
            const doc = new HtmlDocument(res.body)
            const chapters = new Map()
            doc.querySelectorAll('.chapter').forEach(e => chapters.set(e.attributes['data-id'], e.text))
            return new ComicDetails({ title: "…", cover: "…", chapters })
        },
        loadEp: async (comicId, epId) => {
            const res = await Network.get(`${this.baseUrl}/read/${comicId}/${epId}`)
            const doc = new HtmlDocument(res.body)
            return { images: doc.querySelectorAll('img.page').map(e => e.attributes['src']) }
        }
    }
}
```

可用 API：`Network.get/post/put/patch/delete/sendRequest/fetchBytes`、浏览器同形
`fetch()`、`new HtmlDocument(html)` + `querySelector/querySelectorAll/getElementById`、
`Convert.md5/sha1/sha256/sha512/base64/gbk`、`UI.showMessage`、`log()`、`createUuid()`、
`setTimeout/setInterval`、`Map` / `Set`、ES2022 class 字段与 `async/await`。
`chapters` 同时支持一层 `Map<章节id, 标题>` 和两层 `Map<分组, Map<章节id, 标题>>`。

实现差异：Venera 用 QuickJS + 异步宿主，这里用 JavaScriptCore + 同步 HTTP 桥，
把 `await` 的挂起点用微任务泵跑完，所以源代码写法完全一致，不用改一行。

### 5.5 导入方式

1. **GitHub 链接**：仓库根、`/tree/main/sources` 目录、单个 `.json`/`.js` 文件都行，目录会批量拉取（最多 40 个）。
2. **Venera 官方源列表**：导入面板里点「导入 Venera 官方源列表」，一次拉取整套官方源；
   也可以直接填单个源的 CDN 链接，如
   `https://cdn.jsdelivr.net/gh/venera-app/venera-configs@main/manga_dex.js`。
3. **粘贴文本**：JSON 数组、`{sources:[...]}`、`name → 源` 映射、单文件 JS（含 Venera 源）都能识别。
4. **文件选择**：从「文件」App 多选 `.json` / `.js`。
5. **URL Scheme**：`mangareader://import?url=<encodeURIComponent(源地址)>`。

## 六、功能对照

| 页面 | 实现 |
|---|---|
| 书架 | 收藏 / 历史 / 下载 三 Tab；四语言筛选；排序（最近阅读/最近更新/名称/未读）；编辑多选删除；长按菜单 |
| 分类 | 36 个标签，六列；点击按标签拉列表；右上角切源 |
| 榜单 | 10 个榜单侧栏（新作/人气/飙升/畅销/韩漫/日漫/投稿/完结）；1-5 彩色排名 |
| 设置 | 会员、资源管理、关于、社群、FAQ、iCloud 备份/恢复、清缓存（显示真实占用）、评分、多语言 |
| 详情 | 封面/作者/状态/标签/简介折叠、章节正倒序、已读标记、继续阅读 |
| 阅读 | 竖向连续长图（记忆页码）+ 横向翻页（TabView 分页）、上下话切换、章节进度条 |
| 资源管理 | 四列格子、启用开关、拖拽排序、编辑、删除、导入（含 Venera 一键导入）、导出、恢复内置 |

## 七、实现要点

- **同步阻塞的源引擎**：源脚本里 `get()` 是同步的，Swift 侧用 `DispatchSemaphore`
  把 `URLSession` 的回调转成同步返回。这样源作者不用理解事件循环，脚本也更好调试。
- **不用 WKWebView 跑源**：`JavaScriptCore` + 自研 HTML 解析器，冷启动快、无进程开销，
  也不需要处理 `evaluateJavaScript` 的异步回调。
- **图片防盗链**：`ImageCache` 下载时统一带 `Referer` + `Referrer-Policy: no-referrer-when-downgrade`，
  源里可用 `imageReferer` 或 `images()` 返回的 `referer` 覆盖。
- **零第三方依赖**：SQLite3 C API 直接封装，图片缓存自己写，方便 IPA 自签（不用解 SPM 依赖）。
- **Venera 源兼容**：Venera 用 QuickJS + 异步宿主，这里用 JavaScriptCore + 同步 HTTP 桥。
  `sendMessage()` 在兼容层里同步返回结果，源里的 `await` 会挂在微任务队列上，
  宿主用 `__pumpBegin` → 循环 `__vsDone()`（每次 eval 都会 drain 微任务队列）→ `__vsTake`
  把整条 async 链跑完，所以 Venera 源**一行都不用改**。HTML 解析全部在 JS 侧完成
  （宿主只交一棵 JSON 树，CSS 选择器、`:nth-child`、`+`/`~` 组合符都在 `VeneraLib` 里实现）。

## 八、已知限制

- 只做了 iOS 16+，用了部分 iOS 16 的新 API（`NavigationStack`、`.toolbar(.hidden)`）。
- 下载离线阅读的「下载」Tab 目前是占位页，只统计已缓存图片，不做整话打包。
- 会员 / 社群 / 评分是界面占位，没有接后端。
- 源调试没有独立控制台，出错信息走 Toast；需要详细日志时可在源里 `console.log`，
  Xcode 控制台会打印。

## 九、免责

本项目仅用于个人学习 iOS 开发与爬虫/解析技术。所有漫画内容的版权归各自权利人所有，
请勿用于任何商业用途，也不要以本项目分发任何受版权保护的内容。
