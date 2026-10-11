#!/bin/bash
set -euo pipefail

task_project="$(cd "$(dirname "$0")/.." && pwd)"
task_python="$task_project/.macos-venv/bin/python"
task_ffmpeg="${JABLE_FFMPEG:-$(command -v ffmpeg || true)}"
if [[ ! -x "$task_python" ]]; then
    if command -v uv >/dev/null 2>&1; then
        uv venv --python 3.12 "$task_project/.macos-venv"
        uv pip install --python "$task_python" -r "$task_project/macos/requirements.txt"
    else
        python3 -m venv "$task_project/.macos-venv"
        "$task_python" -m pip install -r "$task_project/macos/requirements.txt"
    fi
fi
if [[ ! -x "$task_ffmpeg" ]]; then
    printf '%s\n' '构建需要 FFmpeg，请先安装或设置 JABLE_FFMPEG。'
    exit 1
fi
task_work="$(mktemp -d "$task_project/.macos-build.XXXXXX")"
task_bundle="$task_work/Jable Download.app"
task_output="$task_project/dist/Jable Download.app"
mkdir -p "$task_bundle/Contents/MacOS" "$task_bundle/Contents/Resources" "$task_project/dist"

"$task_python" -m PyInstaller --noconfirm --onedir --name jable-worker \
    --distpath "$task_work/runtime" --workpath "$task_work/pyinstaller" --specpath "$task_work" \
    --collect-data selenium --collect-binaries selenium --add-binary "$task_ffmpeg:tools" \
    --exclude-module tkinter --target-architecture arm64 "$task_project/macos/desktop_worker.py"
ditto "$task_work/runtime/jable-worker" "$task_bundle/Contents/Resources/worker"
xcrun swiftc -swift-version 5 -O -parse-as-library -target arm64-apple-macosx15.0 \
    "$task_project/macos/DownloadStore.swift" "$task_project/macos/LinkEditor.swift" \
    "$task_project/macos/JableDownload.swift" -o "$task_bundle/Contents/MacOS/JableDownload"
xcrun swiftc -swift-version 5 "$task_project/macos/MakeIcon.swift" -o "$task_work/make-icon"
"$task_work/make-icon" "$task_work/AppIcon.iconset" "$task_project/macos/Assets/Jable-Favicon.png"
iconutil -c icns "$task_work/AppIcon.iconset" -o "$task_bundle/Contents/Resources/AppIcon.icns"
cp "$task_project/macos/Assets/Jable-Favicon.png" "$task_bundle/Contents/Resources/JableBrand.png"
cp "$task_project/macos/Info.plist" "$task_bundle/Contents/Info.plist"
cp "$task_project/LICENSE" "$task_bundle/Contents/Resources/JableTVDownload-LICENSE"
cp "$task_project/macos/NOTICE.md" "$task_bundle/Contents/Resources/NOTICE.md"
if [[ -d "$task_project/macos/ThirdPartyLicenses" ]]; then
    ditto "$task_project/macos/ThirdPartyLicenses" "$task_bundle/Contents/Resources/ThirdPartyLicenses"
fi
plutil -lint "$task_bundle/Contents/Info.plist"
xcrun swift -swift-version 5 "$task_project/macos/TestAppIcon.swift" \
    "$task_work/AppIcon.iconset" "$task_bundle" "$task_work/Jable-Icon.png"
codesign --force --deep --sign - "$task_bundle"
codesign --verify --deep --strict "$task_bundle"
if [[ -e "$task_output" ]]; then
    task_id="$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$task_output/Contents/Info.plist")"
    [[ "$task_id" == local.jable.desktop ]] || { printf '%s\n' '输出目录已有未知应用，未覆盖。'; exit 1; }
    mv "$task_output" "$task_work/previous-build.app"
fi
mv "$task_bundle" "$task_output"
cp "$task_work/Jable-Icon.png" "$task_project/dist/Jable-Icon.png"
ditto -c -k --sequesterRsrc --keepParent "$task_output" "$task_work/Jable Download.zip"
mv "$task_work/Jable Download.zip" "$task_project/dist/Jable Download.zip"
printf '构建完成：%s\n构建缓存：%s\n' "$task_output" "$task_work"
