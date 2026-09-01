#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""书源连通性 & 延迟基准测试（纯标准库）

端到端口径：每次请求重新 DNS + TCP + TLS，自动跟随 3xx 重定向并累加各跳耗时。
单位 ms，每端点跑 N 次取中位数。
用法： python bench_sources.py
"""
import socket
import ssl
import time
import statistics
import json
import sys
from urllib.parse import urlparse, urljoin

UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
N = 3                 # 冷启动次数
TIMEOUT = 10
MAX_HOPS = 5

TARGETS = [
    ("包子漫画", "baozi", "https://appcn.baozimh.com/"),
    ("拷贝漫画", "copy_manga", "https://api.copy-manga.com/"),
    ("hitomi 主域", "hitomi", "https://ltn.gold-usergeneratedcontent.net/version?_=1"),
    ("禁漫 · cdnntr", "jm", "https://www.cdnntr.cc/"),
    ("禁漫 · cdnsha", "jm", "https://www.cdnsha.org/"),
    ("禁漫 · cdntwice", "jm", "https://www.cdntwice.org/"),
    ("禁漫 · 图床", "jm", "https://cdn-msp.jmapinodeudzn.net/"),
    ("漫画柜 · 主站", "manhuagui", "https://www.manhuagui.com/"),
    ("漫画柜 · CDN", "manhuagui", "https://cf.mhgui.com/"),
    ("漫蛙吧 · manwali（书源旧值）", "manwaba",
     "https://manwali.cc/api/home?page=1&pageSize=6&type=&flag=false"),
    ("漫蛙吧 · manwari（最终域名）", "manwaba",
     "https://manwari.cc/api/home?page=1&pageSize=6&type=&flag=false"),
    ("漫蛙吧 · 图床", "manwaba", "https://tu.mhttu.cc/"),
    ("虫虫漫画 warchina", "warchina", "https://warchina.com/"),
]


class Conn:
    """一条到 (host, port) 的 TLS 连接，可复用"""

    def __init__(self, host, port):
        self.host, self.port = host, port
        self.conn_cost = {}
        self.sock = None
        t0 = time.perf_counter()
        infos = socket.getaddrinfo(host, port, proto=socket.IPPROTO_TCP)
        dns = (time.perf_counter() - t0) * 1000
        s = socket.socket(infos[0][0], socket.SOCK_STREAM)
        s.settimeout(TIMEOUT)
        t0 = time.perf_counter()
        s.connect(infos[0][4])
        tcp = (time.perf_counter() - t0) * 1000
        ctx = ssl.create_default_context()
        ctx.check_hostname = False
        ctx.verify_mode = ssl.CERT_NONE
        t0 = time.perf_counter()
        self.sock = ctx.wrap_socket(s, server_hostname=host)
        tls = (time.perf_counter() - t0) * 1000
        self.conn_cost = {"dns": dns, "tcp": tcp, "tls": tls}

    def request(self, path):
        req = ("GET %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: %s\r\n"
               "Accept: */*\r\nConnection: keep-alive\r\n\r\n" % (path, self.host, UA))
        t0 = time.perf_counter()
        self.sock.sendall(req.encode())
        buf = b""
        ttfb = None
        while True:
            chunk = self.sock.recv(65536)
            if not chunk:
                break
            if ttfb is None:
                ttfb = (time.perf_counter() - t0) * 1000
            buf += chunk
            head, _, body = buf.partition(b"\r\n\r\n")
            if head:
                # 读满 header 且拿到 content-length 对应长度就停
                cl = 0
                for ln in head.split(b"\r\n")[1:]:
                    if ln.lower().startswith(b"content-length:"):
                        cl = int(ln.split(b":")[1].strip())
                        break
                if cl and len(body) >= cl:
                    break
                if not cl and b"\r\n\r\n" in buf:
                    break
            if len(buf) > 3_000_000:
                break
        total = (time.perf_counter() - t0) * 1000
        head, _, body = buf.partition(b"\r\n\r\n")
        lines = head.decode("utf-8", "replace").split("\r\n")
        code = int(lines[0].split(" ")[1]) if " " in lines[0] else None
        loc = None
        for ln in lines[1:]:
            if ln.lower().startswith("location:"):
                loc = urljoin("https://%s%s" % (self.host, path), ln.split(":", 1)[1].strip())
                break
        return {"ttfb": ttfb or 0.0, "total": total, "code": code,
                "loc": loc, "bytes": len(body)}

    def close(self):
        try:
            self.sock.close()
        except Exception:
            pass


def _path_of(url):
    u = urlparse(url)
    p = u.path or "/"
    return p + ("?" + u.query if u.query else "")


def cold_probe(url):
    """冷启动：每跳都新建连接，时间全部累加（端到端口径）"""
    agg = {"cold": None, "hops": 0, "code": None, "bytes": 0,
           "err": None, "chain": []}
    cur, conn_sum, ttfb_sum, total_sum = url, 0.0, 0.0, 0.0
    for _ in range(MAX_HOPS):
        u = urlparse(cur)
        try:
            c = Conn(u.hostname, u.port or 443)
        except Exception as e:
            agg["err"] = "连接失败"
            agg["detail"] = str(e)
            return agg
        conn_sum += sum(c.conn_cost.values())
        agg["chain"].append(u.hostname)
        try:
            r = c.request(_path_of(cur))
        except Exception as e:
            agg["err"] = "传输失败"
            agg["detail"] = str(e)
            c.close()
            return agg
        finally:
            pass
        c.close()
        ttfb_sum += r["ttfb"]
        total_sum += r["total"]
        agg["code"], agg["bytes"] = r["code"], r["bytes"]
        if r["code"] in (301, 302, 303, 307, 308) and r["loc"]:
            agg["hops"] += 1
            cur = r["loc"]
            continue
        break
    else:
        agg["err"] = "重定向过多"
        return agg
    agg["cold_ttfb"] = conn_sum + ttfb_sum      # 端到端首字节
    agg["cold_total"] = conn_sum + total_sum    # 端到端完整
    agg["conn"] = conn_sum
    return agg


def med(v):
    v = [x for x in v if x is not None]
    return statistics.median(v) if v else None


def main():
    rows = []
    for name, key, url in TARGETS:
        colds = [cold_probe(url) for _ in range(N)]
        ok = [x for x in colds if not x["err"]]
        a = {
            "name": name, "key": key, "url": url,
            "cold_ttfb": med([x.get("cold_ttfb") for x in ok]),
            "cold_total": med([x.get("cold_total") for x in ok]),
            "conn": med([x.get("conn") for x in ok]),
            "hops": ok[-1]["hops"] if ok else 0,
            "code": ok[-1]["code"] if ok else None,
            "bytes": ok[-1]["bytes"] if ok else 0,
            "ok": len(ok), "err": (colds[-1]["err"] if not ok else None),
            "chain": " → ".join(ok[-1]["chain"]) if ok else "",
        }
        rows.append(a)
        print("  %-30s %s" % (name, "OK" if ok else a["err"]), file=sys.stderr)

    rows.sort(key=lambda a: (a["cold_total"] is None, a["cold_total"] or 9e9))

    print("\n" + "=" * 108)
    print("书源连通速度排行（本机实测，延迟中位数，单位 ms，越低越快）")
    print("=" * 108)
    print("%-3s %-30s %9s %9s %9s %5s %5s %9s" %
          ("#", "书源 / 端点", "建连成本", "首字节", "总耗时", "HTTP", "跳转", "成功率"))
    print("-" * 108)
    for i, a in enumerate(rows, 1):
        f = lambda v: ("%9.0f" % v) if v is not None else "        -"
        print("%-3d %-30s %s %s %s %5s %5d %9s %s" % (
            i, a["name"], f(a["conn"]), f(a["cold_ttfb"]), f(a["cold_total"]),
            a["code"] or "FAIL", a["hops"], "%d/%d" % (a["ok"], N), a["err"] or ""))
    print("-" * 108)
    print("建连成本 = DNS+TCP+TLS；首字节 = 建连+服务器响应；总耗时 = 首字节+内容下载。均为端到端口径（含 3xx 各跳累加）")
    if any(a["chain"].count("→") for a in rows):
        print("\n重定向链：")
        for a in rows:
            if a["hops"]:
                print("  %-30s %s" % (a["name"], a["chain"]))

    with open("bench_result.json", "w", encoding="utf-8") as fp:
        json.dump(rows, fp, ensure_ascii=False, indent=2)
    print("\n详细结果 -> bench_result.json")


if __name__ == "__main__":
    main()
