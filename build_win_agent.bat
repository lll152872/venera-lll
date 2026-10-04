@echo off
setlocal
cd /d D:\mycode\venera

set "PUB_HOSTED_URL="
set "FLUTTER_STORAGE_BASE_URL="
set "PATH=D:\edge;D:\flutter_3.44.0\bin;%PATH%"

echo [AGENT BUILD] start %DATE% %TIME% > build_log_agent.txt
where flutter >> build_log_agent.txt 2>&1
where cargo >> build_log_agent.txt 2>&1

flutter build windows --release --no-pub < nul >> build_log_agent.txt 2>&1
set "BUILD_EXIT=%errorlevel%"

echo. >> build_log_agent.txt
echo BUILD EXIT CODE: %BUILD_EXIT% >> build_log_agent.txt
if not "%BUILD_EXIT%"=="0" echo [BUILD FAILED] >> build_log_agent.txt

for %%F in (build\windows\x64\runner\Release\sqlite3.dll) do (
    if %%~zF LSS 100000 (
        echo [ERROR] sqlite3.dll too small >> build_log_agent.txt
        set "BUILD_EXIT=2"
    )
)

exit /b %BUILD_EXIT%
