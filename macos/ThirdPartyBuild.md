# Third-party sources for Jable Download 1.0.0

The release contains `Jable-Download-1.0.0-third-party-sources.tar.gz` next to the application binaries. It includes the original source archives, SHA-256 checksums, the installed Homebrew formulae (including inline patches), Python dependency versions, and FFmpeg's configuration. No third-party source code was modified for this application.

The bundled FFmpeg 9.0.2 build enables GPL components and version 3. It is licensed under GPL-3.0-or-later. The application launches it as a separate command-line process; its own source remains under Apache-2.0. License texts and notices are included in `Jable Download.app/Contents/Resources/ThirdPartyLicenses`.

## Rebuilding

1. Use an Apple Silicon Mac and Xcode Command Line Tools. The supplied binaries were built for macOS 27 with Apple clang 21.0.0.
2. Extract this source archive. `native/*.rb` contains the exact Homebrew build recipes for FFmpeg and its redistributed dependencies. Rebuild the dependency recipes before FFmpeg; their upstream sources are in `archives/`. Inline patches, where used, are part of the recipes. Test-only resources are not required to build the libraries.
3. The FFmpeg configure command is recorded in `FFmpeg-build.txt`. Build with `make`, then `make install`. The recipes describe the library build flags and install steps. Standard compiler tools, SDKs, Homebrew, CMake, Meson, Ninja and pkgconf are available separately.
4. Use Python 3.12.15 and the application repository at tag `v1.0.0`:

   ```sh
   uv venv --python 3.12.15 .macos-venv
   uv pip install --python .macos-venv/bin/python -r macos/requirements-lock.txt
   JABLE_FFMPEG=/path/to/rebuilt/ffmpeg bash macos/BUILD.command
   bash macos/PACKAGE.command
   ```

`macos/BUILD.command` records how PyInstaller bundles Python, the downloader and FFmpeg. PyInstaller adjusts Mach-O library locations and applies ad-hoc signatures; these are packaging changes, not changes to third-party source. Its bootloader license includes the application-bundling exception. Python's standard-library license and all collected Python package licenses are also included.

To refresh release materials from the installed build dependencies:

```sh
.macos-venv/bin/python macos/prepare_release.py
bash macos/BUILD.command
bash macos/PACKAGE.command
```

Component URLs, versions and archive digests are in `SOURCES.json`. Python sources are from Python.org and PyPI; multimedia sources are from the upstream URLs recorded in their Homebrew formulae.
