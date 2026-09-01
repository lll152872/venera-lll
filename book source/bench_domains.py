#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""包子漫画主域名 / CDN 图床候选测速（http.client，自动解 chunked）

主域名格式：https://{lang}.{domain}，lang ∈ {cn, tw}
"""
import http.client
import ssl
import time
import statistics
from concurrent.futures import ThreadPoolExecutor

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

MAIN_DOMAINS = ["bzmgcn.com", "baozimhcn.com", "webmota.com", "kukuc.co",
                "twmanga.com", "dinnerku.com"]
LANGS = ["cn", "tw"]
CDNS = ["as-rsa1-usla.baozicdn.com", "ascn-a3.bzcdn.net", "asgb-a3.bzcdn.net",
        "as.baozimh.com", "s1.baozicdn.com", "static-tw.baozimh.com"]


def probe(host, path, n=2, timeout=12):
    res = []
    for _ in range(n):
        try:
            t0 = time.perf_counter()
            c = http.client.HTTPSConnection(host, 443, timeout=timeout, context=ctx)
            c.request("GET", path, headers={"User-Agent": UA, "Accept": "*/*"})
            r = c.getresponse()
            r.read()
            total = (time.perf_counter() - t0) * 1000
            c.close()
            res.append((total, r.status))
        except Exception:
            res.append(None)
            break
    ok = [x for x in res if x]
    if not ok:
        return None
    return {"total": statistics.median([x[0] for x in ok]),
            "code": ok[-1][1], "n": len(ok)}


def run(batch, label):
    print(label)
    tasks = [(h, p) for h, p in batch]

    def one(t):
        h, p = t
        r = probe(h, p)
        return (h, p, r)

    with ThreadPoolExecutor(max_workers=6) as ex:
        rows = list(ex.map(one, tasks))
    ok_rows = [(h, p, r) for h, p, r in rows if r]
    ok_rows.sort(key=lambda x: x[2]["total"])
    print("  %-42s %9s %6s %5s" % ("目标", "总耗时", "HTTP", "次数"))
    print("  " + "-" * 66)
    for h, p, r in ok_rows:
        print("  %-42s %7.0fms %6d %5d" % (h, r["total"], r["code"], r["n"]))
    for h, p, r in rows:
        if not r:
            print("  %-42s %9s %6s %5s" % (h, "FAIL", "-", "-"))
    print()
    return ok_rows


# 主域名首页（跟随 3xx 也行，先看直连状态）
main_batch = [(f"{lang}.{d}", "/") for d in MAIN_DOMAINS for lang in LANGS]
run(main_batch, "[1] 包子主域名（https://{lang}.{domain}/）")

# CDN 图床：随便用一张包子漫画图路径探测连通性（404 也说明域名可达，只看延迟）
cdn_batch = [(c, "/") for c in CDNS]
run(cdn_batch, "[2] 包子 CDN 域名连通性（根路径，只看延迟）")
