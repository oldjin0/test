@echo off
chcp 65001 >nul
setlocal
cd /d "%~dp0"

set FF=
set DN=
set ICON=
if exist ffmpeg\ffmpeg.exe set FF=--add-binary "ffmpeg\ffmpeg.exe;."
if exist ffmpeg\ffprobe.exe set FF=%FF% --add-binary "ffmpeg\ffprobe.exe;."
if exist deno\deno.exe set DN=--add-binary "deno\deno.exe;."
if exist assets\icon.ico set ICON=--icon assets\icon.ico

if not exist ffmpeg\ffmpeg.exe echo [경고] ffmpeg\ffmpeg.exe 가 없어 FFmpeg 없이 빌드합니다.

pyinstaller --noconfirm --clean --onefile --windowed --name VideoDownloader ^
  --collect-data customtkinter ^
  --collect-submodules yt_dlp ^
  --collect-all yt_dlp_ejs ^
  %FF% %DN% %ICON% ^
  main.py
if errorlevel 1 (
  echo 빌드 실패
  exit /b 1
)

echo.
echo 빌드 완료: dist\VideoDownloader.exe
endlocal
