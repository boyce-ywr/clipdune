#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mode="${1:-prepare}"
case "$mode" in prepare|draft|publish) ;; *) echo "用法：$0 [prepare|draft|publish]" >&2; exit 2 ;; esac
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
key="${CLIPDUNE_UPDATE_PRIVATE_KEY:-$HOME/Library/Application Support/ClipDune Publisher/signing.key}"
if [[ ! -f "$key" ]]; then echo '更新签名私钥缺失，禁止临时换钥发布。' >&2; exit 1; fi
swift run ClipDuneChecks
if [[ "$mode" == publish ]]; then CLIPDUNE_UI_CONFIGURATION=release bash scripts/check-ui.sh bundle; fi
bash scripts/build.sh release
directory="$PWD/dist/release-$version"
mkdir -p "$directory"
archive="$directory/ClipDune-$version-macOS.zip"
if [[ -f "$archive" ]]; then rm "$archive"; fi
COPYFILE_DISABLE=1 /usr/bin/ditto -c -k --norsrc --keepParent dist/ClipDune.app "$archive"
architectures="$(lipo -archs dist/ClipDune.app/Contents/MacOS/ClipDune | tr ' ' ',')"
swift run ClipDuneReleaseTool sign --archive "$archive" --app dist/ClipDune.app --private-key "$key" \
    --notes "docs/releases/$version.md" --architectures "$architectures" --output "$directory/clipdune-update.json"
swift run ClipDuneReleaseTool verify --archive "$archive" --manifest "$directory/clipdune-update.json" --public-key Resources/UpdatePublicKey.txt
if [[ "$mode" == draft || "$mode" == publish ]]; then
    [[ -z "$(git status --porcelain)" ]] || { echo '工作区不干净，先提交并推送。' >&2; exit 1; }
    export HTTPS_PROXY="${HTTPS_PROXY:-http://127.0.0.1:7897}" HTTP_PROXY="${HTTP_PROXY:-http://127.0.0.1:7897}"
    [[ "$(gh api repos/boyce-ywr/clipdune --jq .private)" == true ]] || { echo '仓库必须保持私有。' >&2; exit 1; }
    remote_commit="$(gh api repos/boyce-ywr/clipdune/git/ref/heads/main --jq .object.sha)"
    [[ "$remote_commit" == "$(git rev-parse HEAD)" ]] || { echo '远端 main 与本地不一致。' >&2; exit 1; }
    gh release create "v$version" "$archive" "$directory/clipdune-update.json" --repo boyce-ywr/clipdune \
        --target "$remote_commit" --title "ClipDune $version" --notes-file "docs/releases/$version.md" --draft
    release_id="$(gh release view "v$version" --repo boyce-ywr/clipdune --json databaseId --jq .databaseId)"
    verification="$(mktemp -d /tmp/clipdune-release-verify.XXXXXX)"
    trap 'rm -rf "$verification"' EXIT
    binary_directory="$(swift build --show-bin-path)"
    gh auth token | "$binary_directory/ClipDuneReleaseTool" check-feed --release-id "$release_id" \
        --public-key Resources/UpdatePublicKey.txt --output "$verification"
    if [[ "$mode" == publish ]]; then gh release edit "v$version" --repo boyce-ywr/clipdune --draft=false --latest; fi
fi
printf '已生成签名更新包：%s\n' "$directory"
