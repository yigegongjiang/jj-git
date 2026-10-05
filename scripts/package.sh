#!/bin/bash
# 用法: package.sh  构建 Release universal (ad-hoc 签名, 无需开发者账号) 并打包 zip, 输出 zip 路径
set -euo pipefail

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
derived_dir="$project_dir/build/package"
built_app="$derived_dir/Build/Products/Release/jj-git.app"
version="$(awk -F' *= *' '$1 == "MARKETING_VERSION" { print $2 }' "$project_dir/version.xcconfig")"
zip_path="$derived_dir/jj-git-$version-macos.zip"

cd "$project_dir"
rm -rf -- "$built_app" "$zip_path"
xcodebuild -project jj-git.xcodeproj -scheme jj-git \
  -configuration Release -derivedDataPath "$derived_dir" -destination 'generic/platform=macOS' \
  ONLY_ACTIVE_ARCH=NO build >&2

executable="$built_app/Contents/MacOS/jj-git"
test -x "$executable"
test -x "$built_app/Contents/Resources/jj-git-cli"
archs="$(lipo -archs "$executable")"
[[ " $archs " == *" arm64 "* && " $archs " == *" x86_64 "* ]] || { echo "unexpected archs: $archs" >&2; exit 1; }
bundle_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$built_app/Contents/Info.plist")"
[ "$bundle_version" = "$version" ] || { echo "version mismatch: $bundle_version != $version" >&2; exit 1; }
codesign --verify --strict --deep "$built_app"

# ditto 保留可执行位 / 符号链接 / 签名所需的扩展属性。
ditto -c -k --sequesterRsrc --keepParent "$built_app" "$zip_path"
echo "$zip_path"
