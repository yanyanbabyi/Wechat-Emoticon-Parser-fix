@echo off
chcp 936 >nul
title 微信表情包解密导出工具（修复版）
cd /d "%~dp0"

echo ==============================================
echo    微信表情包解密导出工具（修复版）
echo    Wechat Emoticon Parser (fixed)
echo ==============================================
echo.

where python >nul 2>nul
if errorlevel 1 goto nopython

python -c "import Crypto" >nul 2>nul
if errorlevel 1 (
    echo [*] 正在安装必需依赖 pycryptodome ...
    python -m pip install pycryptodome
    echo.
)

python -c "import imageio_ffmpeg" >nul 2>nul
if not errorlevel 1 goto run
echo [*] 未安装 imageio-ffmpeg：动图（wxgf）将不会转码成 GIF/JPG
choice /c yn /m "    现在安装吗（约 25MB）"
if errorlevel 2 goto run
python -m pip install imageio-ffmpeg
echo.

:run
echo [*] 请先登录微信，并保持微信处于运行状态（密钥需要从内存中提取）
echo.
python wechat_emoticon_export.py
echo.
pause
exit /b 0

:nopython
echo [x] 未检测到 Python，请先安装 Python 3.8 或更高版本
echo     下载地址: https://www.python.org/downloads/
echo     安装时请勾选 "Add Python to PATH"
echo.
pause
exit /b 1
