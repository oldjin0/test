"""Download jobs, quality presets, yt-dlp option building and the worker thread (no Tk)."""
from __future__ import annotations

import itertools
import os
import queue
import threading
import time
from dataclasses import dataclass, field

import yt_dlp
from yt_dlp.utils import DownloadCancelled, DownloadError

from .config import Settings
from .extractor import extract_entries
from .utils import clean_error_message, format_bytes, format_eta, format_speed

# ---------- statuses ----------
ST_QUEUED = "대기 중"
ST_ANALYZING = "분석 중"
ST_DOWNLOADING = "다운로드 중"
ST_MERGING = "병합 중"
ST_AUDIO = "오디오 변환 중"
ST_POST = "후처리 중"
ST_DONE = "완료"
ST_FAILED = "실패"
ST_CANCELLED = "취소됨"

NO_COOKIES = "사용 안 함"
COOKIE_BROWSERS = ["chrome", "edge", "firefox", "whale"]
COOKIE_CHOICES = [NO_COOKIES] + COOKIE_BROWSERS

OUTTMPL = "%(title).150B [%(id)s].%(ext)s"

# Korean subtitles: "ko" plus regional/variant tags (ko-KR, ko-orig, ...). Entries are regexes.
SUB_LANGS = ["ko", "ko-.*"]

# ---------- presets ----------
# Key == Korean label shown in the dropdown. "height" is used for the no-FFmpeg fallback.
PRESETS: dict[str, dict] = {
    "최고 화질 (MP4 병합)": {
        "format": "bv*+ba/b", "merge": "mp4", "height": None,
    },
    # Prefers H.264/AAC for compatibility; on YouTube this may cap at 1080p
    # because higher resolutions are usually VP9/AV1 only.
    "최고 화질 · 호환성 우선 (H.264/AAC MP4)": {
        "format": "bv*+ba/b", "merge": "mp4", "height": None,
        "sort": ["vcodec:h264", "res", "acodec:aac"],
    },
    "1080p 이하": {
        "format": "bv*[height<=1080]+ba/b[height<=1080]", "merge": "mp4", "height": 1080,
    },
    "720p 이하": {
        "format": "bv*[height<=720]+ba/b[height<=720]", "merge": "mp4", "height": 720,
    },
    "480p 이하": {
        "format": "bv*[height<=480]+ba/b[height<=480]", "merge": "mp4", "height": 480,
    },
    "오디오만 (MP3)": {
        "format": "ba/b", "audio": True,
        "postprocessors": [{"key": "FFmpegExtractAudio", "preferredcodec": "mp3",
                            "preferredquality": "192"}],
    },
}
DEFAULT_PRESET = next(iter(PRESETS))


class FFmpegRequiredError(RuntimeError):
    pass


def build_ydl_opts(preset_key, save_dir, ffmpeg_path, has_ffmpeg, cookies_browser,
                   allow_playlist, progress_hook=None, postprocessor_hook=None,
                   logger=None, deno_path=None, subtitles=False, auto_subs=False,
                   embed_subs=False, item=None) -> dict:
    preset = PRESETS.get(preset_key) or PRESETS[DEFAULT_PRESET]
    opts: dict = {
        "outtmpl": os.path.join(save_dir, OUTTMPL),
        "windowsfilenames": True,
        "restrictfilenames": False,
        "retries": 10,
        "fragment_retries": 10,
        "socket_timeout": 30,
        "concurrent_fragment_downloads": 4,
        "progress_hooks": [progress_hook] if progress_hook else [],
        "postprocessor_hooks": [postprocessor_hook] if postprocessor_hook else [],
        "quiet": True,
        "no_warnings": False,
        "noprogress": True,
        "noplaylist": not allow_playlist,
    }
    if logger is not None:
        opts["logger"] = logger
    if has_ffmpeg and ffmpeg_path:
        opts["ffmpeg_location"] = ffmpeg_path
    if deno_path:
        # yt-dlp Python API: {runtime: {"path": ...}} (see YoutubeDL.py js_runtimes docs)
        opts["js_runtimes"] = {"deno": {"path": deno_path}}
    if item:
        opts["playlist_items"] = str(item)
    if cookies_browser in COOKIE_BROWSERS:
        opts["cookiesfrombrowser"] = (cookies_browser,)

    if subtitles:
        opts["writesubtitles"] = True
        opts["writeautomaticsub"] = bool(auto_subs)
        opts["subtitleslangs"] = list(SUB_LANGS)
        opts["subtitlesformat"] = "srt/vtt/best"

    if preset.get("audio"):
        if not has_ffmpeg:
            raise FFmpegRequiredError("FFmpeg가 필요합니다 (MP3 변환)")
        opts["format"] = preset["format"]
        opts["postprocessors"] = [dict(p) for p in preset["postprocessors"]]
    elif has_ffmpeg:
        opts["format"] = preset["format"]
        opts["merge_output_format"] = preset["merge"]
        if preset.get("sort"):
            opts["format_sort"] = list(preset["sort"])
    else:
        h = preset.get("height")
        opts["format"] = f"b[height<={h}]" if h else "b"

    if subtitles and has_ffmpeg:
        pps = opts.setdefault("postprocessors", [])
        pps.append({"key": "FFmpegSubtitlesConvertor", "format": "srt", "when": "before_dl"})
        if embed_subs and not preset.get("audio"):
            # already_have_subtitle=True keeps the .srt file next to the video
            pps.append({"key": "FFmpegEmbedSubtitle", "already_have_subtitle": True})
    return opts


