#!/usr/bin/env python3
"""Track stable Crystal releases for Devbox and the portable Alpine build."""
import json
import os
from pathlib import Path
import re
from urllib.request import Request, urlopen


def main():
    """Refresh stable release pins for the scheduled update pull request."""
    headers = {"User-Agent": "zane-toolchain-updater"}
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if token:
        headers["Authorization"] = "Bearer " + token
    request = Request("https://api.github.com/repos/crystal-lang/crystal/releases/latest", headers=headers)
    with urlopen(request, timeout=60) as response:
        release = json.load(response)
        version = release["tag_name"]
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version):
        raise ValueError("Unexpected Crystal release tag")
    root = Path(__file__).resolve().parents[2]
    assets = {}
    for system, suffix in (("darwin", "darwin-universal"),
                           ("x86_64-linux", "linux-x86_64-bundled"),
                           ("aarch64-linux", "linux-aarch64-bundled")):
        asset = next(a for a in release["assets"]
                     if re.fullmatch(rf"crystal-{re.escape(version)}-[0-9]+-{suffix}\.tar\.gz", a["name"]))
        digest = asset.get("digest", "")
        if not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
            raise ValueError("Crystal release asset has no SHA256 digest")
        assets[system] = {"url": asset["browser_download_url"], "sha256": digest[7:]}
    source = {"version": version, "assets": assets}
    (root / "dev/toolchains/crystal.json").write_text(json.dumps(source, indent=2) + "\n")


if __name__ == "__main__":
    main()
