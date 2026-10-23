#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-debug}"
architecture="${2:-native}"
case "$configuration" in debug|release) ;; *) echo "用法：$0 [debug|release] [native|universal]" >&2; exit 2 ;; esac
build_options=(-c "$configuration")
case "$architecture" in
    native) ;;
    universal) build_options+=(--arch arm64 --arch x86_64) ;;
    *) echo "架构必须是 native 或 universal。" >&2; exit 2 ;;
esac
swift build "${build_options[@]}" --product ClipDune
swift build "${build_options[@]}" --product ClipDuneUpdateHelper
binary_directory="$(swift build "${build_options[@]}" --show-bin-path)"
application="$PWD/dist/ClipDune.app"
mkdir -p "$application/Contents/MacOS" "$application/Contents/Resources" "$application/Contents/Helpers"
cp "$binary_directory/ClipDune" "$application/Contents/MacOS/ClipDune.next"
mv -f "$application/Contents/MacOS/ClipDune.next" "$application/Contents/MacOS/ClipDune"
cp Resources/Info.plist "$application/Contents/Info.plist"
cp Resources/UpdatePublicKey.txt "$application/Contents/Resources/UpdatePublicKey.txt"
cp "$binary_directory/ClipDuneUpdateHelper" "$application/Contents/Helpers/ClipDuneUpdateHelper"
if [[ "$architecture" == universal ]]; then
    for slice in arm64 x86_64; do
        lipo "$application/Contents/MacOS/ClipDune" -verify_arch "$slice"
        lipo "$application/Contents/Helpers/ClipDuneUpdateHelper" -verify_arch "$slice"
    done
fi
icon_directory="$(mktemp -d /tmp/clipdune-icon.XXXXXX)"
trap 'rm -rf "$icon_directory"' EXIT
mkdir -p "$icon_directory/AppIcon.iconset"
"$binary_directory/ClipDune" --render-icon "$icon_directory/source.png"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$icon_directory/source.png" --out "$icon_directory/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$icon_directory/source.png" --out "$icon_directory/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$icon_directory/AppIcon.iconset" -o "$application/Contents/Resources/AppIcon.icns"
codesign --force --sign "${CLIPDUNE_SIGN_IDENTITY:--}" "$application/Contents/Helpers/ClipDuneUpdateHelper"
codesign --force --sign "${CLIPDUNE_SIGN_IDENTITY:--}" --identifier com.github.boyce-ywr.clipdune "$application"
codesign --verify --deep --strict "$application"
printf '\n开发预览包：%s\n' "$application"
printf '安全演示入口：make demo（开发入口，不读取真实剪贴板）\n'
