#!/usr/bin/env python3
"""检查 Add 按钮的 name 与页面上 section-node id 的对应关系。

背景：tsection.htm 第 107 行匿名分支渲染
    name="cbi.cts.<config>.<sectiontype>.<section>"
其中 `section` 来自循环内的 `<%- section = k; isempty = false -%>`。
若模板引擎把 `<%-` 当成别的语义（或该赋值未生效），section 就是空串，
按钮 name 退化成 `cbi.cts.openclash.lan_ac_traffic.` —— 点击时浏览器
不会把它带进 POST body（实测 POST 里只有 cbi.cbe.* 字段），
于是服务端 parse 收不到 cbi.cts.* -> create 分支不进 -> 点了没反应。

本脚本只取证，不修改：
  - 打印所有 Add 按钮的 name
  - 打印页面上 cbi-section-node 的 id
  - 交叉比对：name 末段是否等于某个 section-node 的 id 末段

用法：
    python scripts/_deploy/ui-probe-add-name.py [slug] [sectiontype]
"""
import asyncio
import os
import re
import sys

sys.path.insert(0, os.path.abspath("scripts/_deploy"))
from credentials import DEBIAN_URL, DEBIAN_PWD, DEBIAN_USER, SEL_DEBIAN
from playwright.async_api import async_playwright


async def main():
    slug = sys.argv[1] if len(sys.argv) > 1 else "settings"
    sec = sys.argv[2] if len(sys.argv) > 2 else "lan_ac_traffic"

    async with async_playwright() as pw:
        b = await pw.chromium.launch(headless=True, args=["--disable-images"])
        ctx = await b.new_context(viewport={"width": 1500, "height": 1100})
        pg = await ctx.new_page()
        pg.set_default_timeout(120000)
        await pg.goto(DEBIAN_URL + "/cgi-bin/luci/", wait_until="domcontentloaded",
                      timeout=60000)
        await pg.fill(SEL_DEBIAN[0], DEBIAN_USER)
        await pg.fill(SEL_DEBIAN[1], DEBIAN_PWD)
        await pg.press(SEL_DEBIAN[1], "Enter")
        try:
            await pg.wait_for_load_state("networkidle", timeout=40000)
        except Exception:
            pass

        await pg.goto(f"{DEBIAN_URL}/cgi-bin/luci/admin/services/openclash/{slug}",
                      wait_until="domcontentloaded", timeout=90000)
        try:
            await pg.wait_for_load_state("networkidle", timeout=30000)
        except Exception:
            pass
        await pg.wait_for_timeout(2500)

        html = await pg.content()

        print("=== Add 按钮 name ===")
        for x in await pg.query_selector_all("input.cbi-button-add"):
            nm = await x.get_attribute("name")
            dis = await x.get_attribute("disabled")
            vis = await x.is_visible()
            print(f"  name={nm!r} disabled={dis} visible={vis}")

        print("\n=== 页面里的 cbi-section-node id ===")
        ids = re.findall(r'id="cbi-([A-Za-z_0-9]+)-([A-Za-z_0-9]+)"', html)
        seen = []
        for a, bid in ids:
            if (a, bid) not in seen:
                seen.append((a, bid))
        for a, bid in seen[:40]:
            print(f"  cbi-{a}-{bid}")

        print("\n=== 该 section 是否出现 no-values ===")
        cnt = html.count("This section contains no values yet")
        print(f"  no-values 出现 {cnt} 次")

        print("\n=== Delete 按钮 name（对照：走 cbi.rts.*）===")
        for x in await pg.query_selector_all("input.cbi-button"):
            nm = await x.get_attribute("name") or ""
            if ".rts." in nm:
                val = await x.get_attribute("value")
                print(f"  name={nm!r} value={val!r}")

        await b.close()


asyncio.run(main())