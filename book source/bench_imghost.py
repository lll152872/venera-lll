#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""漫蛙吧图床候选测速。

背景：图片 API 的 `image_source` 参数会被原样拼到返回的图片 URL 前面
（传 https://img1.mhttu.cc 就返回 img1.mhttu.cc/en_images/...），
所以图床是可切换的。本脚本测各候选图床的真实下载延迟，挑最快的。
"""
import ssl
import socket
import time
import statistics
from concurrent.futures import ThreadPoolExecutor

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
REFERER = "https://manwaba.com/"
PATH = "/en_images/20254/6566/371468/0.jpg"

CANDIDATES = [
    "tu.mhttu.cc",
    "img1.mhttu.cc",
    "img2.mhttu.cc",
    "img3.mhttu.cc",
    "tu1.mhttu.cc",
    "tu2.mhttu.cc",
    "img.mhttu.cc",
    "cdn.mhttu.cc",
    "pic.mhttu.cc",
    "mhttu.cc",
]

ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE


def probe(host, n=3):
    res = []
    for _ in range(n):
        try:
            t0 = time.perf_counter()
            s = socket.create_connection((host, 443), timeout=8)
            tcp = (time.perf_counter() - t0) * 1000
            ss = ctx.wrap_socket(s, server_hostname=host)
            tls = (time.perf_counter() - t0) * 1000
            req = ("GET %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: %s\r\nReferer: %s\r\n"
                   "Accept: image/webp,image/*,*/*\r\nConnection: close\r\n\r\n"
                   % (PATH, host, UA, REFERER))
            tt0 = time.perf_counter()
            ss.sendall(req.encode())
            buf = b""
            ttfb = None
            while True:
                c = ss.recv(65536)
                if not c:
                    break
                if ttfb is None:
                    ttfb = (time.perf_counter() - tt0) * 1000
                buf += c
                if len(buf) > 3_000_000:
                    break
            total = (time.perf_counter() - t0) * 1000
            ss.close()
            head = buf.split(b"\r\n\r\n", 1)[0].decode("utf-8", "replace")
            code = int(head.split(" ")[1]) if " " in head else 0
            body = buf.split(b"\r\n\r\n", 1)[1] if b"\r\n\r\n" in buf else b""
            res.append((tcp, tls, ttfb or 0, total, code, len(body)))
        except Exception as e:
            res.append(None)
            break
    ok = [r for r in res if r]
    if not ok:
        return {"host": host, "ok": False}
    return {
        "host": host, "ok": True, "n": len(ok),
        "tcp": statistics.median([r[0] for r in ok]),
        "tls": statistics.median([r[1] for r in ok]),
        "ttfb": statistics.median([r[2] for r in ok]),
        "total": statistics.median([r[3] for r in ok]),
        "code": ok[-1][4], "bytes": ok[-1][5],
    }


def main():
    print("图床候选测速（各 3 次取中位数，图片 %s）\n" % PATH)
    with ThreadPoolExecutor(max_workers=5) as ex:
        rows = list(ex.map(probe, CANDIDATES))
    good = [r for r in rows if r["ok"]]
    good.sort(key=lambda r: r["total"])
    print("%-18s %7s %7s %7s %8s %6s %9s" %
          ("图床", "TCP", "TLS", "TTFB", "TOTAL", "HTTP", "字节"))
    print("-" * 70)
    for r in good:
        print("%-18s %7.0f %7.0f %7.0f %8.0f %6d %9d" %
              (r["host"], r["tcp"], r["tls"], r["ttfb"], r["total"], r["code"], r["bytes"]))
    for r in rows:
        if not r["ok"]:
            print("%-18s %7s %7s %7s %8s %6s %9s" % (r["host"], "-", "-", "-", "-", "FAIL", "-"))
    print("-" * 70)
    if good:
        best = good[0]
        cur = [r for r in good if r["host"] == "tu.mhttu.cc"]
        print("\n最快：%s  %.0fms" % (best["host"], best["total"]))
        if cur:
            c = cur[0]
            print("当前：tu.mhttu.cc  %.0fms  → 换图床可省 %.0fms/张（%.0f%%）"
                  % (c["total"], c["total"] - best["total"],
                     (1 - best["total"] / c["total"]) * 100 if c["total"] else 0))


if __name__ == "__main__":
    main()
