#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""最终判据：拉完整搜索响应，用「关键词命中率」判定搜索是否真的生效。

核心判据（最笨但最可靠）：
  真关键词「海贼王」的响应体里，标题字段出现次数 > 乱关键词的响应体。
  对照组乱词几乎必然 0。
另外输出每个站可直接写书源的 endpoint 信息。
"""
import json
import os
import re
import sys
import socket
import ssl
import time
import gzip
import zlib
import concurrent.futures as cf
from urllib.parse import urlparse, quote

HERE = os.path.dirname(os.path.abspath(__file__))
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
TIMEOUT = 12

# 各站常见的「漫画标题」JSON 字段
NAME_KEYS = ["comic_name", "book_name", "manga_name", "post_title", "title",
             "name", "comicTitle", "bookName", "workTitle", "b_name", "c_name"]
ID_KEYS = ["comic_id", "book_id", "manga_id", "post_id", "article_id", "id",
           "comicId", "bookId", "b_id", "cid", "tid"]


def http_get(url, ua=UA, referer=None, timeout=TIMEOUT):
    cur = url
    for _ in range(4):
        u = urlparse(cur)
        host, port = u.hostname, u.port or 443
        if not host:
            return None, cur, "", "URL无主机"
        try:
            t0 = time.perf_counter()
            infos = socket.getaddrinfo(host, port, proto=socket.IPPROTO_TCP)
            s = socket.socket(infos[0][0], socket.SOCK_STREAM)
            s.settimeout(timeout)
            s.connect(infos[0][4])
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            sock = ctx.wrap_socket(s, server_hostname=host)
        except Exception as e:
            return None, cur, "", type(e).__name__
        try:
            path = u.path or "/"
            if u.query:
                path += "?" + u.query
            hdrs = ["GET %s HTTP/1.1" % path, "Host: %s" % host,
                    "User-Agent: %s" % ua,
                    "Accept: text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8",
                    "Accept-Language: zh-CN,zh;q=0.9",
                    "Accept-Encoding: gzip, deflate", "Connection: close"]
            if referer:
                hdrs.append("Referer: %s" % referer)
            sock.sendall(("\r\n".join(hdrs) + "\r\n\r\n").encode())
            buf = b""
            while len(buf) < 5_000_000:
                try:
                    ch = sock.recv(65536)
                except Exception:
                    break
                if not ch:
                    break
                buf += ch
                head, _, body = buf.partition(b"\r\n\r\n")
                cl = 0
                for ln in head.split(b"\r\n")[1:]:
                    if ln.lower().startswith(b"content-length:"):
                        try:
                            cl = int(ln.split(b":")[1].strip())
                        except Exception:
                            pass
                        break
                if (cl and len(body) >= cl) or (not cl and b"</html>" in body.lower()):
                    break
        except Exception as e:
            try:
                sock.close()
            except Exception:
                pass
            return None, cur, "", "传输:" + type(e).__name__
        finally:
            try:
                sock.close()
            except Exception:
                pass
        head, _, body = buf.partition(b"\r\n\r\n")
        hl = head.decode("iso-8859-1", "replace").split("\r\n")
        try:
            code = int(hl[0].split(" ")[1])
        except Exception:
            code = None
        hd = {}
        for ln in hl[1:]:
            if ":" in ln:
                k, v = ln.split(":", 1)
                hd[k.strip().lower()] = v.strip()
        if "gzip" in hd.get("content-encoding", "").lower():
            try:
                body = gzip.decompress(body)
            except Exception:
                pass
        elif "deflate" in hd.get("content-encoding", "").lower():
            try:
                body = zlib.decompress(body, -zlib.MAX_WBITS)
            except Exception:
                pass
        # 双重编码坑：部分站点同时发 Transfer-Encoding: chunked + Content-Encoding: gzip。
        # 裸 socket 读到的 body 前缀是 chunk 头（如 "1f0f\r\n"）再跟 gzip magic（1f 8b）。
        # 只按 Content-Encoding 解压会失败（gzip.decompress 报 magic 不符），
        # 必须先剥 chunked 帧，再按 gzip 解压，否则全文匹配恒为 0。
        def dechunk(raw):
            out = b""
            while True:
                i = raw.find(b"\r\n")
                if i < 0:
                    return out or raw
                size_line = raw[:i].split(b";")[0].strip()
                try:
                    size = int(size_line, 16)
                except Exception:
                    return out or raw
                if size == 0:
                    return out
                out += raw[i + 2:i + 2 + size]
                raw = raw[i + 2 + size + 2:]

        if "chunked" in hd.get("transfer-encoding", "").lower():
            body = dechunk(body)
        if body[:2] == b"\x1f\x8b":
            try:
                body = gzip.decompress(body)
            except Exception:
                pass
        elif "deflate" in hd.get("content-encoding", "").lower():
            try:
                body = zlib.decompress(body, -zlib.MAX_WBITS)
            except Exception:
                pass
        cs = "utf-8"
        m = re.search(rb'charset=["\']?([\w-]+)', body[:4096], re.I)
        if m:
            cs = m.group(1).decode("ascii", "replace")
        try:
            text = body.decode(cs, "replace")
        except Exception:
            text = body.decode("utf-8", "replace")
        loc = None
        for ln in hl[1:]:
            if ln.lower().startswith("location:"):
                from urllib.parse import urljoin
                loc = urljoin(cur, ln.split(":", 1)[1].strip())
                break
        if code in (301, 302, 303, 307, 308) and loc:
            cur = loc
            continue
        return code, cur, text, None
    return None, cur, "", "跳转过多"


def analyze(text, keyword):
    """统计：标题字段出现次数、id 字段次数、关键词出现次数"""
    n_name = 0
    for k in NAME_KEYS:
        n_name += len(re.findall(r'"%s"\s*:\s*"' % re.escape(k), text))
    if n_name == 0:
        # SSR / HTML：找 <a> 里含关键词的，或 title 属性
        n_name = len(re.findall(r'title="[^"]*%s[^"]*"' % re.escape(keyword), text))
        n_name += len(re.findall(r'>\s*[^<>]{0,40}%s[^<>]{0,40}\s*<' % re.escape(keyword), text))
    n_id = 0
    for k in ID_KEYS:
        n_id += len(re.findall(r'"%s"\s*:\s*"?\d+' % re.escape(k), text))
    n_key = text.count(keyword)
    return n_name, n_id, n_key


def probe(site):
    r = dict(site)
    home, tpl = site["home"], site.get("search_tpl")
    ua = UA
    if not tpl:
        r["verdict"] = "无搜索端点"
        return r
    KW = "海贼王"
    c1, f1, h1, e1 = http_get(tpl.replace("{kw}", quote(KW)), ua=ua, referer=home)
    c2, f2, h2, e2 = http_get(tpl.replace("{kw}", quote("zzqqxxjj999")), ua=ua, referer=home)
    if c1 is None or not h1:
        r["verdict"] = "搜索失败:" + str(e1)
        return r
    a_name, a_id, a_key = analyze(h1, KW)
    b_name, b_id, b_key = analyze(h2 or "", "zzqqxxjj999")
    r.update({
        "search_code": c1, "search_final": f1, "search_len": len(h1),
        "hits": a_name or a_id, "hits_name": a_name, "hits_id": a_id,
        "kw_in_resp": a_key, "ctrl_hits": b_name or b_id, "ctrl_kw": b_key,
        "sample": h1[:3000],
    })
    # 判定
    if (a_name > b_name) or (a_key > b_key + 2) or (a_name > 0 and b_name == 0):
        r["verdict"] = "★可用"
    elif a_name > 0 or a_key > 2:
        r["verdict"] = "⚠️不确定"
    else:
        r["verdict"] = "✗无命中"
    return r


def main():
    rows = json.load(open(os.path.join(HERE, "ycy_sites.json"), encoding="utf-8"))
    cand = [x for x in rows if x.get("home_code") == 200 and x.get("search_tpl")]
    print("待判站点 = %d\n" % len(cand), file=sys.stderr)

    out = []
    with cf.ThreadPoolExecutor(max_workers=10) as ex:
        futs = [ex.submit(probe, s) for s in cand]
        for i, f in enumerate(cf.as_completed(futs), 1):
            try:
                r = f.result()
            except Exception as e:
                r = {"host": "?", "verdict": "异常:" + type(e).__name__}
            out.append(r)
            print("[%2d/%2d] %-30s %-14s hits=%-5s(名%d/ID%d) 对照=%-5s" % (
                i, len(cand), r.get("host", "?")[:30], r.get("verdict", "")[:14],
                r.get("hits", "-"), r.get("hits_name", 0), r.get("hits_id", 0),
                r.get("ctrl_hits", "-")), file=sys.stderr)

    good = [r for r in out if r.get("verdict") == "★可用"]
    print("\n" + "=" * 118)
    print("★★★★ 搜索真生效（标题/ID 命中数 > 乱词对照）（%d 个）" % len(good))
    print("=" * 118)
    print("%-26s %-6s %-5s %-5s %-44s %s" % ("host", "hits", "标题", "ID", "title", "搜索端点"))
    print("-" * 118)
    for r in sorted(good, key=lambda x: -(x.get("hits") or 0)):
        print("%-26s %-6s %-5s %-5s %-44s %s" % (
            r["host"][:26], r.get("hits"), r.get("hits_name"), r.get("hits_id"),
            (r.get("title") or "")[:42], (r.get("search_tpl") or "")[:50]))

    print("\n" + "=" * 118)
    print("其余（%d）" % len([r for r in out if r.get("verdict") != "★可用"]))
    print("=" * 118)
    for r in sorted([r for r in out if r.get("verdict") != "★可用"],
                    key=lambda x: -(x.get("hits") or 0)):
        print("%-26s %-14s hits=%-5s 对照=%-5s %s" % (
            r["host"][:26], r.get("verdict"), r.get("hits", "-"),
            r.get("ctrl_hits", "-"), (r.get("title") or "")[:40]))

    json.dump(out, open(os.path.join(HERE, "ycy_final.json"), "w", encoding="utf-8"),
              ensure_ascii=False, indent=2)
    print("\n-> ycy_final.json")


if __name__ == "__main__":
    main()
