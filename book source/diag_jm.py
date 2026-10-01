#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""禁漫全链路诊断（2026-10）：动态域名 / 兜底线路 / 图片 CDN 全部实测"""
import http.client
import ssl
import socket
import time

UA = ("Mozilla/5.0 (Linux; Android 10; K; wv) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Version/4.0 Chrome/130.0.0.0 Mobile Safari/537.36")
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE

API_HEADERS = {
    "User-Agent": UA,
    "Accept": "application/json",
    "Platform": "1",
    "APP-VERSION": "2.0.16",
    "Referer": "https://localhost/",
}


def get(host, path, headers=None, n=2, timeout=12):
    res, err = [], None
    for _ in range(n):
        try:
            c = http.client.HTTPSConnection(host, 443, timeout=timeout, context=ctx)
            c.request("GET", path, headers=headers or API_HEADERS)
            r = c.getresponse()
            body = r.read()
            c.close()
            res.append((r.status, body))
        except Exception as e:
            err = "%s: %s" % (type(e).__name__, str(e)[:70])
            break
    if not res:
        return None, 0, err
    return res[-1][0], len(res[-1][1]), err


print("[1] 动态域名源 newsvr-2025.txt")
c = http.client.HTTPSConnection("rup4a04-c02.tos-cn-hongkong.bytepluses.com", 443, timeout=15, context=ctx)
try:
    c.request("GET", "/newsvr-2025.txt", headers={"User-Agent": UA})
    r = c.getresponse()
    data = r.read()
    print("    HTTP %d, %d bytes" % (r.status, len(data)))
    if r.status == 200:
        import base64, hashlib
        secret = "diosfjckwpqpdfjkvnqQjsik"
        # jm.js convertData: base64解码 -> AES-ECB(md5hex(secret)做key) 解密
        from Crypto.Cipher import AES  # pycryptodome
        raw = base64.b64decode(data)
        key = hashlib.md5(secret.encode()).hexdigest().encode()
        cipher = AES.new(key, AES.MODE_ECB)
        dec = cipher.decrypt(raw)
        pad = dec[-1]
        dec = dec[:-pad] if 0 < pad <= 16 else dec
        print("    解密结果:", dec.decode("utf-8", "replace")[:300])
except Exception as e:
    print("    失败:", type(e).__name__, str(e)[:80])

print()
print("[2] 四条兜底线路 /categories/filter 真实 API")
for h in ["www.cdnsha.org", "www.cdnntr.cc", "www.cdntwice.org", "www.cdnaspa.cc"]:
    try:
        socket.gethostbyname(h)
    except Exception:
        print("  %-20s DNS 解析失败" % h)
        continue
    code, n, err = get(h, "/categories/filter?o=mr&c=all&page=1")
    print("  %-20s HTTP %s  %s" % (h, code, err or ""))

print()
print("[3] 图片 CDN 域")
for h in ["cdn-msp.jmapinodeudzn.net", "cdn-msp3.jmapiproxy1.cc", "cdn-msp2.jmapiproxy2.cc"]:
    try:
        socket.gethostbyname(h)
    except Exception:
        print("  %-28s DNS 解析失败" % h)
        continue
    code, n, err = get(h, "/media/albums/1_3x4.jpg", n=1)
    print("  %-28s HTTP %s  %s" % (h, code, err or ""))
