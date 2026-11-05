#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
image="${1:?用法：check-dmg.sh <镜像路径> <arm64|x86_64> [--smoke]}"
architecture="${2:?缺少预期架构}"
case "$architecture" in arm64|x86_64) ;; *) echo '只接受 arm64 或 x86_64。' >&2; exit 2 ;; esac
smoke="${3:-}"
case "$smoke" in ''|--smoke) ;; *) echo '第三个参数仅支持 --smoke。' >&2; exit 2 ;; esac
workspace="$(mktemp -d /tmp/clipdune-dmg-check.XXXXXX)"
mountpoint="$workspace/volume"
mounted=false
cleanup() {
    if [[ "$mounted" == true ]]; then
        for attempt in 1 2 3 4 5; do
            if hdiutil detach "$mountpoint" >/dev/null; then mounted=false; break; fi
            sleep 0.5
        done
        if [[ "$mounted" == true ]]; then
            printf '临时镜像卸载失败，请检查：%s\n' "$mountpoint" >&2
            return
        fi
    fi
    rm -rf "$workspace"
}
trap cleanup EXIT
mkdir -p "$mountpoint"
hdiutil verify "$image"
hdiutil attach -readonly -nobrowse -noautoopen -mountpoint "$mountpoint" "$image" >/dev/null
mounted=true
application="$mountpoint/ClipDune.app"
[[ -L "$mountpoint/Applications" && "$(readlink "$mountpoint/Applications")" == /Applications ]]
cmp Resources/Info.plist "$application/Contents/Info.plist"
cmp Resources/UpdatePublicKey.txt "$application/Contents/Resources/UpdatePublicKey.txt"
[[ -s "$application/Contents/Resources/AppIcon.icns" ]]
for executable in "$application/Contents/MacOS/ClipDune" "$application/Contents/Helpers/ClipDuneUpdateHelper"; do
    [[ -x "$executable" ]]
    actual="$(lipo -archs "$executable")"
    if [[ "$actual" != "$architecture" ]]; then
        printf '架构不匹配：预期 %s，实际 %s，文件 %s\n' "$architecture" "$actual" "$executable" >&2
        exit 1
    fi
done
codesign --verify --deep --strict "$application"
if [[ "$smoke" == --smoke && "$(uname -m)" == "$architecture" ]]; then
    # 本机终端安全软件可能间歇终止未在白名单的 ad-hoc 程序；必须有一次真实启动并输出图标才通过
    for attempt in 1 2 3; do
        if "$application/Contents/MacOS/ClipDune" --render-icon "$workspace/smoke.png" && [[ -s "$workspace/smoke.png" ]]; then break; fi
        if [[ "$attempt" == 3 ]]; then echo 'DMG 内应用启动检查连续 3 次失败。' >&2; exit 1; fi
        printf '启动检查第 %s 次失败，5 秒后重试\n' "$attempt" >&2
        sleep 5
    done
    printf 'PASS DMG 内应用本机架构启动与图标渲染：%s\n' "$architecture"
fi
printf 'PASS DMG 挂载、应用版本、安装入口、签名与单架构校验：%s\n' "$architecture"
