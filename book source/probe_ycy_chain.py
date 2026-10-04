#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""对 14 个「搜索真生效」的站做全链路验证：搜索→详情→章节→图片。

书源可行性只看搜索是不够的，必须确认详情页能拿到章节、章节页能拿到图。
输出：ycy_chain.json（每个站的详情/章节端点与实测结果）
"""
import json
import os
import re
import sys
import concurrent.futures as cf
from urllib.parse import urlparse, quote
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from probe_ycy_final import http_get, analyze, UA

HERE = os.path.dirname(os.path.abspath(__file__))

# 排除非漫画站
SKIP_HOSTS = {"www.duitang.com", "getconfig-globalapi.yyhao.com",
              "getcomicinfo-globalapi.yyhao.com"}

# 从异次元图源里找每个 host 的详情/章节规则（ruleBookUrlPattern / ruleContentUrl / ruleChapterList）
def load_rules():
    import base64, zlib, glob
    rules = {}
    for f in sorted(glob.glob(os.path.join(HERE, "_ycy", "*.raw.json"))):
        try:
            items = json.load(open(f, encoding="utf-8"))
        except Exception:
            continue
        for e in items:
            u = (e.get("bookSourceUrl") or "").strip()
            h = urlparse(u).hostname
            if not h:
                continue
            r = rules.setdefault(h, [])
            r.append({
                "name": e.get("bookSourceName"),
                "bookUrlPattern": e.get("ruleBookUrlPattern"),
                "chapterList": e.get("ruleChapterList"),
                "chapterName": e.get("ruleChapterName"),
                "contentUrl": e.get("ruleContentUrl"),
                "contentNext": e.get("ruleContentUrlNext"),
                "coverUrl": e.get("ruleSearchCoverUrl") or e.get("ruleCoverUrl"),
                "bookName": e.get("ruleBookName"),
                "searchList": e.get("ruleSearchList"),
                "searchName": e.get("ruleSearchName"),
                "note": (e.get("sourceRemark") or "")[:100],
            })
    return rules


def find_detail_ids(text):
    """从搜索响应里提详情页 id（多模式）"""
    out = []
    # JSON 的 comic_id / book_id
    for k in ("comic_id", "book_id", "manga_id", "article_id", "id"):
        for m in re.finditer(r'"%s"\s*:\s*"?(\d{3,})' % re.escape(k), text):
            out.append(m.group(1))
    # JSON 的 slug 型 id（comic_newid）
    for m in re.finditer(r'"(?:comic_newid|b_url|path|url|uri)"\s*:\s*"([^"]{3,60})"', text):
        v = m.group(1)
        if not v.startswith("http"):
            out.append(v)
    # HTML 链接
    for m in re.finditer(r'href="([^"]*(?:/comic/|/manhua/|/manga/|/book/|/detail/|/info/|\.html)[^"]*)"', text):
        u = m.group(1)
        if len(u) < 160:
            out.append(u)
    # 去重保序
    seen = set()
    res = []
    for x in out:
        if x not in seen:
            seen.add(x)
            res.append(x)
    return res


def probe_chain(site, rules):
    r = dict(site)
    home, tpl = site["home"], site.get("search_tpl")
    h = site["host"]
    r["yc_rules"] = [x for x in rules.get(h, [])][:3]
    if not tpl:
        r["chain"] = "无搜索端点"
        return r

    c1, f1, h1, e1 = http_get(tpl.replace("{kw}", quote("海贼王")), referer=home)
    if not h1:
        r["chain"] = "搜索失败"
        return r
    ids = find_detail_ids(h1)
    r["detail_candidates"] = ids[:8]
    r["sample"] = h1[:2500]

    # 逐个试详情 URL，看能不能拿到章节列表
    tried = []
    for cand in ids[:5]:
        if cand.startswith("http"):
            durl = cand
        else:
            durl = home.rstrip("/") + "/" + cand.lstrip("/")
        cd, fd, hd, ed = http_get(durl, referer=home)
        if cd is None or not hd:
            tried.append({"url": durl, "code": cd, "err": ed})
            continue
        # 章节痕迹
        ch_links = set()
        for m in re.finditer(r'href="([^"]*(?:/chapter|/read|/manga/|/comic/|\.html)[^"]*)"', hd):
            u = m.group(1)
            if re.search(r'/\d{3,}', u) or '.html' in u:
                ch_links.add(u)
        ep_ids = set(re.findall(r'["\']?chapter_id["\']?\s*[:=]\s*["\']?(\d{3,})', hd))
        m2 = re.search(r"<title[^>]*>(.*?)</title>", hd, re.I | re.S)
        t = re.sub(r"\s+", " ", m2.group(1)).strip()[:60] if m2 else ""
        info = {
            "url": durl, "code": cd, "len": len(hd), "title": t,
            "ch_links": len(ch_links), "ep_ids": len(ep_ids),
            "sample_links": list(ch_links)[:5],
        }
        # 再验一个章节页能否拿到图片
        if ch_links:
            link = list(ch_links)[0]
            curl_ = link if link.startswith("http") else home.rstrip("/") + "/" + link.lstrip("/")
            cc, fc, hc, ec = http_get(curl_, referer=durl)
            imgs = []
            if hc:
                imgs = re.findall(r'(?:src|data-src|original|url)\s*[=:]\s*["\']?(https?://[^"\'\s>]+\.(?:jpg|jpeg|png|webp))', hc, re.I)
                imgs += re.findall(r'\\["\']?(https?://[^"\'\s>]+\.(?:jpg|jpeg|png|webp))', hc, re.I)
            info["ep_page"] = {"code": cc, "len": len(hc or ""), "imgs": len(set(imgs)),
                               "err": ec, "url": curl_}
        tried.append(info)
        if info["ch_links"] > 3 and info.get("ep_page", {}).get("imgs", 0) > 0:
            r["verdict"] = "★全链路通"
            break
    r["chain_results"] = tried
    ok = any(t.get("ch_links", 0) > 3 for t in tried)
    got_img = any((t.get("ep_page") or {}).get("imgs", 0) > 0 for t in tried)
    if ok and got_img:
        r["verdict"] = "★全链路通"
    elif ok:
        r["verdict"] = "⚠️有章节未见图"
    elif any(t.get("code") == 200 for t in tried):
        r["verdict"] = "⚠️详情通但无章节"
    else:
        r["verdict"] = "✗详情打不开"
    return r


def main():
    rows = json.load(open(os.path.join(HERE, "ycy_final.json"), encoding="utf-8"))
    cand = [x for x in rows if x.get("verdict") == "★可用"
            and x.get("host") not in SKIP_HOSTS and x.get("search_tpl")]
    print("待验全链路 = %d\n" % len(cand), file=sys.stderr)
    rules = load_rules()
    print("异次元规则库覆盖 host = %d\n" % len(rules), file=sys.stderr)

    out = []
    with cf.ThreadPoolExecutor(max_workers=6) as ex:
        futs = [ex.submit(probe_chain, s, rules) for s in cand]
        for i, f in enumerate(cf.as_completed(futs), 1):
            try:
                r = f.result()
            except Exception as e:
                r = {"host": "?", "verdict": "异常:" + type(e).__name__}
            out.append(r)
            best = None
            for t in (r.get("chain_results") or []):
                if t.get("ch_links", 0) > 0:
                    best = t
                    break
            print("[%d/%d] %-24s %-16s 候选id=%-3s 章节链接=%-4s 图=%-4s" % (
                i, len(cand), r.get("host", "?")[:24], r.get("verdict", "")[:16],
                len(r.get("detail_candidates") or []),
                (best or {}).get("ch_links", "-"),
                ((best or {}).get("ep_page") or {}).get("imgs", "-")), file=sys.stderr)

    good = [r for r in out if r.get("verdict") == "★全链路通"]
    print("\n" + "=" * 116)
    print("★★★★★ 全链路可用：搜索→详情→章节→图片（%d 个）" % len(good))
    print("=" * 116)
    for r in good:
        print("★ %-24s %s" % (r["host"][:24], (r.get("title") or "")[:48]))
        for t in (r.get("chain_results") or [])[:2]:
            if t.get("ch_links", 0) > 0:
                print("    详情: %s" % t["url"][:88])
                print("    章节链接 %d 个, 章节页图 %s 张" % (
                    t["ch_links"], (t.get("ep_page") or {}).get("imgs", "?")))
                break

    print("\n" + "=" * 116)
    print("其余（%d）" % len([r for r in out if r.get("verdict") != "★全链路通"]))
    print("=" * 116)
    for r in [r for r in out if r.get("verdict") != "★全链路通"]:
        print("%-24s %-16s %s" % (r["host"][:24], r.get("verdict"),
                                   (r.get("title") or "")[:36]))

    json.dump(out, open(os.path.join(HERE, "ycy_chain.json"), "w", encoding="utf-8"),
              ensure_ascii=False, indent=2)
    print("\n-> ycy_chain.json")


if __name__ == "__main__":
    main()
