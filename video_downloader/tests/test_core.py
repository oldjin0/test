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
    assert s.theme == "Dark" and s.allow_playlist is False
    s.quality = "720p 이하"
    assert save_settings(s, tmp_path / "sub" / "s.json")
    assert load_settings(tmp_path / "sub" / "s.json").quality == "720p 이하"
