"""One row in the download list. Updated in place by the main window."""
from __future__ import annotations

import customtkinter as ctk

from .. import downloader as dl
from ..utils import truncate

FONT = "Malgun Gothic"

BADGE_COLORS = {
    dl.ST_QUEUED: "#7A7F87",
    dl.ST_DOWNLOADING: "#2F6FDE",
    dl.ST_MERGING: "#8E4FD6",
    dl.ST_AUDIO: "#8E4FD6",
    dl.ST_POST: "#8E4FD6",
    dl.ST_DONE: "#2E9D57",
    dl.ST_FAILED: "#D64545",
    dl.ST_CANCELLED: "#4A4D52",
}


class JobCard(ctk.CTkFrame):
    def __init__(self, master, job: dl.DownloadJob, on_reveal):
        super().__init__(master, corner_radius=10)
        self.job = job
        self._on_reveal = on_reveal
        self.columnconfigure(1, weight=1)

        self.badge = ctk.CTkLabel(self, text=dl.ST_QUEUED, width=92, height=24, corner_radius=12,
                                  fg_color=BADGE_COLORS[dl.ST_QUEUED], text_color="white",
                                  font=ctk.CTkFont(FONT, 12, "bold"))
        self.badge.grid(row=0, column=0, rowspan=2, padx=(12, 10), pady=12, sticky="n")

        self.title_lbl = ctk.CTkLabel(self, text=truncate(job.url, 80), anchor="w",
                                      font=ctk.CTkFont(FONT, 13, "bold"))
        self.title_lbl.grid(row=0, column=1, sticky="ew", pady=(10, 0))
        self.url_lbl = ctk.CTkLabel(self, text=truncate(job.url, 100), anchor="w",
                                    text_color="gray", font=ctk.CTkFont(FONT, 11))
        self.url_lbl.grid(row=1, column=1, sticky="ew")

        self.bar = ctk.CTkProgressBar(self, height=8)
        self.bar.set(0)
        self.bar.grid(row=2, column=1, sticky="ew", pady=(6, 0))
        self.info_lbl = ctk.CTkLabel(self, text="", anchor="w", text_color="gray",
                                     font=ctk.CTkFont(FONT, 11))
        self.info_lbl.grid(row=3, column=1, sticky="ew", pady=(0, 10))
        self.err_lbl = ctk.CTkLabel(self, text="", anchor="w", justify="left", text_color="#E05555",
                                    wraplength=520, font=ctk.CTkFont(FONT, 11))

        self.reveal_btn = ctk.CTkButton(self, text="📂 폴더에서 보기", width=120, state="disabled",
                                        font=ctk.CTkFont(FONT, 12), command=self._reveal)

    def _reveal(self):
        self._on_reveal(self.job)

    @property
    def finished(self) -> bool:
        return self.job.status in (dl.ST_DONE, dl.ST_FAILED, dl.ST_CANCELLED)

    def set_title(self, title: str):
        self.title_lbl.configure(text=truncate(title, 80))

    def set_status(self, status: str, msg: str = ""):
        self.job.status = status
        self.badge.configure(text=status, fg_color=BADGE_COLORS.get(status, "#7A7F87"))
        if status == dl.ST_DONE:
            self.bar.set(1)
            self.info_lbl.configure(text="")
            self.reveal_btn.grid(row=0, column=2, rowspan=2, padx=12, pady=12)
            self.reveal_btn.configure(state="normal")
        if msg:
            self.info_lbl.configure(text=msg)

    def set_progress(self, percent: float | None, text: str):
        if percent is not None:
            self.bar.set(max(0.0, min(percent / 100.0, 1.0)))
        self.info_lbl.configure(text=text)

    def set_error(self, msg: str):
        self.set_status(dl.ST_FAILED)
        self.info_lbl.configure(text="")
        self.err_lbl.configure(text=msg)
        self.err_lbl.grid(row=4, column=0, columnspan=3, sticky="ew", padx=12, pady=(0, 10))
