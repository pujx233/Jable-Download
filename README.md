# Jable Download

[简体中文](README.md) | [English](README.en.md)

Jable 的非官方 macOS 下载器。粘贴影片链接，视频和封面自动保存在同一个目录。

基于 [hcjohn463/JableTVDownload](https://github.com/hcjohn463/JableTVDownload)，保留原版命令行程序，新增原生 SwiftUI 客户端。

## 下载 1.0.0

- [DMG 安装包](https://github.com/pujx233/Jable-Download/releases/download/v1.0.0/Jable-Download-1.0.0-arm64.dmg)：打开后，把应用拖到 Applications。
- [ZIP 应用包](https://github.com/pujx233/Jable-Download/releases/download/v1.0.0/Jable-Download-1.0.0-arm64.zip)：解压后把应用放到“应用程序”。
- [完整源码 ZIP](https://github.com/pujx233/Jable-Download/releases/download/v1.0.0/Jable-Download-1.0.0-source.zip)：包含原版命令行程序、macOS 客户端和中英文说明。
- [全部附件](https://github.com/pujx233/Jable-Download/releases/tag/v1.0.0)。

要求 Apple Silicon、macOS 27 或更新版本，以及已安装的 Google Chrome。应用已包含 Python、FFmpeg 和下载依赖，不需要 Docker。当前界面为中文。

当前包使用临时签名，未经过 Apple 公证。如果首次打开被拦截，请先确认来源与 SHA-256 校验值，再根据 [Apple 的说明](https://support.apple.com/en-us/102445)自行决定是否允许打开。无需关闭系统安全检查。

## 使用

1. 粘贴 Jable 影片链接，每行一条。
2. 选择保存目录，点击“开始下载”（`⌘↩`）。
3. 视频和封面保存在同名的大写目录中。

```text
影片编号/
  影片编号.mp4
  影片编号.jpg
```

支持批量队列、去重、暂停继续、退出后恢复、失败重试和运行记录。已有视频不会被覆盖，缺少封面时只补封面。

“设置”（`⌘,`）可调整保存目录、分片并发数和验证浏览器。支持选择已挂载的 NAS 目录；不会读取 SSH 密钥或 NAS 账号。

如果网页要求验证，开启“遇到验证时打开 Chrome”后重试，在独立 Chrome 窗口完成验证。支持 MPEG-TS 点播 HLS 和 AES-128；暂不支持独立音轨、fMP4 或字节范围流。

详细说明见 [macos/README.md](macos/README.md)。原版 Python、Docker 和 Windows 用法见 [CLI_README.md](CLI_README.md)。

## 构建

需要 Apple Silicon Mac、Xcode Command Line Tools、Python 3.12.15（或 uv）和 FFmpeg。

```sh
uv venv --python 3.12.15 .macos-venv
uv pip install --python .macos-venv/bin/python -r macos/requirements-lock.txt
bash macos/BUILD.command
bash macos/PACKAGE.command
```

输出位于 `dist/`。发布材料的生成方式见 [macos/ThirdPartyBuild.md](macos/ThirdPartyBuild.md)。

## 许可证

客户端与上游代码使用 [Apache-2.0](LICENSE)。Jable 名称和图标归原站点所有，本项目与原站点无隶属关系。

随附的 FFmpeg 含 GPL 组件，使用 GPL-3.0-or-later；各依赖保留其原有许可证。第三方许可证随应用附带，对应源码与构建说明位于同版 Release 的 `Jable-Download-1.0.0-third-party-sources.tar.gz`。

仅下载你有权访问和保存的内容。
