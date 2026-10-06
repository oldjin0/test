import json
import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from app import downloader as dl
from app.config import Settings, load_settings, save_settings
from app.utils import (clean_error_message, format_bytes, format_eta, parse_urls,
                       truncate)


def test_parse_urls_multiline_dedupe_comments():
    text = """
    # comment
    https://youtu.be/abc

    https://youtu.be/abc
    https://example.com/a   https://example.com/b
    """
    valid, invalid = parse_urls(text)
    assert valid == ["https://youtu.be/abc", "https://example.com/a", "https://example.com/b"]
    assert invalid == []


def test_parse_urls_prefix_and_invalid():
    valid, invalid = parse_urls("youtu.be/xyz\nwww.instagram.com/p/1/\nhello\nftp://a.com/x\nhttp://localhost:8000/v")
    assert valid == ["https://youtu.be/xyz", "https://www.instagram.com/p/1/", "http://localhost:8000/v"]
    assert invalid == ["hello", "ftp://a.com/x"]


def test_parse_urls_dedupe_after_prefix():
    valid, _ = parse_urls("youtu.be/x\nhttps://youtu.be/x")
    assert valid == ["https://youtu.be/x"]


def _opts(preset=dl.DEFAULT_PRESET, ff=True, cookies=dl.NO_COOKIES, pl=False):
    return dl.build_ydl_opts(preset, "/tmp/x", "/ff" if ff else None, ff, cookies, pl)


def test_default_preset():
    o = _opts()
    assert dl.DEFAULT_PRESET == "최고 화질 (MP4 병합)"
    assert o["format"] == "bv*+ba/b"
    assert o["merge_output_format"] == "mp4"
    assert o["ffmpeg_location"] == "/ff"
    assert o["noplaylist"] is True
    assert o["quiet"] and o["noprogress"]
    assert "cookiesfrombrowser" not in o


def test_no_ffmpeg_fallback():
    o = _opts(ff=False)
    assert o["format"] == "b" and "merge_output_format" not in o
    assert "ffmpeg_location" not in o
    assert _opts("720p 이하", ff=False)["format"] == "b[height<=720]"


@pytest.mark.parametrize("h", [1080, 720, 480])
def test_height_caps(h):
    o = _opts(f"{h}p 이하")
    assert f"height<={h}" in o["format"] and o["merge_output_format"] == "mp4"


def test_mp3_preset():
    o = _opts("오디오만 (MP3)")
    assert o["format"] == "ba/b"
    assert o["postprocessors"][0]["key"] == "FFmpegExtractAudio"
    assert o["postprocessors"][0]["preferredcodec"] == "mp3"
    with pytest.raises(dl.FFmpegRequiredError, match="FFmpeg가 필요합니다"):
        _opts("오디오만 (MP3)", ff=False)


def test_cookies_playlist_and_compat():
    o = _opts(cookies="firefox", pl=True)
    assert o["cookiesfrombrowser"] == ("firefox",) and o["noplaylist"] is False
    assert _opts(dl.PRESETS and list(dl.PRESETS)[1])["format_sort"][0] == "vcodec:h264"


def test_deno_option():
    o = dl.build_ydl_opts(dl.DEFAULT_PRESET, "/t", None, False, dl.NO_COOKIES, False, deno_path="/d/deno")
    assert o["js_runtimes"] == {"deno": {"path": "/d/deno"}}


def test_pick_final_path():
    assert dl.pick_final_path({}, "/a.mp4") == "/a.mp4"
    assert dl.pick_final_path({"requested_downloads": [{"filepath": "/b.mp4"}]}, None) == "/b.mp4"
    pl = {"entries": [{"requested_downloads": [{"filepath": "/1"}]}, {"requested_downloads": [{"filepath": "/2"}]}]}
    assert dl.pick_final_path(pl, None) == "/2"
    assert dl.pick_final_path(None, None) is None


def test_format_helpers():
    assert format_bytes(3.2 * 1024 * 1024) == "3.2 MiB"
    assert format_bytes(512) == "512 B"
    assert format_eta(65) == "01:05"
    assert format_eta(None) == "--:--"
    assert format_eta(3725) == "1:02:05"
    assert truncate("a" * 100, 10) == "a" * 9 + "…"
    assert truncate("abc", 10) == "abc"
    assert clean_error_message("\x1b[0;31mERROR:\x1b[0m [x] boom\nmore") == "[x] boom"


