"""Expand a page / playlist / channel URL into individual video URLs (no Tk).

1. Ask yt-dlp (flat playlist extraction, recursive for channel tabs).
2. If yt-dlp does not support the page, scan its HTML for embedded videos.
"""
from __future__ import annotations

import re
import urllib.request
from dataclasses import dataclass
from html.parser import HTMLParser
from urllib.parse import parse_qs, urljoin, urlparse

import yt_dlp
from yt_dlp.utils import DownloadError

MAX_ENTRIES = 200
MAX_DEPTH = 3
MAX_HTML_BYTES = 5_000_000
USER_AGENT = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
              "(KHTML, like Gecko) Chrome/124.0 Safari/537.36")

MEDIA_EXT_RE = re.compile(r"\.(mp4|m3u8|webm|mov|mkv|m4v|mpd)(\?|#|$)", re.I)
KNOWN_VIDEO_HOSTS = (
    "youtube.com", "youtu.be", "youtube-nocookie.com", "vimeo.com", "dailymotion.com",
    "tiktok.com", "instagram.com", "facebook.com", "fb.watch", "bilibili.com", "twitch.tv",
    "streamable.com", "tv.naver.com", "tv.kakao.com", "xiaohongshu.com", "xhslink.com",
    "twitter.com", "x.com", "soundcloud.com",
)
_YT_ID_RE = re.compile(
    r"(?:youtube(?:-nocookie)?\.com/(?:embed|v)/|youtube\.com/watch\?v=|youtu\.be/)([\w-]{11})")
_TEXT_URL_RE = re.compile(r"https?:\\?/\\?/[^\s\"'<>]+?\.(?:mp4|m3u8|webm|mov|mkv|m4v)[^\s\"'<>\\]*", re.I)


@dataclass
class Entry:
    url: str
    title: str = ""
    index: int | None = None  # 1-based playlist item of `url` (videos embedded inline in a page)


