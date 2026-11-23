#!/bin/zsh
# 构建 Release 并打包成 DMG（含 /Applications 拖拽安装链接）
set -eu
cd "$(dirname "$0")"

APP_NAME="V2raya Control"
VERSION="${1:-1.0}"
BUILD_DIR=".build/dmg"
VOL="${APP_NAME}-${VERSION}"
OUT="dist/${VOL}.dmg"

# 1. 构建（中立 DerivedData，避免 iCloud 目录污染签名）
rm -rf /tmp/v2raya-dd-dmg
xcodebuild -project V2rayaControlWidget.xcodeproj \
  -scheme V2rayaControlWidget -configuration Release \
  -derivedDataPath /tmp/v2raya-dd-dmg build 2>&1 | grep -E 'error:|BUILD' || true
[ -d "/tmp/v2raya-dd-dmg/Build/Products/Release/${APP_NAME}.app" ] || { echo "构建失败"; exit 1; }

# 2. 组装 DMG 源目录
rm -rf "$BUILD_DIR" && mkdir -p "$BUILD_DIR/dmg" dist
cp -R "/tmp/v2raya-dd-dmg/Build/Products/Release/${APP_NAME}.app" "$BUILD_DIR/dmg/"
# 去除 iCloud 隔离属性
xattr -cr "$BUILD_DIR/dmg/${APP_NAME}.app"
ln -sf /Applications "$BUILD_DIR/dmg/Applications"

# 3. 生成 DMG
rm -f "$OUT"
hdiutil create -volname "$VOL" \
  -srcfolder "$BUILD_DIR/dmg" \
  -ov -format UDZO \
  "$OUT"

# 4. 校验
hdiutil verify "$OUT" | tail -2
echo
echo "✔ DMG 已生成: $(pwd)/$OUT ($(du -h "$OUT" | cut -f1))"
echo "   安装方式：双击打开 → 把 ${APP_NAME}.app 拖入 Applications 文件夹"
