#!/bin/bash
# 用法: publish-release.sh vX.Y.Z  打包并发布到 GitHub Release (需 GH_TOKEN 具备 contents 写权限)
set -euo pipefail

tag="${1:?usage: publish-release.sh vX.Y.Z}"
project_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
repo="${GITHUB_REPOSITORY:-yigegongjiang/jj-git}"
version="$(awk -F' *= *' '$1 == "MARKETING_VERSION" { print $2 }' "$project_dir/version.xcconfig")"

cd "$project_dir"
[ "$tag" = "v$version" ] || { echo "tag $tag != v$version (version.xcconfig)" >&2; exit 1; }
git fetch --quiet origin master
git merge-base --is-ancestor "$tag^{commit}" origin/master || { echo "$tag is not on master" >&2; exit 1; }

zip_path="$(./scripts/package.sh)"
notes="$(dirname "$zip_path")/release-notes.md"
{
  awk -v header="## [$version]" 'index($0, header) == 1 { found = 1; next } found && /^## \[/ { exit } found' CHANGELOG.md
  cat <<'NOTES'

### 安装

未经 Apple 公证 (ad-hoc 签名)，解压后移至 `/Applications` 并移除隔离属性：

```bash
xattr -dr com.apple.quarantine /Applications/jj-git.app
```
NOTES
} >"$notes"

if gh release view "$tag" -R "$repo" >/dev/null 2>&1; then
  gh release upload "$tag" "$zip_path" --clobber -R "$repo"
  gh release edit "$tag" --notes-file "$notes" -R "$repo"
else
  gh release create "$tag" "$zip_path" --verify-tag --title "$tag" --notes-file "$notes" -R "$repo"
fi
