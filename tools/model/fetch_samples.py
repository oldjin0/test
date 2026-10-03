"""Collects sample images for the preview: scikit-image test photos plus a few
public-domain Hokusai Manga pages from Wikimedia Commons (best effort)."""

import json
import os
import sys
import urllib.parse
import urllib.request

from skimage import data, io

out = sys.argv[1]
os.makedirs(out, exist_ok=True)
for name in ["astronaut", "coffee", "chelsea"]:
    io.imsave(f"{out}/{name}.png", getattr(data, name)())

UA = {"User-Agent": "manga-viewer-model-ci/1.0 (github actions)"}
try:
    q = urllib.parse.urlencode({
        "action": "query", "format": "json", "generator": "search",
        "gsrsearch": "Hokusai Manga filetype:bitmap", "gsrnamespace": "6", "gsrlimit": "12",
        "prop": "imageinfo", "iiprop": "url|mime", "iiurlwidth": "900"})
    req = urllib.request.Request("https://commons.wikimedia.org/w/api.php?" + q, headers=UA)
    pages = json.load(urllib.request.urlopen(req, timeout=30))["query"]["pages"].values()
    n = 0
    for p in pages:
        info = p["imageinfo"][0]
        if info.get("mime") not in ("image/jpeg", "image/png") or n >= 3:
            continue
        req = urllib.request.Request(info["thumburl"], headers=UA)
        with open(f"{out}/hokusai_{n}.jpg", "wb") as f:
            f.write(urllib.request.urlopen(req, timeout=30).read())
        n += 1
    print("hokusai samples:", n)
except Exception as e:  # samples are optional
    print("wikimedia fetch failed:", e)
