import contextlib
import concurrent.futures
from functools import partial
import http.server
import io
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import threading
import time
from types import SimpleNamespace
import unittest
import weakref
from unittest.mock import patch

from Crypto.Cipher import AES
from Crypto.Util.Padding import pad
import desktop_worker as worker


class WorkerUnitTests(unittest.TestCase):
    def test_cli_workers_are_applied(self):
        args = ["jable-worker", "--url", "https://jable.tv/videos/start-498/",
                "--output", "/tmp/jable-settings-test", "--workers", "4"]
        with patch.object(worker.sys, "argv", args), patch.object(worker, "Downloader") as constructor, \
                patch.object(worker.signal, "signal"), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(worker.main(), 0)
            constructor.assert_called_once_with("ffmpeg", False, workers=4)
            constructor.return_value.download.assert_called_once_with(
                "https://jable.tv/videos/start-498/", Path("/tmp/jable-settings-test"))

    def test_cli_rejects_invalid_workers(self):
        for value in ("0", "17"):
            with self.subTest(value=value), patch.object(worker.sys, "argv", ["jable-worker", "--url",
                    "https://jable.tv/videos/start-498/", "--workers", value]), \
                    contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                worker.main()

    def test_normalizes_url(self):
        self.assertEqual(worker.normalize_url("https://www.jable.tv/videos/START-498/?source=copy#x"),
                         ("https://jable.tv/videos/start-498/", "START-498"))

    def test_rejects_other_hosts_and_paths(self):
        for url in ("https://jable.tv.evil.test/videos/a/", "https://jable.tv/actors/a/",
                    "file:///videos/a/", "https://user:secret@jable.tv/videos/a/",
                    "https://jable.tv:8080/videos/a/", "https://jable.tv/videos/../"):
            with self.subTest(url=url), self.assertRaises(ValueError):
                worker.normalize_url(url)

    def test_page_parsing(self):
        page = '<meta property="og:image" content="/preview.jpg"><meta property="og:title" content="A &amp; B"><script>var hls = "https:\\/\\/cdn.example\\/index.m3u8?x=1&amp;y=2";</script>'
        metadata = worker.parse_page(page, "https://jable.tv/videos/start-498/")
        self.assertEqual(metadata["stream"], "https://cdn.example/index.m3u8?x=1&y=2")
        self.assertEqual(metadata["cover"], "https://jable.tv/preview.jpg")
        self.assertEqual(metadata["title"], "A & B")

    def test_verification_page_is_not_success(self):
        with self.assertRaises(ValueError):
            worker.parse_page("<title>Please verify</title>", "https://jable.tv/videos/a/")

    def test_empty_cover_is_not_treated_as_page_url(self):
        page = '<meta property="og:image" content=" "><script>var hls="https://cdn.example/a.m3u8";</script>'
        with self.assertRaises(ValueError):
            worker.parse_page(page, "https://jable.tv/videos/a/")

    def test_iv_and_decryption(self):
        key = bytes(range(16))
        for iv, sequence in (("0x000000000000000000000000000000ab", 1), (None, 258)):
            with self.subTest(iv=iv):
                expected = (171 if iv else sequence).to_bytes(16, "big")
                self.assertEqual(worker.segment_iv(iv, sequence), expected)
                plaintext = b"test transport stream" * 7
                encrypted = AES.new(key, AES.MODE_CBC, expected).encrypt(pad(plaintext, 16))
                self.assertEqual(worker.decrypt_segment(encrypted, key, expected), plaintext)

    def test_publication_keeps_existing_file(self):
        with tempfile.TemporaryDirectory() as temp:
            source, destination = Path(temp) / "new", Path(temp) / "existing"
            source.write_bytes(b"new")
            destination.write_bytes(b"old")
            with self.assertRaises(ValueError):
                worker.publish_new(source, destination)
            self.assertEqual(destination.read_bytes(), b"old")
            self.assertEqual(source.read_bytes(), b"new")

    @unittest.skipUnless(worker.sys.platform == "darwin", "macOS exclusive rename")
    def test_publication_does_not_require_hardlinks(self):
        with tempfile.TemporaryDirectory() as temp:
            source, destination = Path(temp) / "new", Path(temp) / "final"
            source.write_bytes(b"complete")
            with patch.object(worker.os, "link", side_effect=OSError("volume has no hardlinks")):
                worker.publish_new(source, destination)
            self.assertEqual(destination.read_bytes(), b"complete")
            self.assertFalse(source.exists())

    def test_cleanup_ignores_unowned_cache(self):
        with tempfile.TemporaryDirectory() as temp:
            cache = Path(temp) / ("a" * 64)
            cache.mkdir()
            fragment = cache / "00000000.ts"
            fragment.write_bytes(b"user file")
            (cache / "manifest.json").write_text(json.dumps({"owner": "other", "segments": 1}))
            worker.Downloader.cleanup_caches(Path(temp), "https://jable.tv/videos/a/")
            self.assertEqual(fragment.read_bytes(), b"user file")

    def test_playlist_selects_highest_bandwidth(self):
        downloader = worker.Downloader("/usr/bin/false")
        self.addCleanup(downloader.close)
        master = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=100\nlow.m3u8\n#EXT-X-STREAM-INF:BANDWIDTH=200\nhigh.m3u8\n"
        media = "#EXTM3U\n#EXTINF:1,\nsegment.ts\n#EXT-X-ENDLIST\n"
        responses = [SimpleNamespace(text=master, url="https://cdn.example/master.m3u8"),
                     SimpleNamespace(text=media, url="https://cdn.example/high.m3u8")]
        with patch.object(downloader, "request", side_effect=responses) as request:
            self.assertEqual(len(downloader.playlist("https://cdn.example/master.m3u8").segments), 1)
        self.assertEqual(request.call_args_list[-1].args[1], "https://cdn.example/high.m3u8")

    def test_unsupported_playlists_fail_before_segment_downloads(self):
        downloader = worker.Downloader("/usr/bin/false")
        self.addCleanup(downloader.close)
        playlists = [
            "#EXTM3U\n#EXTINF:1,\nsegment.ts\n",  # live
            '#EXTM3U\n#EXT-X-MAP:URI="init.mp4"\n#EXTINF:1,\nsegment.m4s\n#EXT-X-ENDLIST\n',
            "#EXTM3U\n#EXTINF:1,\n#EXT-X-BYTERANGE:20@0\nsegment.ts\n#EXT-X-ENDLIST\n",
            '#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="audio",URI="audio.m3u8"\n#EXT-X-STREAM-INF:BANDWIDTH=200,AUDIO="a"\nvideo.m3u8\n'
        ]
        for source in playlists:
            with self.subTest(source=source), patch.object(downloader, "request", return_value=SimpleNamespace(text=source, url="https://cdn.example/master.m3u8")), self.assertRaises(RuntimeError):
                downloader.playlist("https://cdn.example/master.m3u8")

    def test_existing_download_does_not_visit_site(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp) / "START-498"
            folder.mkdir()
            (folder / "START-498.mp4").write_bytes(b"existing video")
            (folder / "START-498.jpg").write_bytes(b"existing cover")
            events = []
            downloader = worker.Downloader("/usr/bin/false", reporter=lambda event, **fields: events.append((event, fields)))
            try:
                with patch.object(downloader, "metadata", side_effect=AssertionError("must not visit")):
                    downloader.download("https://jable.tv/videos/start-498/", temp)
                self.assertEqual(events[-1][0], "done")
                self.assertEqual((folder / "START-498.mp4").read_bytes(), b"existing video")
            finally:
                downloader.close()

    def test_cache_symlink_is_not_followed(self):
        with tempfile.TemporaryDirectory() as temp:
            folder = Path(temp) / "START-498"
            other = Path(temp) / "unrelated"
            folder.mkdir()
            other.mkdir()
            (folder / ".jable-cache").symlink_to(other, target_is_directory=True)
            downloader = worker.Downloader("/usr/bin/false")
            try:
                with self.assertRaises(ValueError):
                    downloader.download("https://jable.tv/videos/start-498/", temp)
                self.assertFalse(list(other.iterdir()))
            finally:
                downloader.close()


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path == "/segment003.ts?slow=1":
            time.sleep(0.4)
        super().do_GET()


class LocalDownloadTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.ffmpeg = shutil.which("ffmpeg")
        if not cls.ffmpeg:
            raise unittest.SkipTest("FFmpeg is needed for the local HLS integration fixture")
        cls.temp = tempfile.TemporaryDirectory(prefix="jable-client-test-")
        cls.base = Path(cls.temp.name)
        cls.media = cls.base / "media"
        cls.media.mkdir()
        subprocess.run([cls.ffmpeg, "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                        "-f", "lavfi", "-i", "color=c=0xee5566:s=96x64:r=10", "-f", "lavfi", "-i", "sine=frequency=440",
                        "-t", "3.2", "-c:v", "libx264", "-g", "10", "-sc_threshold", "0", "-pix_fmt", "yuv420p",
                        "-c:a", "aac", "-f", "hls", "-hls_time", "1", "-hls_list_size", "0",
                        "-hls_segment_filename", str(cls.media / "segment%03d.ts"), str(cls.media / "plain.m3u8")], check=True)
        subprocess.run([cls.ffmpeg, "-nostdin", "-hide_banner", "-loglevel", "error", "-y",
                        "-f", "lavfi", "-i", "color=c=0xee5566:s=96x64", "-frames:v", "1", str(cls.media / "cover.jpg")], check=True)
        key = bytes(range(16))
        (cls.media / "key.bin").write_bytes(key)
        lines = (cls.media / "plain.m3u8").read_text().splitlines()
        (cls.media / "slow.m3u8").write_text("\n".join(line + "?slow=1" if line.startswith("segment") else line for line in lines) + "\n")
        result, sequence = [], 0
        for line in lines:
            if line.startswith("segment"):
                name = "encrypted-" + line
                iv = worker.segment_iv(None, sequence)
                (cls.media / name).write_bytes(AES.new(key, AES.MODE_CBC, iv).encrypt(pad((cls.media / line).read_bytes(), 16)))
                result.append(name)
                sequence += 1
            else:
                result.append(line)
                if line == "#EXTM3U":
                    result.append('#EXT-X-KEY:METHOD=AES-128,URI="key.bin"')
        (cls.media / "encrypted.m3u8").write_text("\n".join(result) + "\n")
        cls.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), partial(QuietHandler, directory=str(cls.media)))
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.url = "http://127.0.0.1:{}/".format(cls.server.server_address[1])

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=2)
        cls.temp.cleanup()

    def make_downloader(self, stream="plain.m3u8", ffmpeg=None):
        events = []
        downloader = worker.Downloader(ffmpeg or self.ffmpeg, workers=3,
                                       reporter=lambda event, **fields: events.append((event, fields)))
        metadata = {"title": "Local HLS fixture", "stream": self.url + stream, "cover": self.url + "cover.jpg"}
        downloader.metadata = lambda _: metadata
        self.addCleanup(downloader.close)
        return downloader, events

    def output(self, name):
        output = self.base / name
        folder = output / "CLIENT-001"
        folder.mkdir(parents=True)
        (folder / "keep-me.txt").write_bytes(b"user file")
        return output, folder

    def verify_completed(self, folder):
        self.assertGreater((folder / "CLIENT-001.mp4").stat().st_size, 2000)
        self.assertEqual((folder / "CLIENT-001.jpg").read_bytes(), (self.media / "cover.jpg").read_bytes())
        self.assertEqual((folder / "keep-me.txt").read_bytes(), b"user file")
        self.assertFalse(list((folder / ".jable-cache").rglob("*.ts")))
        # Decode the result too: existence alone does not prove a playable merge.
        subprocess.run([self.ffmpeg, "-nostdin", "-hide_banner", "-loglevel", "error", "-i", str(folder / "CLIENT-001.mp4"),
                        "-f", "null", "-"], check=True, stdout=subprocess.DEVNULL)

    def test_plain_hls_video_and_cover_in_same_directory(self):
        output, folder = self.output("plain-output")
        downloader, events = self.make_downloader()
        downloader.download("https://jable.tv/videos/client-001/", output)
        self.verify_completed(folder)
        self.assertEqual(events[-1][0], "done")

    def test_encrypted_hls(self):
        output, folder = self.output("encrypted-output")
        downloader, _ = self.make_downloader("encrypted.m3u8")
        downloader.download("https://jable.tv/videos/client-001/", output)
        self.verify_completed(folder)

    def test_failed_merge_preserves_fragments_and_resume_uses_them(self):
        output, folder = self.output("resume-output")
        first, _ = self.make_downloader(ffmpeg="/usr/bin/false")
        with self.assertRaises(RuntimeError):
            first.download("https://jable.tv/videos/client-001/", output)
        self.assertFalse((folder / "CLIENT-001.mp4").exists())
        fragments = list((folder / ".jable-cache").rglob("*.ts"))
        self.assertGreater(len(fragments), 1)
        second, events = self.make_downloader()
        second.download("https://jable.tv/videos/client-001/", output)
        progress = [fields for kind, fields in events if kind == "progress" and "resumed" in fields]
        self.assertEqual(progress[-1]["resumed"], len(fragments))
        self.verify_completed(folder)

    def test_resume_survives_rotated_signed_queries(self):
        output, folder = self.output("rotated-query-output")
        first, _ = self.make_downloader(ffmpeg="/usr/bin/false")
        playlist = first.playlist(self.url + "plain.m3u8")
        for segment in playlist.segments:
            segment.uri += "?token=old"
        with patch.object(first, "playlist", return_value=playlist), self.assertRaises(RuntimeError):
            first.download("https://jable.tv/videos/client-001/", output)
        fragments = list((folder / ".jable-cache").rglob("*.ts"))
        second, events = self.make_downloader()
        for segment in playlist.segments:
            segment.uri = segment.uri.replace("token=old", "token=new")
        with patch.object(second, "playlist", return_value=playlist):
            second.download("https://jable.tv/videos/client-001/", output)
        progress = [fields for kind, fields in events if kind == "progress" and "resumed" in fields]
        self.assertEqual(progress[-1]["resumed"], len(fragments))
        self.verify_completed(folder)

    def test_large_playlist_uses_bounded_futures_and_progress(self):
        output, folder = self.output("large-playlist-output")
        (folder / ".jable-cache").mkdir()
        downloader, events = self.make_downloader()
        playlist = worker.m3u8.loads("#EXTM3U\n" + "#EXTINF:1,\nsegment.ts\n" * 10_000 + "#EXT-X-ENDLIST\n", uri=self.url)
        peak = 0
        live = weakref.WeakSet()

        class TrackingExecutor(concurrent.futures.ThreadPoolExecutor):
            def submit(self, *args, **kwargs):
                nonlocal peak
                future = super().submit(*args, **kwargs)
                live.add(future)
                peak = max(peak, len(live))
                return future

        with patch.object(downloader, "playlist", return_value=playlist), \
                patch.object(downloader, "fetch_segment", return_value=(1000, True)), \
                patch.object(downloader, "merge"), patch.object(downloader, "fetch_cover"), \
                patch.object(worker.concurrent.futures, "ThreadPoolExecutor", TrackingExecutor):
            downloader.download_media({"title": "large fixture", "stream": self.url, "cover": self.url},
                                      "https://jable.tv/videos/client-001/", "CLIENT-001", folder, folder / ".jable-cache")
        progress = [fields for kind, fields in events if kind == "progress" and "resumed" in fields]
        self.assertEqual(progress[-1]["completed"], 10_000)
        self.assertLessEqual(peak, downloader.workers * 4 + 1)
        self.assertLess(len(progress), 20)

    def test_sigterm_preserves_fragments_and_can_resume(self):
        output, folder = self.output("cancel-output")
        script = """
import signal, sys
import desktop_worker as worker
downloader = worker.Downloader(sys.argv[1], workers=3)
downloader.metadata = lambda _: {"title": "signal fixture", "stream": sys.argv[2], "cover": sys.argv[3]}
signal.signal(signal.SIGTERM, downloader.cancel)
try:
    downloader.download("https://jable.tv/videos/client-001/", sys.argv[4])
except worker.Cancelled:
    worker.emit("cancelled")
    raise SystemExit(130)
finally:
    downloader.close()
"""
        process = subprocess.Popen([worker.sys.executable, "-c", script, self.ffmpeg, self.url + "slow.m3u8",
                                    self.url + "cover.jpg", str(output)], cwd=Path(worker.__file__).parent,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            for line in process.stdout:
                event = json.loads(line)
                if event["event"] == "progress":
                    process.terminate()
                    break
            stdout, stderr = process.communicate(timeout=5)
            self.assertEqual(process.returncode, 130, stderr)
            self.assertIn('"cancelled"', stdout)
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
        fragments = list((folder / ".jable-cache").rglob("*.ts"))
        self.assertTrue(fragments)
        self.assertFalse((folder / "CLIENT-001.mp4").exists())
        resumed, events = self.make_downloader("slow.m3u8")
        resumed.download("https://jable.tv/videos/client-001/", output)
        progress = [fields for kind, fields in events if kind == "progress" and "resumed" in fields]
        self.assertGreater(progress[-1]["resumed"], 0)
        self.verify_completed(folder)

    def test_cover_failure_does_not_redownload_or_overwrite_video(self):
        output, folder = self.output("cover-output")
        first, _ = self.make_downloader()
        with patch.object(first, "fetch_cover", side_effect=RuntimeError("cover temporarily unavailable")), self.assertRaises(RuntimeError):
            first.download("https://jable.tv/videos/client-001/", output)
        before = (folder / "CLIENT-001.mp4").read_bytes()
        second, events = self.make_downloader()
        with patch.object(second, "playlist", side_effect=AssertionError("must not download again")):
            second.download("https://jable.tv/videos/client-001/", output)
        self.assertEqual((folder / "CLIENT-001.mp4").read_bytes(), before)
        self.assertTrue((folder / "CLIENT-001.jpg").is_file())
        self.assertFalse(list((folder / ".jable-cache").rglob("*.ts")))
        self.assertEqual(events[-1][0], "done")


if __name__ == "__main__":
    unittest.main()
