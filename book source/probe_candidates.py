#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""候选书源站点连通性快筛（纯标准库）

用途：对一批候选漫画站域名做 HTTPS 探测，快速淘汰不可用/需跳转的。
输出：probe_candidates.json + 终端表格
用法： python probe_candidates.py
"""
import socket
import ssl
import time
import json
import sys
from urllib.parse import urlparse, urljoin

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
N = 2
TIMEOUT = 8
MAX_HOPS = 5

# (显示名, 候选 URL)
CANDIDATES = [
    # --- 常见国产漫画站 ---
    ("漫画人", "https://www.manuar.com/"),
    ("漫画人2", "https://www.manuaren.com/"),
    ("魔趣漫画", "https://www.moqucc.com/"),
    ("魔趣漫画2", "https://moquy.com/"),
    ("皮皮漫画", "https://www.pipimanga.com/"),
    ("熊猫漫画", "https://www.xiongmh.com/"),
    ("奶牛快传", "https://www.nkdm666.com/"),
    ("摊牌漫画", "https://www.tanpaiwang.com/"),
    ("蜜桃漫画", "https://www.mitao5.com/"),
    ("极限漫画", "https://www.jiximanhua.com/"),
    ("卟卟漫画", "https://www.bubugua.com/"),
    ("233漫画", "https://www.233mh.com/"),
    ("来看漫画", "https://www.ylm.la/"),
    ("漫番", "https://www.manfans.com/"),
    ("漫Fun", "https://www.manfuns.com/"),
    ("动漫之家", "https://www.dmzh.com/"),
    ("动漫阁", "https://www.dmge.com/"),
    ("天漫", "https://www.tmanhu.com/"),
    ("漫画仓库", "https://www.manmangzhang.com/"),
    ("淘漫画", "https://www.taomanhua.com/"),
    ("樱花动漫", "https://www.yhmgo.com/"),
    ("樱花动漫2", "https://www.yhdm.la/"),
    ("imetry", "https://www.imetry.com/"),
    ("imh", "https://imh.im/"),
    ("ktmanga", "https://www.ktmanga.com/"),
    ("mangabz", "https://www.mangabz.com/"),
    ("拷贝(cn)", "https://www.copy-manga.com/"),
    ("禁漫主域", "https://18comic.vip/"),
    ("one piece", "https://one-piece.com/"),
    ("漫画人3", "https://manhua.qq.com/"),
    ("快看漫画", "https://www.kuaikanmanhua.com/"),
    ("哔哩哔哩漫画", "https://www.bilibili.com/manga/"),
    ("咚漫漫画", "https://www.dongmanzaixian.com/"),
    ("漫剧", "https://www.manju.live/"),
    ("漫蛙吧备用", "https://manwaba.com/"),
    ("hitomi备用", "https://hitomi.la/"),
    ("nyaa漫画", "https://nyaa.land/"),
    ("Kirara", "https://kirara.info/"),
    ("腐电站", "https://fuzhanpo.com/"),
    ("魔怔漫画", "https://mozhengmanhua.com/"),
    ("重力漫", "https://www.zhongliman.com/"),
    ("次元仓", "https://www.cycang.com/"),
    ("acg团", "https://www.acgt.cn/"),
    ("T的世界", "https://www.t-world.cn/"),
]


def _path_of(url):
    u = urlparse(url)
    p = u.path or "/"
    return p + ("?" + u.query if u.query else "")


def one_shot(url):
    """单跳请求，跟随 3xx，每跳新建连接，耗时累加"""
    res = {"url": url, "code": None, "bytes": 0, "hops": 0,
           "total": None, "conn": None, "err": None, "chain": [],
           "final": url, "title": None}
    cur = url
    conn_sum = 0.0
    for _ in range(MAX_HOPS):
        u = urlparse(cur)
        host = u.hostname
        if not host:
            res["err"] = "URL 无主机名"
            return res
        res["chain"].append(host)
        try:
            t0 = time.perf_counter()
            infos = socket.getaddrinfo(host, u.port or 443, proto=socket.IPPROTO_TCP)
            s = socket.socket(infos[0][0], socket.SOCK_STREAM)
            s.settimeout(TIMEOUT)
            s.connect(infos[0][4])
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            sock = ctx.wrap_socket(s, server_hostname=host)
            conn_cost = (time.perf_counter() - t0) * 1000
        except Exception as e:
            res["err"] = type(e).__name__
            res["detail"] = str(e)[:120]
            return res
        try:
            req = ("GET %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: %s\r\n"
                   "Accept: text/html,*/*\r\nAccept-Language: zh-CN,zh;q=0.9\r\n"
                   "Connection: close\r\n\r\n" % (_path_of(cur), host, UA))
            t0 = time.perf_counter()
            sock.sendall(req.encode())
            buf = b""
            while len(buf) < 400_000:
                try:
                    chunk = sock.recv(65536)
                except Exception:
                    break
                if not chunk:
                    break
                buf += chunk
                head, _, body = buf.partition(b"\r\n\r\n")
                cl = 0
                for ln in head.split(b"\r\n")[1:]:
                    if ln.lower().startswith(b"content-length:"):
                        try:
                            cl = int(ln.split(b":")[1].strip())
                        except Exception:
                            pass
                        break
                if (cl and len(body) >= cl) or (not cl and b"</html>" in body.lower()) or cl == 0:
                    break
            total = (time.perf_counter() - t0) * 1000
        except Exception as e:
            try:
                sock.close()
            except Exception:
                pass
            res["err"] = "传输失败:" + type(e).__name__
            return res
        try:
            sock.close()
        except Exception:
            pass

        head, _, body = buf.partition(b"\r\n\r\n")
        lines = head.decode("utf-8", "replace").split("\r\n")
        try:
            code = int(lines[0].split(" ")[1])
        except Exception:
            code = None
        res["code"] = code
        res["bytes"] = len(body)
        conn_sum += conn_cost
        res["conn"] = conn_sum
        res["total"] = conn_sum + total
        res["final"] = cur

        # 提取 <title>
        if code == 200:
            try:
                txt = body.decode("utf-8", "replace")
            except Exception:
                txt = body.decode("gbk", "replace")
            lo = txt.lower()
            a = lo.find("<title")
            if a >= 0:
                b = lo.find(">", a)
                e = lo.find("</title>", b)
                if b > 0 and e > b:
                    res["title"] = txt[b + 1:e].strip()[:60]

        loc = None
        for ln in lines[1:]:
            if ln.lower().startswith("location:"):
                loc = urljoin(cur, ln.split(":", 1)[1].strip())
                break
        if code in (301, 302, 303, 307, 308) and loc:
            res["hops"] += 1
            cur = loc
            continue
        break
    else:
        res["err"] = "重定向过多"
    return res


def main():
    rows = []
    total = len(CANDIDATES)
    for i, (name, url) in enumerate(CANDIDATES, 1):
        runs = [one_shot(url) for _ in range(N)]
        ok = [r for r in runs if r["err"] is None]
        best = min(ok, key=lambda r: r["total"]) if ok else runs[-1]
        rows.append({"name": name, "url": url, **best, "ok": len(ok)})
        flag = "OK " if len(ok) == N else "PART"
        print("[%2d/%2d] %s %-14s %s %s" % (
            i, total, flag, name, best["code"] or best["err"],
            best.get("title") or ""), file=sys.stderr)

    rows.sort(key=lambda a: (a["total"] is None, a["total"] or 9e9))
    print("\n" + "=" * 104)
    print("候选站点连通性排行（端到端中位数 ms，含 3xx 各跳累加）")
    print("=" * 104)
    print("%-3s %-14s %8s %8s %6s %5s %7s  %s" % (
        "#", "站点", "总耗时", "建连", "HTTP", "跳转", "字节", "最终 host / title"))
    print("-" * 104)
    for i, a in enumerate(rows, 1):
        if a["total"] is None:
            print("%-3d %-14s %8s %8s %6s %5d %7s  %s" % (
                i, a["name"], "-", "-", a["code"] or "FAIL", a["hops"],
                "-", a.get("detail", a.get("err", ""))[:40]))
            continue
        fin = urlparse(a["final"]).hostname or ""
        chain = a["chain"][-1] if a["chain"] else ""
        mark = " *跳转*" if a["hops"] else ""
        print("%-3d %-14s %8.0f %8.0f %6s %5d %7d  %s %s | %s" % (
            i, a["name"], a["total"], a["conn"], a["code"], a["hops"],
            a["bytes"], fin, mark, a.get("title") or ""))

    with open("probe_candidates.json", "w", encoding="utf-8") as fp:
        json.dump(rows, fp, ensure_ascii=False, indent=2)
    print("\n详细 -> probe_candidates.json")


if __name__ == "__main__":
    main()