def pick_final_path(info: dict | None, captured: str | None) -> str | None:
    """Prefer hook-captured path, else requested_downloads (last entry for playlists)."""
    if captured:
        return captured
    if not info:
        return None
    entries = [e for e in (info.get("entries") or []) if e]
    for node in ([entries[-1]] if entries else []) + [info]:
        rd = node.get("requested_downloads") or []
        if rd and rd[-1].get("filepath"):
            return rd[-1]["filepath"]
    return None


def collect_subtitle_langs(info: dict | None) -> list[str]:
    """Languages of the subtitles that were downloaded (the video itself or its playlist items)."""
    found: set[str] = set()
    for node in [info] + list((info or {}).get("entries") or []):
        if node:
            found.update((node.get("requested_subtitles") or {}).keys())
    return sorted(found)


# ---------- model & events ----------
@dataclass
class DownloadJob:
    id: int
    url: str
    title: str = ""
    status: str = ST_QUEUED
    filepath: str | None = None
    error: str = ""
    resolved: bool = False  # True once the URL is known to be a single video
    item: int | None = None  # playlist item to take from `url` (video embedded in a page)


_ids = itertools.count(1)


def new_job(url: str) -> DownloadJob:
    return DownloadJob(id=next(_ids), url=url)


@dataclass
class JobStarted:
    job_id: int
    title: str


@dataclass
class Progress:
    job_id: int
    percent: float | None
    speed: str
    eta: str
    downloaded: str


@dataclass
class StatusEvent:
    job_id: int
    status: str
    msg: str = ""


@dataclass
class JobDone:
    job_id: int
    filepath: str | None
    subs: list = field(default_factory=list)  # downloaded subtitle languages


@dataclass
class JobsExpanded:
    """A page/playlist job was replaced by the videos found inside it."""
    parent_id: int
    jobs: list


@dataclass
class JobFailed:
    job_id: int
    error: str


@dataclass
class LogEvent:
    level: str
    msg: str


@dataclass
class AllDone:
    ok: int = 0
    failed: int = 0
    cancelled: int = 0
    failures: list = field(default_factory=list)  # [(url, reason)]


class _Logger:
    def __init__(self, post):
        self._post = post

    def debug(self, msg):
        pass

    def info(self, msg):
        pass

    def warning(self, msg):
        self._post(LogEvent("warning", clean_error_message(msg)))

    def error(self, msg):
        self._post(LogEvent("error", clean_error_message(msg)))


