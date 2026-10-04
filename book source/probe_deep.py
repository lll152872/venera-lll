#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""存活站深度结构探测：搜索页 / 详情页 / 章节页 / 图片直链 是否可解析"""
import socket
import ssl
import json
import sys
import re
import gzip
import zlib
from urllib.parse import urlparse, urljoin, quote

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
TIMEOUT = 12


def http_get(url, referer=None, extra_headers=None):
    """返回 (code, final_url, text, headers)，跟随 3xx，最多 5 跳"""
    cur = url
    for _ in range(5):
        u = urlparse(cur)
        host, port = u.hostname, u.port or 443
        try:
            infos = socket.getaddrinfo(host, port, proto=socket.IPPROTO_TCP)
            s = socket.socket(infos[0][0], socket.SOCK_STREAM)
            s.settimeout(TIMEOUT)
            s.connect(infos[0][4])
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            sock = ctx.wrap_socket(s, server_hostname=host)
        except Exception as e:
            return None, cur, "", {}, "连接失败 %s" % type(e).__name__
        try:
            path = u.path or "/"
            if u.query:
                path += "?" + u.query
            hdrs = [
                "GET %s HTTP/1.1" % path,
                "Host: %s" % host,
                "User-Agent: %s" % UA,
                "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8",
                "Accept-Language: zh-CN,zh;q=0.9",
                "Accept-Encoding: gzip, deflate",
                "Connection: close",
            ]
            if referer:
                hdrs.append("Referer: %s" % referer)
            for k, v in (extra_headers or {}).items():
                hdrs.append("%s: %s" % (k, v))
            sock.sendall(("\r\n".join(hdrs) + "\r\n\r\n").encode())
            buf = b""
            while len(buf) < 4_000_000:
                try:
                    ch = sock.recv(65536)
                except Exception:
                    break
                if not ch:
                    break
                buf += ch
        except Exception as e:
            return None, cur, "", {}, "传输失败 %s" % type(e).__name__
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

        enc = hd.get("content-encoding", "").lower()
        if "gzip" in enc:
            try:
                body = gzip.decompress(body)
            except Exception:
                pass
        elif "deflate" in enc:
            try:
                body = zlib.decompress(body, -zlib.MAX_WBITS)
            except Exception:
                pass
        # 猜编码
        m = re.search(rb'charset=["\']?([\w-]+)', body[:4096], re.I)
        cs = "utf-8"
        if m:
            cs = m.group(1).decode("ascii", "replace")
        try:
            text = body.decode(cs, "replace")
        except Exception:
            text = body.decode("utf-8", "replace")
        if "charset" not in enc and cs.lower() not in ("utf-8", "utf8") and cs.lower() != "gb2312":
            pass
        loc = None
        for ln in hl[1:]:
            if ln.lower().startswith("location:"):
                loc = urljoin(cur, ln.split(":", 1)[1].strip())
                break
        if code in (301, 302, 303, 307, 308) and loc:
            cur = loc
            continue
        return code, cur, text, hd, None
    return None, cur, "", {}, "跳转过多"


IMG_RE = re.compile(r'https?://[^\s"\'<>\\)]+?\.(?:jpg|jpeg|png|webp|gif)(?:\?[^\s"\'<>\\)]*)?', re.I)


def summarize(tag, code, final, text, err):
    title = ""
    m = re.search(r"<title[^>]*>(.*?)</title>", text, re.I | re.S)
    if m:
        title = re.sub(r"\s+", " ", m.group(1)).strip()[:70]
    return {
        "tag": tag, "code": code, "final": final, "title": title,
        "len": len(text), "err": err,
        "imgs": len(set(IMG_RE.findall(text))),
    }


# ---- 逐站探测 ----
SITES = {}

def probe(site, paths):
    out = []
    for label, url in paths:
        code, final, text, hd, err = http_get(url)
        s = summarize(label, code, final, text, err)
        out.append(s)
        print("  %-22s %-5s %8d  %s | %s" % (
            s["tag"], s["code"] or s["err"], s["len"], url[:66], s["title"]), file=sys.stderr)
    return out


print("=== 快看漫画 ===", file=sys.stderr)
SITES["kuaikan"] = probe("kuaikan", [
    ("搜索页", "https://www.kuaikanmanhua.com/search?keyword=" + quote("海贼王")),
    ("搜索页2", "https://www.kuaikanmanhua.com/search/%E6%B5%B7%E8%B4%BC%E7%8E%8B"),
    ("分类页", "https://www.kuaikanmanhua.com/"),
])
print("=== 233漫画 ===", file=sys.stderr)
SITES["233mh"] = probe("233mh", [
    ("搜索页", "https://www.233mh.com/search?keyword=" + quote("海贼王")),
    ("首页", "https://www.233mh.com/"),
])
print("=== B站漫画 ===", file=sys.stderr)
SITES["bili"] = probe("bili", [
    ("漫画首页", "https://www.bilibili.com/manga/"),
    ("漫画搜索", "https://api.bilibili.com/x/web-interface/search/type?search_type=media_bangumi&keyword=" + quote("海贼王")),
])
print("=== one-piece.com ===", file=sys.stderr)
SITES["onepiece"] = probe("onepiece", [
    ("目录", "https://one-piece.com/"),
    ("作品列表", "https://one-piece.com/comics/o/"),
])
print("=== 动漫阁 ===", file=sys.stderr)
SITES["dmge"] = probe("dmge", [
    ("搜索页", "https://www.dmge.com/search?title=" + quote("海贼王")),
    ("首页", "https://www.dmge.com/"),
])
print("=== imetry ===", file=sys.stderr)
SITES["imetry"] = probe("imetry", [
    ("首页", "https://www.imetry.com/"),
    ("搜索", "https://www.imetry.com/search?keyword=test"),
])
print("=== 樱花动漫 ===", file=sys.stderr)
SITES["yhmgo"] = probe("yhmgo", [
    ("首页", "https://www.yhmgo.com/"),
])

with open("probe_deep.json", "w", encoding="utf-8") as fp:
    json.dump(SITES, fp, ensure_ascii=False, indent=2)

print("\n" + "=" * 100)
print("%-10s %-12s %6s %9s %7s  %s" % ("站点", "页面", "HTTP", "长度", "图数", "title"))
print("=" * 100)
for k, rows in SITES.items():
    for r in rows:
        print("%-10s %-12s %6s %9d %7d  %s" % (
            k, r["tag"], r["code"] or r["err"], r["len"], r["imgs"], r["title"]))
