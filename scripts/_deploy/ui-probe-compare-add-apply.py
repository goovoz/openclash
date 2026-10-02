#!/usr/bin/env python3
"""双机对照：同一个 Add 按钮，点下去后段是否落到 /etc/config。

这是判定「Add 失效是 bug 还是上游设计」的关键实验。
若 OpenWrt 上同样不落盘 -> 上游设计如此（需再点「保存&应用」）
若 OpenWrt 落盘而我们不落盘 -> 我方缺陷。

做法：在 OpenWrt 上用 LuCI 自带的 rpcd/ubus 无法从外部改配置，
所以改为对比两台机器 Add 点击后的**页面表现**——
刷新后新段是否出现在表格里。这与用户感知一致。

用法：
    python scripts/_deploy/ui-probe-compare-add-apply.py [slug] [sectiontype]
"""
import asyncio
import os
import re
import sys

sys.path.insert(0, os.path.abspath("scripts/_deploy"))
from credentials import (DEBIAN_URL, DEBIAN_PWD, DEBIAN_USER,
                         OPENWRT_URL, OPENWRT_PWD, OPENWRT_USER,
                         SEL_DEBIAN, SEL_OPENWRT)
from playwright.async_api import async_playwright


async def probe(pw, base, user, pwd, sel, slug, sec, label):
    b = await pw.chromium.launch(headless=True, args=["--disable-images"])
    ctx = await b.new_context(viewport={"width": 1500, "height": 1100})
    pg = await ctx.new_page()
    pg.set_default_timeout(120000)
    posts = []
    pg.on("response", lambda r: posts.append((r.request.method, r.status,
                                             r.url, r.headers.get("location", ""),
                                             r.headers.get("x-cbi-state", ""))
                                            if "openclash" in r.url else None))
    try:
        await pg.goto(base + "/cgi-bin/luci/", wait_until="domcontentloaded",
                      timeout=60000)
        await pg.fill(sel[0], user)
        await pg.fill(sel[1], pwd)
        await pg.press(sel[1], "Enter")
        try:
            await pg.wait_for_load_state("networkidle", timeout=40000)
        except Exception:
            pass

        url = f"{base}/cgi-bin/luci/admin/services/openclash/{slug}"
        await pg.goto(url, wait_until="domcontentloaded", timeout=90000)
        try:
            await pg.wait_for_load_state("networkidle", timeout=30000)
        except Exception:
            pass
        await pg.wait_for_timeout(2500)

        before_html = await pg.content()
        before_rows = len(re.findall(r'class="tr cbi-section-table-row',
                                     before_html))

        posts.clear()
        clicked = False
        for x in await pg.query_selector_all("input.cbi-button-add"):
            if not await x.is_visible():
                continue
            nm = await x.get_attribute("name") or ""
            if sec in nm:
                await x.click(force=True)
                clicked = True
                break
        if clicked:
            await pg.wait_for_timeout(7000)

        print(f"\n===== {label} ({sec}) =====")
        for m, st, u, loc, stt in [p for p in posts if p]:
            if m == "POST":
                print(f"  POST status={st} X-CBI-State={stt} "
                      f"Location={loc[:70]}")

        # 页面是否刷新出新段
        await pg.goto(url, wait_until="domcontentloaded", timeout=90000)
        try:
            await pg.wait_for_load_state("networkidle", timeout=30000)
        except Exception:
            pass
        await pg.wait_for_timeout(2500)
        after_html = await pg.content()
        after_rows = len(re.findall(r'class="tr cbi-section-table-row',
                                    after_html))
        # 新段会带 cbi-<config>-<sectype>-<sid> 的 input id
        sids = set(re.findall(r'id="cbid\.openclash\.[A-Za-z_0-9]+\.([A-Za-z_0-9]+)"',
                              after_html))
        print(f"  表格行数 {before_rows} -> {after_rows}")
        print(f"  刷新后该section 的 cbid 段名: {sorted(sids)[:8]}")
        print(f"  判定: {'新段可见 ✅' if after_rows > before_rows or len(sids) > 0 else '无新段 ❌'}")
    finally:
        await b.close()


async def main():
    slug = sys.argv[1] if len(sys.argv) > 1 else "settings"
    sec = sys.argv[2] if len(sys.argv) > 2 else "lan_ac_traffic"
    async with async_playwright() as pw:
        await probe(pw, OPENWRT_URL, OPENWRT_USER, OPENWRT_PWD, SEL_OPENWRT,
                    slug, sec, f"OpenWrt {OPENWRT_URL}")
        await probe(pw, DEBIAN_URL, DEBIAN_USER, DEBIAN_PWD, SEL_DEBIAN,
                    slug, sec, f"openclash-rt {DEBIAN_URL}")


asyncio.run(main())