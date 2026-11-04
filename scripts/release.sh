#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mode="${1:-prepare}"
case "$mode" in prepare|draft|publish) ;; *) echo "用法：$0 [prepare|draft|publish]" >&2; exit 2 ;; esac
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
key="${CLIPDUNE_UPDATE_PRIVATE_KEY:-$HOME/Library/Application Support/ClipDune Publisher/signing.key}"
if [[ ! -f "$key" ]]; then echo '更新签名私钥缺失，禁止临时换钥发布。' >&2; exit 1; fi
workspace="$(mktemp -d /tmp/clipdune-package.XXXXXX)"
cleanup() {
    if [[ "$?" == 0 ]]; then rm -rf "$workspace"
    else printf '发布校验失败，保留诊断目录：%s\n' "$workspace" >&2
    fi
}
trap cleanup EXIT
swift run ClipDuneChecks
if [[ "$mode" == publish ]]; then CLIPDUNE_UI_CONFIGURATION=release CLIPDUNE_BUILD_ARCHITECTURE=universal bash scripts/check-ui.sh bundle; fi
bash scripts/build.sh release universal
directory="$PWD/dist/release-$version"
mkdir -p "$directory"
archive="$directory/ClipDune-$version-macOS.zip"
if [[ -f "$archive" ]]; then rm "$archive"; fi
COPYFILE_DISABLE=1 /usr/bin/ditto -c -k --norsrc --keepParent dist/ClipDune.app "$archive"
architectures="$(lipo -archs dist/ClipDune.app/Contents/MacOS/ClipDune | tr ' ' ',')"
swift run ClipDuneReleaseTool sign --archive "$archive" --app dist/ClipDune.app --private-key "$key" \
    --notes "docs/releases/$version.md" --architectures "$architectures" --output "$directory/clipdune-update.json"
swift run ClipDuneReleaseTool verify --archive "$archive" --manifest "$directory/clipdune-update.json" --public-key Resources/UpdatePublicKey.txt
disk_images=()
for architecture in arm64 x86_64; do
    staging="$workspace/$architecture"
    application="$staging/ClipDune.app"
    mkdir -p "$staging"
    ditto dist/ClipDune.app "$application"
    for executable in "$application/Contents/MacOS/ClipDune" "$application/Contents/Helpers/ClipDuneUpdateHelper"; do
        lipo "$executable" -thin "$architecture" -output "$executable.thin"
        chmod +x "$executable.thin"
        mv -f "$executable.thin" "$executable"
    done
    codesign --force --sign "${CLIPDUNE_SIGN_IDENTITY:--}" "$application/Contents/Helpers/ClipDuneUpdateHelper"
    codesign --force --sign "${CLIPDUNE_SIGN_IDENTITY:--}" --identifier com.github.boyce-ywr.clipdune "$application"
    ln -s /Applications "$staging/Applications"
    image="$directory/ClipDune-$version-macOS-$architecture.dmg"
    hdiutil create -volname "ClipDune $version $architecture" -srcfolder "$staging" -fs HFS+ -format UDZO -ov "$image"
    bash scripts/check-dmg.sh "$image" "$architecture"
    disk_images+=("$image")
done
if [[ "$mode" == publish ]]; then
    for architecture in arm64 x86_64; do
        bash scripts/check-dmg.sh "$directory/ClipDune-$version-macOS-$architecture.dmg" "$architecture" --smoke
    done
fi
(
    cd "$directory"
    shasum -a 256 "ClipDune-$version-macOS.zip" clipdune-update.json \
        "ClipDune-$version-macOS-arm64.dmg" "ClipDune-$version-macOS-x86_64.dmg" > SHA256SUMS.txt
)
if [[ "$mode" == draft || "$mode" == publish ]]; then
    [[ -z "$(git status --porcelain)" ]] || { echo '工作区不干净，先提交并推送。' >&2; exit 1; }
    export HTTPS_PROXY="${HTTPS_PROXY:-http://127.0.0.1:7897}" HTTP_PROXY="${HTTP_PROXY:-http://127.0.0.1:7897}"
    remote_commit="$(gh api repos/boyce-ywr/clipdune/git/ref/heads/main --jq .object.sha)"
    [[ "$remote_commit" == "$(git rev-parse HEAD)" ]] || { echo '远端 main 与本地不一致。' >&2; exit 1; }
    gh release create "v$version" "$archive" "$directory/clipdune-update.json" "${disk_images[@]}" "$directory/SHA256SUMS.txt" --repo boyce-ywr/clipdune \
        --target "$remote_commit" --title "ClipDune $version" --notes-file "docs/releases/$version.md" --draft
    release_id="$(gh release view "v$version" --repo boyce-ywr/clipdune --json databaseId --jq .databaseId)"
    verification="$workspace/verification"
    binary_directory="$(swift build --show-bin-path)"
    gh auth token | "$binary_directory/ClipDuneReleaseTool" check-feed --release-id "$release_id" \
        --public-key Resources/UpdatePublicKey.txt --output "$verification"
    gh release download "v$version" --repo boyce-ywr/clipdune --dir "$verification" --pattern '*.dmg' --pattern SHA256SUMS.txt
    cmp "$directory/SHA256SUMS.txt" "$verification/SHA256SUMS.txt"
    (cd "$verification" && shasum -a 256 -c SHA256SUMS.txt)
    for architecture in arm64 x86_64; do
        bash scripts/check-dmg.sh "$verification/ClipDune-$version-macOS-$architecture.dmg" "$architecture"
        if [[ "$mode" == publish ]]; then
            bash scripts/check-dmg.sh "$verification/ClipDune-$version-macOS-$architecture.dmg" "$architecture" --smoke
        fi
    done
    if [[ "$mode" == publish ]]; then gh release edit "v$version" --repo boyce-ywr/clipdune --draft=false --latest; fi
fi
printf '已生成双架构 DMG、Universal 签名更新包与校验文件：%s\n' "$directory"