def test_settings_corrupt_and_roundtrip(tmp_path):
    p = tmp_path / "s.json"
    assert load_settings(p) == Settings()
    p.write_text("{not json", encoding="utf-8")
    assert load_settings(p) == Settings()
    p.write_text(json.dumps({"theme": "Dark", "bogus": 1, "allow_playlist": "yes"}), encoding="utf-8")
    s = load_settings(p)
    assert s.theme == "Dark" and s.allow_playlist is True  # wrong type -> default
    s.quality = "720p 이하"
    assert save_settings(s, tmp_path / "sub" / "s.json")
    assert load_settings(tmp_path / "sub" / "s.json").quality == "720p 이하"


# ---------- subtitles / page extraction ----------
from app.extractor import find_video_links, is_single_video_hint, normalize_embed  # noqa: E402


def _sub_opts(**kw):
    base = dict(preset_key=dl.DEFAULT_PRESET, save_dir="/tmp/x", ffmpeg_path="/ff", has_ffmpeg=True,
                cookies_browser="사용 안 함", allow_playlist=False)
    base.update(kw)
    return dl.build_ydl_opts(**base)


def test_no_subtitles_by_default():
    o = _sub_opts()
    assert "writesubtitles" not in o and "postprocessors" not in o


def test_korean_subtitles_with_ffmpeg():
    o = _sub_opts(subtitles=True, auto_subs=True)
    assert o["writesubtitles"] and o["writeautomaticsub"]
    assert o["subtitleslangs"] == ["ko", "ko-.*"]
    keys = [p["key"] for p in o["postprocessors"]]
    assert keys == ["FFmpegSubtitlesConvertor"]


def test_embed_subtitles_keeps_srt():
    o = _sub_opts(subtitles=True, embed_subs=True)
    emb = [p for p in o["postprocessors"] if p["key"] == "FFmpegEmbedSubtitle"]
    assert emb and emb[0]["already_have_subtitle"] is True
    assert o["writeautomaticsub"] is False


def test_subtitles_without_ffmpeg_have_no_postprocessors():
    o = _sub_opts(subtitles=True, has_ffmpeg=False, ffmpeg_path=None)
    assert o["writesubtitles"] and "postprocessors" not in o


def test_audio_preset_never_embeds():
    o = _sub_opts(preset_key="오디오만 (MP3)", subtitles=True, embed_subs=True)
    assert "FFmpegEmbedSubtitle" not in [p["key"] for p in o["postprocessors"]]


def test_playlist_item_option():
    assert _sub_opts(item=2)["playlist_items"] == "2"
    assert "playlist_items" not in _sub_opts()


def test_collect_subtitle_langs():
    assert dl.collect_subtitle_langs(None) == []
    info = {"entries": [{"requested_subtitles": {"ko": {}}}, None, {"requested_subtitles": None}]}
    assert dl.collect_subtitle_langs(info) == ["ko"]
    assert dl.collect_subtitle_langs({"requested_subtitles": {"ko-KR": {}}}) == ["ko-KR"]


def test_find_video_links_page_scan():
    html = """
    <meta property="og:video" content="/media/og.mp4">
    <video src="v1.mp4"></video>
    <video><source src="//cdn.example.com/v2.webm"></video>
    <iframe src="https://www.youtube.com/embed/dQw4w9WgXcQ"></iframe>
    <iframe src="https://ads.example.com/banner"></iframe>
    <a href="https://vimeo.com/12345">v</a><a href="/about">about</a>
    <a href="clip.m3u8?token=1">hls</a>
    <script>var u = "https:\\/\\/cdn.example.com\\/x\\/s.mp4?a=1";</script>
    """
    urls = [e.url for e in find_video_links(html, "https://site.example.com/page/")]
    assert "https://site.example.com/media/og.mp4" in urls
    assert "https://site.example.com/page/v1.mp4" in urls
    assert "https://cdn.example.com/v2.webm" in urls
    assert "https://www.youtube.com/watch?v=dQw4w9WgXcQ" in urls
    assert "https://vimeo.com/12345" in urls
    assert "https://site.example.com/page/clip.m3u8?token=1" in urls
    assert "https://cdn.example.com/x/s.mp4?a=1" in urls
    assert not any("ads.example.com" in u or u.endswith("/about") for u in urls)
    assert len(urls) == len(set(urls))


def test_find_video_links_skips_self_and_junk():
    html = '<a href="https://s.example.com/p">self</a><video src="data:video/mp4;base64,AAA"></video>'
    assert find_video_links(html, "https://s.example.com/p") == []


def test_single_video_hint_and_embed_normalize():
    assert is_single_video_hint("https://www.youtube.com/watch?v=abc&list=PL1")
    assert not is_single_video_hint("https://www.youtube.com/playlist?list=PL1")
    assert normalize_embed("https://www.youtube-nocookie.com/embed/dQw4w9WgXcQ?rel=0").endswith("v=dQw4w9WgXcQ")
    assert normalize_embed("https://example.com/a") == "https://example.com/a"
