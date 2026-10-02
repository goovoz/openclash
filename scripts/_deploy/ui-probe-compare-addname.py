#!/usr/bin/env python3
"""对照：抓 OpenWrt（172.20.0.2）与 openclash-rt（172.20.0.101:9080）
同一页面的 Add 按钮 name，用于确认正确行为应该是什么。

用法：
    export OCRT_OPENWRT_URL=http://172.20.0.2
    export OCRT_OPENWRT_PWD='<pwd>'
    python scripts/_deploy/ui-probe-compare-addname.py [slug] [sectiontype]
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
        await pg.goto(f"{base}/cgi-bin/luci/admin/services/openclash/{slug}",
                      wait_until="domcontentloaded", timeout=90000)
        try:
            await pg.wait_for_load_state("networkidle", timeout=30000)
        except Exception:
            pass
        await pg.wait_for_timeout(3000)

        html = await pg.content()
        names = []
        for x in await pg.query_selector_all("input.cbi-button-add"):
            nm = await x.get_attribute("name")
            dis = await x.get_attribute("disabled")
            vis = await x.is_visible()
            names.append((nm, dis, vis))
        nodes = re.findall(r'id="cbi-openclash-([A-Za-z_0-9]+)"', html)
        nvals = html.count("This section contains no values yet")

        print(f"\n===== {label} =====")
        print(f"  Add 按钮数: {len(names)}")
        for nm, dis, vis in names:
            if sec in (nm or ""):
                print(f"  ★ name={nm!r} disabled={dis} visible={vis}")
        print(f"  lan_ac_traffic 节点 id 存在: "
              f"{'是' if sec in nodes else '否'}")
        print(f"  no-values 次数: {nvals}")
        # 该 section 段数（页面上渲染出的 section-node 数）
        print(f"  含 '{sec}' 的节点 id: "
              f"{[n for n in nodes if sec in n]}")
        return names
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