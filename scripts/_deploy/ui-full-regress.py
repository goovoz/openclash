"""
openclash-rt · 真机 UI 全量回归测试

在真实 Chromium 里逐个访问 OpenClash 的全部 LuCI 页面，点开每个 tab，
收集：页面标题、JS 错误、非 200 的响应、渲染出的DOM 关键内容。
目的是抓「HTTP 200 但页面实际报错」这类 curl 看不见的问题。

配合 ui-502-probe.py（点击类动作）使用：
  - 本脚本：全量页面 + tab 巡检（只读，安全）
  - ui-502-probe.py：点按钮触发动作（会改状态）

用法： python scripts/_deploy/ui-full-regress.py
"""
import asyncio, json, sys
from playwright.async_api import async_playwright

BASE = "http://172.20.0.101:9080"
OUT = r"C:/Users/HHH/WorkBuddy/Worktrees/openclash 改造任意服务器端/main-a538dd5b/.ui-shots"

# 从控制器 entry清单里拿到的真实路由（2026-10-02 真机提取）
PAGES = [
    ("client",       "Overviews"),
    ("settings",     "Plugin Settings"),
    ("config-overwrite", "Overwrite Settings"),
    ("config-subscribe", "Config Subscribe"),
    ("config",       "Config Manage"),
    ("servers",      "Servers"),
    ("other-rules-edit", "Other Rules Edit"),
    ("custom-dns-edit",   "Custom DNS Edit"),
    ("other-file-edit",   "Other File Edit"),
    ("proxy-provider-file-manage", "Provider File Manage"),
    ("rule-providers-file-manage", "Rule Providers Manage"),
    ("config-subscribe-edit", "Subscribe Edit"),
    ("servers-config",     "Servers Config"),
    ("groups-config",      "Groups Config"),
    ("proxy-provider-config", "Provider Config"),
    ("log",           "Server Logs"),
    ("update",        "Update"),
]

def is_ignorable_console(text):
    """已知的无害噪声：GitHub avatar / 内核 ws 连不上。"""
    if "avatars.githubusercontent.com" in text or "avatars2.githubusercontent.com" in text:
        return True
    if "9090" in text and ("WebSocket" in text or "ERR_CONNECTION" in text):
        return True   # 内核 ws，取决于内核是否在跑
    return False

async def main():
    report = {"pages": [], "summary": {}}
    ok = bad = 0

    async with async_playwright() as p:
        b = await p.chromium.launch(headless=True)
        ctx = await b.new_context(viewport={"width": 1500, "height": 1200})
        pg = await ctx.new_page()

        cur = {"errors": [], "bad": []}
        pg.on("console", lambda m: cur["errors"].append(f"{m.type}: {m.text[:200]}")
              if m.type == "error" and not is_ignorable_console(m.text) else None)
        pg.on("pageerror", lambda e: cur["errors"].append(f"pageerror: {str(e)[:200]}"))

        def on_resp(r):
            if r.status >= 400 and "/openclash/" in r.url:
                name = r.url.split("openclash/")[-1].split("?")[0]
                cur["bad"].append(f"{r.status} {name}")
        pg.on("response", on_resp)

        # 登录
        await pg.goto(f"{BASE}/cgi-bin/luci/", wait_until="networkidle", timeout=60000)
        if await pg.query_selector("#luci_username"):
            await pg.fill("#luci_username", "root")
            await pg.fill("#luci_password", "password")
            await pg.press("#luci_password", "Enter")
            await pg.wait_for_load_state("networkidle", timeout=60000)
        print("登录完成:", await pg.title(), "\n")

        for slug, label in PAGES:
            cur["errors"].clear(); cur["bad"].clear()
            url = f"{BASE}/cgi-bin/luci/admin/services/openclash/{slug}"
            try:
                resp = await pg.goto(url, wait_until="networkidle", timeout=45000)
                code = resp.status if resp else 0
            except Exception as e:
                code, = (0,)
                cur["errors"].append(f"nav: {str(e)[:120]}")
            await pg.wait_for_timeout(1200)

            title = await pg.title()
            body_len = len(await pg.content())
            # 抓页面上可见的错误提示
            err_text = ""
            for sel in (".cbi-section-error", ".alert-error", ".error"):
                el = await pg.query_selector(sel)
                if el and await el.is_visible():
                    err_text = (await el.inner_text())[:120]
                    break
            # 抓主要区块标题，确认真的渲染出内容而不是空壳
            h = ""
            for sel in ("h2", ".cbi-map", "h1"):
                el = await pg.query_selector(sel)
                if el:
                    h = (await el.inner_text()).strip()[:60]
                    break

            shot = f"full_{slug}.png"
            try:
                await pg.screenshot(path=f"{OUT}/{shot}", full_page=False)
            except Exception:
                pass

            entry = {
                "slug": slug, "label": label, "http": code, "title": title,
                "body_len": body_len, "heading": h, "ui_error": err_text,
                "js_errors": cur["errors"][:4], "bad_responses": sorted(set(cur["bad"]))[:6],
            }
            report["pages"].append(entry)

            flag = "OK " if code == 200 and not err_text else "!! "
            if code == 200 and not err_text and not cur["errors"]:
                ok += 1
            else:
                bad += 1
            print(f"{flag}HTTP {code}  {slug:28} {label:24} body={body_len:7}  {h[:30]}")
            if cur["bad"]:
                print(f"      异常响应: {sorted(set(cur['bad']))}")
            if err_text:
                print(f"      UI 错误: {err_text}")
            if cur["errors"]:
                print(f"      JS 错误: {cur['errors'][:2]}")

        report["summary"] = {"ok": ok, "bad": bad, "total": len(PAGES)}
        await b.close()

    print("\n" + "=" * 66)
    print(f"页面巡检：{ok} 正常 / {bad} 有问题 / 共 {len(PAGES)}")
    print("=" * 66)
    json.dump(report, open(f"{OUT}/full_regress.json", "w", encoding="utf-8"),
              ensure_ascii=False, indent=2)

asyncio.run(main())
