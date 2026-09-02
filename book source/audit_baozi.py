#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""包子漫画全量可用性审计：主域名 / 章节 API / 图床域名 一一验证

产出：每项 可用性 + 延迟 + 状态码，结论直接可执行。
"""
import http.client
import json
import ssl
import socket
import time
import statistics
from concurrent.futures import ThreadPoolExecutor

UA = ("Mozilla/5.0 (Linux; Android 10; K; wv) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36")
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE


def get(host, path, referer=None, n=2, timeout=12):
    """返回 (状态码, 中位延迟ms, 字节数, 错误)"""
    res, err = [], None
    for _ in range(n):
        try:
            t0 = time.perf_counter()
            c = http.client.HTTPSConnection(host, 443, timeout=timeout, context=ctx)
            h = {"User-Agent": UA, "Accept": "*/*"}
            if referer:
                h["Referer"] = referer
            c.request("GET", path, headers=h)
            r = c.getresponse()
            body = r.read()
            el = (time.perf_counter() - t0) * 1000
            c.close()
            res.append((r.status, el, len(body)))
        except Exception as e:
            err = "%s: %s" % (type(e).__name__, str(e)[:60])
            break
    if not res:
        return (None, None, 0, err)
    ok = [x for x in res if x[0] == 200] or res
    codes = [x[0] for x in ok]
    return (codes[-1], statistics.median([x[1] for x in ok]),
            ok[-1][2], None)


rows = []

print("=" * 78)
print("[1] 主域名（搜索/详情用） GET /")
print("=" * 78)
for d in ["cn.bzmgcn.com", "cn.baozimhcn.com", "cn.webmota.com",
          "tw.webmota.com", "cn.kukuc.co", "tw.twmanga.com",
          "cn.dinnerku.com", "tw.dinnerku.com"]:
    code, ms, n, err = get(d, "/")
    tag = "OK" if code == 200 else ("跳转" if code in (301, 302) else "坏")
    print("  %-20s %s  %s  %s" % (d, tag,
          ("%dms" % ms) if ms else "-", err or ("HTTP %s" % code)))

print()
print("=" * 78)
print("[2] 章节 API（appcn.baozimh.com）")
print("=" * 78)
code, ms, n, err = get("appcn.baozimh.com",
                       "/baozimhapp/comic/chapter/haizeiwang-weitianrongyilang/0_0.html")
print("  appcn.baozimh.com        %s  %s  %d bytes  %s" % (
    "OK" if code == 200 else "坏", ("%dms" % ms) if ms else "-", n, err or ""))

print()
print("=" * 78)
print("[3] 图床域名（同一张真实图片路径）")
print("=" * 78)
IMG = "/scomic/haizeiwang-weitianrongyilang/0/0-9uis/1.jpg"
REF = "https://cn.bzmgcn.com/"
for c in ["s.baozicdn.com", "s1.baozicdn.com", "as.baozimh.com",
          "as-rsa1-usla.baozicdn.com", "ascn-a3.bzcdn.net", "asgb-a3.bzcdn.net",
          "static-tw.baozimh.com", "as.baozicdn.com", "s2.baozicdn.com",
          "s3.baozicdn.com", "img1.baozicdn.com", "cdn.baozicdn.com"]:
    code, ms, n, err = get(c, IMG, referer=REF)
    tag = ("OK %dKB" % (n // 1024)) if code == 200 else ("HTTP %s" % code if code else "连不上")
    print("  %-26s %-10s %s  %s" % (c, tag,
          ("%dms" % ms) if ms else "-", err or ""))

print()
print("=" * 78)
print("[4] 封面域 static-tw.baozimh.com（搜索列表封面用）")
print("=" * 78)
code, ms, n, err = get("static-tw.baozimh.com",
                       "/cover/00000.jpg", n=1)
print("  连通性: %s %s" % (code if code else "连不上", err or ""))
