#!/usr/bin/env bash
# 打包 cswap.app（只需 Command Line Tools）。用法：
#   tools/package.sh            在仓库根目录生成 cswap.app
#   tools/package.sh install    生成后安装到 /Applications/cswap.app（会先退出正在运行的 cswap 菜单栏）
#   tools/package.sh release    发布：要求工作区干净、CHANGELOG.md 有本版本一节，打 v<版本> 标签并推送；
#                               推送标签后由 CI（.github/workflows/release.yml）打包、签名、发 GitHub Release
#   tools/package.sh dist       生成 dist/cswap-<版本>.zip（CI 用；App 内更新按这个文件名找安装包）
#
# 环境变量 CSWAP_REQUIRE_CERT=1：钥匙串里没有证书就失败，不退回临时签名（CI 必须带：临时签名的包装不上自动更新）
#
# 签名：钥匙串里有「cswap Code Signing」证书就用它（通知权限等随签名身份保存，固定证书重装后不丢）；
# 没有则退回临时签名（ad-hoc）并提示。可用环境变量 CSWAP_SIGN_ID 指定别的证书名。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")"/.. && pwd)"
MODE="${1:-}"
APP="$ROOT/cswap.app"
# 版本号与介绍的唯一来源：Sources/CswapCore/Version.swift；构建号 = 提交数，同一版本的不同构建靠它区分
VERSION_FILE="$ROOT/Sources/CswapCore/Version.swift"
VERSION="$(sed -n 's/.*static let current = "\(.*\)".*/\1/p' "$VERSION_FILE")"
TAGLINE="$(sed -n 's/.*static let tagline = "\(.*\)".*/\1/p' "$VERSION_FILE")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "✗ 版本号格式不对：「${VERSION}」（应为 0.1.0 这样的三位）"; exit 1; }
BUILD="$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 0)"
[ "$BUILD" -gt 0 ] 2>/dev/null || BUILD=1

cd "$ROOT"
# 发布：工作区必须干净（包里的就是某个提交），并打 v<版本> 标签；标签已在别的提交上 = 改了代码却忘了改版本号
if [ "$MODE" = release ]; then
  [ -z "$(git status --porcelain)" ] || { echo "✗ 有未提交的改动，先提交再打发布包"; exit 1; }
  TAG="v${VERSION}"
  if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
    [ "$(git rev-list -n 1 "${TAG}")" = "$(git rev-parse HEAD)" ] \
      || { echo "✗ ${TAG} 已经发布过（在别的提交上）：先在 Version.swift 改版本号、CHANGELOG.md 记一笔"; exit 1; }
  else
    grep -q "^## ${VERSION} " CHANGELOG.md || { echo "✗ CHANGELOG.md 里没有 ${VERSION} 这一节"; exit 1; }
  fi
  git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null || git tag -a "${TAG}" -m "cswap ${VERSION}"
  git push origin "${TAG}"
  echo "已推送标签 ${TAG}：CI 会打包并发布到 GitHub Release（gh run watch 可看进度）"
  exit 0
fi
swift build -c release --product cswap-app
BIN="$(swift build -c release --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/cswap-app" "$APP/Contents/MacOS/cswap"
# SwiftPM 资源包放进 Contents/Resources（代码里先找这里；放包根目录会破坏签名）
cp -R "$BIN/cswap_CswapUI.bundle" "$APP/Contents/Resources/"
# 设置页「更新日志」读它
cp CHANGELOG.md "$APP/Contents/Resources/CHANGELOG.md"

# App 图标：由 assets/claude-icon-2048-bright.png 生成各尺寸
ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s assets/claude-icon-2048-bright.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) assets/claude-icon-2048-bright.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>cswap</string>
    <key>CFBundleDisplayName</key><string>cswap</string>
    <key>CFBundleIdentifier</key><string>com.eric.cswap</string>
    <key>CFBundleExecutable</key><string>cswap</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
    <key>LSUIElement</key><true/>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>CFBundleGetInfoString</key><string>$TAGLINE</string>
    <key>NSHumanReadableCopyright</key><string>$TAGLINE</string>
</dict>
</plist>
PLIST

SIGN_ID="${CSWAP_SIGN_ID:-cswap Code Signing}"
if [[ "$(security find-identity -p codesigning 2>/dev/null)" == *"\"${SIGN_ID}\""* ]]; then
  codesign --force --options runtime --sign "$SIGN_ID" "$APP" >/dev/null
  SIGNED="证书「${SIGN_ID}」"
else
  [ "${CSWAP_REQUIRE_CERT:-}" = 1 ] && { echo "✗ 钥匙串里没有「${SIGN_ID}」证书（CSWAP_REQUIRE_CERT=1）"; exit 1; }
  codesign --force --sign - "$APP" >/dev/null
  SIGNED="临时签名（钥匙串里没有「${SIGN_ID}」；通知权限可能在每次重装后要重新允许）"
fi
codesign --verify --strict "$APP"
echo "已打包：${APP}（版本 ${VERSION}，构建 ${BUILD}，$(du -sh "$APP" | cut -f1)，${SIGNED}）"

case "$MODE" in
  install)
    pkill -f "/Applications/cswap.app/Contents/MacOS/cswap" 2>/dev/null && sleep 1 || true
    rm -rf /Applications/cswap.app
    ditto "$APP" /Applications/cswap.app
    echo "已安装到 /Applications/cswap.app"
    open /Applications/cswap.app ;;
  dist)
    mkdir -p "$ROOT/dist"
    ZIP="$ROOT/dist/cswap-${VERSION}.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "安装包：${ZIP}（$(du -h "$ZIP" | cut -f1)）" ;;
  "") ;;
  *) echo "用法：tools/package.sh [install|release|dist]"; exit 2 ;;
esac
