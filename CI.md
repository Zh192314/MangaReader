# 用 GitHub Actions 云编译出 IPA

本机不用装 Xcode，也不用 Mac。把仓库推到 GitHub，runner 会自动编译并给你一个 `.ipa`。

流水线定义在 `.github/workflows/build.yml`，三条触发线：

| 触发 | 产出 | 谁需要 |
|---|---|---|
| push 到 `main` / `master` | artifact：`MangaReader-unsigned-ipa`（需登录 GitHub 下载，保留 30 天） | 日常改代码 |
| 打 tag `v1.4.0` | Release 附件：`MangaReader-unsigned.ipa`（**不用登录就能下**） | 想要稳定下载链接 |
| Actions 页面 → Run workflow | 同 push | 手动重跑 |

流水线同时支持两种仓库布局：`project.yml` 在仓库根，或在 `MangaReader/` 下，脚本会自动定位。

---

## 一、第一次推上去（3 条命令）

```bash
cd MangaReader

git init -b main
git add -A
git commit -m "feat: 漫阅 MangaReader —— Venera 源兼容版"
```

然后建仓库。两种方式选一个：

**A. 有 GitHub CLI（推荐）**

```bash
gh auth login
gh repo create MangaReader --private --source=. --push
```

**B. 没有 CLI** —— 先到 <https://github.com/new> 建一个空仓库（不要勾 README / .gitignore），然后：

```bash
git remote add origin https://github.com/<你的用户名>/MangaReader.git
git push -u origin main
```

推完打开仓库的 **Actions** 标签，`Build IPA` 会自己开始跑，大约 5–8 分钟（大头是 `brew install xcodegen` 和首次编译）。

---

## 二、把 ipa 拿到手

### 方式 1：Release（推荐，不登录也能下）

```bash
git tag v1.4.0
git push origin v1.4.0
```

跑完去仓库的 **Releases** 页面，`MangaReader-unsigned.ipa` 直接点下载。

### 方式 2：artifact

Actions → 点进最近一次成功的 run → 页面底部 **Artifacts** → `MangaReader-unsigned-ipa`。
私有仓库需要登录 GitHub 才能下。

---

## 三、装到 iPhone 上

产物是**未签名** ipa，三条路：

| 工具 | 用法 |
|---|---|
| **TrollStore**（iOS 14.0–16.6.1 / 17.0） | 直接把 ipa 拖进 TrollStore 或点「Install IPA」，装完长期有效，不会掉签 |
| **Sideloadly**（Win / Mac） | 拖入 ipa → 填 Apple ID → Start，自动重签并安装；免费账号 7 天有效，到期重装覆盖即可（数据不丢） |
| **AltStore / SideStore** | 同上，走 AltServer 或配对文件，支持后台自动续签 |

细节见 `SIGNING.md`。

---

## 四、可选：让 CI 直接签出能装的 ipa

如果你有付费开发者账号（或想用免费账号签 7 天版），可以配 6 个 Secrets，让 CI 产出**已签名**的 ipa。

### 1. 准备三样东西

**a. 证书 `.p12`**
钥匙串 → 登录 → 我的证书 → 找到 `Apple Development: xxx` → 右键导出 → 存为 `.p12`，设一个密码（记下来，后面要用）。

**b. 描述文件 `.mobileprovision`**
<https://developer.apple.com/account/resources/profiles> → 新建 iOS App Development → 选 App ID（Bundle ID 要和工程一致，默认 `com.yg.manga.reader`）→ 选证书 → 选设备 → 下载。

**c. Team ID**
<https://developer.apple.com/account> → Membership → Team ID（10 位，形如 `A1B2C3D4E5`）。

### 2. 转成 base64

macOS / Linux：
```bash
base64 -i cert.p12        | tr -d '\n' > cert.b64
base64 -i profile.mobileprovision | tr -d '\n' > profile.b64
```

Windows PowerShell：
```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("cert.p12"))        | Set-Content cert.b64 -NoNewline
[Convert]::ToBase64String([IO.File]::ReadAllBytes("profile.mobileprovision")) | Set-Content profile.b64 -NoNewline
```

### 3. 填进仓库

**Settings → Secrets and variables → Actions**

Secrets 页加 6 条：

| 名称 | 内容 |
|---|---|
| `BUILD_CERTIFICATE_BASE64` | `cert.b64` 的内容 |
| `P12_PASSWORD` | 导出 p12 时设的密码 |
| `PROVISIONING_PROFILE_BASE64` | `profile.b64` 的内容 |
| `KEYCHAIN_PASSWORD` | 随便编一个，CI 临时钥匙串用（如 `manga-ci-2026`） |
| `APPLE_TEAM_ID` | 你的 Team ID |
| `APP_BUNDLE_ID` | 如 `com.yg.manga.reader`（要和描述文件的 App ID 一致） |

Variables 页加 1 条：

| 名称 | 值 |
|---|---|
| `ENABLE_SIGNING` | `true` |

下次 push，就会多出一个 job `Signed IPA (optional)`，产物是 `MangaReader-signed-ipa`，**装的时候不用再签**。

> 证书别提交进仓库。只走 Secrets。

---

## 五、可能踩的坑

| 现象 | 原因 / 处理 |
|---|---|
| `找不到 project.yml` | 仓库根和 `MangaReader/` 下都没有。检查是不是把整个 workspace 推上去了，且漏了子目录 |
| `xcodegen: command not found` | brew 那步失败了，重跑一次；或本地先 `xcodegen generate` 把 `.xcodeproj` 一起提交 |
| archive 报 `no applicable content for AppIcon` | 图标丢了。`Resources/Assets.xcassets/AppIcon.appiconset/Icon-1024.png` 必须在仓库里 |
| 编译过但启动黑屏 | `Info.plist` 里 `UILaunchScreen` 的 `UIColorName` 要能在 Assets 里找到 `LaunchBg` 颜色 |
| 装上去闪退 | 没在 设置 → 通用 → VPN与设备管理 里信任证书（自签才有这一步） |
| 签名 job 报 `No signing certificate "iOS Development" found` | Secrets 里的 p12 类型与 `CODE_SIGN_IDENTITY` 不匹配；免费账号用 `Apple Development`，付费分发用 `Apple Distribution` |
| 下载的 ipa 只有几十 KB | artifact 里可能是 zip 套壳，解压后才是 ipa；Release 附件不会有这个问题 |

---

## 六、不用 GitHub 的话

`build.sh` 就是同一套命令的本地版（要求 macOS + Xcode 15+ + xcodegen）：

```bash
bash build.sh          # → build/MangaReader.ipa
```

CI 里的 `unsigned` job 与它逐步对应，任何一步在本机失败，都能在对应的 step 名上找到。
