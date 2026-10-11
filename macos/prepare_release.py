"""Collect redistribution notices and matching dependency source archives."""

import concurrent.futures
import hashlib
import importlib.metadata
import json
import re
import shutil
import subprocess
import sys
import tarfile
import urllib.parse
import zipfile
from pathlib import Path

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

PROJECT = Path(__file__).resolve().parents[1]
SOURCES = PROJECT / "dist/release-sources"
LICENSES = PROJECT / "macos/ThirdPartyLicenses"
NATIVE = ["ffmpeg", "x264", "x265", "lame", "mpg123", "openssl@4", "dav1d",
          "libvpx", "opus", "svt-av1", "libvmaf", "xz"]
LICENSE_NAME = re.compile(r"^(?:licen[cs]e|copying|copyright|notice)(?:\b|[._-])", re.I)


def command(*args):
    return subprocess.check_output(args, text=True).strip()


def digest(path):
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def get_json(url):
    with requests.Session() as session:
        session.mount("https://", HTTPAdapter(max_retries=Retry(
            total=3, backoff_factor=0.5, status_forcelist=[429, 502, 503, 504])))
        response = session.get(url, timeout=(15, 60))
        response.raise_for_status()
        return response.json()


def download(component):
    url = component["url"]
    filename = Path(urllib.parse.urlsplit(url).path).name
    destination = SOURCES / "archives" / filename
    expected = component.get("sha256")
    if destination.is_file() and (not expected or digest(destination) == expected):
        component["sha256"] = digest(destination)
        component["archive"] = "archives/" + filename
        return component
    temporary = destination.with_suffix(destination.suffix + ".download")
    try:
        subprocess.run(["curl", "--fail", "--location", "--silent", "--show-error",
                        "--proto", "=https", "--proto-redir", "=https",
                        "--retry", "3", "--retry-all-errors", "--connect-timeout", "15",
                        "--max-time", "180", "--output", str(temporary), url], check=True)
        actual = digest(temporary)
        if expected and actual != expected:
            raise ValueError("Source checksum mismatch: " + component["name"])
        # Reject HTML/error responses even when the server returned HTTP 200.
        if zipfile.is_zipfile(temporary):
            with zipfile.ZipFile(temporary) as archive:
                archive.testzip()
        else:
            with tarfile.open(temporary):
                pass
        temporary.replace(destination)
        component["sha256"] = actual
        component["archive"] = "archives/" + filename
        print("Source ready: {} {}".format(component["name"], component["version"]), flush=True)
        return component
    finally:
        temporary.unlink(missing_ok=True)


def archive_licenses(component):
    path = SOURCES / component["archive"]
    target = LICENSES / component["name"]

    def save(name, data):
        parts = Path(name).parts
        if ".." in parts or name.startswith("/"):
            raise ValueError("Invalid archive path")
        relative = Path(*parts[1:]) if len(parts) > 1 else Path(parts[0])
        output = target / relative
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_bytes(data)

    if zipfile.is_zipfile(path):
        with zipfile.ZipFile(path) as archive:
            for info in archive.infolist():
                if not info.is_dir() and LICENSE_NAME.match(Path(info.filename).name):
                    save(info.filename, archive.read(info))
    else:
        with tarfile.open(path) as archive:
            for info in archive:
                if info.isfile() and LICENSE_NAME.match(Path(info.name).name):
                    save(info.name, archive.extractfile(info).read())


