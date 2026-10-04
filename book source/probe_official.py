#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从官方源库下载全部 JS，提取真实域名/端点，逐个实测连通性。

比猜域名靠谱：域名写在源码里。
用法： python probe_official.py
"""
import os
import re
import json
import sys
import subprocess
import concurrent.futures as cf

CDN = "https://cdn.jsdelivr.net/gh/venera-app/venera-configs@main/"
HERE = os.path.dirname(os.path.abspath(__file__))
RAW = os.path.join(HERE, "_official_raw")

HEAD_RE = re.compile(
    r'https?://[A-Za-z0-9._-]+(?::\d+)?'
    r'(?:/[A-Za-z0-9._~!$&\'()*+,;=:@%/?#-]*)?', re.I)

# 明显不是站点入口的域名（CDN/图床/字体/统计/官方文档等），先剔除
SKIP_PAT = re.compile(
    r'(w3\.org|github\.com|githubusercontent|jsdelivr|github\.io|'
    r'gstatic|googleapis|cloudflare|schema\.org|xmlns|'
    r'creativecommons|mozilla\.org|apache\.org|'
    r'jquery|jsdelivr\.net/npm)', re.I)


def run(cmd, timeout=60):
    try:
        p = subprocess.run(cmd, capture_output=True, timeout=timeout)
        return p.stdout.decode("utf-8", "replace")
    except Exception as e:
        return ""


def fetch_sources():
    os.makedirs(RAW, exist_ok=True)
    idx = json.load(open(os.path.join(HERE, "official_index.json"), encoding="utf-8"))
    # 同 key 多版本只取最高
    best = {}
    for x in idx:
        k = x["key"]
        try:
            v = tuple(int(i) for i in re.findall(r"\d+", x.get("version", "0"))[:3])
        except Exception:
            v = (0,)
        if k not in best or v > best[k][0]:
            best[k] = (v, x)
    out = []
    for k, (v, x) in best.items():
        fn = x.get("fileName") or (k + ".js")
        path = os.path.join(RAW, fn)
        if not os.path.exists(path) or os.path.getsize(path) < 100:
            run(["curl", "-sL", "-m", "40", CDN + fn, "-o", path])
        if os.path.exists(path) and os.path.getsize(path) > 100:
            out.append((x, path))
    return out


def extract_hosts(src):
    txt = open(src, encoding="utf-8", errors="replace").read()
    # 去掉注释里的 URL 干扰：只保留代码部分（粗略）
    hosts = []
    for m in HEAD_RE.finditer(txt):
        u = m.group(0).rstrip(".,;)\"'")
        hm = re.match(r"https?://([^/:?#]+)(?::(\d+))?", u)
        if not hm:
            continue
        host = hm.group(1)
        if SKIP_PAT.search(host):
            continue
        if host not in hosts:
            hosts.append(host)
    return hosts


def probe_host(host):
    """TLS + HTTP HEAD/GET 根路径"""
    code, so, ss, t0 = None, None, None, None
    import socket, ssl, time
    for port in (443,):
        try:
            st = time.perf_counter()
            infos = socket.getaddrinfo(host, port, proto=socket.IPPROTO_TCP)
            s = socket.socket(infos[0][0], socket.SOCK_STREAM)
            s.settimeout(8)
            s.connect(infos[0][4])
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            sock = ctx.wrap_socket(s, server_hostname=host)
            conn = (time.perf_counter() - st) * 1000
            req = ("GET / HTTP/1.1\r\nHost: %s\r\nUser-Agent: Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                   "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36\r\n"
                   "Accept: text/html,*/*\r\nAccept-Language: zh-CN,zh;q=0.9\r\n"
                   "Connection: close\r\n\r\n" % host)
            st = time.perf_counter()
            sock.sendall(req.encode())
            buf = b""
            while len(buf) < 300_000:
                try:
                    ch = sock.recv(65536)
                except Exception:
                    break
                if not ch:
                    break
                buf += ch
                head, _, body = buf.partition(b"\r\n\r\n")
                if b"</html>" in body.lower() or b"</body>" in body.lower():
                    break
                cl = 0
                for ln in head.split(b"\r\n")[1:]:
                    if ln.lower().startswith(b"content-length:"):
                        try:
                            cl = int(ln.split(b":")[1].strip())
                        except Exception:
                            pass
                        break
                if cl and len(body) >= cl:
                    break
            total = (time.perf_counter() - st) * 1000
            sock.close()
            try:
                code = int(buf.split(b" ")[1])
            except Exception:
                code = None
            title = ""
            m = re.search(rb"<title[^>]*>(.*?)</title>", body, re.I | re.S)
            if m:
                cs = "utf-8"
                cm = re.search(rb'charset=["\']?([\w-]+)', body[:4096], re.I)
                if cm:
                    cs = cm.group(1).decode("ascii", "replace")
                try:
                    title = re.sub(r"\s+", " ", m.group(1).decode(cs, "replace")).strip()[:50]
                except Exception:
                    title = m.group(1).decode("utf-8", "replace")[:50]
            return {"host": host, "ok": True, "code": code, "conn": round(conn),
                    "total": round(conn + total), "title": title}
        except Exception as e:
            err = type(e).__name__
    return {"host": host, "ok": False, "err": err}


def main():
    srcs = fetch_sources()
    print("已下载官方源 %d 个\n" % len(srcs), file=sys.stderr)
    tasks = []
    for x, path in srcs:
        hosts = extract_hosts(path)
        tasks.append((x, path, hosts))
        print("  %-22s %-6s hosts=%d" % (x["name"], x["key"], len(hosts)), file=sys.stderr)

    all_hosts = sorted({h for _, _, hs in tasks for h in hs})
    print("\n去重后待测 host：%d 个\n" % len(all_hosts), file=sys.stderr)
    with cf.ThreadPoolExecutor(max_workers=16) as ex:
        results = {r["host"]: r for r in ex.map(probe_host, all_hosts)}

    rows = []
    for x, path, hosts in tasks:
        rs = [results[h] for h in hosts if h in results]
        live = [r for r in rs if r["ok"]]
        dead = [r for r in rs if not r["ok"]]
        rows.append({
            "name": x["name"], "key": x["key"], "version": x.get("version"),
            "hosts": hosts, "live": live, "dead": dead,
            "best": min(live, key=lambda r: r["total"]) if live else None,
        })
        flag = "可用" if live else "全灭"
        b = rows[-1]["best"]
        print("[%s] %-22s live=%d/%d  %s" % (
            flag, x["name"], len(live), len(rs),
            ("%s %sms %s" % (b["host"], b["total"], b["title"])) if b else
            " ".join("%s(%s)" % (r["host"], r["err"]) for r in dead[:3])), file=sys.stderr)

    rows.sort(key=lambda a: (a["best"] is None, a["best"]["total"] if a["best"] else 9e9))
    print("\n" + "=" * 104)
    print("官方源实测排行（按最快活 host 排）")
    print("=" * 104)
    print("%-3s %-20s %-6s %5s %8s %6s  %s" % (
        "#", "源", "key", "活/总", "最快ms", "HTTP", "最快 host | title"))
    print("-" * 104)
    for i, a in enumerate(rows, 1):
        if a["best"]:
            print("%-3d %-20s %-6s %5s %8d %6s  %s | %s" % (
                i, a["name"], a["key"], "%d/%d" % (len(a["live"]), len(a["hosts"])),
                a["best"]["total"], a["best"]["code"], a["best"]["host"], a["best"]["title"]))
        else:
            print("%-3d %-20s %-6s %5s %8s %6s  %s" % (
                i, a["name"], a["key"], "0/%d" % len(a["hosts"]), "-", "FAIL",
                ",".join("%s(%s)" % (r["host"], r["err"]) for r in a["dead"][:4])))

    print("\n\n各源全部存活 host 明细：")
    for a in rows:
        if a["live"]:
            print("  %-20s %s" % (a["name"], " | ".join(
                "%s(%dms,%s)" % (r["host"], r["total"], r["code"]) for r in a["live"])))

    json.dump(rows, open(os.path.join(HERE, "official_probe.json"), "w", encoding="utf-8"),
              ensure_ascii=False, indent=2)
    print("\n-> official_probe.json")


if __name__ == "__main__":
    main()
