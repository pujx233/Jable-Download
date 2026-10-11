# Jable Download

[简体中文](README.md) | [English](README.en.md)

Jable 的非官方 macOS 下载器。粘贴影片链接，视频和封面自动保存在同一个目录。

## 功能

- 批量下载，自动过滤重复链接。
- 按影片编号创建大写目录，保存视频和封面。
- 暂停继续、退出后恢复、失败重试。
- 保存目录、下载并发设置和运行记录。

## 下载 1.0.0

[DMG 安装包](https://github.com/pujx233/Jable-Download/releases/download/v1.0.0/Jable-Download-1.0.0-arm64.dmg) · [ZIP 应用包](https://github.com/pujx233/Jable-Download/releases/download/v1.0.0/Jable-Download-1.0.0-arm64.zip) · [发布页](https://github.com/pujx233/Jable-Download/releases/tag/v1.0.0)

支持 Apple Silicon、macOS 27+，需要安装 Google Chrome。应用自带 Python 和 FFmpeg，无需 Docker。当前界面为中文。

打开 DMG 后把应用拖到 Applications，或解压 ZIP 后放到“应用程序”。粘贴影片链接（每行一条），选择保存目录，点击“开始下载”即可。

应用尚未经过 Apple 公证，首次打开可能需要按 [Apple 的说明](https://support.apple.com/en-us/102445)允许打开。

基于 [hcjohn463/JableTVDownload](https://github.com/hcjohn463/JableTVDownload)，保留原版命令行程序。[客户端使用与构建](macos/README.md) · [原版使用说明](CLI_README.md)

[Apache-2.0](LICENSE)。第三方许可证随应用附带，对应源码见发布页。仅下载你有权保存的内容。
