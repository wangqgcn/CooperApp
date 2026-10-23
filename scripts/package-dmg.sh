#!/bin/bash
# Build a signed universal Release, or package an explicitly supplied existing app.
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
cd "$project_dir"
mkdir -p .build output/releases

if [ "$#" -gt 1 ]; then
    echo "Usage: $0 [path-to-Cooper.app]" >&2
    exit 1
fi

if [ "$#" -eq 1 ]; then
    app_path="$1"
else
    xcodegen generate
    xcodebuild -project Cooper.xcodeproj -scheme Cooper -configuration Release \
        -destination 'generic/platform=macOS' -derivedDataPath .build/dmg-release \
        ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO build \
        > .build/dmg-release-build.log 2>&1 || {
            tail -n 60 .build/dmg-release-build.log >&2
            exit 1
        }
    app_path="$project_dir/.build/dmg-release/Build/Products/Release/Cooper.app"
fi

app_path="$(cd "$app_path" && pwd)"
codesign --verify --deep --strict "$app_path"
extension_path="$app_path/Contents/PlugIns/CooperFileProvider.appex"
codesign --verify --strict "$extension_path"

version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app_path/Contents/Info.plist")
architectures=$(lipo -archs "$app_path/Contents/MacOS/Cooper")
case "$architectures" in
    *arm64*x86_64*|*x86_64*arm64*) platform="universal" ;;
    arm64|x86_64) platform="$architectures" ;;
    *) echo "Unsupported architectures: $architectures" >&2; exit 1 ;;
esac

# 文件名固定，每次打包替换上一次的产物；版本和架构写在校验文件旁的说明里
dmg_path="$project_dir/output/releases/Cooper-macOS.dmg"
if [ -e "$dmg_path" ]; then
    echo "Replacing existing package: $dmg_path"
    rm -f "$dmg_path" "$dmg_path.sha256"
fi

staging_dir=$(mktemp -d "$project_dir/.build/dmg-stage.XXXXXX")
mount_dir=$(mktemp -d "$project_dir/.build/dmg-check.XXXXXX")
mounted=0
cleanup() {
    if [ "$mounted" -eq 1 ]; then
        hdiutil detach "$mount_dir" -quiet || return
    fi
    rm -rf "$staging_dir" "$mount_dir"
}
trap cleanup EXIT

ditto "$app_path" "$staging_dir/Cooper.app"
ln -s /Applications "$staging_dir/Applications"
cat > "$staging_dir/安装说明.txt" <<'EOF'
Cooper — 云存储接入 Finder

1. 把 Cooper.app 拖到 Applications（应用程序）文件夹。
2. 从“应用程序”打开 Cooper。
3. 在首页点“添加存储桶”，选择服务商并填写访问信息，测试连接后添加。

系统要求：macOS 14 或更高版本。
应用需要放在“应用程序”文件夹中，以便系统发现 File Provider 扩展。

此脚本仅制作 DMG，不执行 Apple 公证，也不改变应用原有签名。
使用 Apple Development 签名的构建用于已配置的开发设备，不是公开分发版本。
EOF

hdiutil create -volname Cooper -srcfolder "$staging_dir" -format UDZO \
    -imagekey zlib-level=9 "$dmg_path"
hdiutil verify "$dmg_path"
hdiutil attach "$dmg_path" -readonly -nobrowse -mountpoint "$mount_dir" -quiet
mounted=1
test -L "$mount_dir/Applications"
test "$(readlink "$mount_dir/Applications")" = /Applications
test -f "$mount_dir/Cooper.app/Contents/Resources/AppIcon.icns"
test -f "$mount_dir/Cooper.app/Contents/Resources/Assets.car"
codesign --verify --deep --strict "$mount_dir/Cooper.app"
codesign --verify --strict "$mount_dir/Cooper.app/Contents/PlugIns/CooperFileProvider.appex"
hdiutil detach "$mount_dir" -quiet
mounted=0

package_name=$(basename "$dmg_path")
(cd "$project_dir/output/releases" && shasum -a 256 "$package_name" > "$package_name.sha256")
echo "DMG ready: $dmg_path (version $version, $platform)"
