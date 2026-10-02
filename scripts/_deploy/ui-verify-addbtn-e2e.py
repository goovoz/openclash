#!/usr/bin/env python3
"""Add 按钮端到端验证：真实点击 -> 段落地 -> 刷新页面能看到 -> 清理。

与 ui-verify-addbtn.py 的区别：那个脚本每轮结束就 cleanup，只看
「响应形态」；这个脚本把段留下，验证三件事：

  1. 点击后 uci 里真的多出段（不只是 302）
  2. 刷新页面后新段出现在 HTML 里（用户可见）
  3. 段有正确的 sectiontype

判据只看 (1)(2)，因为 (2) 才是用户真正感知到的「有反应」。
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

CASES = [
    ("settings", "lan_ac_traffic", "Lan Traffic Access List"),
    ("config-overwrite", "authentication", "Set Authentication"),
]


def ssh(cmd):
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username="root", password=DEBIAN_PWD, allow_agent=False,
              look_for_keys=False, timeout=15)
    si, so, se = c.exec_command(cmd, timeout=30)
    out = so.read().decode()
    c.close()
    return out


def sections(sec):
    """返回该类型下所有段名（匿名 @name[i] 与具名 name 都算）。"""
    out = ssh("uci -q show openclash")
    names = re.findall(r"^openclash\.@" + re.escape(sec) + r"\[(\d+)\]="
                       + re.escape(sec) + r"\s*$", out, re.M)
    names += re.findall(r"^openclash\.([A-Za-z_0-9]+)=" + re.escape(sec)
                        + r"\s*$", out, re.M)
    return names


def cleanup(sec):
    out = ssh("uci -q show openclash")
    ids = re.findall(r"^openclash\.@" + re.escape(sec) + r"\[(\d+)\]", out, re.M)
    if ids:
        cmds = ";".join(f"uci delete openclash.{sec}[{i}]"
                        for i in sorted(set(ids), reverse=True))
        ssh(f"{cmds}; uci commit openclash")


async def main():
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

        all_ok = True
        for slug, sec, label in CASES:
            cleanup(sec)
            before = set(sections(sec))

            await pg.goto(f"{DEBIAN_URL}/cgi-bin/luci/admin/services/openclash/{slug}",
                          wait_until="domcontentloaded", timeout=90000)
            try:
                await pg.wait_for_load_state("networkidle", timeout=30000)
            except Exception:
                pass
            await pg.wait_for_timeout(2500)

            clicked = False
            for x in await pg.query_selector_all("input.cbi-button-add"):
                if not await x.is_visible():
                    continue
                nm = await x.get_attribute("name") or ""
                if sec not in nm:
                    continue
                await x.click()
                clicked = True
                break
            if clicked:
                await pg.wait_for_timeout(5000)

            after = set(sections(sec))
            new = sorted(after - before)

            # 刷新页面，确认新段出现在 HTML 里（用户可见）
            visible = False
            if new:
                await pg.goto(f"{DEBIAN_URL}/cgi-bin/luci/admin/services/openclash/{slug}",
                              wait_until="domcontentloaded", timeout=90000)
                try:
                    await pg.wait_for_load_state("networkidle", timeout=30000)
                except Exception:
                    pass
                await pg.wait_for_timeout(2500)
                html = await pg.content()
                # 新段的 cbid 前缀（含 uci 生成的段名）应出现在 HTML 里
                for sid in new:
                    if sid in html:
                        visible = True
                        break

            ok = bool(new) and visible
            all_ok = all_ok and ok
            print(f"  {'OK  ' if ok else 'FAIL'} {label:28} "
                  f"段 {len(before)}->{len(after)}  新段={new or '无'}  "
                  f"刷新可见={'是' if visible else '否'}")
            cleanup(sec)

        print("\n" + "=" * 60)
        print(f"Add 端到端：{'全部通过' if all_ok else '存在失败'}")
        print("=" * 60)
        await b.close()
        sys.exit(0 if all_ok else 1)


asyncio.run(main())