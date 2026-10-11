"""A cancellable JSON-lines download worker for the native macOS client.

Adapted from JableTVDownload's page -> HLS segments -> MP4 + cover workflow.
The original command-line downloader is deliberately left unchanged.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import contextlib
import ctypes
import fcntl
import hashlib
import html
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import threading
import time
from urllib.parse import urljoin, urlsplit

from bs4 import BeautifulSoup
from Crypto.Cipher import AES
from Crypto.Util.Padding import unpad
import m3u8
import requests

VERSION = "1.0.0"
USER_AGENT = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36"


class Cancelled(Exception):
    pass


def emit(event, **fields):
    print(json.dumps({"event": event, **fields}, ensure_ascii=False), flush=True)


def normalize_url(value):
    parts = urlsplit(value.strip())
    if (parts.scheme not in {"https", "http"} or
            parts.hostname not in {"jable.tv", "www.jable.tv"} or
            parts.username or parts.password or parts.port):
        raise ValueError("请输入 jable.tv 的影片链接")
    match = re.fullmatch(r"/videos/([a-zA-Z0-9][a-zA-Z0-9-]{0,79})/?", parts.path)
    if not match:
        raise ValueError("需要单部影片链接")
    slug = match.group(1).lower()
    return "https://jable.tv/videos/" + slug + "/", slug.upper()


def parse_page(source, page_url):
    source = html.unescape(source.replace("\\/", "/"))
    soup = BeautifulSoup(source, "html.parser")
    stream = re.search(r"https?://[^\s\"'<>]+\.m3u8(?:\?[^\s\"'<>]*)?", source)
    if not stream:
        raise ValueError("网页没有提供视频地址，可能需要浏览器验证")
    cover = soup.select_one('meta[property="og:image"]')
    if cover is None:
        cover = next((node for node in soup.find_all("meta") if "preview.jpg" in node.get("content", "")), None)
    cover_value = cover.get("content", "").strip() if cover else ""
    cover_url = urljoin(page_url, cover_value) if cover_value else ""
    if urlsplit(cover_url).scheme not in {"http", "https"}:
        raise ValueError("网页没有提供有效的封面地址")
    title = soup.select_one('meta[property="og:title"]')
    name = title.get("content", "") if title else (soup.title.get_text(strip=True) if soup.title else "")
    return {"stream": stream.group(0), "cover": cover_url, "title": name}


def segment_iv(iv, sequence):
    if iv:
        try:
            return int(iv, 16).to_bytes(16, "big")
        except (ValueError, OverflowError) as error:
            raise ValueError("视频加密 IV 无效") from error
    return int(sequence).to_bytes(16, "big")


def decrypt_segment(data, key, iv):
    if len(key) != 16 or not data or len(data) % 16:
        raise ValueError("视频加密片段不完整")
    return unpad(AES.new(key, AES.MODE_CBC, iv).decrypt(data), 16)


def publish_new(source, destination):
    """Atomically publish without ever replacing a pre-existing user file."""
    try:
        if sys.platform == "darwin":
            # Exclusive rename also works on volumes without hard links.
            libc = ctypes.CDLL(None, use_errno=True)
            rename = libc.renamex_np
            rename.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint]
            rename.restype = ctypes.c_int
            if rename(os.fsencode(source), os.fsencode(destination), 0x00000004) == 0:
                return
            error = ctypes.get_errno()
            raise OSError(error, os.strerror(error), str(destination))
        os.link(source, destination)
    except FileExistsError:
        raise ValueError("目标文件已存在：" + destination.name)
    source.unlink()


class Downloader:
    def __init__(self, ffmpeg, show_browser=False, workers=8, reporter=emit):
        self.ffmpeg = str(ffmpeg)
        self.show_browser = show_browser
        self.workers = workers
        self.report = reporter
        self.stop = threading.Event()
        self.session = requests.Session()
        self.session.headers["User-Agent"] = USER_AGENT
        self.local = threading.local()
        self.sessions = []
        self.sessions_lock = threading.Lock()

    def cancel(self, *_):
        if not self.stop.is_set():
            self.stop.set()
            raise Cancelled()

    def check(self):
        if self.stop.is_set():
            raise Cancelled()

    def close(self):
        self.session.close()
        for session in self.sessions:
            session.close()

    def request(self, session, url):
        for attempt in range(3):
            self.check()
            try:
                response = session.get(url, timeout=(10, 20))
                response.raise_for_status()
                return response
            except requests.RequestException as error:
                if attempt == 2:
                    status = error.response.status_code if error.response is not None else "连接失败"
                    raise RuntimeError("网络请求失败（{}），可以稍后继续".format(status)) from error
                if self.stop.wait(attempt + 1):
                    raise Cancelled()

    def browser_page(self, url):
        from selenium.webdriver.chrome.webdriver import WebDriver as Chrome
        from selenium.webdriver.chrome.options import Options
        from selenium.webdriver.chrome.service import Service
        chrome = Path("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome")
        if not chrome.is_file():
            chrome = Path.home() / "Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        if not chrome.is_file():
            raise RuntimeError("请先安装 Google Chrome；客户端用它解析视频网页")
        app_data = Path.home() / "Library/Application Support/Jable Desktop"
        driver_cache = app_data / "drivers"
        driver_cache.mkdir(parents=True, exist_ok=True, mode=0o700)
        os.environ["SE_CACHE_PATH"] = str(driver_cache)
        os.environ["SE_AVOID_STATS"] = "true"
        os.environ["SE_AVOID_BROWSER_DOWNLOAD"] = "true"
        os.environ["SE_TIMEOUT"] = "45"
        self.report("phase", phase="解析网页", detail="" if not self.show_browser else "请在 Chrome 中完成验证")
        with tempfile.TemporaryDirectory(prefix="jable-browser-") as profile:
            options = Options()
            options.binary_location = str(chrome)
            options.add_argument("--user-data-dir=" + profile)
            options.add_argument("--disable-extensions")
            options.add_argument("--no-first-run")
            options.add_argument("--no-default-browser-check")
            options.add_argument("--user-agent=" + USER_AGENT)
            if not self.show_browser:
                options.add_argument("--headless=new")
            driver = None
            service = Service(log_output=subprocess.DEVNULL)
            try:
                driver = Chrome(options=options, service=service)
                driver.set_page_load_timeout(25)
                with contextlib.suppress(Exception):
                    driver.get(url)
                deadline = time.monotonic() + (90 if self.show_browser else 20)
                while time.monotonic() < deadline:
                    self.check()
                    try:
                        metadata = parse_page(driver.page_source, url)
                        self.session.headers["User-Agent"] = driver.execute_script("return navigator.userAgent")
                        for cookie in driver.get_cookies():
                            self.session.cookies.set(cookie["name"], cookie["value"], domain=cookie.get("domain"), path=cookie.get("path", "/"))
                        return metadata
                    except ValueError:
                        if self.stop.wait(1):
                            raise Cancelled()
                if self.show_browser:
                    raise RuntimeError("网页没有提供视频地址，请确认影片可访问且已完成验证")
                raise RuntimeError("请开启“遇到验证时打开 Chrome”后重试")
            finally:
                if driver is not None:
                    with contextlib.suppress(Exception):
                        driver.quit()
                else:
                    with contextlib.suppress(Exception):
                        service.stop()

    def metadata(self, url):
        self.session.headers["Referer"] = url
        self.report("phase", phase="解析网页", detail="")
        try:
            response = self.session.get(url, timeout=(10, 20))
            response.raise_for_status()
            return parse_page(response.text, url)
        except (requests.RequestException, ValueError):
            return self.browser_page(url)

    def playlist(self, url):
        for _ in range(5):
            response = self.request(self.session, url)
            if not response.text.lstrip().startswith("#EXTM3U"):
                raise RuntimeError("视频地址没有返回 HLS 播放列表")
            playlist = m3u8.loads(response.text, uri=response.url)
            if playlist.is_variant:
                candidates = list(playlist.playlists)
                if not candidates:
                    raise RuntimeError("播放列表没有可用清晰度")
                best = max(candidates, key=lambda item: item.stream_info.bandwidth or 0)
                if best.stream_info.audio and any(item.type == "AUDIO" and item.uri and item.group_id == best.stream_info.audio for item in playlist.media):
                    raise RuntimeError("暂不支持此影片的独立音轨")
                url = best.absolute_uri
                continue
            if not playlist.is_endlist or not playlist.segments:
                raise RuntimeError("只支持完整的点播视频，不支持直播")
            if any(segment.byterange or segment.init_section for segment in playlist.segments):
                raise RuntimeError("此视频使用暂不支持的分片格式")
            return playlist
        raise RuntimeError("播放列表嵌套过深")

    def thread_session(self):
        if not hasattr(self.local, "session"):
            session = requests.Session()
            session.headers.update(self.session.headers)
            session.cookies.update(self.session.cookies)
            self.local.session = session
            with self.sessions_lock:
                self.sessions.append(session)
        return self.local.session

    def segment_data(self, item):
        self.check()
        response = self.request(self.thread_session(), item["url"])
        data = response.content
        if not data or "text/html" in response.headers.get("Content-Type", "") or data.lstrip().startswith(b"<html"):
            raise ValueError("视频片段返回了无效内容")
        if item["key"] is not None:
            data = decrypt_segment(data, item["key"], item["iv"])
        return data

    def fetch_segment(self, item, path, data=None):
        self.check()
        if path.is_symlink():
            raise ValueError("缓存文件是符号链接，已停止")
        if path.is_file() and path.stat().st_size:
            return path.stat().st_size, True
        if data is None:
            data = self.segment_data(item)
        self.check()
        temporary = path.with_suffix(".tmp")
        with temporary.open("wb") as handle:
            handle.write(data)
        temporary.replace(path)
        return len(data), False

    def fetch_cover(self, url, folder, code):
        destination = folder / (code + ".jpg")
        if destination.exists():
            if destination.is_symlink() or not destination.is_file() or not destination.stat().st_size:
                raise ValueError("已有封面文件无效，请检查影片目录")
            return
        response = self.request(self.session, url)
        data = response.content
        # Do not save an HTML error/verification page under a .jpg extension.
        if not data.startswith(b"\xff\xd8\xff") or not data.rstrip().endswith(b"\xff\xd9"):
            raise ValueError("封面不是有效的 JPEG 图片，请重试")
        self.check()
        with tempfile.NamedTemporaryFile(prefix=".cover-", suffix=".jpg", dir=folder, delete=False) as handle:
            temporary = Path(handle.name)
            handle.write(data)
        try:
            publish_new(temporary, destination)
        finally:
            temporary.unlink(missing_ok=True)

    def merge(self, cache, paths, destination, duration):
        concat = cache / "concat.txt"
        concat.write_text("".join("file '{}'\n".format(path.name) for path in paths), encoding="utf-8")
        temporary = cache / "merged.mp4"
        command = [self.ffmpeg, "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                   "-f", "concat", "-safe", "1", "-i", str(concat), "-map", "0:v:0", "-map", "0:a:0?",
                   "-c", "copy", "-bsf:a", "aac_adtstoasc", "-movflags", "+faststart",
                   "-progress", "pipe:1", str(temporary)]
        self.report("phase", phase="合并视频", detail="")
        with tempfile.TemporaryFile() as errors:
            process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=errors, text=True, encoding="utf-8")
            try:
                for line in process.stdout:
                    self.check()
                    if line.startswith("out_time_us="):
                        with contextlib.suppress(ValueError):
                            seconds = int(line.partition("=")[2]) / 1_000_000
                            self.report("progress", phase="合并视频", progress=min(0.98, 0.9 + 0.08 * seconds / max(duration, 1)))
                status = process.wait()
                if status or not temporary.is_file() or not temporary.stat().st_size:
                    errors.seek(0)
                    message = errors.read(1000).decode("utf-8", errors="replace").strip()
                    raise RuntimeError("视频合并失败" + ("：" + message if message else ""))
                self.check()
                publish_new(temporary, destination)
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()
                if process.stdout:
                    process.stdout.close()

    def recover_legacy_cache(self, cache_root, target, url, items, first_data):
        if target.exists():
            return
        candidates = []
        for directory in cache_root.iterdir():
            if directory.is_symlink() or not directory.is_dir() or not re.fullmatch(r"[0-9a-f]{64}", directory.name):
                continue
            manifest = directory / "manifest.json"
            if manifest.is_symlink():
                continue
            try:
                info = json.loads(manifest.read_text(encoding="utf-8"))
                if (info.get("owner") != "jable-desktop-v1" or info.get("url") != url or
                        info.get("segments") != len(items) or info.get("content_identity")):
                    continue
                present = sorted(int(path.stem) for path in directory.iterdir()
                                 if re.fullmatch(r"\d{8}\.ts", path.name) and not path.is_symlink()
                                 and path.is_file() and path.stat().st_size and int(path.stem) < len(items))
                if not present or present[0] != 0 or (directory / "00000000.ts").read_bytes() != first_data:
                    continue
                candidates.append((present, directory))
            except (OSError, ValueError, TypeError):
                continue
        for present, directory in sorted(candidates, key=lambda candidate: len(candidate[0]), reverse=True):
            # Older caches lacked a content identity. Verify samples across their
            # saved range before preserving them under the new stable identity.
            samples = {present[len(present) // 2], present[-1]} - {0}
            if all((directory / ("{:08d}.ts".format(index))).read_bytes() == self.segment_data(items[index])
                   for index in sorted(samples)):
                self.check()
                directory.rename(target)
                return

    def download_media(self, metadata, url, code, folder, cache_root):
        video = folder / (code + ".mp4")
        self.report("metadata", code=code, title=metadata["title"])
        if video.exists():
            if video.is_symlink() or not video.is_file() or not video.stat().st_size:
                raise ValueError("已有视频文件无效，请检查影片目录")
            self.report("phase", phase="下载封面", detail="")
            self.fetch_cover(metadata["cover"], folder, code)
            return
        playlist = self.playlist(metadata["stream"])
        keys = {}
        items = []
        for index, segment in enumerate(playlist.segments):
            self.check()
            key_bytes = None
            iv = None
            if segment.key and segment.key.method not in {"NONE", None}:
                if segment.key.method != "AES-128" or segment.key.keyformat not in {None, "identity"}:
                    raise ValueError("不支持此视频的加密方式")
                key_url = segment.key.absolute_uri
                if key_url not in keys:
                    keys[key_url] = self.request(self.session, key_url).content
                key_bytes = keys[key_url]
                iv = segment_iv(segment.key.iv, playlist.media_sequence + index)
            items.append({"url": segment.absolute_uri, "key": key_bytes, "iv": iv, "duration": segment.duration})
        self.report("phase", phase="下载视频", detail="")
        started = time.monotonic()
        first_data = self.segment_data(items[0])
        # Identify decrypted content, not rotating CDN addresses or transport
        # keys. Different encodings/layouts still receive separate caches.
        fingerprint = hashlib.sha256(json.dumps([
            url, playlist.media_sequence, [item["duration"] for item in items],
            hashlib.sha256(first_data).hexdigest()
        ], separators=(",", ":")).encode()).hexdigest()
        cache = cache_root / fingerprint
        if cache.is_symlink():
            raise ValueError("缓存目录是符号链接，已停止")
        self.recover_legacy_cache(cache_root, cache, url, items, first_data)
        cache.mkdir(exist_ok=True, mode=0o700)
        manifest = cache / "manifest.json"
        manifest.write_text(json.dumps({"owner": "jable-desktop-v1", "url": url, "segments": len(items),
                                       "content_identity": fingerprint}), encoding="utf-8")
        paths = [cache / ("{:08d}.ts".format(index)) for index in range(len(items))]
        size, cached = self.fetch_segment(items[0], paths[0], first_data)
        del first_data
        done, transferred, resumed = 1, 0 if cached else size, int(cached)
        with concurrent.futures.ThreadPoolExecutor(max_workers=self.workers) as executor:
            remaining = iter(zip(items[1:], paths[1:]))
            pending = set()
            last_report = time.monotonic()

            def fill_pending():
                while len(pending) < self.workers * 2:
                    pair = next(remaining, None)
                    if pair is None:
                        break
                    pending.add(executor.submit(self.fetch_segment, *pair))

            fill_pending()
            try:
                while pending:
                    self.check()
                    completed, pending = concurrent.futures.wait(pending, return_when=concurrent.futures.FIRST_COMPLETED)
                    for future in completed:
                        size, cached = future.result()
                        done += 1
                        resumed += int(cached)
                        transferred += 0 if cached else size
                    now = time.monotonic()
                    if done == len(items) or now - last_report >= 0.25:
                        elapsed = max(now - started, 0.01)
                        self.report("progress", phase="下载视频", progress=0.9 * done / len(items),
                                    completed=done, total=len(items), resumed=resumed, bytes_per_second=transferred / elapsed)
                        last_report = now
                    fill_pending()
            except BaseException:
                self.stop.set()
                for future in pending:
                    future.cancel()
                raise
        self.check()
        self.merge(cache, paths, video, sum(item["duration"] for item in items))
        self.report("phase", phase="下载封面", detail="")
        self.fetch_cover(metadata["cover"], folder, code)
        self.check()

    @staticmethod
    def cleanup_caches(cache_root, url):
        # Also clean fragments left by a previous successful merge whose cover
        # failed. Only files named in this worker's own manifest are eligible.
        for cache in cache_root.iterdir():
            if cache.is_symlink() or not cache.is_dir() or not re.fullmatch(r"[0-9a-f]{64}", cache.name):
                continue
            manifest = cache / "manifest.json"
            if manifest.is_symlink():
                continue
            try:
                info = json.loads(manifest.read_text(encoding="utf-8"))
                count = info["segments"]
                if (info.get("owner") != "jable-desktop-v1" or info.get("url") != url or
                        type(count) is not int or not 0 < count <= 100_000):
                    continue
            except (OSError, ValueError, KeyError, TypeError):
                continue
            for index in range(count):
                for suffix in ("ts", "tmp"):
                    with contextlib.suppress(OSError):
                        (cache / ("{:08d}.{}".format(index, suffix))).unlink(missing_ok=True)
            for path in [cache / "concat.txt", cache / "merged.mp4", manifest]:
                with contextlib.suppress(OSError):
                    path.unlink(missing_ok=True)
            with contextlib.suppress(OSError):
                cache.rmdir()

    def download(self, value, output):
        url, code = normalize_url(value)
        folder = Path(output).expanduser().resolve() / code
        if folder.is_symlink():
            raise ValueError("影片目录是符号链接，已停止")
        folder.mkdir(parents=True, exist_ok=True)
        cache_root = folder / ".jable-cache"
        if cache_root.is_symlink():
            raise ValueError("缓存目录是符号链接，已停止")
        cache_root.mkdir(exist_ok=True, mode=0o700)
        lock_path = cache_root / "download.lock"
        if lock_path.is_symlink():
            raise ValueError("缓存锁是符号链接，已停止")
        with lock_path.open("a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise ValueError("同一目录的影片已在下载，请勿重复启动") from error
            video, cover = folder / (code + ".mp4"), folder / (code + ".jpg")
            if all(path.is_file() and not path.is_symlink() and path.stat().st_size for path in (video, cover)):
                self.cleanup_caches(cache_root, url)
                self.report("done", progress=1, folder=str(folder), video=str(video), cover=str(cover), existing=True)
                return
            metadata = self.metadata(url)
            self.download_media(metadata, url, code, folder, cache_root)
            self.cleanup_caches(cache_root, url)
            self.report("done", progress=1, folder=str(folder), video=str(video), cover=str(cover))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", action="version", version=VERSION)
    parser.add_argument("--url", required=True)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--ffmpeg", default="ffmpeg")
    parser.add_argument("--show-browser", action="store_true")
    parser.add_argument("--workers", type=int, choices=range(1, 17), default=8)
    parser.add_argument("--inspect", action="store_true", help="Only check page parsing; do not download media")
    args = parser.parse_args()
    os.umask(0o077)
    worker = Downloader(args.ffmpeg, args.show_browser, workers=args.workers)
    signal.signal(signal.SIGTERM, worker.cancel)
    signal.signal(signal.SIGINT, worker.cancel)
    try:
        url, code = normalize_url(args.url)
        if args.inspect:
            metadata = worker.metadata(url)
            emit("inspected", code=code, has_stream=bool(metadata["stream"]), has_cover=bool(metadata["cover"]))
        elif args.output:
            worker.download(url, args.output)
        else:
            raise ValueError("缺少保存目录")
        return 0
    except Cancelled:
        emit("cancelled", detail="")
        return 130
    except Exception as error:
        # Selenium exception dumps may include remote URLs and stack traces.
        message = str(error).split("Stacktrace:")[0].strip()
        message = re.sub(r"https?://\S+", "[远程地址]", message)
        emit("error", detail=message[:500] or type(error).__name__)
        return 1
    finally:
        worker.close()


if __name__ == "__main__":
    raise SystemExit(main())