# ---------- worker ----------
class DownloadWorker(threading.Thread):
    def __init__(self, jobs: list[DownloadJob], settings: Settings,
                 events: "queue.Queue", cancel: threading.Event,
                 ffmpeg_path: str | None, deno_path: str | None = None):
        super().__init__(daemon=True, name="DownloadWorker")
        self.jobs = jobs
        self.settings = settings
        self.events = events
        self.cancel = cancel
        self.ffmpeg_path = ffmpeg_path
        self.deno_path = deno_path

    def post(self, ev) -> None:
        self.events.put(ev)

    def run(self) -> None:
        summary = AllDone()
        pending = list(self.jobs)
        try:
            while pending:
                job = pending.pop(0)
                if self.cancel.is_set():
                    self._mark_cancelled(job, summary)
                    continue
                try:
                    if not job.resolved:
                        children = self._analyze(job)
                        if children:
                            pending[0:0] = children
                            continue
                    self._run_job(job)
                    summary.ok += 1
                except DownloadCancelled:
                    self._mark_cancelled(job, summary)
                except DownloadError as e:
                    if self.cancel.is_set():
                        self._mark_cancelled(job, summary)
                    else:
                        self._fail(job, summary, e)
                except Exception as e:  # never let the thread die
                    self._fail(job, summary, e)
        except BaseException as e:
            self.post(LogEvent("error", clean_error_message(repr(e))))
        finally:
            self.post(summary)

    def _analyze(self, job: DownloadJob) -> list[DownloadJob] | None:
        """Look inside the URL. Returns child jobs when it holds several videos, else None
        (the job itself is a single video and gets downloaded as is)."""
        s = self.settings
        job.status = ST_ANALYZING
        self.post(StatusEvent(job.id, ST_ANALYZING))
        entries, truncated = extract_entries(
            job.url,
            cookies_browser=s.cookies_browser if s.cookies_browser in COOKIE_BROWSERS else None,
            deno_path=self.deno_path, logger=_Logger(self.post), allow_many=s.allow_playlist)
        job.resolved = True
        if len(entries) == 1:
            job.url, job.item = entries[0].url, entries[0].index
            if entries[0].title:
                job.title = entries[0].title
            return None
        children = []
        for e in entries:
            c = new_job(e.url)
            c.title, c.resolved, c.item = e.title, True, e.index
            children.append(c)
        self.post(JobsExpanded(job.id, children))
        if truncated:
            self.post(LogEvent("warning", f"영상이 너무 많아 처음 {len(entries)}개만 추출했습니다"))
        return children

    def _mark_cancelled(self, job, summary):
        summary.cancelled += 1
        job.status = ST_CANCELLED
        self.post(StatusEvent(job.id, ST_CANCELLED))

    def _fail(self, job, summary, exc):
        msg = clean_error_message(str(exc) or exc.__class__.__name__)
        summary.failed += 1
        job.status, job.error = ST_FAILED, msg
        summary.failures.append((job.url, msg))
        self.post(JobFailed(job.id, msg))

    def _run_job(self, job: DownloadJob) -> None:
        s = self.settings
        os.makedirs(s.save_dir, exist_ok=True)
        self.post(JobStarted(job.id, job.title or job.url))
        job.status = ST_DOWNLOADING

        state = {"title": job.title, "item": None, "parts_done": 0, "last": 0.0, "path": None}

        def progress_hook(d):
            if self.cancel.is_set():
                raise DownloadCancelled()
            info = d.get("info_dict") or {}
            title = info.get("title")
            if title and title != state["title"]:
                state["title"] = title
                job.title = title
                self.post(JobStarted(job.id, title))
            item_id = info.get("id")
            if item_id != state["item"]:
                state["item"], state["parts_done"] = item_id, 0
            parts = max(1, len(info.get("requested_formats") or []))
            done = min(state["parts_done"], parts - 1)
            status = d.get("status")
            if status == "finished":
                state["parts_done"] += 1
                last_part = state["parts_done"] >= parts
                self.post(Progress(job.id, 100.0 * state["parts_done"] / parts
                                   if not last_part else 100.0, "", "", format_bytes(d.get("total_bytes") or d.get("downloaded_bytes"))))
                if last_part:
                    self.post(StatusEvent(job.id, ST_POST))
                return
            if status != "downloading":
                return
            now = time.monotonic()
            if now - state["last"] < 0.2:
                return
            state["last"] = now
            downloaded = d.get("downloaded_bytes") or 0
            total = d.get("total_bytes") or d.get("total_bytes_estimate")
            pct = None
            if total:
                frac = min(downloaded / total, 1.0)
                pct = (done + frac) / parts * 100.0
            self.post(Progress(job.id, pct, format_speed(d.get("speed")),
                               format_eta(d.get("eta")), format_bytes(downloaded)))

        def pp_hook(d):
            if self.cancel.is_set():
                raise DownloadCancelled()
            pp, status = d.get("postprocessor"), d.get("status")
            if status == "started":
                if pp == "Merger":
                    self.post(StatusEvent(job.id, ST_MERGING))
                elif pp == "ExtractAudio":
                    self.post(StatusEvent(job.id, ST_AUDIO))
                else:
                    self.post(StatusEvent(job.id, ST_POST))
            elif status == "finished":
                fp = (d.get("info_dict") or {}).get("filepath")
                if fp:
                    state["path"] = fp

        opts = build_ydl_opts(
            s.quality, s.save_dir, self.ffmpeg_path, bool(self.ffmpeg_path),
            s.cookies_browser, False, progress_hook, pp_hook,
            _Logger(self.post), self.deno_path,
            subtitles=s.subtitles, auto_subs=s.auto_subs, embed_subs=s.embed_subs,
            item=job.item)

        with yt_dlp.YoutubeDL(opts) as ydl:
            info = ydl.extract_info(job.url, download=True)
            path = pick_final_path(info, state["path"])
            if not path and info and not info.get("entries"):
                try:
                    path = ydl.prepare_filename(info)
                except Exception:
                    path = None
        subs = collect_subtitle_langs(info)
        job.filepath, job.status = path, ST_DONE
        self.post(JobDone(job.id, path, subs))
