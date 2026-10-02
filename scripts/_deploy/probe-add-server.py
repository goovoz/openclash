#!/usr/bin/env python3
"""服务端直连验证：手工构造标准 multipart POST，看 Add 是否真能建段。

意义：把「浏览器/宿主传参」与「cbi.lua 服务端逻辑」彻底分开。
浏览器实测已经证明 POST body 里**确实**带
    name="cbi.cts.openclash.<sectiontype>."  value="Add"
（且 token 正确），但 /etc/config/openclash 里段数不变。
本脚本绕开 UI，用同一页面拿到的 token 手工发一次最小 POST：
只带 token + cbi.submit + 那一个 cts 字段。

若本脚本能建段 -> 服务端 OK，问题在宿主传参；
若不能 -> 服务端 parse/create 链路有缺陷。

用 Playwright 的 context.request 发请求：它自动复用浏览器 cookie，
不用自己处理登录与 session。

用法：
    export OCRT_DEBIAN_URL=http://<host>:9080
    export OCRT_DEBIAN_PWD='<pwd>'
    python scripts/_deploy/probe-add-server.py [slug] [sectiontype]
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


def sec_count(sec):
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username="root", password=DEBIAN_PWD, allow_agent=False,
              look_for_keys=False, timeout=15)
    si, so, se = c.exec_command("cat /etc/config/openclash", timeout=30)
    out = so.read().decode()
    c.close()
    return len([ln for ln in out.splitlines() if ln.strip().endswith("=" + sec)])


def cleanup(sec):
    import paramiko
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username="root", password=DEBIAN_PWD, allow_agent=False,
              look_for_keys=False, timeout=15)
    ids = re.findall(r"^openclash\.@" + re.escape(sec) + r"\[(\d+)\]",
                     c.exec_command("uci -q show openclash", timeout=30)[1]
                     .read().decode(), re.M)
    if ids:
        cmds = ";".join(f"uci delete openclash.{sec}[{i}]"
                        for i in sorted(set(ids), reverse=True))
        c.exec_command(cmds + "; uci commit openclash", timeout=30)
    c.close()


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

        url = f"{DEBIAN_URL}/cgi-bin/luci/admin/services/openclash/{slug}"
        await pg.goto(url, wait_until="domcontentloaded", timeout=90000)
        try:
            await pg.wait_for_load_state("networkidle", timeout=30000)
        except Exception:
            pass
        await pg.wait_for_timeout(2000)

        token = await pg.eval_on_selector(
            "input[name=token]", "el => el.value")
        print(f"token = {token!r}")

        cleanup(sec)
        before = sec_count(sec)
        print(f"提交前 {sec} 行数 = {before}")

        # 手工 multipart：只带 token / submit / cts 三个字段
        r = await ctx.request.post(url, multipart={
            "token": token,
            "cbi.submit": "1",
            f"cbi.cts.openclash.{sec}.": "Add",
        }, max_redirects=0, timeout=120000)
        print(f"响应: status={r.status} "
              f"Location={r.headers.get('location')} "
              f"X-CBI-State={r.headers.get('x-cbi-state')}")

        after = sec_count(sec)
        print(f"提交后 {sec} 行数 = {after}   变化 {before} -> {after}")
        print("结论: " + ("段已落地 ✅" if after > before
                          else "段未落地 ❌（服务端 create 链路问题）"))
        cleanup(sec)
        await b.close()


asyncio.run(main())