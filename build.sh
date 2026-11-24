#!/usr/bin/env bash
#
# 漫阅 · 一键构建未签名 IPA（在 macOS 上运行）
#   用法：bash build.sh
#   产物：build/MangaReader.ipa（未签名，交给 Sideloadly / AltStore 签名安装）
#
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="MangaReader"
SCHEME="MangaReader"
CONFIG="Release"
BUILD_DIR="build"

echo "==> 检查依赖"
command -v xcodebuild >/dev/null 2>&1 || { echo "找不到 xcodebuild，请先安装 Xcode"; exit 1; }
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "找不到 xcodegen，执行：brew install xcodegen"
  exit 1
fi

echo "==> 生成 Xcode 工程"
xcodegen generate

echo "==> 编译（Release / iphoneos / 不签名）"
xcodebuild \
  -project "${APP_NAME}.xcodeproj" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIG}" \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "${BUILD_DIR}/dd" \
  -archivePath "${BUILD_DIR}/${APP_NAME}.xcarchive" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  archive

APP="${BUILD_DIR}/${APP_NAME}.xcarchive/Products/Applications/${APP_NAME}.app"
if [ ! -d "${APP}" ]; then
  echo "编译产物不存在：${APP}"
  exit 1
fi

echo "==> 打包 Payload"
rm -rf "${BUILD_DIR}/Payload" "${BUILD_DIR}/${APP_NAME}.ipa"
mkdir -p "${BUILD_DIR}/Payload"
cp -R "${APP}" "${BUILD_DIR}/Payload/"
( cd "${BUILD_DIR}" && zip -qry "${APP_NAME}.ipa" Payload )

SIZE=$(du -h "${BUILD_DIR}/${APP_NAME}.ipa" | cut -f1)
echo ""
echo "构建完成：${BUILD_DIR}/${APP_NAME}.ipa  (${SIZE})"
echo "下一步：用 Sideloadly / AltStore 导入这个 ipa，填自己的 Apple ID 签名安装。"
echo "详见 SIGNING.md。"
