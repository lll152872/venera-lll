@echo off
setlocal
cd /d D:\mycode\venera
echo [1/2] 编译 Windows...
flutter build windows --release --no-pub
if errorlevel 1 (
    echo 编译失败
    pause
    exit /b 1
)

echo [2/2] 验证 sqlite3.dll...
for %%F in (build\windows\x64\runner\Release\sqlite3.dll) do (
    if %%~zF LSS 100000 (
        echo 错误：sqlite3.dll 太小（%%~zF 字节），可能是空壳
        pause
        exit /b 1
    )
)

echo 完成！
start "" build\windows\x64\runner\Release\venera.exe
