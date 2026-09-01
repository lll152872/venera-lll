#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""禁漫 4 条线路真实 API 测速（/categories/filter 是 explore 用的接口）"""
import http.client
import ssl
import time
import statistics
from urllib.parse import urlparse

UA = ("Mozilla/5.0 (Linux; Android 10; K; wv) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Version/4.0 Chrome/130.0.0.0 Mobile Safari/537.36")
PATH = "/categories/filter?o=mr&c=all&page=1"
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

LINES = ["www.cdntwice.org", "www.cdnsha.org", "www.cdnntr.cc", "www.cdnaspa.cc"]


def probe(host, n=3):
    res = []
    for _ in range(n):
        try:
            t0 = time.perf_counter()
            c = http.client.HTTPSConnection(host, 443, timeout=12, context=ctx)
            c.request("GET", PATH, headers={
                "User-Agent": UA,
                "Accept": "application/json",
                "Platform": "1",
                "APP-VERSION": "2.0.16",
                "Referer": "https://localhost/",
            })
            r = c.getresponse()
            body = r.read()
            total = (time.perf_counter() - t0) * 1000
            c.close()
            res.append((total, r.status, len(body)))
        except Exception:
            res.append(None)
            break
    ok = [x for x in res if x]
    if not ok:
        return None
    return {"total": statistics.median([x[0] for x in ok]), "code": ok[-1][1],
            "bytes": ok[-1][2], "n": len(ok)}


for host in LINES:
    r = probe(host)
    if r:
        print("%-20s %6.0fms  HTTP %d  %d bytes  (%d/%d)" %
              (host, r["total"], r["code"], r["bytes"], r["n"], 3))
    else:
        print("%-20s  FAIL（连接失败/DNS）" % host)
