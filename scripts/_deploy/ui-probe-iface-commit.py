#!/usr/bin/env python3
"""真机实测：Overwrite Settings 改 interface_name 并点 Commit Settings。

用户反馈：2026-10-03 「Bind Network Interface 不能保存 eth0」。

已确认的事实（SSH + 双机对照）：
  - UI 上该字段**能选到 eth0**（jQuery Select widget，选项 eth0/lo/0）
  - 该页没有 Save 按钮，只有两个自定义 apply 按钮：
        Commit Settings -> m.uci:commit("openclash")
        Apply Settings  -> set enable=1 + commit + restart
  - model 里该 option 在 tab "settings" 内，路径
        cbid.openclash.config.interface_name
  - 但 `uci get openclash.config.interface_name` 为空，
    `/etc/config/openclash` 里连这一行都没有
  - 无论只提交 interface_name、只提交 log_level、只提交一个绝对合法的
    tolerance=150、还是什么都不改，X-CBI-State 全部是 -1（FORM_INVALID）
    -> 说明**整页 Map.parse 在Node.parse 之前就return 了**

所以要验的是：浏览器真实操作（选 eth0 -> 点 Commit Settings）能否落盘。
如果也不能，就证明 FORM_INVALID 是常态 bug，与字段无关。

用法：
    export OCRT_DEBIAN_URL=http://<host>:9080
    export OCRT_DEBIAN_PWD='<pwd>'
    python scripts/_deploy/ui-probe-iface-commit.py [value]
"""
import asyncio
import os
import subprocess
import sys

sys.path.insert(0, os.path.abspath("scripts/_deploy"))
from credentials import DEBIAN_URL, DEBIAN_PWD, DEBIAN_USER, SEL_DEBIAN
from playwright.async_api import async_playwright

import paramiko

HOST = os.environ.get("OCRT_DEBIAN_URL_SSH", "172.20.0.101")
WANT = sys.argv[1] if len(sys.argv) > 1 else "eth0"


def ssh(cmd):
    c = paramiko.SSHClient()
    c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
    c.connect(HOST, username="root", password=DEBIAN_PWD, allow_agent=False,
              look_for_keys=False, timeout=15)
    si, so, se = c.exec_command(cmd, timeout=30)
    out = so.read().decode()
    c.close()
    return out.strip()


async def main():
    async with async_playwright() as pw:
        b = await pw.chromium.launch(headless=True, args=["--disable-images"])
        ctx = await b.new_context(viewport={"width": 1500, "height": 1100})
        pg = await ctx.new_page()
        pg.set_default_timeout(120000)

        posts = []
        pg.on("response", lambda r: posts.append(
            (r.request.method, r.status, r.headers.get("x-cbi-state", ""),
             r.headers.get("location", "")[:70]))
            if "config-overwrite" in r.url else None)

        await pg.goto(DEBIAN_URL + "/cgi-bin/luci/", wait_until="domcontentloaded",
                      timeout=60000)
        await pg.fill(SEL_DEBIAN[0], DEBIAN_USER)
        await pg.fill(SEL_DEBIAN[1], DEBIAN_PWD)
        await pg.press(SEL_DEBIAN[1], "Enter")
        try:
            await pg.wait_for_load_state("networkidle", timeout=40000)
        except Exception:
            pass

        print(f"保存前 uci 值: {ssh('uci -q get openclash.config.interface_name')!r}")

        await pg.goto(f"{DEBIAN_URL}/cgi-bin/luci/admin/services/openclash/config-overwrite",
                      wait_until="domcontentloaded", timeout=120000)
        try:
            await pg.wait_for_load_state("networkidle", timeout=45000)
        except Exception:
            pass
        await pg.wait_for_timeout(3000)

        # 找到该字段的真实 DOM 形态
        info = await pg.evaluate("""(want) => {
            const lbl = document.querySelector('label[for="cbid.openclash.config.interface_name"]');
            const row = lbl ? lbl.closest('.cbi-value') : null;
            const sel = row ? row.querySelector('select') : null;
            const inp = row ? row.querySelector('input') : null;
            return {
              rowHtml: row ? row.outerHTML.slice(0, 900) : null,
              tag: sel ? 'select' : (inp ? 'input' : 'none'),
              curVal: sel ? sel.value : (inp ? inp.value : null),
              options: sel ? Array.from(sel.options).map(o => o.value) : [],
              widgetDiv: row ? (row.querySelector('[data-ui-widget]')||{}).outerHTML?.slice(0,300) : null,
            };
        }""", WANT)
        print(f"\n字段形态: tag={info['tag']} 当前值={info['curVal']!r}")
        print(f"选项: {info['options']}")

        # 用 Playwright 真实交互：找到 select 并选 eth0
        changed = False
        for sel_name in [f"#cbid\\.openclash\\.m\\.interface_name",
                         "select[name='cbid.openclash.config.interface_name']"]:
            try:
                el = await pg.query_selector(sel_name)
                if el:
                    await el.select_option(WANT)
                    changed = True
                    print(f"已通过 {sel_name} 选 {WANT}")
                    break
            except Exception:
                pass
        if not changed:
            # jQuery select widget：点开原生 select 设置值后触发 change
            changed = await pg.evaluate("""(want) => {
                const lbl = document.querySelector('label[for="cbid.openclash.config.interface_name"]');
                const row = lbl ? lbl.closest('.cbi-value') : null;
                const sel = row ? row.querySelector('select') : null;
                if (!sel) return false;
                sel.value = want;
                sel.dispatchEvent(new Event('change', {bubbles: true}));
                const hd = row.querySelector('[data-ui-widget]');
                if (hd) { hd.setAttribute('data-value', want); }
                return true;
            }""", WANT)
            print(f"用 JS 设置 select: {changed} -> {WANT}")

        await pg.wait_for_timeout(1500)
        now = await pg.evaluate("""() => {
            const lbl = document.querySelector('label[for="cbid.openclash.config.interface_name"]');
            const row = lbl ? lbl.closest('.cbi-value') : null;
            const sel = row ? row.querySelector('select') : null;
            const inp = row ? row.querySelector('input') : null;
            return { v: sel ? sel.value : (inp ? inp.value : null) };
        }""")
        print(f"选择后页面值: {now['v']!r}")

        # 点 Commit Settings
        posts.clear()
        clicked = False
        for x in await pg.query_selector_all("input.cbi-button-apply, button.cbi-button-apply"):
            v = (await x.get_attribute("value")) or ""
            if "Commit" in v:
                await x.click()
                clicked = True
                print(f"已点击: {v!r}")
                break
        if not clicked:
            print("!! 没找到 Commit Settings 按钮")
        await pg.wait_for_timeout(8000)

        print(f"\nPOST 响应: {posts[:3]}")
        after = ssh("uci -q get openclash.config.interface_name")
        print(f"保存后 uci 值: {after!r}")
        line = ssh("grep -n interface_name /etc/config/openclash || echo '(none)'")
        print(f"配置文件: {line}")

        if after == WANT:
            print("判定: Commit Settings 能保存 OK")
        else:
            print("判定: 保存失败 FAIL")

        await b.close()


asyncio.run(main())