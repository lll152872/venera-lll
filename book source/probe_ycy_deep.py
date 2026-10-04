#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""对异次元挖到的 45 个「搜索端点真实响应」站点做深度验证。

上一轮 search_hits 全是 0，因为 ID 正则只认 HTML 的 /comic/123/ 形式，
而这些站大量是 JSON API（comic_id）或 SSR 页面（data-n-head）。
本轮改判据：
  1. 直接看两次响应（真关键词 vs 乱码）内容是否不同 —— 这是搜索真假的唯一可靠标准
  2. 尝试多种 JSON 字段名 + HTML 链接模式提取命中数
  3. 顺带抓一次详情页，验证能不能拿到章节
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
TIMEOUT = 10

# JSON 里的漫画 id 字段名
JSON_ID_KEYS = ["comic_id", "id", "comicId", "book_id", "manga_id", "cid",
                "article_id", "post_id", "id_good", "b_id"]
# JSON 里的标题字段
JSON_NAME_KEYS = ["comic_name", "name", "title", "book_name", "manga_name",
                  "post_title", "b_name"]
# HTML 详情链接模式（多站通用）
HTML_LINK_RES = [
    re.compile(r'/comic/(\d{3,})[./?"\']', re.I),
    re.compile(r'/manhua/(\d{3,})[./?"\']', re.I),
    re.compile(r'/manga/(\d{3,})[./?"\']', re.I),
    re.compile(r'/book/(\d{3,})[./?"\']', re.I),
    re.compile(r'/info/(\d{3,})[./?"\']', re.I),
    re.compile(r'/(\d{4,})[./?"\'#]', re.I),
    re.compile(r'href="[^"]*?/(?:detail|show|read|chapter)[/_-](\d{3,})', re.I),
]


def http_get(url, ua=UA, referer=None, timeout=TIMEOUT, want_bytes=False):
    cur = url
    for _ in range(4):
        u = urlparse(cur)
        host, port = u.hostname, u.port or 443
        if not host:
            return None, cur, b"", "URL无主机"
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
            conn = (time.perf_counter() - t0) * 1000
        except Exception as e:
            return None, cur, b"", type(e).__name__
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
            t0 = time.perf_counter()
            buf = b""
            while len(buf) < 3_000_000:
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
            total = (time.perf_counter() - t0) * 1000
        except Exception as e:
            try:
                sock.close()
            except Exception:
                pass
            return None, cur, b"", "传输:" + type(e).__name__
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
        loc = None
        for ln in hl[1:]:
            if ln.lower().startswith("location:"):
                from urllib.parse import urljoin
                loc = urljoin(cur, ln.split(":", 1)[1].strip())
                break
        if code in (301, 302, 303, 307, 308) and loc:
            cur = loc
            continue
        # 解码
        cs = "utf-8"
        m = re.search(rb'charset=["\']?([\w-]+)', body[:4096], re.I)
        if m:
            cs = m.group(1).decode("ascii", "replace")
        try:
            text = body.decode(cs, "replace")
        except Exception:
            text = body.decode("utf-8", "replace")
        if want_bytes:
            return code, cur, text, None
        return code, cur, text, None
    return None, cur, "", "跳转过多"


def count_hits(text):
    """从响应里尽力提取漫画条目数：先试 JSON，再试 HTML 链接"""
    # 1) JSON
    t = text.lstrip()
    if t[:1] in "[{":
        try:
            j = json.loads(text)
        except Exception:
            j = None
        if j is not None:
            items = None
            if isinstance(j, list):
                items = j
            elif isinstance(j, dict):
                for k in ("data", "list", "result", "rows", "items", "books",
                          "comics", "dataList", "records"):
                    v = j.get(k)
                    if isinstance(v, list):
                        items = v
                        break
                    if isinstance(v, dict):
                        for k2 in ("list", "data", "rows", "items", "books"):
                            v2 = v.get(k2)
                            if isinstance(v2, list):
                                items = v2
                                break
                        if items:
                            break
            if items is not None:
                return len(items), "json"
    # 2) SSR 内嵌 JSON（data-n-head / __NUXT__ / window.__INITIAL_STATE__）
    for pat in (r'data-n-head="([^"]+)"', r'window\.__NUXT__\s*=\s*(.*?);</script>',
                r'__INITIAL_STATE__\s*=\s*(\{.*?\})</script>'):
        m = re.search(pat, text, re.S)
        if not m:
            continue
        raw = m.group(1)
        if "&quot;" in raw or "%7B" in raw:
            from urllib.parse import unquote
            raw = unquote(raw)
        try:
            j = json.loads(raw.replace("&quot;", '"').replace("&amp;", "&"))
        except Exception:
            continue
        s = json.dumps(j, ensure_ascii=False)
        for k in JSON_NAME_KEYS:
            n = s.count('"%s"' % k)
            if n:
                return n, "ssr:" + k
    # 3) HTML 链接
    best = 0
    for r in HTML_LINK_RES:
        n = len(set(r.findall(text)))
        if n > best:
            best = n
    if best:
        return best, "html"
    # 4) 兜底：数一下常见漫画卡片 class
    n = max(text.count(c) for c in ["item", "card", "book-item", "comic-item"]) if text else 0
    return (n, "guess") if n else (0, "none")


