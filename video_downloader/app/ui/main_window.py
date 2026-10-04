"""Main window: layout, event pump and wiring to the download worker."""
from __future__ import annotations

import queue
import threading
from tkinter import TclError, filedialog, messagebox

import customtkinter as ctk

from .. import downloader as dl
from ..config import load_settings, save_settings, Settings
from ..utils import (find_deno, find_ffmpeg, open_folder, parse_urls,
                     reveal_in_explorer, truncate)
from .job_card import FONT, JobCard

THEME_MAP = {"시스템": "System", "다크": "Dark", "라이트": "Light"}
THEME_REV = {v: k for k, v in THEME_MAP.items()}


class App(ctk.CTk):
    def __init__(self, settings: Settings | None = None):
        super().__init__()
        ctk.set_default_color_theme("blue")
        self.settings = settings or load_settings()
        if self.settings.quality not in dl.PRESETS:
            self.settings.quality = dl.DEFAULT_PRESET
        if self.settings.cookies_browser not in dl.COOKIE_CHOICES:
            self.settings.cookies_browser = dl.NO_COOKIES
        ctk.set_appearance_mode(self.settings.theme)

        self.title("Video Downloader")
        self.geometry("980x760")
        self.minsize(820, 640)

        self.events: queue.Queue = queue.Queue()
        self.cancel = threading.Event()
        self.worker: dl.DownloadWorker | None = None
        self.cards: dict[int, JobCard] = {}
        self.batch: list[dl.DownloadJob] = []
        self.finished_count = 0
        self.item_fraction = 0.0
        self.ffmpeg_path = find_ffmpeg()
        self.deno_path = find_deno()
        self._option_widgets: list = []

        self._build()
        self._update_url_count()
        if not self.ffmpeg_path:
            self.status_lbl.configure(
                text="FFmpeg를 찾을 수 없습니다. 병합/MP3 변환이 제한됩니다.", text_color="#E08A1E")
        self.protocol("WM_DELETE_WINDOW", self._on_close)
        self.after(100, self._poll_events)

    # ---------- layout ----------
    def _font(self, size=13, weight="normal"):
        return ctk.CTkFont(FONT, size, weight)

    def _section(self, row, title, expand=False):
        frame = ctk.CTkFrame(self, corner_radius=12)
        frame.grid(row=row, column=0, sticky="nsew" if expand else "ew", padx=16, pady=(0, 10))
        frame.columnconfigure(0, weight=1)
        ctk.CTkLabel(frame, text=title, font=self._font(14, "bold"), anchor="w").grid(
            row=0, column=0, sticky="w", padx=14, pady=(10, 4))
        return frame

    def _build(self):
        self.columnconfigure(0, weight=1)
        self.rowconfigure(4, weight=1)

        # top bar
        top = ctk.CTkFrame(self, fg_color="transparent")
        top.grid(row=0, column=0, sticky="ew", padx=16, pady=(12, 8))
        top.columnconfigure(0, weight=1)
        ctk.CTkLabel(top, text="Video Downloader", font=self._font(24, "bold"), anchor="w").grid(
            row=0, column=0, sticky="w")
        ctk.CTkLabel(top, text="YouTube · Instagram · TikTok · 小红书 등 1000+ 사이트 지원",
                     text_color="gray", font=self._font(12), anchor="w").grid(row=1, column=0, sticky="w")
        self.theme_btn = ctk.CTkSegmentedButton(
            top, values=list(THEME_MAP), command=self._on_theme, font=self._font(12))
        self.theme_btn.set(THEME_REV.get(self.settings.theme, "시스템"))
        self.theme_btn.grid(row=0, column=1, rowspan=2, sticky="e")

        # 1. URL input
        s1 = self._section(1, "URL 입력")
        ctk.CTkLabel(s1, text="한 줄에 하나씩 URL을 붙여넣으세요", text_color="gray",
                     font=self._font(11), anchor="w").grid(row=1, column=0, sticky="w", padx=14)
        self.textbox = ctk.CTkTextbox(s1, height=110, font=self._font(13))
        self.textbox.grid(row=2, column=0, sticky="ew", padx=14, pady=4)
        self.textbox.bind("<KeyRelease>", lambda e: self._update_url_count())
        self.textbox.bind("<<Paste>>", lambda e: self.after(50, self._update_url_count))
        row = ctk.CTkFrame(s1, fg_color="transparent")
        row.grid(row=3, column=0, sticky="ew", padx=14, pady=(2, 12))
        ctk.CTkButton(row, text="📋 클립보드 붙여넣기", width=150, font=self._font(),
                      command=self._paste).pack(side="left")
        ctk.CTkButton(row, text="🗑 입력 초기화", width=120, font=self._font(),
                      fg_color="gray40", hover_color="gray30", command=self._clear).pack(side="left", padx=8)
        self.count_lbl = ctk.CTkLabel(row, text="", font=self._font(12))
        self.count_lbl.pack(side="right")

        # 2. options
        s2 = self._section(2, "옵션")
        grid = ctk.CTkFrame(s2, fg_color="transparent")
        grid.grid(row=1, column=0, sticky="ew", padx=14, pady=(0, 12))
        grid.columnconfigure(1, weight=1)
        ctk.CTkLabel(grid, text="저장 위치", font=self._font()).grid(row=0, column=0, sticky="w", pady=4)
        self.path_entry = ctk.CTkEntry(grid, font=self._font())
        self.path_entry.insert(0, self.settings.save_dir)
        self.path_entry.configure(state="readonly")
        self.path_entry.grid(row=0, column=1, sticky="ew", padx=8)
        pb = ctk.CTkFrame(grid, fg_color="transparent")
        pb.grid(row=0, column=2, sticky="e")
        self.choose_btn = ctk.CTkButton(pb, text="폴더 선택", width=90, font=self._font(),
                                        command=self._choose_dir)
        self.choose_btn.pack(side="left")
        ctk.CTkButton(pb, text="열기", width=60, font=self._font(), fg_color="gray40",
                      hover_color="gray30",
                      command=lambda: open_folder(self.settings.save_dir)).pack(side="left", padx=(6, 0))

        ctk.CTkLabel(grid, text="화질", font=self._font()).grid(row=1, column=0, sticky="w", pady=4)
        self.quality_menu = ctk.CTkOptionMenu(grid, values=list(dl.PRESETS), font=self._font(),
                                              dropdown_font=self._font(), command=self._on_quality)
        self.quality_menu.set(self.settings.quality)
        self.quality_menu.grid(row=1, column=1, sticky="w", padx=8)
        cr = ctk.CTkFrame(grid, fg_color="transparent")
        cr.grid(row=1, column=2, sticky="e")
        ctk.CTkLabel(cr, text="브라우저 쿠키", font=self._font()).pack(side="left", padx=(0, 6))
        self.cookie_menu = ctk.CTkOptionMenu(cr, values=dl.COOKIE_CHOICES, width=110, font=self._font(),
                                             dropdown_font=self._font(), command=self._on_cookie)
        self.cookie_menu.set(self.settings.cookies_browser)
        self.cookie_menu.pack(side="left")

        chk = ctk.CTkFrame(grid, fg_color="transparent")
        chk.grid(row=2, column=0, columnspan=3, sticky="ew", pady=(6, 0))
        self.open_var = ctk.BooleanVar(value=self.settings.open_folder_after)
        self.open_chk = ctk.CTkCheckBox(chk, text="다운로드 완료 후 저장 폴더 열기", variable=self.open_var,
                                        font=self._font(), command=self._on_checks)
        self.open_chk.pack(side="left")
        self.pl_var = ctk.BooleanVar(value=self.settings.allow_playlist)
        self.pl_chk = ctk.CTkCheckBox(chk, text="재생목록 전체 다운로드", variable=self.pl_var,
                                      font=self._font(), command=self._on_checks)
        self.pl_chk.pack(side="left", padx=20)
        if self.ffmpeg_path:
            txt, col = "FFmpeg: 사용 가능 ✓", "#2E9D57"
        else:
            txt, col = "FFmpeg 없음 – 병합 불가, 단일 파일 최고 화질로 대체", "#E08A1E"
        ctk.CTkLabel(chk, text=txt, text_color=col, font=self._font(12)).pack(side="right")
        self._option_widgets = [self.choose_btn, self.quality_menu, self.cookie_menu,
                                self.open_chk, self.pl_chk]

        # 3. progress
        s3 = self._section(3, "진행 상황")
        br = ctk.CTkFrame(s3, fg_color="transparent")
        br.grid(row=1, column=0, sticky="ew", padx=14)
        br.columnconfigure(0, weight=1)
        self.start_btn = ctk.CTkButton(br, text="⬇ 다운로드 시작", height=44, font=self._font(15, "bold"),
                                       command=self._start)
        self.start_btn.grid(row=0, column=0, sticky="ew")
        self.stop_btn = ctk.CTkButton(br, text="⏹ 중지", height=44, width=110, font=self._font(14),
                                      fg_color="#C0392B", hover_color="#962D22", state="disabled",
                                      command=self._stop)
        self.stop_btn.grid(row=0, column=1, padx=(8, 0))
        self.current_lbl = ctk.CTkLabel(s3, text="현재: -", anchor="w", font=self._font(13))
        self.current_lbl.grid(row=2, column=0, sticky="ew", padx=14, pady=(8, 0))
        self.item_bar = ctk.CTkProgressBar(s3)
        self.item_bar.set(0)
        self.item_bar.grid(row=3, column=0, sticky="ew", padx=14, pady=(4, 0))
        self.item_lbl = ctk.CTkLabel(s3, text="", anchor="w", text_color="gray", font=self._font(12))
        self.item_lbl.grid(row=4, column=0, sticky="ew", padx=14)
        self.total_bar = ctk.CTkProgressBar(s3)
        self.total_bar.set(0)
        self.total_bar.grid(row=5, column=0, sticky="ew", padx=14, pady=(6, 0))
        self.total_lbl = ctk.CTkLabel(s3, text="전체 0 / 0 (0%)", anchor="w", font=self._font(12))
        self.total_lbl.grid(row=6, column=0, sticky="ew", padx=14, pady=(0, 10))

        # 4. list
        s4 = self._section(4, "다운로드 목록", expand=True)
        s4.rowconfigure(1, weight=1)
        ctk.CTkButton(s4, text="완료/실패 항목 지우기", width=160, height=26, font=self._font(12),
                      fg_color="gray40", hover_color="gray30",
                      command=self._clear_finished).grid(row=0, column=0, sticky="e", padx=14, pady=(8, 0))
        self.list_frame = ctk.CTkScrollableFrame(s4, fg_color="transparent")
        self.list_frame.grid(row=1, column=0, sticky="nsew", padx=8, pady=(4, 10))
        self.list_frame.columnconfigure(0, weight=1)

        self.status_lbl = ctk.CTkLabel(self, text="준비됨", anchor="w", font=self._font(12))
        self.status_lbl.grid(row=5, column=0, sticky="ew", padx=20, pady=(0, 8))

    # ---------- URL input ----------
    def _text(self) -> str:
        return self.textbox.get("1.0", "end")

    def _update_url_count(self):
        valid, _ = parse_urls(self._text())
        self.count_lbl.configure(text=f"유효한 URL: {len(valid)}개")

    def _paste(self):
        try:
            clip = self.clipboard_get()
        except TclError:
            clip = ""
        if not clip.strip():
            messagebox.showwarning("클립보드", "클립보드에 텍스트가 없습니다")
            return
        if self._text().strip():
            clip = "\n" + clip
        self.textbox.insert("end", clip)
        self._update_url_count()

    def _clear(self):
        self.textbox.delete("1.0", "end")
        self._update_url_count()

    # ---------- settings ----------
    def _save(self):
        save_settings(self.settings)

    def _on_theme(self, label):
        self.settings.theme = THEME_MAP.get(label, "System")
        ctk.set_appearance_mode(self.settings.theme)
        self._save()

    def _on_quality(self, v):
        self.settings.quality = v
        self._save()

    def _on_cookie(self, v):
        self.settings.cookies_browser = v
        self._save()

    def _on_checks(self):
        self.settings.open_folder_after = bool(self.open_var.get())
        self.settings.allow_playlist = bool(self.pl_var.get())
        self._save()

    def _choose_dir(self):
        d = filedialog.askdirectory(initialdir=self.settings.save_dir, title="저장 폴더 선택")
        if d:
            self.settings.save_dir = d
            self.path_entry.configure(state="normal")
            self.path_entry.delete(0, "end")
            self.path_entry.insert(0, d)
            self.path_entry.configure(state="readonly")
            self._save()

    # ---------- run control ----------
    @property
    def running(self) -> bool:
        return self.worker is not None and self.worker.is_alive()

    def _set_running(self, running: bool):
        self.start_btn.configure(state="disabled" if running else "normal")
        self.stop_btn.configure(state="normal" if running else "disabled")
        for w in self._option_widgets:
            w.configure(state="disabled" if running else "normal")

    def _start(self):
        if self.running:
            return
        valid, invalid = parse_urls(self._text())
        if not valid:
            messagebox.showerror("URL 없음", "유효한 URL이 없습니다. URL을 입력해 주세요.")
            return
        if invalid:
            lst = "\n".join(invalid[:10]) + (f"\n... 외 {len(invalid) - 10}개" if len(invalid) > 10 else "")
            messagebox.showwarning("잘못된 URL", f"다음 항목은 URL이 아니어서 건너뜁니다:\n\n{lst}")

        self.batch = [dl.new_job(u) for u in valid]
        for job in self.batch:
            card = JobCard(self.list_frame, job, self._reveal)
            card.pack(fill="x", padx=4, pady=4)
            self.cards[job.id] = card
        self.finished_count = 0
        self.item_fraction = 0.0
        self.cancel.clear()
        self._refresh_total()
        self.item_bar.set(0)
        self.item_lbl.configure(text="")
        self.current_lbl.configure(text="현재: -")
        self.status_lbl.configure(text="다운로드 중...", text_color=("gray10", "gray90"))
        self.worker = dl.DownloadWorker(self.batch, Settings(**vars(self.settings)), self.events,
                                        self.cancel, self.ffmpeg_path, self.deno_path)
        self._set_running(True)
        self.worker.start()

    def _stop(self):
        self.cancel.set()
        self.stop_btn.configure(state="disabled")
        self.status_lbl.configure(text="중지하는 중...")

    def _reveal(self, job):
        if job.filepath:
            reveal_in_explorer(job.filepath)
        else:
            open_folder(self.settings.save_dir)

    def _clear_finished(self):
        for jid, card in list(self.cards.items()):
            if card.finished:
                card.destroy()
                del self.cards[jid]

    # ---------- progress display ----------
    def _refresh_total(self):
        total = len(self.batch)
        frac = ((self.finished_count + self.item_fraction) / total) if total else 0.0
        frac = min(frac, 1.0)
        self.total_bar.set(frac)
        self.total_lbl.configure(text=f"전체 {self.finished_count} / {total} ({frac * 100:.0f}%)")

    def _poll_events(self):
        try:
            for _ in range(200):
                try:
                    ev = self.events.get_nowait()
                except queue.Empty:
                    break
                self._handle(ev)
        except Exception as e:  # keep the pump alive
            self.status_lbl.configure(text=f"내부 오류: {e}")
        self.after(100, self._poll_events)

    def _handle(self, ev):
        card = self.cards.get(getattr(ev, "job_id", None))
        if isinstance(ev, dl.JobStarted):
            self.current_lbl.configure(text="현재: " + truncate(ev.title, 70))
            if card:
                card.set_title(ev.title)
                if card.job.status == dl.ST_QUEUED:
                    card.set_status(dl.ST_DOWNLOADING)
        elif isinstance(ev, dl.Progress):
            if ev.percent is not None:
                self.item_fraction = ev.percent / 100.0
                self.item_bar.set(self.item_fraction)
                text = f"{ev.percent:.1f}%  ·  {ev.speed}  ·  남은 시간 {ev.eta}"
            else:
                text = f"{ev.downloaded} 받는 중  ·  {ev.speed}"
            self.item_lbl.configure(text=text)
            if card:
                card.set_progress(ev.percent, text)
            self._refresh_total()
        elif isinstance(ev, dl.StatusEvent):
            if card:
                card.set_status(ev.status, ev.msg)
            if ev.status != dl.ST_CANCELLED:
                self.item_lbl.configure(text=ev.status)
            else:
                self.finished_count += 1
                self._refresh_total()
        elif isinstance(ev, dl.JobDone):
            if card:
                card.job.filepath = ev.filepath
                card.set_status(dl.ST_DONE)
            self.finished_count += 1
            self.item_fraction = 0.0
            self.item_bar.set(1)
            self._refresh_total()
        elif isinstance(ev, dl.JobFailed):
            if card:
                card.set_error(ev.error)
            self.finished_count += 1
            self.item_fraction = 0.0
            self._refresh_total()
        elif isinstance(ev, dl.LogEvent):
            self.status_lbl.configure(text=truncate(ev.msg, 140),
                                      text_color="#E08A1E" if ev.level == "warning" else "#E05555")
        elif isinstance(ev, dl.AllDone):
            self._on_all_done(ev)

    def _on_all_done(self, s: dl.AllDone):
        self._set_running(False)
        self.item_fraction = 0.0
        self.current_lbl.configure(text="현재: -")
        self.status_lbl.configure(text=f"완료 {s.ok} · 실패 {s.failed} · 취소 {s.cancelled}",
                                  text_color=("gray10", "gray90"))
        self._refresh_total()
        if s.ok and self.settings.open_folder_after:
            open_folder(self.settings.save_dir)
        if s.failures:
            lines = [f"{truncate(u, 60)}\n   → {r}" for u, r in s.failures[:5]]
            if len(s.failures) > 5:
                lines.append(f"... 외 {len(s.failures) - 5}개")
            messagebox.showwarning("일부 다운로드 실패", "\n\n".join(lines))

    def _on_close(self):
        if self.running:
            if not messagebox.askyesno("종료", "다운로드 중입니다. 종료하시겠습니까?"):
                return
            self.cancel.set()
        self._save()
        self.destroy()
