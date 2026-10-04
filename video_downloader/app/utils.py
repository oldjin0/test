"""URL parsing, tool locating, folder opening and formatting helpers (no Tk)."""
from __future__ import annotations

import os
import re
import shutil
import subprocess
import sys
from urllib.parse import urlparse

from .config import app_base_dir, resource_dir

_ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[ -/]*[@-~]")


# ---------- URL ----------
def _normalize(token: str) -> str | None:
    """Return a valid http(s) URL for token, or None."""
    t = token.strip()
    if not t:
        return None
    if "://" not in t:
        first = re.split(r"[/?#]", t, 1)[0]
        if "." in first or first.lower().startswith("localhost"):
            t = "https://" + t
        else:
            return None
    try:
        p = urlparse(t)
        host = p.hostname or ""
    except ValueError:
        return None
    if p.scheme not in ("http", "https") or not host:
        return None
    if "." not in host and host != "localhost":
        return None
    return t


def parse_urls(text: str) -> tuple[list[str], list[str]]:
    valid: list[str] = []
    invalid: list[str] = []
    seen: set[str] = set()
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        for token in line.split():
            url = _normalize(token)
            if url is None:
                if token not in invalid:
                    invalid.append(token)
            elif url not in seen:
                seen.add(url)
                valid.append(url)
    return valid, invalid


# ---------- tool locating ----------
def _exe_name(name: str) -> str:
    return name + (".exe" if os.name == "nt" else "")


def _search_dirs(subdir: str) -> list[str]:
    base = app_base_dir()
    dirs = [resource_dir(), base, base / subdir, base / subdir / "bin"]
    out: list[str] = []
    for d in dirs:
        s = str(d)
        if s not in out:
            out.append(s)
    return out


def _find_tool(name: str, subdir: str) -> str | None:
    """Full path to the tool executable, or None."""
    exe = _exe_name(name)
    for d in _search_dirs(subdir):
        cand = os.path.join(d, exe)
        if os.path.isfile(cand):
            return cand
    return shutil.which(name)


def find_ffmpeg() -> str | None:
    """Directory containing ffmpeg (usable as yt-dlp ffmpeg_location), or None."""
    p = _find_tool("ffmpeg", "ffmpeg")
    return os.path.dirname(p) if p else None


def find_deno() -> str | None:
    """Full path to deno executable, or None."""
    return _find_tool("deno", "deno")


# ---------- open folder ----------
def _spawn(cmd: list[str]) -> None:
    try:
        subprocess.Popen(cmd)
    except Exception:
        pass


def open_folder(folder: str) -> None:
    try:
        if not folder or not os.path.isdir(folder):
            return
        if sys.platform.startswith("win"):
            os.startfile(folder)  # type: ignore[attr-defined]
        elif sys.platform == "darwin":
            _spawn(["open", folder])
        else:
            _spawn(["xdg-open", folder])
    except Exception:
        pass


def reveal_in_explorer(path: str) -> None:
    try:
        if path and os.path.isfile(path):
            if sys.platform.startswith("win"):
                _spawn(["explorer", "/select,", os.path.normpath(path)])
            elif sys.platform == "darwin":
                _spawn(["open", "-R", path])
            else:
                open_folder(os.path.dirname(path))
        elif path:
            open_folder(os.path.dirname(path) if not os.path.isdir(path) else path)
    except Exception:
        pass


# ---------- formatting ----------
def format_bytes(n: float | int | None) -> str:
    if n is None:
        return "--"
    n = float(n)
    if n < 1024:
        return f"{int(n)} B"
    for unit in ("KiB", "MiB", "GiB", "TiB"):
        n /= 1024
        if n < 1024 or unit == "TiB":
            return f"{n:.1f} {unit}"
    return f"{n:.1f} TiB"


def format_speed(bps: float | None) -> str:
    return f"{format_bytes(bps)}/s" if bps else "--"


def format_eta(seconds: float | int | None) -> str:
    if seconds is None or seconds < 0:
        return "--:--"
    s = int(seconds)
    h, rem = divmod(s, 3600)
    m, sec = divmod(rem, 60)
    return f"{h}:{m:02d}:{sec:02d}" if h else f"{m:02d}:{sec:02d}"


def truncate(text: str, limit: int = 70) -> str:
    text = text or ""
    return text if len(text) <= limit else text[: limit - 1] + "…"


def strip_ansi(text: str) -> str:
    return _ANSI_RE.sub("", text or "")


def clean_error_message(msg: str, limit: int = 300) -> str:
    lines = [l.strip() for l in strip_ansi(str(msg)).splitlines() if l.strip()]
    text = lines[0] if lines else "알 수 없는 오류"
    if text.startswith("ERROR:"):
        text = text[len("ERROR:"):].strip()
    return truncate(text, limit)
