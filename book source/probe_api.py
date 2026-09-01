#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""探测漫蛙吧 API 的分页上限，为并发 / 大分页优化提供决策依据。

用法： python probe_api.py [起始id] [结束id]
"""
import json
import ssl
import http.client
import time
import sys
from concurrent.futures import ThreadPoolExecutor

HOST = "manwari.cc"
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")

# 站点返回 Transfer-Encoding: chunked，裸 socket 拿不到解码后的 body。
# 必须用 http.client（自动解 chunked），否则 json.loads 会失败。
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE


def get(path, timeout=25, retries=2):
    last = None
    for _ in range(retries):
        try:
            conn = http.client.HTTPSConnection(HOST, 443, timeout=timeout, context=ctx)
            t0 = time.perf_counter()
            conn.request("GET", path, headers={"User-Agent": UA, "Accept": "*/*"})
            resp = conn.getresponse()
            body = resp.read()
            el = (time.perf_counter() - t0) * 1000
            conn.close()
            try:
                return json.loads(body.decode("utf-8")), el, len(body)
            except Exception:
                return None, el, len(body)
        except Exception as e:
            last = e
            time.sleep(0.4)
    print("    请求失败 %s -> %s" % (path, last))
    return None, 0.0, 0


def total_of(cid):
    d, _, _ = get("/api/comic/chapter?comicId=%d&page=1&pageSize=1" % cid, 15, retries=2)
    if d and d.get("pagination"):
        return cid, d["pagination"].get("total", 0)
    return cid, 0


def main():
    lo = int(sys.argv[1]) if len(sys.argv) > 1 else 1
    hi = int(sys.argv[2]) if len(sys.argv) > 2 else 120

    print("[1/3] 扫描 comicId %d-%d，找章节最多的漫画（并发 6）..." % (lo, hi))
    with ThreadPoolExecutor(max_workers=6) as ex:
        res = list(ex.map(total_of, range(lo, hi + 1)))
    ok = [r for r in res if r[1] > 0]
    print("  成功 %d / %d" % (len(ok), len(res)))
    ok.sort(key=lambda x: -x[1])
    print("  章节数 Top10:", ok[:10])
    if not ok:
        print("  全部失败，站点可能在限流，稍后重试或缩小扫描范围")
        return
    big_id, big_total = ok[0]
    print("  选定 comicId=%d (total=%d)\n" % (big_id, big_total))

    print("[2/3] 章节 API 大分页上限（comicId=%d, 真实 total=%d）" % (big_id, big_total))
    for ps in (100, 500, 1000, 2000, 5000):
        d, el, n = get("/api/comic/chapter?comicId=%d&page=1&pageSize=%d" % (big_id, ps), 30)
        got = len(d["data"]) if d and d.get("data") else -1
        tot = (d.get("pagination") or {}).get("total") if d else None
        print("  pageSize=%-5d 返回 %-5d / total=%-5s  %6.0fms  %7.1fKB" % (ps, got, tot, el, n / 1024))

    print("\n[3/3] 图片 API 分页上限")
    d, _, _ = get("/api/comic/chapter?comicId=%d&page=1&pageSize=5" % big_id)
    eps = d["data"] if d and d.get("data") else []
    if not eps:
        print("  取不到章节，跳过")
        return
    ep = eps[0]
    print("  用 epId=%s (标题 %s)" % (ep.get("id"), ep.get("title")))
    for ps in (50, 200, 500, 1000):
        d2, el, n = get("/api/comic/image/%s?image_source=https://tu.mhttu.cc&page=1&page_size=%d"
                        % (ep.get("id"), ps), 30)
        if d2 and d2.get("data"):
            imgs = d2["data"].get("images") or []
            tot = (d2["data"].get("pagination") or {}).get("total")
            print("  page_size=%-5d 返回 %-4d / total=%-5s  %6.0fms  %7.1fKB"
                  % (ps, len(imgs), tot, el, n / 1024))
        else:
            print("  page_size=%-5d 失败" % ps)
    d3, _, _ = get("/api/comic/image/%s?image_source=https://tu.mhttu.cc&page=1&page_size=3"
                   % eps[0].get("id"))
    if d3 and d3.get("data", {}).get("images"):
        print("  图片 URL 样例:", d3["data"]["images"][0].get("url"))


if __name__ == "__main__":
    main()
