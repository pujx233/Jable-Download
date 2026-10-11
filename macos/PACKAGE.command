#!/bin/bash
set -euo pipefail

task_project="$(cd "$(dirname "$0")/.." && pwd)"
task_app="$task_project/dist/Jable Download.app"
task_tools="$task_project/.macos-tools-venv"
[[ -d "$task_app" ]] || { printf '%s\n' '请先运行 macos/BUILD.command。'; exit 1; }
codesign --verify --deep --strict "$task_app"
task_version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$task_app/Contents/Info.plist")"
task_id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$task_app/Contents/Info.plist")"
[[ "$task_id" == local.jable.desktop && "$task_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 1
task_name="Jable-Download-$task_version-arm64"
task_work="$(mktemp -d "$task_project/.macos-release.XXXXXX")"
task_mounted=false
cleanup() {
    if [[ "$task_mounted" == true ]]; then
        hdiutil detach "$task_work/verify-mount" >/dev/null || true
    fi
}
trap cleanup EXIT
if [[ ! -x "$task_tools/bin/dmgbuild" ]]; then
    uv venv --python 3.12 "$task_tools"
    uv pip install --python "$task_tools/bin/python" 'dmgbuild==1.6.7'
fi
ditto -c -k --sequesterRsrc --keepParent "$task_app" "$task_work/$task_name.zip"
"$task_tools/bin/dmgbuild" -s "$task_project/macos/DMG.settings.py" \
    -D "app=$task_app" 'Jable Download' "$task_work/$task_name.dmg"
hdiutil verify "$task_work/$task_name.dmg"
mkdir "$task_work/verify-mount"
hdiutil attach -readonly -nobrowse -mountpoint "$task_work/verify-mount" \
    "$task_work/$task_name.dmg" >/dev/null
task_mounted=true
codesign --verify --deep --strict "$task_work/verify-mount/Jable Download.app"
hdiutil detach "$task_work/verify-mount" >/dev/null
task_mounted=false
ditto -x -k "$task_work/$task_name.zip" "$task_work/verify-zip"
codesign --verify --deep --strict "$task_work/verify-zip/Jable Download.app"
for task_suffix in zip dmg; do
    task_destination="$task_project/dist/$task_name.$task_suffix"
    if [[ -e "$task_destination" ]]; then
        mv "$task_destination" "$task_work/previous-$task_name.$task_suffix"
    fi
    mv "$task_work/$task_name.$task_suffix" "$task_destination"
done
task_sources="Jable-Download-$task_version-third-party-sources.tar.gz"
if [[ -f "$task_project/dist/$task_sources" ]]; then
    (cd "$task_project/dist"; shasum -a 256 "$task_name.zip" "$task_name.dmg" "$task_sources") > "$task_work/SHA256SUMS.txt"
else
    (cd "$task_project/dist"; shasum -a 256 "$task_name.zip" "$task_name.dmg") > "$task_work/SHA256SUMS.txt"
fi
mv "$task_work/SHA256SUMS.txt" "$task_project/dist/SHA256SUMS.txt"
printf '发布文件：%s\n构建缓存：%s\n' "$task_project/dist/$task_name.{zip,dmg}" "$task_work"
