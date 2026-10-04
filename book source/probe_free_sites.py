#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""免费漫画站深筛：连通性 + 搜索页是否真能按关键词返回不同结果。

比官方源那套更严格：直接验「搜索能不能搜到东西」，
因为很多站首页能开但搜索早废了。
"""
import socket
import ssl
import time
import re
import json
import sys
import gzip
import zlib
import concurrent.futures as cf
from urllib.parse import urlparse, quote

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
TIMEOUT = 10


def http_get(url, referer=None):
    cur = url
    for _ in range(4):
        u = urlparse(cur)
        host, port = u.hostname, u.port or 443
        try:
            t0 = time.perf_counter()
            infos = socket.getaddrinfo(host, port, proto=socket.IPPROTO_TCP)
            s = socket.socket(infos[0][0], socket.SOCK_STREAM)
            s.settimeout(TIMEOUT)
            s.connect(infos[0][4])
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            sock = ctx.wrap_socket(s, server_hostname=host)
            conn = (time.perf_counter() - t0) * 1000
        except Exception as e:
            return None, cur, "", "连接失败:" + type(e).__name__
        try:
            path = u.path or "/"
            if u.query:
                path += "?" + u.query
            hdrs = ["GET %s HTTP/1.1" % path, "Host: %s" % host,
                    "User-Agent: %s" % UA,
                    "Accept: text/html,application/xhtml+xml;q=0.9,*/*;q=0.8",
                    "Accept-Language: zh-CN,zh;q=0.9",
                    "Accept-Encoding: gzip, deflate", "Connection: close"]
            if referer:
                hdrs.append("Referer: %s" % referer)
            sock.sendall(("\r\n".join(hdrs) + "\r\n\r\n").encode())
            t0 = time.perf_counter()
            buf = b""
            while len(buf) < 2_500_000:
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
            return None, cur, "", "传输失败:" + type(e).__name__
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


DETAIL_RE = re.compile(
    r'href="[^"]*/(?:comic|manga|manhua|book|info|detail|show|chapter)?[^"]*?'
    r'/(\d{3,})[/.]"|href="[^"]*/(comic|manga|info|book)/([a-zA-Z0-9_-]+)[/.]"',
    re.I)


def probe(site):
    name, home, search_tpl = site
    row = {"name": name, "home": home, "search_tpl": search_tpl}
    code, final, home_html, err = http_get(home)
    row["home_code"], row["home_err"] = code, err
    if code != 200:
        return row
    m = re.search(r"<title[^>]*>(.*?)</title>", home_html, re.I | re.S)
    row["title"] = re.sub(r"\s+", " ", m.group(1)).strip()[:50] if m else ""
    row["home_ids"] = len(set(DETAIL_RE.findall(home_html)))
    # 搜索：同关键词必须返回不同内容，否则搜索是废的
    outs = {}
    for kw in ("海贼王", "zzz不存在zzz"):
        u = search_tpl.replace("{kw}", quote(kw))
        c2, f2, h2, e2 = http_get(u, referer=home)
        t2 = re.search(r"<title[^>]*>(.*?)</title>", h2, re.I | re.S)
        outs[kw] = {
            "code": c2, "err": e2, "len": len(h2),
            "ids": len(set(DETAIL_RE.findall(h2))),
            "title": re.sub(r"\s+", " ", t2.group(1)).strip()[:50] if t2 else "",
        }
    row["s1"], row["s2"] = outs["海贼王"], outs["zzz不存在zzz"]
    # 搜索有效性判定：两次响应必须不同（长度或 id 集合）
    row["search_alive"] = (row["s1"]["len"] != row["s2"]["len"]) or (row["s1"]["ids"] != row["s2"]["ids"])
    return row


SITES = [
    ("漫画全集", "https://www.manhuajiquan.com/", "https://www.manhuajiquan.com/search?keyword={kw}"),
    ("漫画岛", "https://www.manhuDao.com/", "https://www.manhuDao.com/search?keyword={kw}"),
    ("皮皮漫画", "https://www.pipimanga.com/", "https://www.pipimanga.com/search?keyword={kw}"),
    ("次元仓", "https://www.cycang.com/", "https://www.cycang.com/search?keyword={kw}"),
    ("一刻动漫", "https://www.yikedongman.com/", "https://www.yikedongman.com/search?keyword={kw}"),
    ("追追漫画", "https://www.zhuizhui8.com/", "https://www.zhuizhui8.com/search?keyword={kw}"),
    (" Gadget", "https://m.gadgetkt.com/", "https://m.gadgetkt.com/search?keyword={kw}"),
    ("漫Diy", "https://www.mandiyi.com/", "https://www.mandiyi.com/search?keyword={kw}"),
    ("内漫", "https://www.neiman.us/", "https://www.neiman.us/search?keyword={kw}"),
    ("漫Life", "https://www.manlife.cc/", "https://www.manlife.cc/search?keyword={kw}"),
    ("多漫", "https://www.duomanmanhua.com/", "https://www.duomanmanhua.com/search?keyword={kw}"),
    ("漫无尽", "https://www.manwujin.com/", "https://www.manwujin.com/search?keyword={kw}"),
    ("K漫画", "https://www.kkmh.cc/", "https://www.kkmh.cc/search?keyword={kw}"),
    ("漫姬", "https://www.manji.cc/", "https://www.manji.cc/search?keyword={kw}"),
    ("嗷呜", "https://www.aowu.la/", "https://www.aowu.la/search?keyword={kw}"),
    ("ACG猫", "https://www.acgmao.com/", "https://www.acgmao.com/search?keyword={kw}"),
    ("动漫仓", "https://www.dmzc.com/", "https://www.dmzc.com/search?keyword={kw}"),
    ("巴士漫画", "https://www.bushimanga.com/", "https://www.bushimanga.com/search?keyword={kw}"),
    ("Futa漫", "https://futa.im/", "https://futa.im/search?keyword={kw}"),
    ("禁漫XY", "https://www.jmxy.org/", "https://www.jmxy.org/search?keyword={kw}"),
    ("魔都", "https://www.modu.la/", "https://www.modu.la/search?keyword={kw}"),
    ("漫姬论坛", "https://www.manjitianxia.com/", "https://www.manjitianxia.com/search?keyword={kw}"),
    ("琉璃神社", "https://www.hacg1.com/", "https://www.hacg1.com/search?keyword={kw}"),
    ("ACG漫", "https://www.acgmanga.com/", "https://www.acgmanga.com/search?keyword={kw}"),
    ("布 reenc", "https://www.burec.top/", "https://www.burec.top/search?keyword={kw}"),
    ("彩虹漫画", "https://www.caihongmanhua.com/", "https://www.caihongmanhua.com/search?keyword={kw}"),
    ("铅笔动漫", "https://www.qianbianga.com/", "https://www.qianbianga.com/search?keyword={kw}"),
    ("漫客栈", "https://www.mankezhan.com/", "https://www.mankezhan.com/search?keyword={kw}"),
    ("幻书阁", "https://www.hsgc.com/", "https://www.hsgc.com/search?keyword={kw}"),
    ("漫趣", "https://www.manqu123.com/", "https://www.manqu123.com/search?keyword={kw}"),
    ("看漫画", "https://www.kanmanhua.com/", "https://www.kanmanhua.com/search?keyword={kw}"),
    ("漫画同步", "https://www.manhuatongbu.com/", "https://www.manhuatongbu.com/search?keyword={kw}"),
    ("天天漫画", "https://www.tiantianmanhua.com/", "https://www.tiantianmanhua.com/search?keyword={kw}"),
    ("悟空漫画", "https://www.wukongmh.com/", "https://www.wukongmh.com/search?keyword={kw}"),
    ("蜡笔漫画", "https://www.lbihmh.com/", "https://www.lbihmh.com/search?keyword={kw}"),
    ("肉漫", "https://www.rouman.us/", "https://www.rouman.us/search?keyword={kw}"),
    ("漫网2", "https://www.manwang2.com/", "https://www.manwang2.com/search?keyword={kw}"),
    ("搜漫", "https://www.souman.us/", "https://www.souman.us/search?keyword={kw}"),
    ("漫本", "https://www.manben.com/", "https://www.manben.com/search?keyword={kw}"),
    ("戏虫", "https://www.xichong.com/", "https://www.xichong.com/search?keyword={kw}"),
    ("漫宇宙", "https://www.manuniverse.com/", "https://www.manuniverse.com/search?keyword={kw}"),
    ("ACG之家", "https://www.acgzhizhi.com/", "https://www.acgzhizhi.com/search?keyword={kw}"),
    ("漫喵", "https://www.manmiao.com/", "https://www.manmiao.com/search?keyword={kw}"),
    ("樱花漫", "https://www.sakura.man/", "https://www.sakura.man/search?keyword={kw}"),
    ("星河 comic", "https://www.xhcomic.com/", "https://www.xhcomic.com/search?keyword={kw}"),
    ("绘漫", "https://www.huimanmanhua.com/", "https://www.huimanmanhua.com/search?keyword={kw}"),
    ("漫画岛2", "https://www.manhuadao.cc/", "https://www.manhuadao.cc/search?keyword={kw}"),
    ("漫潭", "https://www.mantan.top/", "https://www.mantan.top/search?keyword={kw}"),
    ("水墨", "https://www.shuimomo.com/", "https://www.shuimomo.com/search?keyword={kw}"),
    ("君漫", "https://www.junman365.com/", "https://www.junman365.com/search?keyword={kw}"),
    ("轻之国度", "https://www.lightnovel.cn/", "https://www.lightnovel.cn/search?keyword={kw}"),
]


def main():
    rows = []
    with cf.ThreadPoolExecutor(max_workers=14) as ex:
        futs = {ex.submit(probe, s): s for s in SITES}
        for i, f in enumerate(cf.as_completed(futs), 1):
            try:
                r = f.result()
            except Exception as e:
                r = {"name": futs[f][0], "home_code": None, "home_err": "异常:" + type(e).__name__}
            rows.append(r)
            s1, s2 = r.get("s1"), r.get("s2")
            if r.get("home_code") != 200:
                print("[%2d/%2d] ❌ %-14s %s" % (i, len(SITES), r["name"], r.get("home_err")), file=sys.stderr)
            else:
                mark = "✅搜索有效" if r.get("search_alive") else "⚠️ 搜索无效"
                print("[%2d/%2d] %s %-14s 首页ids=%-4s 搜1(ids=%s,%dB) 搜2(ids=%s,%dB)" % (
                    i, len(SITES), mark, r["name"], r.get("home_ids"),
                    (s1 or {}).get("ids"), (s1 or {}).get("len", 0),
                    (s2 or {}).get("ids"), (s2 or {}).get("len", 0)), file=sys.stderr)

    alive = [r for r in rows if r.get("home_code") == 200 and r.get("search_alive")]
    onlyhome = [r for r in rows if r.get("home_code") == 200 and not r.get("search_alive")]
    dead = [r for r in rows if r.get("home_code") != 200]

    print("\n" + "=" * 100)
    print("★ 可用：首页活 + 搜索真的按关键词返回不同结果（%d 个）" % len(alive))
    print("=" * 100)
    print("%-16s %-46s %-8s %-7s %s" % ("站点", "title", "首页ids", "搜1ids", "搜2ids(对照)"))
    print("-" * 100)
    for r in sorted(alive, key=lambda x: -(x.get("s1", {}).get("ids") or 0)):
        print("%-16s %-46s %-8s %-7s %s" % (
            r["name"], (r.get("title") or "")[:44], r.get("home_ids"),
            (r.get("s1") or {}).get("ids"), (r.get("s2") or {}).get("ids")))

    print("\n" + "=" * 100)
    print("⚠️ 仅首页活，搜索已废（%d 个）" % len(onlyhome))
    print("=" * 100)
    for r in onlyhome:
        print("%-16s %-46s 搜1=%sB 搜2=%sB" % (
            r["name"], (r.get("title") or "")[:44],
            (r.get("s1") or {}).get("len"), (r.get("s2") or {}).get("len")))

    print("\n" + "=" * 100)
    print("❌ 站点不可达（%d 个）" % len(dead))
    print("=" * 100)
    for r in dead:
        print("%-16s %s" % (r["name"], r.get("home_err")))

    json.dump(rows, open("free_sites.json", "w", encoding="utf-8"), ensure_ascii=False, indent=2)
    print("\n-> free_sites.json")


if __name__ == "__main__":
    main()
