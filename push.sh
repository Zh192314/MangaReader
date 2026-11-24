#!/usr/bin/env bash
#
# 漫阅 · 把工程推到 GitHub，触发云端编译出 IPA
#
# 用法：
#   bash push.sh                                  # 有 gh CLI：自动建仓并推
#   bash push.sh git@github.com:you/MangaReader.git   # 指定已有仓库
#   bash push.sh https://github.com/you/MangaReader.git
#
# 推完去仓库的 Actions 页面看进度（约 5-8 分钟）；
# 想直接下 ipa（免登录）就再打个 tag：
#   git tag v1.4.0 && git push origin v1.4.0
#
set -euo pipefail
cd "$(dirname "$0")"

REMOTE="${1:-}"
REPO_NAME="${REPO_NAME:-MangaReader}"

echo "==> 检查 git"
command -v git >/dev/null 2>&1 || { echo "没装 git。"; exit 1; }

if [ ! -d .git ]; then
  echo "==> 初始化仓库"
  git init -b main
else
  echo "==> 已有仓库，沿用当前配置"
  # 确保分支名是 main
  git symbolic-ref -q HEAD >/dev/null || git checkout -b main 2>/dev/null || true
fi

echo "==> 检查有没有东西可提交"
if ! git diff --quiet || ! git diff --cached --quiet || [ -z "$(git rev-parse HEAD 2>/dev/null)" ]; then
  echo "==> 提交"
  git add -A
  # 允许空提交，避免重复运行时报错
  git commit -m "feat: 漫阅 MangaReader —— Venera 源兼容版" --allow-empty
else
  echo "    没有改动，跳过提交"
fi

echo "==> 确认关键文件都在版本控制里"
for f in project.yml build.sh Resources/Info.plist \
         Resources/Assets.xcassets/AppIcon.appiconset/Icon-1024.png \
         .github/workflows/build.yml; do
  if git ls-files --error-unmatch "$f" >/dev/null 2>&1; then
    echo "    ok  $f"
  else
    echo "    !!  $f 没被提交，CI 会失败"
  fi
done

if [ -n "$REMOTE" ]; then
  echo "==> 设置 remote: $REMOTE"
  if git remote get-url origin >/dev/null 2>&1; then
    git remote set-url origin "$REMOTE"
  else
    git remote add origin "$REMOTE"
  fi
  echo "==> 推送"
  git push -u origin main
elif command -v gh >/dev/null 2>&1; then
  echo "==> 用 gh 建仓库并推送（私有仓库）"
  gh repo create "$REPO_NAME" --private --source=. --remote=origin --push
else
  echo ""
  echo "没检测到 gh CLI，也没有指定 remote。手动两步："
  echo "  1) 打开 https://github.com/new 建一个空仓库（不要勾 README）"
  echo "  2) bash push.sh https://github.com/<你的用户名>/${REPO_NAME}.git"
  exit 0
fi

echo ""
echo "==> 完成。接下来："
echo "    · Actions 页面看构建：https://github.com/$(git remote get-url origin | sed -E 's#.*[:/]([^/]+/[^/]+)(\.git)?$#\1#')/actions"
echo "    · 想要免登录下载链接：git tag v1.4.0 && git push origin v1.4.0"
echo "    · 之后每次改代码只要 git push，CI 会自己重编"
