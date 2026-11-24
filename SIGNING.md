# IPA 打包与自签

本项目不发布二进制，你从源码构建出一个 **未签名 IPA**，再用任意自签工具装到自己的 iPhone 上。
下面每条命令都可以直接复制。

---

## 0. 构建未签名 IPA

```bash
cd MangaReader
xcodegen generate

xcodebuild \
  -project MangaReader.xcodeproj \
  -scheme MangaReader \
  -configuration Release \
  -sdk iphoneos \
  -derivedDataPath build/dd \
  -archivePath build/MangaReader.xcarchive \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  archive
```

打出 `Payload/` 结构：

```bash
cd build
rm -rf Payload MangaReader.ipa
mkdir Payload
cp -R MangaReader.xcarchive/Products/Applications/MangaReader.app Payload/
zip -qry MangaReader.ipa Payload
cd ..
ls -lh build/MangaReader.ipa
```

产物：`build/MangaReader.ipa`（约 2–4 MB）。

> 如果 `xcodebuild` 报 `No signing certificate "iOS Development" found`，
> 说明 `CODE_SIGNING_ALLOWED=NO` 没生效 —— 检查是否用了 `-workspace` 而不是 `-project`，
> 或者直接在 Xcode 里 Build 一次再看错误行。

---

## 1. 路线 A：Sideloadly（最简单，Win/Mac 都有）

适合：手上只有 Windows 电脑，iOS 16+。

1. 下载 Sideloadly（sideloadly.io），装好 iTunes（Windows 需要 Apple 驱动）。
2. iPhone 用数据线连电脑，信任这台电脑。
3. Sideloadly 里：
   - **IPA**：选 `build/MangaReader.ipa`
   - **Apple ID**：填你的 Apple ID（用于申请免费开发证书）
   - **Bundle ID**：改成唯一的，比如 `com.你的名字.manga`
4. 点 Start，输入 Apple ID 密码（会走 2FA，用 App 专用密码）。
5. 手机上：设置 → 通用 → VPN与设备管理 → 信任你的开发者证书。
6. 打开 App。

**限制**：免费 Apple ID 签的 App **7 天过期**，到期重签一次（数据保留，重签覆盖安装即可）。

---

## 2. 路线 B：AltStore / SideStore（自动续签）

适合：不想每 7 天手动重签。

1. 电脑装 AltServer，手机装 AltStore（或 SideStore，免电脑续签）。
2. AltStore → My Apps → 左上角 `+` → 选 `MangaReader.ipa`。
3. 填 Apple ID，安装完成后在「设置 → 通用 → VPN与设备管理」信任证书。
4. AltStore 会在同一 Wi-Fi 下自动续签（需要 AltServer 在电脑上常驻）；
   SideStore 用 WireGuard 本地 VPN 实现无电脑续签。

**注意**：AltStore 免费账号最多同时装 3 个 App，且每个 App 有 10 个 App ID 上限。

---

## 3. 路线 C：TrollStore（永久签名）

适合：iOS 14.0 – 16.6.1 / 17.0（依赖 CoreTrust 漏洞），装完不过期、不用电脑。

1. 按 TrollStore 官网（github.com/opa334/TrollStore）的安装指引装好 TrollStore。
2. 把 `MangaReader.ipa` 传到手机（AirDrop / 文件 App / 网盘）。
3. TrollStore → `+` → 选 IPA → Install。
4. 直接打开，永久有效。

> 这条路线不需要 Apple ID，也不会 7 天过期，是本项目最推荐的用法。
> 如果你的系统版本不在支持范围，用路线 A 或 B。

---

## 4. 路线 D：自有证书（企业证书 / 开发者证书）

适合：有 99 美元开发者账号，或手上已有可用的企业证书 + 描述文件。

```bash
# 1) 用证书重签（需要 ldid 或 codesign）
#    先解包
unzip -o build/MangaReader.ipa -d build/unsigned

# 2) 替换描述文件
cp YourProfile.mobileprovision \
   build/unsigned/Payload/MangaReader.app/embedded.mobileprovision

# 3) 改 Bundle ID（如果描述文件不匹配）
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.your.company.manga" \
   build/unsigned/Payload/MangaReader.app/Info.plist

# 4) 用 ldid 签名（越狱设备 / TrollStore 环境常用）
ldid -SYourEntitlements.plist \
   build/unsigned/Payload/MangaReader.app/MangaReader

# 5) 重新打包
cd build/unsigned && zip -qry ../MangaReader-signed.ipa Payload
```

图形化工具：**ESign**、**轻松签**、**全能签** 都可以直接导入 IPA + 证书 + 描述文件一键签。

---

## 5. 常见问题

**Q：装完打开闪退**
A：99% 是没信任证书。设置 → 通用 → VPN与设备管理 → 开发者 App → 信任。
仍有问题就看 Xcode → Devices → Open Console 抓崩溃日志。

**Q：提示 "Unable to Install，此 App 的 Bundle ID 已被使用"**
A：换个 Bundle ID。Sideloadly / AltStore 里都有这个输入框，改成
`com.你的名字.manga.reader` 这种唯一值即可。也可以在 `project.yml` 里改
`PRODUCT_BUNDLE_IDENTIFIER` 后重新构建。

**Q：7 天后打不开**
A：免费证书过期。用同一个工具重装一次 IPA 即可，**不要先删 App**，覆盖安装数据不丢。

**Q：iCloud 备份用不了**
A：本项目用的是 `ubiquityContainerIdentifier: nil`，也就是 App 自己的 iCloud 容器。
自签 App 通常没有 iCloud 权限，此时备份会自动落到本机 `Documents/`，
在「文件」App → 我的 iPhone → 漫阅 里能看到 `MangaReader-*.json`，手动导出即可。

**Q：网络请求全失败**
A：`Info.plist` 已经开了 `NSAllowsArbitraryLoads`。如果仍然失败，
检查是否开了代理/VPN 且证书被拦；另外部分源站在国内需要代理。

**Q：能不能上架 App Store？**
A：不能。App 本身不含内容，但「可导入任意第三方源」这一条就过不了审核。
本项目定位是自己签自己用。
