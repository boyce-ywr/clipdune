#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
launch_mode="${1:-development}"
case "$launch_mode" in development|bundle) ;; *) echo "用法：$0 [development|bundle]" >&2; exit 2 ;; esac
swift build --product ClipDune
swift build --product ClipDuneQAHost
binary_directory="$(swift build --show-bin-path)"
output="$(mktemp -d /tmp/clipdune-ui.XXXXXX)"
app_executable="$binary_directory/ClipDune"
host_executable="$binary_directory/ClipDuneQAHost"
if [[ "$launch_mode" == bundle ]]; then
bash scripts/build.sh debug
host_application="$output/ClipDuneQAHost.app"
mkdir -p "$host_application/Contents/MacOS"
cp "$binary_directory/ClipDuneQAHost" "$host_application/Contents/MacOS/ClipDuneQAHost"
cp Resources/Info.plist "$host_application/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable ClipDuneQAHost' "$host_application/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier com.github.boyce-ywr.clipdune.qahost' "$host_application/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName ClipDuneQAHost' "$host_application/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :LSUIElement false' "$host_application/Contents/Info.plist"
codesign --force --sign - "$host_application"
app_executable="$PWD/dist/ClipDune.app/Contents/MacOS/ClipDune"
host_executable="$host_application/Contents/MacOS/ClipDuneQAHost"
fi
host_pid=""
app_pid=""
cleanup() {
    if [[ -n "$app_pid" ]]; then kill "$app_pid" 2>/dev/null || true; wait "$app_pid" 2>/dev/null || true; fi
    if [[ -n "$host_pid" ]]; then kill "$host_pid" 2>/dev/null || true; wait "$host_pid" 2>/dev/null || true; fi
}
trap cleanup EXIT
printf '隔离 UI 测试入口：%s；输出：%s\n' "$launch_mode" "$output"
for mode in windowed fullscreen; do
    directory="$output/$mode"
    mkdir -p "$directory"
    if [[ "$mode" == windowed ]]; then
        "$host_executable" "$directory" --windowed >"$directory/host.log" 2>&1 &
    else
        "$host_executable" "$directory" >"$directory/host.log" 2>&1 &
    fi
    host_pid=$!
    for attempt in $(seq 1 150); do
        [[ -f "$directory/host.json" ]] && break
        kill -0 "$host_pid" 2>/dev/null || break
        sleep 0.1
    done
    if [[ ! -f "$directory/host.json" ]]; then echo "测试窗口未就绪：$directory/host.log" >&2; exit 1; fi
    state="$(plutil -extract status raw -o - "$directory/host.json")"
    if [[ "$state" == blocked_screen_locked ]]; then echo "屏幕锁定，UI 验证未执行。"; exit 2; fi
    if [[ "$state" != windowed_ready && "$state" != full_screen_ready ]]; then echo "测试窗口失败：$state" >&2; exit 1; fi
    "$app_executable" --ui-check "$directory" >"$directory/app.log" 2>&1 &
    app_pid=$!
    for attempt in $(seq 1 300); do
        [[ -f "$directory/ui-check.json" ]] && break
        kill -0 "$app_pid" 2>/dev/null || break
        sleep 0.1
    done
    if [[ ! -f "$directory/ui-check.json" ]]; then echo "应用 UI 测试未完成：$directory/app.log" >&2; exit 1; fi
    cat "$directory/ui-check.json"
    result="$(plutil -extract status raw -o - "$directory/ui-check.json")"
    cleanup
    app_pid=""
    host_pid=""
    if [[ "$result" != passed ]]; then echo "UI 测试未通过：$mode" >&2; exit 1; fi
done
printf '\n普通窗口与原生全屏隔离检查通过：%s\n' "$output"
