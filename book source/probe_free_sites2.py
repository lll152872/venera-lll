#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""第二批免费站深筛：域名来自搜索引擎真实结果（第一批全是我猜的，39/51 DNS 不存在）。

判据与 probe_free_sites.py 相同，但额外输出搜索 URL 模板线索，
便于直接写书源。
"""
import re
import json
import sys
import concurrent.futures as cf
from probe_free_sites import http_get, DETAIL_RE

SITES = [
    ("MHH1", "https://www.mhh1.com/", "https://www.mhh1.com/search?keyword={kw}"),
    ("MHH1alt", "https://mhh1.com/", "https://mhh1.com/search?keyword={kw}"),
    ("极速漫画", "https://www.jiximania.com/", "https://www.jiximania.com/search?keyword={kw}"),
    ("极速2", "https://www.jixinmanhua.com/", "https://www.jixinmanhua.com/search?keyword={kw}"),
    ("yymanhua", "https://www.yymanhua.com/", "https://www.yymanhua.com/search?keyword={kw}"),
    ("图库漫画", "https://www.tukumanga.com/", "https://www.tukumanga.com/search?keyword={kw}"),
    ("猫番", "https://www.maofan.com/", "https://www.maofan.com/search?keyword={kw}"),
    ("猫番2", "https://maofan.top/", "https://maofan.top/search?keyword={kw}"),
    ("咚漫", "https://www.webtoon.com.cn/", "https://www.webtoon.com.cn/search?keyword={kw}"),
    ("可米", "https://www.komic.cn/", "https://www.komic.cn/search?keyword={kw}"),
    ("漫漫", "https://www.manman123.com/", "https://www.manman123.com/search?keyword={kw}"),
    ("漫漫2", "https://www.manmanxia.com/", "https://www.manmanxia.com/search?keyword={kw}"),
    ("彩漫", "https://www.caimanmanhua.com/", "https://www.caimanmanhua.com/search?keyword={kw}"),
    ("MHH", "https://www.mhh1.xyz/", "https://www.mhh1.xyz/search?keyword={kw}"),
    ("韩漫", "https://www.hanmanhu.com/", "https://www.hanmanhu.com/search?keyword={kw}"),
    ("韩漫2", "https://www.hanman.top/", "https://www.hanman.top/search?keyword={kw}"),
    ("漫画盒子", "https://www.manhuhezi.com/", "https://www.manhuhezi.com/search?keyword={kw}"),
    ("动漫番", "https://www.dongmanfan.com/", "https://www.dongmanfan.com/search?keyword={kw}"),
    ("樱花动漫", "https://www.yhdmv1.com/", "https://www.yhdmv1.com/search?keyword={kw}"),
    ("樱花动漫2", "https://www.yhdmm.cc/", "https://www.yhdmm.cc/search?keyword={kw}"),
    ("生肉", "https://www.shengrou2.com/", "https://www.shengrou2.com/search?keyword={kw}"),
    ("琉璃", "https://www.liulicuan.com/", "https://www.liulicuan.com/search?keyword={kw}"),
    ("番剧", "https://www.fanju.tv/", "https://www.fanju.tv/search?keyword={kw}"),
    ("漫姬", "https://www.manjitop.com/", "https://www.manjitop.com/search?keyword={kw}"),
    ("bilibili漫画", "https://manga.bilibili.com/", "https://manga.bilibili.com/search?keyword={kw}"),
    ("快看", "https://www.kuaikanmanhua.com/", "https://www.kuaikanmanhua.com/search?keyword={kw}"),
    ("塔可", "https://www.takemanga.com/", "https://www.takemanga.com/search?keyword={kw}"),
    ("TAPP", "https://tapp.moe/", "https://tapp.moe/search?keyword={kw}"),
    ("拷贝", "https://www.copy-manga.com/", "https://www.copy-manga.com/search?keyword={kw}"),
    ("包子", "https://www.baozimh.com/", "https://www.baozimh.com/search?keyword={kw}"),
    ("禁漫", "https://www.jmapinodeudzn.net/", "https://www.jmapinodeudzn.net/search?keyword={kw}"),
    ("manhua", "https://manhuaus.com/", "https://manhuaus.com/search?keyword={kw}"),
    ("MComic", "https://www.mcomic.cn/", "https://www.mcomic.cn/search?keyword={kw}"),
    ("Musii", "https://www.musii.top/", "https://www.musii.top/search?keyword={kw}"),
    ("萌娘", "https://moe.town/", "https://moe.town/search?keyword={kw}"),
    ("ACG探", "https://acg.163.com/", "https://acg.163.com/search?keyword={kw}"),
    ("漫窝", "https://www.manwo.com/", "https://www.manwo.com/search?keyword={kw}"),
    ("漫画屋", "https://www.manhuawu.com/", "https://www.manhuawu.com/search?keyword={kw}"),
    ("漫世", "https://www.manshi.com/", "https://www.manshi.com/search?keyword={kw}"),
    ("动漫之家", "https://www.dmzhan.com/", "https://www.dmzhan.com/search?keyword={kw}"),
    ("极品漫画", "https://www.jipinmanhua.com/", "https://www.jipinmanhua.com/search?keyword={kw}"),
    ("漫画集市", "https://www.manjishi.com/", "https://www.manjishi.com/search?keyword={kw}"),
    ("漫社", "https://www.man-sha.com/", "https://www.man-sha.com/search?keyword={kw}"),
    ("ACG视频", "https://www.acgv.cn/", "https://www.acgv.cn/search?keyword={kw}"),
    ("动漫资源", "https://www.dmzy.com/", "https://www.dmzy.com/search?keyword={kw}"),
]


def probe(site):
    name, home, tpl = site
    row = {"name": name, "home": home, "tpl": tpl}
    code, final, html, err = http_get(home)
    row["home_code"], row["home_err"], row["final"] = code, err, final
    if code != 200:
        return row
    m = re.search(r"<title[^>]*>(.*?)</title>", html, re.I | re.S)
    row["title"] = re.sub(r"\s+", " ", m.group(1)).strip()[:52] if m else ""
    row["home_ids"] = len(set(DETAIL_RE.findall(html)))
    # 探测真实搜索参数：试 keyword / q / keyword= 几种
    best = None
    for t in (tpl, tpl.replace("keyword=", "q="), tpl.replace("?keyword=", "?search=")):
        c2, f2, h2, e2 = http_get(t.replace("{kw}", "%E6%B5%B7%E8%B4%BC%E7%8E%8B"), referer=home)
        c3, f3, h3, e3 = http_get(t.replace("{kw}", "zzzqxx"), referer=home)
        if c2 is None:
            continue
        n1, n2 = len(set(DETAIL_RE.findall(h2))), len(set(DETAIL_RE.findall(h3)))
        alive = (len(h2) != len(h3)) or (n1 != n2)
        cand = {"tpl": t, "alive": alive, "s1_len": len(h2), "s2_len": len(h3),
                "s1_ids": n1, "s2_ids": n2, "code": c2, "err": e2}
        if best is None or (cand["alive"] and not best["alive"]) or (cand["alive"] == best["alive"] and n1 > best["s1_ids"]):
            best = cand
        if cand["alive"] and n1 > 3:
            break
    row["search"] = best
    return row


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
            s = r.get("search")
            if r.get("home_code") != 200:
                print("[%2d] ❌ %-14s %s" % (i, r["name"], r.get("home_err")), file=sys.stderr)
            else:
                mark = "✅" if (s and s["alive"]) else "⚠️ "
                print("[%2d] %s %-14s ids=%-4s 搜:%s ids=%s/%s len=%d/%d | %s" % (
                    i, mark, r["name"], r.get("home_ids"),
                    (s or {}).get("code"), (s or {}).get("s1_ids"), (s or {}).get("s2_ids"),
                    (s or {}).get("s1_len", 0), (s or {}).get("s2_len", 0),
                    (r.get("title") or "")[:40]), file=sys.stderr)

    alive = [r for r in rows if r.get("home_code") == 200 and r.get("search", {}).get("alive")]
    print("\n" + "=" * 104)
    print("★★ 可用：首页活 + 搜索按关键词返回不同结果（%d 个）" % len(alive))
    print("=" * 104)
    for r in sorted(alive, key=lambda x: -(x["search"]["s1_ids"] or 0)):
        s = r["search"]
        print("%-14s %-40s 搜ids=%-4s 对照=%-4s %s" % (
            r["name"], (r.get("title") or "")[:38], s["s1_ids"], s["s2_ids"], s["tpl"]))
        print("               首页=%s" % r["home"])

    print("\n" + "=" * 104)
    print("⚠️ 首页活但搜索无效（%d 个）" % len([r for r in rows if r.get("home_code") == 200 and not r.get("search", {}).get("alive")]))
    print("=" * 104)
    for r in rows:
        if r.get("home_code") == 200 and not r.get("search", {}).get("alive"):
            s = r.get("search") or {}
            print("%-14s %-40s 搜len %d/%d ids %s/%s" % (
                r["name"], (r.get("title") or "")[:38], s.get("s1_len", 0), s.get("s2_len", 0),
                s.get("s1_ids"), s.get("s2_ids")))

    print("\n" + "=" * 104)
    print("❌ 不可达（%d）" % len([r for r in rows if r.get("home_code") != 200]))
    print("=" * 104)
    for r in rows:
        if r.get("home_code") != 200:
            print("%-14s %s" % (r["name"], r.get("home_err")))

    json.dump(rows, open("free_sites2.json", "w", encoding="utf-8"), ensure_ascii=False, indent=2)
    print("\n-> free_sites2.json")


if __name__ == "__main__":
    main()
