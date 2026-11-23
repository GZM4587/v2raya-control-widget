#!/bin/zsh
# 构建 V2rayA Control.app 并安装到 /Applications
set -eu
cd "$(dirname "$0")"

APP_NAME="V2raya Control"
OUT_DIR=".build/app"
DERIVED="$OUT_DIR/DerivedData"

xcodebuild \
  -project V2rayaControlWidget.xcodeproj \
  -scheme V2rayaControlWidget \
  -configuration Release \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_ENTITLEMENTS="" \
  build

APP=$(find "$DERIVED/Build/Products/Release" -maxdepth 1 -name "*.app" | head -1)
if [ -z "$APP" ]; then
  echo "error: no .app produced" >&2; exit 1
fi

rm -rf "/Applications/$APP_NAME.app"
cp -R "$APP" "/Applications/$APP_NAME.app"

# 重新 ad-hoc 签名（拷贝后保持有效）
codesign --force --deep --sign - "/Applications/$APP_NAME.app" 2>/dev/null || true
xattr -dr com.apple.quarantine "/Applications/$APP_NAME.app" 2>/dev/null || true

echo
echo "✔ 已安装: /Applications/$APP_NAME.app"
open "/Applications/$APP_NAME.app"
echo "请在屏幕右上角菜单栏找 ⚡ 图标（不在桌面小组件库里）"