def main():
    (SOURCES / "archives").mkdir(parents=True, exist_ok=True)
    (SOURCES / "native").mkdir(exist_ok=True)
    LICENSES.mkdir(parents=True, exist_ok=True)
    formulas = json.loads(command("brew", "info", "--json=v2", *NATIVE))["formulae"]
    components = []
    for formula in formulas:
        name = formula["name"]
        prefix = Path(command("brew", "--prefix", name)).resolve()
        version = prefix.name
        expected = formula["versions"]["stable"]
        revision = formula["revision"]
        if revision:
            expected += "_" + str(revision)
        if version != expected:
            raise ValueError("Installed formula differs from source recipe: " + name)
        shutil.copy2(prefix / ".brew" / (name + ".rb"), SOURCES / "native" / (name + ".rb"))
        source = formula["urls"]["stable"]
        url = source["url"]
        if url.endswith(".git"):
            commit = source["revision"]
            if not commit:
                raise ValueError("Git source requires an exact revision: " + name)
            url = url[:-4] + "/-/archive/" + commit + "/" + name + "-" + commit + ".tar.gz"
        components.append({"name": name, "version": version, "url": url,
                           "sha256": source["checksum"], "license": formula["license"],
                           "revision": source["revision"], "recipe": "native/" + name + ".rb"})

    python_version = ".".join(map(str, sys.version_info[:3]))
    components.append({"name": "CPython", "version": python_version,
                       "url": "https://www.python.org/ftp/python/{0}/Python-{0}.tar.xz".format(python_version)})
    shutil.copy2(Path(sys.base_prefix) / "lib" / ("python" + ".".join(python_version.split(".")[:2])) /
                 "LICENSE.txt", LICENSES / "Python-LICENSE.txt")
    for line in (PROJECT / "macos/requirements-lock.txt").read_text().splitlines():
        name, version = line.split("==")
        distribution = importlib.metadata.distribution(name)
        if distribution.version != version:
            raise ValueError("Installed Python dependency differs from lock: " + name)
        metadata = get_json("https://pypi.org/pypi/{}/{}/json".format(name, version))
        source = next(item for item in metadata["urls"] if item["packagetype"] == "sdist")
        components.append({"name": name, "version": version, "url": source["url"],
                           "sha256": source["digests"]["sha256"],
                           "license": metadata["info"].get("license_expression") or metadata["info"].get("license")})
        for file in distribution.files or []:
            if LICENSE_NAME.match(file.name):
                target = LICENSES / name / file
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(distribution.locate_file(file), target)

    # The installer uses dmgbuild's bundled arrow artwork.
    metadata = get_json("https://pypi.org/pypi/dmgbuild/1.6.7/json")
    source = next(item for item in metadata["urls"] if item["packagetype"] == "sdist")
    components.append({"name": "dmgbuild", "version": "1.6.7", "url": source["url"],
                       "sha256": source["digests"]["sha256"], "license": "MIT"})

    # Include the source of MPL-licensed Rust components shipped in Selenium Manager.
    selenium = Path(importlib.metadata.distribution("selenium").locate_file("selenium"))
    manager = selenium / "webdriver/common"
    notice_target = LICENSES / "selenium-manager"
    notice_target.mkdir(exist_ok=True)
    shutil.copy2(manager / "selenium-manager-THIRD-PARTY-NOTICES.txt", notice_target / "NOTICE.txt")
    sbom = json.loads((manager / "selenium-manager.cdx.json").read_text())
    for crate in sbom["components"]:
        if any("MPL-2.0" in item.get("expression", "") for item in crate.get("licenses", [])):
            name, version = crate["name"], crate["version"]
            checksum = next(item["content"] for item in crate["hashes"] if item["alg"] == "SHA-256")
            components.append({"name": "selenium-manager-" + name, "version": version,
                               "url": "https://static.crates.io/crates/{0}/{0}-{1}.crate".format(name, version),
                               "sha256": checksum, "license": "MPL-2.0"})

    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as executor:
        components = list(executor.map(download, components))
    for component in components:
        archive_licenses(component)
    (SOURCES / "SOURCES.json").write_text(json.dumps(components, indent=2, ensure_ascii=False) + "\n")
    shutil.copy2(SOURCES / "SOURCES.json", LICENSES / "SOURCES.json")
    shutil.copy2(PROJECT / "macos/ThirdPartyBuild.md", SOURCES / "BUILD.md")
    shutil.copy2(PROJECT / "macos/ThirdPartyBuild.md", LICENSES / "BUILD.md")
    (SOURCES / "FFmpeg-build.txt").write_text(command("ffmpeg", "-hide_banner", "-version") + "\n")
    archive = PROJECT / "dist/Jable-Download-1.0.0-third-party-sources.tar.gz"
    with tarfile.open(archive, "w:gz") as handle:
        handle.add(SOURCES, arcname="Jable-Download-1.0.0-third-party-sources")
    print("Source archive ready: " + archive.name, flush=True)


if __name__ == "__main__":
    main()