# ---------- HTML scan (offline-testable) ----------
class _Scanner(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.found: list[tuple[str, str]] = []  # (url, kind)

    def handle_starttag(self, tag, attrs):
        a = {k.lower(): (v or "") for k, v in attrs}
        if tag in ("video", "source", "embed") and a.get("src"):
            self.found.append((a["src"], tag))
        if tag == "video" and a.get("data-src"):
            self.found.append((a["data-src"], tag))
        elif tag == "iframe" and (a.get("src") or a.get("data-src")):
            self.found.append((a.get("src") or a["data-src"], "iframe"))
        elif tag == "meta":
            key = (a.get("property") or a.get("name") or "").lower()
            if key in ("og:video", "og:video:url", "og:video:secure_url", "twitter:player:stream") \
                    and a.get("content"):
                self.found.append((a["content"], "meta"))
        elif tag == "a" and a.get("href"):
            self.found.append((a["href"], "a"))


def _host(url: str) -> str:
    try:
        return (urlparse(url).hostname or "").lower()
    except ValueError:
        return ""


def _known_host(url: str) -> bool:
    h = _host(url)
    return any(h == k or h.endswith("." + k) for k in KNOWN_VIDEO_HOSTS)


def normalize_embed(url: str) -> str:
    """youtube.com/embed/ID -> watch?v=ID (yt-dlp handles both, watch is the canonical form)."""
    m = _YT_ID_RE.search(url)
    return f"https://www.youtube.com/watch?v={m.group(1)}" if m else url


def find_video_links(html: str, base_url: str) -> list[Entry]:
    """Video candidates found in raw HTML: <video>/<source>, og:video, known-host iframes/links,
    direct media links and media URLs embedded in inline JSON/scripts."""
    sc = _Scanner()
    try:
        sc.feed(html)
    except Exception:
        pass
    cands: list[str] = []
    for raw, kind in sc.found:
        raw = raw.strip()
        if not raw or raw.startswith(("data:", "blob:", "javascript:", "#")):
            continue
        url = urljoin(base_url, raw)
        if urlparse(url).scheme not in ("http", "https"):
            continue
        if kind in ("video", "source", "meta") or MEDIA_EXT_RE.search(url) or _known_host(url):
            if kind in ("a", "iframe", "embed") and not (MEDIA_EXT_RE.search(url) or _known_host(url)):
                continue
            cands.append(normalize_embed(url))
    for m in _TEXT_URL_RE.finditer(html):
        cands.append(urljoin(base_url, m.group(0).replace("\\/", "/")))
    for m in _YT_ID_RE.finditer(html):
        cands.append(f"https://www.youtube.com/watch?v={m.group(1)}")

    out: list[Entry] = []
    seen = {base_url.rstrip("/")}
    for u in cands:
        key = u.rstrip("/")
        if key in seen:
            continue
        seen.add(key)
        out.append(Entry(u))
    return out


def fetch_html(url: str, timeout: int = 20) -> str:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Accept-Language": "ko,en;q=0.8"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        raw = r.read(MAX_HTML_BYTES)
        charset = r.headers.get_content_charset() or "utf-8"
    return raw.decode(charset, errors="replace")


# ---------- yt-dlp expansion ----------
def is_single_video_hint(url: str) -> bool:
    """YouTube watch?v=X&list=Y means 'this video', not the whole list."""
    try:
        p = urlparse(url)
        q = parse_qs(p.query)
    except ValueError:
        return False
    return "youtube" in (p.hostname or "") and p.path.startswith("/watch") and "v" in q


def _entry_url(e: dict) -> str | None:
    for key in ("url", "webpage_url"):
        u = e.get(key)
        if isinstance(u, str) and u.startswith(("http://", "https://")):
            return u
    return None


def _flatten(info: dict, out: list[Entry], seen: set, depth: int = 0) -> None:
    page_url = info.get("webpage_url") or info.get("original_url")
    for pos, e in enumerate(info.get("entries") or [], 1):
        if not e or len(out) >= MAX_ENTRIES:
            continue
        if e.get("_type") == "playlist" or (e.get("entries") is not None):
            if depth < MAX_DEPTH:
                _flatten(e, out, seen, depth + 1)
            continue
        if e.get("formats") and page_url:
            # fully extracted inline (e.g. <video> tags): keep the page + item number so
            # subtitles (<track>) and request headers survive
            key, entry = (page_url, pos), Entry(page_url, e.get("title") or "", pos)
        else:
            url = _entry_url(e)
            if not url:
                continue
            key, entry = (url, None), Entry(url, e.get("title") or "")
        if key in seen:
            continue
        seen.add(key)
        out.append(entry)


def extract_entries(url: str, *, cookies_browser: str | None = None, deno_path: str | None = None,
                    logger=None, allow_many: bool = True) -> tuple[list[Entry], bool]:
    """Return (entries, truncated). A single video yields one Entry with the original URL.
    allow_many=False keeps only the first video of a multi-video page."""
    opts: dict = {
        "quiet": True, "no_warnings": True, "skip_download": True, "noprogress": True,
        "extract_flat": "in_playlist", "socket_timeout": 30,
    }
    if is_single_video_hint(url):
        opts["noplaylist"] = True  # only set when True: some extractors treat an explicit False differently
    if logger is not None:
        opts["logger"] = logger
    if deno_path:
        opts["js_runtimes"] = {"deno": {"path": deno_path}}
    if cookies_browser:
        opts["cookiesfrombrowser"] = (cookies_browser,)

    entries: list[Entry] = []
    ytdlp_error: Exception | None = None
    try:
        with yt_dlp.YoutubeDL(opts) as ydl:
            info = ydl.extract_info(url, download=False)
        if info:
            if info.get("entries") is None:
                return [Entry(url, info.get("title") or "")], False
            _flatten(info, entries, set())
    except DownloadError as e:
        ytdlp_error = e

    if not entries:
        # yt-dlp has no extractor for this page (or it was empty): scan the HTML ourselves
        try:
            entries = find_video_links(fetch_html(url), url)
        except Exception as e:  # network / decoding problems
            if ytdlp_error is not None:
                raise ytdlp_error
            raise DownloadError(f"페이지를 읽지 못했습니다: {e}")
        if not entries:
            if ytdlp_error is not None:
                raise ytdlp_error
            raise DownloadError("이 페이지에서 영상을 찾지 못했습니다")

    truncated = len(entries) >= MAX_ENTRIES
    if not allow_many:
        entries, truncated = entries[:1], False
    return entries[:MAX_ENTRIES], truncated
