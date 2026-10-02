#!/usr/bin/env python3
"""抓 Add 按钮点击时 POST 的真实请求体与服务端响应。

用途：判定「点了没反应」到底是
  (a) 按钮没提交（表单/字段问题）
  (b) 提交了但服务端没建段（parse/create 链路问题）
  (c) 建段了但没 commit（uci:save/commit 链路问题）

判据靠三处证据拼出来：
  - 请求侧：request.post_data 里有没有 cbi.cts.* 字段
  - 响应侧：状态码、Location、X-CBI-State 响应头
  - 服务端：点击前后 /etc/config/openclash 里该类型的段数

用法：
    export OCRT_DEBIAN_URL=http://<host>:9080
    export OCRT_DEBIAN_PWD='<pwd>'
    python scripts/_deploy/ui-probe-add-post.py [slug] [sectiontype]
"""
import asyncio
import os
import re
import sys

sys.path.insert(0, os.path.abspath("scripts/_deploy"))
from credentials import DEBIAN_URL, DEBIAN_PWD, DEBIAN_USER, SEL_DEBIAN
from playwright.async_api import async_playwright

import paramiko

HOST = os.environ.get("OCRT_DEBIAN_URL_SSH", "172.20.0.101")


def sh(cmd):
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username="root", password=DEBIAN_PWD, allow_agent=False,
              look_for_keys=False, timeout=15)
    si, so, se = c.exec_command(cmd, timeout=30)
    out = so.read().decode()
    c.close()
    return out


def raw_count(sec):
    """直接数 /etc/config/openclash 里 `= <sec>` 的行数（含未 commit 的）。"""
    return len([ln for ln in sh(f"cat /etc/config/openclash").splitlines()
                if ln.strip().endswith("=" + sec)])


async def main():
    slug = sys.argv[1] if len(sys.argv) > 1 else "settings"
    sec = sys.argv[2] if len(sys.argv) > 2 else "lan_ac_traffic"

    async with async_playwright() as pw:
        b = await pw.chromium.launch(headless=True, args=["--disable-images"])
        ctx = await b.new_context(viewport={"width": 1500, "height": 1100})
        pg = await ctx.new_page()
        pg.set_default_timeout(120000)

        captured = []

        def on_req(r):
            if r.method == "POST" and "openclash" in r.url:
                captured.append({
                    "url": r.url,
                    "post": r.post_data or "",
                    "headers": dict(r.headers),
                })

        pg.on("request", on_req)

        await pg.goto(DEBIAN_URL + "/cgi-bin/luci/", wait_until="domcontentloaded",
                      timeout=60000)
        await pg.fill(SEL_DEBIAN[0], DEBIAN_USER)
        await pg.fill(SEL_DEBIAN[1], DEBIAN_PWD)
        await pg.press(SEL_DEBIAN[1], "Enter")
        try:
            await pg.wait_for_load_state("networkidle", timeout=40000)
        except Exception:
            pass

        url = f"{DEBIAN_URL}/cgi-bin/luci/admin/services/openclash/{slug}"
        await pg.goto(url, wait_until="domcontentloaded", timeout=90000)
        try:
            await pg.wait_for_load_state("networkidle", timeout=30000)
        except Exception:
            pass
        await pg.wait_for_timeout(2500)

        # 按钮清单：把所有 Add 按钮的 name / disabled / visible 打出来
        print("=== 该页所有 Add 按钮 ===")
        for x in await pg.query_selector_all("input.cbi-button-add"):
            nm = await x.get_attribute("name") or "(no-name)"
            dis = await x.get_attribute("disabled")
            vis = await x.is_visible()
            print(f"  name={nm!r} disabled={dis} visible={vis}")

        before = raw_count(sec)
        print(f"\n=== 点击前 /etc/config/openclash 里 {sec} 行数: {before} ===")

        captured.clear()
        target = None
        for x in await pg.query_selector_all("input.cbi-button-add"):
            if not await x.is_visible():
                continue
            nm = await x.get_attribute("name") or ""
            if sec in nm:
                target = x
                break

        if target is None:
            print("!! 没找到目标 Add 按钮")
            await b.close()
            return

        nm = await target.get_attribute("name")
        dis = await target.get_attribute("disabled")
        print(f"\n=== 目标按钮 name={nm!r} disabled={dis} ===")
        if dis is not None:
            print("!! 按钮是 disabled —— 这就是「点了没反应」的直接原因")
            print("!! 上游用 cbi_validate_named_section_add 在输入名字后 enable 它")

        await target.click(force=True)
        await pg.wait_for_timeout(6000)

        print(f"\n=== POST 请求数: {len(captured)} ===")
        for i, r in enumerate(captured):
            print(f"--- POST #{i} {r['url']}")
            body = r["post"]
            # multipart 里只打关键字段，避免刷屏
            keys = re.findall(r'name="(cbi\.[^"]+)"', body)
            print(f"    长度={len(body)}  cbi.* 字段数={len(keys)}")
            for k in keys[:20]:
                print(f"      {k}")
            if not keys:
                print(f"    (无 cbi 字段) 前 300 字符: {body[:300]!r}")

        after = raw_count(sec)
        print(f"\n=== 点击后 /etc/config/openclash 里 {sec} 行数: {after} ===")
        print(f"=== 变化: {before} -> {after} ===")

        await b.close()


asyncio.run(main())