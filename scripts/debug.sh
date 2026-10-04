#!/bin/bash
set -euo pipefail

# 用固定 Team 签名: TCC 按证书识别 App, 重新编译后「文稿」等授权不失效。
if [[ $# -ne 1 || -z "$1" ]]; then
  echo "用法: $0 <DEVELOPMENT_TEAM>" >&2
  exit 64
fi
team="$1"

project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
built_app="$project_dir/build/Build/Products/Debug/jj-git Debug.app"
bundle_id="com.yigegongjiang.jj-git.debug"

cd "$project_dir"
xcodebuild -project jj-git.xcodeproj -scheme jj-git \
  -configuration Debug -derivedDataPath build -destination 'platform=macOS' \
  CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development" DEVELOPMENT_TEAM="$team" \
  build

# 旧进程仍在时 open 只会激活它, 新二进制不会运行。
osascript - "$bundle_id" <<'APPLESCRIPT'
on run argv
    set bundleID to item 1 of argv
    if application id bundleID is running then
        tell application id bundleID to quit
        repeat 50 times
            if application id bundleID is not running then return
            delay 0.1
        end repeat
        error "jj-git Debug did not quit."
    end if
end run
APPLESCRIPT

open "$built_app"
