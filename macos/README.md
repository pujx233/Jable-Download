# Jable Download（Mac 客户端）

原生 SwiftUI 窗口，独立 Python 下载进程；原有命令行程序不改动。
当前本机构建：Apple Silicon，macOS 27 或更新版本（随附的本机 FFmpeg 最低系统要求为 27.0）。界面源码以 macOS 15 为目标；在较旧系统重新构建时，需要使用与目标系统兼容的 FFmpeg 及动态库。

## 使用

双击 `dist/Jable Download.app`，粘贴 Jable 单部影片链接，每行一条，点击“开始下载”（`⌘↩`）。
应用内已包含 Python、FFmpeg 和依赖；运行时只需本机安装 Google Chrome。
左下角“设置”或 `⌘,` 可调整默认保存目录、分片并发数和验证浏览器；设置自动保存。
左侧“运行记录”打开独立日志窗口，支持自动滚动和复制本次运行的记录。
如果站点要求验证，在设置中开启“遇到验证时打开 Chrome”后重试，在打开的独立 Chrome 窗口中完成验证。

每部影片会生成一个大写目录，例如：

```text
START-498/
  START-498.mp4
  START-498.jpg
  .jable-cache/     # 下载锁及可续传片段；成功后清理下载片段
```

- 批量链接串行排队，分片并发数默认 8，可在设置中调整。
- 下载期间防止系统自动休眠，停止下载后恢复。
- 默认保存目录只影响之后加入的任务；并发数和验证浏览器从下一次启动下载生效，不会打断正在下载的任务。
- 暂停、失败与退出不会删除已下载的完整片段；继续时按影片内容识别并复用匹配片段，不依赖临时 CDN 地址。
- 视频合并成功才发布最终文件；视频存在时仅补缺失封面，不覆盖用户文件。
- 移除任务只删任务记录，不删影片或缓存。
- 原生保存目录选择器可选择本机目录或已挂载的 NAS 目录。不读取、不打包 SSH 密钥，也不修改 NAS 定时任务。
- 首次获取匹配的 ChromeDriver 需要联网；浏览器使用独立临时配置，关闭后清理。
- 任务和保存目录会记住，应用重新打开后点击“全部继续”。
- 无效链接会留在输入框中；加入新任务时自动切回全部任务。
- 左侧分类、设置和运行记录整行可点击；下载状态和日志随组件输出实时更新。
- 分片请求按并发数限量排队，进度最多每秒刷新四次；补下载封面成功后也会清理对应缓存。
- 支持普通 MPEG-TS 点播 HLS 与 AES-128；独立音轨、fMP4 和字节范围流暂不支持，会明确报错，不生成缺音轨视频。

数据目录沿用 `~/Library/Application Support/Jable Desktop`，保留改名前的任务与设置。发布包使用临时签名，未经过 Apple 公证；首次打开可能需要由你在 macOS“隐私与安全性”中确认。

## 构建

需要 Xcode Command Line Tools、Python 3.12（或 uv）和 FFmpeg；双击或运行 `macos/BUILD.command`。
编译环境隔离在 `.macos-venv`，不会改动原来的 `.venv`。`BUILD.command` 输出应用、ZIP 与图标预览；`PACKAGE.command` 生成带版本号的 ZIP、DMG 和校验文件。
重建只替换本项目生成的应用，并将上一构建留在本次构建缓存，避免覆盖未知文件。
图标使用站点 favicon 的粉色与白色 J，生成满幅、不透明的 sRGB 正方形素材；圆角、尺寸适配和外轮廓效果交给 macOS，不再手动覆盖 Dock 图标。构建时会检查全部 10 个输入尺寸，并将系统渲染的轮廓与本机 Finder 对照。

```sh
uv venv --python 3.12.15 .macos-venv
uv pip install --python .macos-venv/bin/python -r macos/requirements-lock.txt
bash macos/BUILD.command
bash macos/PACKAGE.command
```

完整内容下载会占用磁盘与流量；只保存你有权访问、下载的内容。
