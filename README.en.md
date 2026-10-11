# Jable Download

[简体中文](README.md) | [English](README.en.md)

An unofficial macOS downloader for Jable. Paste video links to save each video and its cover in the same folder.

## Features

- Batch downloads with duplicate filtering.
- Videos and covers saved in uppercase video-ID folders.
- Pause and resume, task restoration after quitting, and retries.
- Destination and concurrency settings, plus download logs.

## Download 1.0.0

[DMG installer](https://github.com/pujx233/Jable-Download/releases/download/v1.0.0/Jable-Download-1.0.0-arm64.dmg) · [ZIP app](https://github.com/pujx233/Jable-Download/releases/download/v1.0.0/Jable-Download-1.0.0-arm64.zip) · [Release page](https://github.com/pujx233/Jable-Download/releases/tag/v1.0.0)

Supports Apple Silicon and macOS 27+. Google Chrome is required. Python and FFmpeg are bundled; Docker is not needed. The app interface is currently in Chinese.

Open the DMG and drag the app to Applications, or extract the ZIP and move it there. Paste video links (one per line), choose a destination, and click “开始下载” (Start download).

The app is not notarized by Apple. On first launch, you may need to allow it using [Apple's instructions](https://support.apple.com/en-us/102445).

Based on [hcjohn463/JableTVDownload](https://github.com/hcjohn463/JableTVDownload), with the original command-line program preserved. [macOS usage and build instructions](macos/README.md) · [Original CLI instructions](CLI_README.md) (both in Chinese).

[Apache-2.0](LICENSE). Third-party licenses are included in the app, with corresponding source code on the release page. Only download content you have the right to save.
