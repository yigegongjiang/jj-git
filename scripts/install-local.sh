#!/bin/bash
set -euo pipefail

team="${1:?用法: $0 <DEVELOPMENT_TEAM>}"

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
built_app="$project_dir/build/Build/Products/Release/jj-git.app"
installed_app="/Applications/jj-git.app"

cd "$project_dir"
xcodebuild -project jj-git.xcodeproj -scheme jj-git \
  -configuration Release -derivedDataPath build -destination 'platform=macOS' \
  CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM="$team" \
  build

# 构建 / 产物检查失败时保留旧版。
test -x "$built_app/Contents/MacOS/jj-git"
codesign --verify --strict "$built_app"

quit_app() {
  osascript <<'APPLESCRIPT'
if application id "com.yigegongjiang.jj-git" is running then
    tell application id "com.yigegongjiang.jj-git" to quit
    repeat 50 times
        if application id "com.yigegongjiang.jj-git" is not running then return
        delay 0.1
    end repeat
    error "jj-git did not quit."
end if
APPLESCRIPT
}

quit_app

rm -rf -- "$installed_app"
ditto "$built_app" "$installed_app"
codesign --verify --strict "$installed_app"
trap quit_app EXIT
open -g "$installed_app"
osascript <<'APPLESCRIPT'
repeat 50 times
    if application id "com.yigegongjiang.jj-git" is running then
        tell application id "com.yigegongjiang.jj-git" to get version
        return
    end if
    delay 0.1
end repeat
error "jj-git did not start."
APPLESCRIPT
quit_app
trap - EXIT
printf '已安装并验证启动，App 已退出: %s\n' "$installed_app"
