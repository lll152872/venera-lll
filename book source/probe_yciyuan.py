#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从异次元图源合集提取真实站点域名 + 搜索端点，全量实测。

数据源：yiciyuan123/yiciyuan 仓库 9 个合集（base64+zlib），共 1000+ 图源条目。
这是真实社区维护的域名，比猜域名靠谱一个量级。

产出：ycy_sites.json（去重后的站点 + 搜索端点 + 解析线索）
"""
import base64
import zlib
import json
import glob
import os
import re
import sys
import socket
import ssl
import time
import gzip
import concurrent.futures as cf
from urllib.parse import urlparse, quote

HERE = os.path.dirname(os.path.abspath(__file__))
UA = ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36")
TIMEOUT = 9
UA_MOBILE = ("Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 "
             "(KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1")

# 不可能是漫画站的域名（工具/统计/图床/CDN/官方站）
SKIP = re.compile(
    r'(w3\.org|github|githubusercontent|jsdelivr|gstatic|googleapis|cloudflare|'
    r'schema\.org|xmlns|creativecommons|mozilla|apache|jquery|'
    r'navo\.top|yckceo|gitee|acg\.|bilivideo|hdslb|'
    r'creativecommons|fontawesome|bootstrap|cdnjs)', re.I)


def load_all():
    """合并 9 个合集，按 bookSourceUrl+ruleSearchUrl 去重"""
    merged = {}
    for f in sorted(glob.glob(os.path.join(HERE, "_ycy", "*.raw.json"))):
        try:
            items = json.load(open(f, encoding="utf-8"))
        except Exception:
            continue
        for e in items:
            url = (e.get("bookSourceUrl") or "").strip()
            if not url:
                continue
            k = (url, (e.get("ruleSearchUrl") or "").strip())
            if k not in merged:
                merged[k] = e
    return list(merged.values())


def hosts_of(entry):
    """从图源里提取所有 http(s) 域名（站点 + 搜索端点 + 正文端点）"""
    out = []
    for fld in ("bookSourceUrl", "ruleSearchUrl", "ruleSearchUrlNext",
                "ruleContentUrl", "ruleContentUrlNext", "ruleFindUrl",
                "loginUrl", "ruleSearchNoteUrl"):
        v = entry.get(fld) or ""
        for m in re.finditer(r"https?://([A-Za-z0-9._-]+)(?::\d+)?", v):
            h = m.group(1)
            if not SKIP.search(h) and h not in out:
                out.append(h)
    return out


def search_keyword_tpl(entry):
    """把 ruleSearchUrl 变成可实测的 URL 模板。

    异次元规则里 searchKey / searchKey2 是占位符，其余部分就是真实端点。
    例：https://api.gmh1234.com/comic/search?@keywords=searchKey
        → https://api.gmh1234.com/comic/search?keywords={kw}
    """
    u = (entry.get("ruleSearchUrl") or "").strip()
    if not u:
        return None
    # 去掉规则前缀标记：@keywords= 这种 @ 后面是规则名
    u = re.sub(r"@(\w+)", r"\1", u)
    if "searchKey" not in u:
        return None
    # 参数名可能是 keywords / keyword / q / search / key
    u = re.sub(r"searchKey2?", "{kw}", u, flags=re.I)
    # 占位符可能是 {searchKey} 形式
    u = re.sub(r"\{searchKey2?\}", "{kw}", u, flags=re.I)
    if "{kw}" not in u:
        return None
    return u


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
            conn = (time.perf_counter() - t0) * 1000
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
            t0 = time.perf_counter()
            buf = b""
            while len(buf) < 1_500_000:
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


# 判定「详情页链接」的通用正则：抓到数字 id 就算有内容
ID_RE = re.compile(r'/(?:comic|manga|manhua|chapter|book|read|info|detail|mh)/(\d{3,})[./?"\']')


def probe_site(site):
    """对单个站点：首页 + 搜索端点真伪验证"""
    row = dict(site)
    ua = UA_MOBILE if row.get("mobile") else UA
    code, final, html, err = http_get(row["home"], ua=ua)
    row["home_code"], row["home_err"], row["home_final"] = code, err, final
    if code != 200:
        return row
    m = re.search(r"<title[^>]*>(.*?)</title>", html, re.I | re.S)
    row["title"] = re.sub(r"\s+", " ", m.group(1)).strip()[:60] if m else ""
    row["home_ids"] = len(set(ID_RE.findall(html)))
    row["home_len"] = len(html)

    tpl = row.get("search_tpl")
    if not tpl:
        row["search_alive"] = False
        return row
    # 真关键词 vs 乱码：两次响应必须不同，否则搜索是废的
    try:
        c1, f1, h1, e1 = http_get(tpl.replace("{kw}", quote("海贼王")), ua=ua, referer=row["home"])
        c2, f2, h2, e2 = http_get(tpl.replace("{kw}", quote("zzqqxxjj")), ua=ua, referer=row["home"])
    except Exception as e:
        row["search_err"] = type(e).__name__
        row["search_alive"] = False
        return row
    n1, n2 = len(set(ID_RE.findall(h1))), len(set(ID_RE.findall(h2)))
    row["s1"] = {"code": c1, "len": len(h1), "ids": n1, "err": e1}
    row["s2"] = {"code": c2, "len": len(h2), "ids": n2, "err": e2}
    # 判据：内容长度不同 或 id 集合不同 → 搜索真的响应了关键词
    row["search_alive"] = bool(c1 == 200 and (len(h1) != len(h2) or n1 != n2))
    # 命中强度：能否搜到 >0 个 id
    row["search_hits"] = n1
    return row


def main():
    entries = load_all()
    print("图源条目（去重后）= %d" % len(entries), file=sys.stderr)

    # 按 host 聚合成站点
    site_map = {}
    for e in entries:
        hs = hosts_of(e)
        if not hs:
            continue
        home = (e.get("bookSourceUrl") or "").strip().rstrip("/")
        if not home.startswith("http"):
            continue
        home_host = urlparse(home).hostname
        if not home_host or SKIP.search(home_host):
            continue
        tpl = search_keyword_tpl(e)
        # 同一 host 取「有搜索模板 + UA 是移动端」的那条，信息最全
        prev = site_map.get(home_host)
        cand = {
            "host": home_host, "home": home, "search_tpl": tpl,
            "source_name": e.get("bookSourceName"),
            "search_list_rule": e.get("ruleSearchList"),
            "search_name_rule": e.get("ruleSearchName"),
            "chapter_list_rule": e.get("ruleChapterList"),
            "cover_rule": e.get("ruleSearchCoverUrl"),
            "has_search": bool(tpl),
            "mobile": "iPhone" in (e.get("httpUserAgent") or ""),
            "all_hosts": hs,
            "note": (e.get("sourceRemark") or "")[:120],
        }
        if prev is None:
            site_map[home_host] = cand
        else:
            # 合并：优先补上缺失的搜索模板
            if not prev["search_tpl"] and tpl:
                prev["search_tpl"] = tpl
                prev["search_list_rule"] = cand["search_list_rule"]
                prev["search_name_rule"] = cand["search_name_rule"]
            prev["has_search"] = prev["has_search"] or cand["has_search"]
            for h in hs:
                if h not in prev["all_hosts"]:
                    prev["all_hosts"].append(h)

    sites = list(site_map.values())
    print("去重后站点 = %d\n" % len(sites), file=sys.stderr)

    rows = []
    with cf.ThreadPoolExecutor(max_workers=16) as ex:
        futs = [ex.submit(probe_site, s) for s in sites]
        for i, f in enumerate(cf.as_completed(futs), 1):
            try:
                r = f.result()
            except Exception as e:
                r = {"host": "?", "home_code": None, "home_err": "异常:" + type(e).__name__}
            rows.append(r)
            if r.get("home_code") != 200:
                st = "❌"
            elif r.get("search_alive"):
                st = "✅"
            else:
                st = "⚠️ "
            print("[%3d/%3d] %s %-30s ids=%-4s 搜=%-5s %s" % (
                i, len(sites), st, r.get("host"), r.get("home_ids"),
                r.get("s1", {}).get("ids") if r.get("s1") else "-",
                (r.get("title") or "")[:44]), file=sys.stderr)

    alive = [r for r in rows if r.get("home_code") == 200 and r.get("search_alive")]
    print("\n" + "=" * 112)
    print("★★★ 站点活 + 搜索真的按关键词返回不同结果（%d 个）" % len(alive))
    print("=" * 112)
    print("%-30s %-42s %-7s %-6s %s" % ("host", "title", "首页ids", "搜hits", "搜索端点"))
    print("-" * 112)
    for r in sorted(alive, key=lambda x: -(x.get("search_hits") or 0)):
        print("%-30s %-42s %-7s %-6s %s" % (
            r["host"], (r.get("title") or "")[:40], r.get("home_ids"),
            r.get("search_hits"), (r.get("search_tpl") or "")[:64]))

    no_search = [r for r in rows if r.get("home_code") == 200 and not r.get("search_alive")]
    print("\n" + "=" * 112)
    print("⚠️ 站点活但搜索不可用（%d 个）" % len(no_search))
    print("=" * 112)
    for r in sorted(no_search, key=lambda x: -(x.get("home_ids") or 0))[:60]:
        s1, s2 = r.get("s1") or {}, r.get("s2") or {}
        print("%-30s %-40s 搜len %-7s/%-7s ids %s/%s" % (
            r["host"], (r.get("title") or "")[:38], s1.get("len"), s2.get("len"),
            s1.get("ids"), s2.get("ids")))

    dead = [r for r in rows if r.get("home_code") != 200]
    print("\n" + "=" * 112)
    print("❌ 不可达（%d 个）" % len(dead))
    print("=" * 112)
    for r in dead:
        print("%-30s %s" % (r.get("host"), r.get("home_err")))

    json.dump(rows, open(os.path.join(HERE, "ycy_sites.json"), "w", encoding="utf-8"),
              ensure_ascii=False, indent=2)
    print("\n-> ycy_sites.json  (共 %d 站)" % len(rows))


if __name__ == "__main__":
    main()
