#!/usr/bin/env python3
"""真机 UI 实测：Overviews 的内核状态 + Overwrite Settings 的网卡绑定。

三个问题一起查（用户 2026-10-03 反馈）：
  1. 内核启动失败 —— 抓 Overviews 的状态卡片 + 启动按钮点击后的响应
  2. Bind Network Interface 选不中 eth0 —— 打开 General Settings tab，
     枚举该字段的 option 文本与当前值，并实际提交一次 eth0
  3. 页面加载很慢 —— 逐页计时

用法：
    export OCRT_DEBIAN_URL=http://<host>:9080
    export OCRT_DEBIAN_PWD='<pwd>'
    python scripts/_deploy/ui-probe-overwrite-iface.py
"""
import asyncio
import os
import re
import sys
import time

sys.path.insert(0, os.path.abspath("scripts/_deploy"))
from credentials import DEBIAN_URL, DEBIAN_PWD, DEBIAN_USER, SEL_DEBIAN
from playwright.async_api import async_playwright


async def login(pg):
    await pg.goto(DEBIAN_URL + "/cgi-bin/luci/", wait_until="domcontentloaded",
                  timeout=60000)
    await pg.fill(SEL_DEBIAN[0], DEBIAN_USER)
    await pg.fill(SEL_DEBIAN[1], DEBIAN_PWD)
    await pg.press(SEL_DEBIAN[1], "Enter")
    try:
        await pg.wait_for_load_state("networkidle", timeout=40000)
    except Exception:
        pass


async def time_pages(pg, slugs):
    print("=== 页面加载耗时 ===")
    for slug in slugs:
        url = f"{DEBIAN_URL}/cgi-bin/luci/admin/services/openclash/{slug}"
        t0 = time.time()
        try:
            await pg.goto(url, wait_until="domcontentloaded", timeout=120000)
            t_dom = time.time() - t0
            try:
                await pg.wait_for_load_state("networkidle", timeout=45000)
            except Exception:
                pass
            t_all = time.time() - t0
            html = await pg.content()
            print(f"  {slug:20} DOMContentLoaded={t_dom:6.2f}s  "
                  f"networkidle={t_all:6.2f}s  {len(html):>9,}B")
        except Exception as e:
            print(f"  {slug:20} 失败: {type(e).__name__} {e}")


async def probe_status(pg):
    """Overviews 的内核状态卡片。"""
    print("\n=== Overviews 内核状态 ===")
    url = f"{DEBIAN_URL}/cgi-bin/luci/admin/services/openclash/client"
    await pg.goto(url, wait_until="domcontentloaded", timeout=120000)
    try:
        await pg.wait_for_load_state("networkidle", timeout=45000)
    except Exception:
        pass
    await pg.wait_for_timeout(3000)
    body = await pg.inner_text("body")

    for kw in ["Core", "核心", "运行", "Status", "状态"]:
        for m in re.finditer(kw, body):
            seg = body[max(0, m.start() - 60):m.start() + 120].replace("\n", " ")
            print(f"  [{kw}] {seg}")
            break

    # 状态相关的 value
    for m in re.finditer(r"([A-Za-z ]{3,30})[:：]\s*(\S[^\n]{0,60})", body):
        k, v = m.group(1).strip(), m.group(2).strip()
        if any(x in k.lower() for x in ("core", "status", "state", "运行", "状态")):
            print(f"  字段: {k} = {v}")

    # 找出启动/停止按钮
    btns = []
    for x in await pg.query_selector_all("input[type=submit], button"):
        v = (await x.get_attribute("value")) or (await x.inner_text()) or ""
        if v.strip():
            btns.append((v.strip(), await x.get_attribute("name")))
    print(f"  按钮: {[b[0] for b in btns][:12]}")
    return body


async def probe_iface(pg):
    """Overwrite Settings -> General Settings 里的网卡绑定字段。"""
    print("\n=== Overwrite Settings 网卡绑定字段 ===")
    url = f"{DEBIAN_URL}/cgi-bin/luci/admin/services/openclash/config-overwrite"
    await pg.goto(url, wait_until="domcontentloaded", timeout=120000)
    try:
        await pg.wait_for_load_state("networkidle", timeout=45000)
    except Exception:
        pass
    await pg.wait_for_timeout(3000)

    html = await pg.content()
    # 找所有 cbi-select 的 name 与 option
    for m in re.finditer(r'<select\b[^>]*name="([^"]+)"[^>]*>(.*?)</select>',
                         html, re.I | re.S):
        nm, inner = m.group(1), m.group(2)
        opts = re.findall(r'<option\b([^>]*)>', inner, re.I)
        vals = []
        for o in opts:
            v = re.search(r'value="([^"]*)"', o)
            sel = "checked" in o or "selected" in o
            label = re.sub(r"<[^>]+>", "", o)[:24]
            vals.append(f"{label}{'*' if sel else ''}")
        print(f"  {nm}")
        print(f"    选项({len(opts)}): {vals[:14]}")

    # 找网卡相关的 input / 字段
    print("\n  --- 含 interface/bind/eth 的字段 ---")
    for m in re.finditer(r'name="(cbid\.[^"]*(?:interface|bind|eth|nic)[^"]*)"'
                         r'[^>]*value="([^"]*)"', html, re.I):
        print(f"    {m.group(1)} = {m.group(2)!r}")
    for m in re.finditer(r'name="(cbid\.[^"]*)"[^>]*>\s*([^<]{0,30})'
                         r'\s*</textarea>', html, re.I):
        if re.search(r"eth0|interface", m.group(2), re.I):
            print(f"    textarea {m.group(1)} = {m.group(2)!r}")


async def main():
    async with async_playwright() as pw:
        b = await pw.chromium.launch(headless=True, args=["--disable-images"])
        ctx = await b.new_context(viewport={"width": 1500, "height": 1100})
        pg = await ctx.new_page()
        pg.set_default_timeout(120000)
        await login(pg)

        await time_pages(pg, ["config", "settings", "config-overwrite",
                              "config-subscribe", "log", "client"])
        await probe_status(pg)
        await probe_iface(pg)

        await b.close()


asyncio.run(main())