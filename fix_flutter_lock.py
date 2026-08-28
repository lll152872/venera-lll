#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""删除 flutter SDK 的残留锁文件（lockfile / flutter.bat.lock）。

背景：flutter test 后台任务被强杀后，bin/cache/lockfile 常处于
delete-pending 状态（Restart Manager 报 NO live process，但 DeleteFileW
返回 ACCESS_DENIED），导致 flutter 任何命令卡死。

用法（用系统版 CPython 3.x，托管版 ctypes 会段错误）：
  C:/Users/DELL/AppData/Local/Programs/Python/Python312/python.exe fix_flutter_lock.py

说明：
- 若持有进程还活着，先 tasklist.exe | grep -i dart 找到并 taskkill /F /IM dart.exe。
- delete-pending 残留的清除依赖内核延迟，可能需等待数分钟；本脚本会循环重试。
"""
import ctypes
import os
import sys
import time

LOCKFILES = [
    r"D:\flutter_3.44.0\bin\cache\lockfile",
    r"D:\flutter_3.44.0\bin\cache\flutter.bat.lock",
]

k32 = ctypes.WinDLL("kernel32", use_last_error=True)


def delete_one(path: str) -> bool:
    if not os.path.exists(path):
        print(f"ABSENT  {path}")
        return True
    for attempt in range(10):
        r = k32.DeleteFileW(path)
        if r:
            print(f"DELETED {path}")
            return True
        err = ctypes.get_last_error()
        print(f"retry {attempt}: {os.path.basename(path)} err={err}", flush=True)
        time.sleep(3)
    print(f"FAILED  {path}（可能持有者未退出 / delete-pending 未清除）")
    return False


def main() -> int:
    ok = True
    for p in LOCKFILES:
        ok = delete_one(p) and ok
    # 验证 flutter 可用
    if ok:
        print("\n锁文件已清，可重试 flutter 命令。")
        print("若仍卡：1) tasklist.exe | grep -i dart → taskkill /F /IM dart.exe")
        print("         2) 等几分钟内核清除 delete-pending 后再跑本脚本")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
