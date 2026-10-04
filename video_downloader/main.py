import os
import sys

# PyInstaller --windowed: stdout/stderr can be None; fix before importing yt_dlp.
if sys.stdout is None:
    sys.stdout = open(os.devnull, "w")
if sys.stderr is None:
    sys.stderr = open(os.devnull, "w")


def _enable_dpi_awareness():
    if sys.platform != "win32":
        return
    try:
        import ctypes
        ctypes.windll.shcore.SetProcessDpiAwareness(1)
    except Exception:
        pass


def main():
    _enable_dpi_awareness()
    from app.ui.main_window import App
    App().mainloop()


if __name__ == "__main__":
    main()
