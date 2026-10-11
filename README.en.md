# Jable Download

[简体中文](README.md) | [English](README.en.md)

An unofficial macOS downloader for Jable. Paste video links to save each video and its cover in the same folder.

Built on [hcjohn463/JableTVDownload](https://github.com/hcjohn463/JableTVDownload), with a native SwiftUI app alongside the original command-line downloader.

## Download 1.0.0

- [DMG installer](https://github.com/pujx233/Jable-Download/releases/download/v1.0.0/Jable-Download-1.0.0-arm64.dmg): open it and drag the app to Applications.
- [ZIP app](https://github.com/pujx233/Jable-Download/releases/download/v1.0.0/Jable-Download-1.0.0-arm64.zip): extract it and move the app to Applications.
- [Full source ZIP](https://github.com/pujx233/Jable-Download/releases/download/v1.0.0/Jable-Download-1.0.0-source.zip): includes the original command-line program, macOS app, and both README versions.
- [All release files](https://github.com/pujx233/Jable-Download/releases/tag/v1.0.0).

Requires Apple Silicon, macOS 27 or later, and Google Chrome. Python, FFmpeg, and the download dependencies are bundled; Docker is not required. The app interface is currently in Chinese.

The app is ad-hoc signed and not notarized by Apple. If macOS blocks it on first launch, verify the source and SHA-256 checksum, then follow [Apple's guidance](https://support.apple.com/en-us/102445) to decide whether to allow it. There is no need to disable system security checks.

## Usage

1. Paste Jable video links, one per line.
2. Choose a destination and click “开始下载” (Start download), or press `⌘↩`.
3. Each video and cover are saved in an uppercase video-ID folder.

```text
VIDEO-ID/
  VIDEO-ID.mp4
  VIDEO-ID.jpg
```

Supports batch queues, duplicate filtering, pause and resume, task restoration after quitting, retries, and logs. Existing videos are not overwritten; missing covers can be downloaded separately.

Open “设置” (Settings) with `⌘,` to change the destination, segment concurrency, and verification browser setting. Mounted NAS folders are supported. The app does not read SSH keys or NAS credentials.

If the site requires verification, enable “遇到验证时打开 Chrome” (Open Chrome when verification is required), retry, and complete verification in the separate Chrome window. Supports MPEG-TS VOD HLS and AES-128. Separate audio tracks, fMP4, and byte-range streams are not yet supported.

More macOS details are in [macos/README.md](macos/README.md) (Chinese). The original Python, Docker, and Windows instructions are in [CLI_README.md](CLI_README.md) (Chinese).

## Build

Requires an Apple Silicon Mac, Xcode Command Line Tools, Python 3.12.15 (or uv), and FFmpeg.

```sh
uv venv --python 3.12.15 .macos-venv
uv pip install --python .macos-venv/bin/python -r macos/requirements-lock.txt
bash macos/BUILD.command
bash macos/PACKAGE.command
```

Outputs are saved to `dist/`. See [macos/ThirdPartyBuild.md](macos/ThirdPartyBuild.md) (Chinese) for release source preparation.

## License

The app and upstream code use [Apache-2.0](LICENSE). The Jable name and icon belong to the original site; this project is not affiliated with it.

The bundled FFmpeg includes GPL components and uses GPL-3.0-or-later. Other dependencies retain their respective licenses. Third-party licenses are included in the app; corresponding source code and build instructions are available in `Jable-Download-1.0.0-third-party-sources.tar.gz` on the same release page.

Only download content you have the right to access and save.
