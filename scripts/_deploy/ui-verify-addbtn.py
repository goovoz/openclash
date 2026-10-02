"""
Add 按钮真机验证（浏览器真实点击）

## 两个判据陷阱（都曾导致误判「Add 无效」）

1. **段数统计正则**：匿名段在 `uci show` 里有两种形态：
     openclash.@dns_servers[0]=dns_servers     （匿名，带索引）
     openclash.config=openclash                （具名，无索引）
   只 grep `=dns_servers$` 会漏掉前者。

2. **成功形态有两种**：
   - 段数增加（无 create 覆盖的 section，如 lan_ac_traffic）
   - **302 跳转到编辑页**（有 create 覆盖的 section，如 dns_servers
     的 `ds.create` 里 `HTTP.redirect(ds.extedit % sid)`）——
     此时段名是 uci 生成的随机串（形如 cfg296193），且**不会**出现在
     提交后的 `uci show` 里（已被后续流程消费），只看段数会误判失败。

## 前置依赖
- 必须走**浏览器真实点击**（表单是 multipart，且带 CSRF token；
  用 curl 模拟会因缺 token 得到 403 "Form token mismatch"）
- section 声明见 docs/09-tab渲染缺陷.md

用法：
    export OCRT_DEBIAN_URL=http://<host>:9080
    export OCRT_DEBIAN_PWD='<pwd>'
    python scripts/_deploy/ui-verify-addbtn.py
"""
import asyncio
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.abspath("scripts/_deploy"))
from credentials import DEBIAN_URL, DEBIAN_PWD, DEBIAN_USER, SEL_DEBIAN
from playwright.async_api import async_playwright

SSH = ["ssh", "-o", "BatchMode=yes", "root@172.20.0.101"]

# (slug, section, 中文标签)
CASES = [
    ("settings",         "lan_ac_traffic",   "Lan Traffic Access List"),
    ("config-overwrite", "dns_servers",      "Add Custom DNS Servers"),
    ("config-overwrite", "authentication",   "Set Authentication"),
    ("config-subscribe", "config_subscribe", "Config Subscribe Edit"),
]


def _uci():
    return subprocess.run(SSH + ["uci", "-q", "show", "openclash"],
                          capture_output=True, text=True, timeout=30).stdout


def section_names(name):
    """返回该 section 类型下所有段名（匿名 @name[i] 与具名 name 都算）。"""
    out = _uci()
    names = re.findall(r"^openclash\.@" + re.escape(name) + r"\[(\d+)\]=" + re.escape(name)
                       + r"\s*$", out, re.M)
    names += re.findall(r"^openclash\.([A-Za-z_0-9]+)=" + re.escape(name) + r"\s*$", out, re.M)
    return names


def cleanup(name):
    out = _uci()
    ids = re.findall(r"^openclash\.@" + re.escape(name) + r"\[(\d+)\]", out, re.M)
    if ids:
        cmds = ";".join(f"uci delete openclash.{name}[{i}]"
                         for i in sorted(set(ids), reverse=True))
        subprocess.run(SSH + ["sh", "-c", cmds + "; uci commit openclash"],
                       capture_output=True, timeout=30)


async def main():
    async with async_playwright() as pw:
        b = await pw.chromium.launch(headless=True, args=["--disable-images"])
        ctx = await b.new_context(viewport={"width": 1500, "height": 1100})
        pg = await ctx.new_page()
        pg.set_default_timeout(120000)
        posts = []

        def on_resp(r):
            if r.request.method == "POST" and "openclash" in r.url:
                posts.append((r.status, r.headers.get("location", "")))

        pg.on("response", on_resp)
        await pg.goto(DEBIAN_URL + "/cgi-bin/luci/", wait_until="domcontentloaded",
                      timeout=60000)
        await pg.fill(SEL_DEBIAN[0], DEBIAN_USER)
        await pg.fill(SEL_DEBIAN[1], DEBIAN_PWD)
        await pg.press(SEL_DEBIAN[1], "Enter")
        try: await pg.wait_for_load_state("networkidle", timeout=40000)
        except Exception: pass

        results = []
        for slug, sec, label in CASES:
            before = set(section_names(sec))
            await pg.goto(f"{DEBIAN_URL}/cgi-bin/luci/admin/services/openclash/{slug}",
                          wait_until="domcontentloaded", timeout=90000)
            try: await pg.wait_for_load_state("networkidle", timeout=30000)
            except Exception: pass
            await pg.wait_for_timeout(3000)

            posts.clear()
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
            after = set(section_names(sec))
            new_names = after - before

            # 成功形态：段增加 或 302 跳编辑页
            redir = [loc for st, loc in posts if st == 302 and loc]
            ok = bool(new_names) or bool(redir)
            results.append((label, ok))

            detail = []
            if new_names:
                detail.append(f"新段={sorted(new_names)}")
            if redir:
                detail.append(f"302->{redir[0].split('/')[-1]}")
            if not ok:
                detail.append(f"POST={posts[:2]}")
            print(f"  {'OK  ' if ok else 'FAIL'} {label:30} "
                  f"段 {len(before)}->{len(after)}  {'  '.join(detail)}")
            cleanup(sec)

        n = sum(1 for _, ok in results if ok)
        print("\n" + "=" * 60)
        print(f"Add 按钮：{n}/{len(results)} 生效")
        print("=" * 60)
        await b.close()


asyncio.run(main())
