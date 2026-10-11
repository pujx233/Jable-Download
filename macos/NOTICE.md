# Jable Download 1.0.0

这是基于 hcjohn463/JableTVDownload 工作流程制作的本地 macOS 客户端，不是站点官方客户端。
图标基于站点原始 favicon 生成满幅、不透明素材，外轮廓由 macOS 统一渲染。品牌素材归原站点所有，本项目与原站点无隶属关系。
上游项目采用 Apache-2.0 许可证，完整许可证随应用附带。

应用内包含 Python、Requests、Beautiful Soup、m3u8、PyCryptodome、Selenium、PyInstaller runtime 与 FFmpeg 及其动态库。
各组件保留其原有许可证。打包时使用本机 Homebrew FFmpeg；该构建包含 GPL 组件。
完整第三方许可证位于应用的 Contents/Resources/ThirdPartyLicenses。对应源码归档和构建说明与 ZIP、DMG 一同发布在 https://github.com/pujx233/Jable-Download/releases/tag/v1.0.0 。
当前包使用临时签名，尚未进行 Developer ID 签名或公证。

原项目：https://github.com/hcjohn463/JableTVDownload
FFmpeg：https://ffmpeg.org/
Python：https://www.python.org/
PyInstaller：https://pyinstaller.org/
Selenium：https://www.selenium.dev/

客户端不会读取日常 Chrome 配置、NAS SSH 密钥或极空间登录信息。
首次使用网页解析可能从 Google 官方服务下载匹配的 ChromeDriver。网站验证须由用户手动完成。
任务记录仅保存在本机 Application Support/Jable Desktop；没有新增遥测或上传服务，Selenium Manager 统计已关闭。
