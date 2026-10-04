"""Settings dataclass with tolerant JSON load/save, plus base-dir helpers."""
from __future__ import annotations

import json
import os
import sys
from dataclasses import asdict, dataclass, fields
from pathlib import Path

from . import APP_NAME

THEMES = ("System", "Dark", "Light")
DEFAULT_PRESET_KEY = "최고 화질 (MP4 병합)"


def app_base_dir() -> Path:
    """Directory of the exe when frozen, else the project folder."""
    if getattr(sys, "frozen", False):
        return Path(sys.executable).resolve().parent
    return Path(__file__).resolve().parent.parent


def resource_dir() -> Path:
    """PyInstaller extraction dir when frozen, else the project folder."""
    if getattr(sys, "frozen", False):
        return Path(getattr(sys, "_MEIPASS", app_base_dir()))
    return Path(__file__).resolve().parent.parent


def settings_path() -> Path:
    if os.name == "nt":
        root = Path(os.environ.get("APPDATA") or Path.home() / "AppData" / "Roaming")
    else:
        root = Path.home() / ".config"
    return root / APP_NAME / "settings.json"


def default_save_dir() -> str:
    dl = Path.home() / "Downloads"
    if dl.is_dir():
        return str(dl)
    return str(app_base_dir() / "downloads")


@dataclass
class Settings:
    save_dir: str = ""
    quality: str = DEFAULT_PRESET_KEY
    open_folder_after: bool = False
    theme: str = "System"
    cookies_browser: str = "사용 안 함"
    allow_playlist: bool = False

    def __post_init__(self):
        if not self.save_dir:
            self.save_dir = default_save_dir()


def load_settings(path: Path | str | None = None) -> Settings:
    p = Path(path) if path else settings_path()
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            return Settings()
    except (OSError, ValueError):
        return Settings()
    defaults = Settings()
    kwargs = {}
    for f in fields(Settings):
        if f.name not in data:
            continue
        v = data[f.name]
        if type(v) is type(getattr(defaults, f.name)):
            kwargs[f.name] = v
    s = Settings(**kwargs)
    if s.theme not in THEMES:
        s.theme = "System"
    return s


def save_settings(s: Settings, path: Path | str | None = None) -> bool:
    p = Path(path) if path else settings_path()
    try:
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(json.dumps(asdict(s), ensure_ascii=False, indent=2), encoding="utf-8")
        return True
    except OSError:
        return False