def probe(site):
    r = dict(site)
    home = site["home"]
    ua = site.get("ua") or UA
    tpl = site.get("search_tpl")
    code, final, html, err = http_get(home, ua=ua)
    r["home_code"], r["home_final"] = code, final
    if code != 200:
        r["home_err"] = err
        return r
    m = re.search(r"<title[^>]*>(.*?)</title>", html, re.I | re.S)
    r["title"] = re.sub(r"\s+", " ", m.group(1)).strip()[:56] if m else ""

    if not tpl:
        r["verdict"] = "无搜索端点"
        return r
    c1, f1, h1, e1 = http_get(tpl.replace("{kw}", quote("海贼王")), ua=ua, referer=home)
    c2, f2, h2, e2 = http_get(tpl.replace("{kw}", quote("zzqqxxjj999")), ua=ua, referer=home)
    r["s1"] = {"code": c1, "len": len(h1 or ""), "err": e1, "final": f1}
    r["s2"] = {"code": c2, "len": len(h2 or ""), "err": e2}
    if c1 is None:
        r["verdict"] = "搜索请求失败:" + str(e1)
        return r
    n1, how1 = count_hits(h1 or "")
    n2, how2 = count_hits(h2 or "")
    r["hits"], r["how"] = n1, how1
    r["ctrl_hits"], r["ctrl_how"] = n2, how2
    # 判定：真关键词命中 > 乱码命中（乱码一般 0）
    if n1 > 0 and n1 > n2:
        r["verdict"] = "★可用"
    elif n1 > 0 and n1 == n2:
        r["verdict"] = "⚠️搜索不响应关键词"
    else:
        r["verdict"] = "✗无命中"
    # 存一份真实关键词响应体，供后续写书源参考
    r["sample"] = (h1 or "")[:1200]
    return r


def main():
    rows = json.load(open(os.path.join(HERE, "ycy_sites.json"), encoding="utf-8"))
    cand = [x for x in rows if x.get("home_code") == 200 and x.get("search_alive")]
    print("待深测站点 = %d\n" % len(cand), file=sys.stderr)

    out = []
    with cf.ThreadPoolExecutor(max_workers=12) as ex:
        futs = [ex.submit(probe, s) for s in cand]
        for i, f in enumerate(cf.as_completed(futs), 1):
            try:
                r = f.result()
            except Exception as e:
                r = {"host": "?", "verdict": "异常:" + type(e).__name__}
            out.append(r)
            print("[%2d/%2d] %-34s %-22s hits=%-4s(%s) 对照=%-3s %s" % (
                i, len(cand), r.get("host", "?")[:34], r.get("verdict", "")[:22],
                r.get("hits", "-"), (r.get("how") or "")[:10],
                r.get("ctrl_hits", "-"), (r.get("title") or "")[:34]), file=sys.stderr)

    good = [r for r in out if r.get("verdict") == "★可用"]
    print("\n" + "=" * 116)
    print("★★★★ 深度验证通过：搜索真响应关键词 + 能提到漫画条目（%d 个）" % len(good))
    print("=" * 116)
    print("%-28s %-34s %-6s %-10s %s" % ("host", "title", "hits", "提取方式", "搜索端点"))
    print("-" * 116)
    for r in sorted(good, key=lambda x: -(x.get("hits") or 0)):
        print("%-28s %-34s %-6s %-10s %s" % (
            r["host"][:28], (r.get("title") or "")[:32], r.get("hits"),
            r.get("how"), (r.get("search_tpl") or "")[:60]))

    other = [r for r in out if r.get("verdict") != "★可用"]
    if other:
        print("\n" + "=" * 116)
        print("其余（%d 个）" % len(other))
        print("=" * 116)
        for r in sorted(other, key=lambda x: -(x.get("hits") or 0)):
            print("%-28s %-34s hits=%-5s 对照=%-5s %s" % (
                r["host"][:28], (r.get("title") or "")[:32], r.get("hits"),
                r.get("ctrl_hits"), r.get("verdict")))

    json.dump(out, open(os.path.join(HERE, "ycy_deep.json"), "w", encoding="utf-8"),
              ensure_ascii=False, indent=2)
    print("\n-> ycy_deep.json")


if __name__ == "__main__":
    main()
