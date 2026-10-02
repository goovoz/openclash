#!/usr/bin/env python3
"""双机对照（精确版）：点 Add 后，**不刷新**，直接看页面里是否多出新段。

上一版判定有误：正则`cbid.openclash.<option>` 匹配到的是主 section
`openclash` 里的普通选项（auto_restart 之类），不是 lan_ac_traffic 段。

正确判据：lan_ac_traffic 段的每个字段在 HTML 里的 name 前缀是
    cbid.openclash.<段名>.<option>       （具名段）
匿名段由 uci 生成的段名形如 cfgXXXXXX，所以前缀是
    cbid.openclash.cfgXXXXXX.<option>
而主 section 的段名固定叫 "openclash"。据此可精确区分：
    「cbid.openclash.openclash.*」 -> 主 section，与 Add 无关
    其它段名-> Add 创建的新段

用法：
    python scripts/_deploy/ui-probe-compare-add-visual.py [slug] [sectiontype]
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


def sections_of(html):
    """返回 HTML 里出现的所有 uci 段名（cbid.<config>.<段名>. 里的段名）。"""
    names = re.findall(r'cbid\.openclash\.([A-Za-z_0-9]+)\.', html)
    return {n for n in names if n != "openclash"}   # 排除主 section


async def probe(pw, base, user, pwd, sel, slug, sec, label):
    b = await pw.chromium.launch(headless=True, args=["--disable-images"])
    ctx = await b.new_context(viewport={"width": 1500, "height": 1100})
    pg = await ctx.new_page()
    pg.set_default_timeout(120000)
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

        before = sections_of(await pg.content())
        print(f"\n===== {label} ({sec}) =====")
        print(f"  点击前的其它段: {sorted(before) or '(无)'}")

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
            await pg.wait_for_timeout(8000)

        after = sections_of(await pg.content())
        new = after - before
        print(f"  点击后（未刷新）的其它段: {sorted(after) or '(无)'}")
        print(f"  新增段: {sorted(new) or '(无)'}")
        print(f"  判定: {'新段立即可见 ✅' if new else '新段未出现 ❌'}")
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