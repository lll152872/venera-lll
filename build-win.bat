@echo off
setlocal
setlocal EnableDelayedExpansion
chcp 65001 > nul

REM ============================================================
REM Venera 本地构建脚本（Windows exe）
REM
REM 用法：
REM   build-win.bat            仅编译 exe（默认）
REM   build-win.bat run        编译 exe 后启动
REM   build-win.bat clean      清理 build\windows + ephemeral 后编译
REM   build-win.bat rebuild    清理 + 编译 + 启动
REM
REM 默认行为：build exe（不启动，避免启动后运行时崩溃掩盖编译错误）
REM 必须用 `cmd /c build-win.bat` 调用，git-bash 不能直接执行
REM ============================================================

cd /d D:\mycode\venera

set "DO_RUN=0"
set "DO_CLEAN=0"
set "ACTION=编译"

if /i "%1"=="run" (
    set "DO_RUN=1"
    set "ACTION=编译并启动"
)
if /i "%1"=="clean" (
    set "DO_CLEAN=1"
    set "ACTION=清理后编译"
)
if /i "%1"=="rebuild" (
    set "DO_CLEAN=1"
    set "DO_RUN=1"
    set "ACTION=清理后编译并启动"
)

echo ============================================================
echo  模式：%ACTION%
echo  产物：build\windows\x64\runner\Release\venera.exe
echo ============================================================

REM 1. 清理（如需）
if %DO_CLEAN%==1 (
    echo [1/3] 清理旧产物...
    if exist build\windows rmdir /s /q build\windows
    if exist windows\flutter\ephemeral rmdir /s /q windows\flutter\ephemeral
)

REM 2. PATH 必须包含 Flutter SDK 和 nuget
set "PATH=D:\edge;D:\flutter_3.44.0\bin;%PATH%"

REM 3. 编译
echo [编译] flutter build windows --release --no-pub
flutter build windows --release --no-pub
if errorlevel 1 (
    echo.
    echo ========== 编译失败 ==========
    pause
    exit /b 1
)

REM 4. 验证产物完整性
echo [验证] 检查关键 dll...
set "MISSING=0"
for %%F in (venera.exe sqlite3.dll flutter_windows.dll) do (
    set "FILE=build\windows\x64\runner\Release\%%F"
    if not exist !FILE! (
        echo   缺失：%%F
        set "MISSING=1"
    ) else (
        for %%S in ("!FILE!") do echo   ✓ %%F ^(%%~zS 字节^)
    )
)
if !MISSING!==1 (
    echo 错误：关键文件缺失
    pause
    exit /b 1
)

REM 5. sqlite3.dll 大小校验（防止空壳）
for %%F in (build\windows\x64\runner\Release\sqlite3.dll) do (
    if %%~zF LSS 100000 (
        echo 错误：sqlite3.dll 太小（%%~zF 字节），可能是空壳
        pause
        exit /b 1
    )
)

echo.
echo ========== 完成 ==========
echo 产物：build\windows\x64\runner\Release\venera.exe

REM 6. 可选：启动
if %DO_RUN%==1 (
    echo 启动 exe...
    start "" build\windows\x64\runner\Release\venera.exe
) else (
    echo 默认未启动。如需启动请用：build-win.bat run
)

pause