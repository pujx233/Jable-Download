#!/bin/bash
set -euo pipefail
task_project="$(cd "$(dirname "$0")/.." && pwd)"
task_work="$(mktemp -d "$task_project/.macos-tests.XXXXXX")"
trap '/bin/rm -f "$task_work/desktop-tests"; /bin/rmdir "$task_work"' EXIT
PYTHONDONTWRITEBYTECODE=1 "$task_project/.macos-venv/bin/python" -m unittest discover -s "$task_project/macos" -p 'test_*.py' -v
xcrun swiftc -swift-version 5 -parse-as-library \
    "$task_project/macos/DownloadStore.swift" "$task_project/macos/LinkEditor.swift" \
    "$task_project/macos/TestDesktop.swift" -o "$task_work/desktop-tests"
"$task_work/desktop-tests"
