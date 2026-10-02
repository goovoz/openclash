"""
openclash-rt · 10 个 502 端点的真机UI 点击验证

背景：curl裸扫发现 10 个端点返回 502，但 curl 无法判断「这是设计语义
（操作被成功发起，只是无 body 可返回）还是真失败」。
本脚本用 Playwright 驱动真实 Chromium，点真机UI 上对应的按钮/菜单，
观察三件事：
  1. UI 是否给出成功/失败的可见反馈（toast /按钮态/ 面板数据变化）
  2. 对应动作在真机侧是否真的产生了副作用（脚本同时用 SSH 侧采样佐证）
  3. 502 出现在「点击前」还是「点击后」——这是区分
     「无 POST 参数的裸调」与「真实操作失败」的关键

用法： python scripts/_deploy/ui-502-probe.py
"""
import asyncio, sys, json
from playwright.async_api import async_playwright

BASE = "http://172.20.0.101:9080"
OUT = r"C:/Users/HHH/WorkBuddy/Worktrees/openclash 改造任意服务器端/main-a538dd5b/.ui-shots"

# 502 端点 → 在 UI 上的语义说明（用于报告）
ENDPOINTS = {
    "close_all_connection": "Quick Action 里的 Close Connect",
    "core_download":       "更新内核（会真下载 12MB，耗时）",
    "del_log":             "删除运行日志",
    "del_start_log":       "删除启动日志",
    "one_key_update":      "一键更新",
    "reload_firewall":     "Reload Firewall",
    "remove_all_core":     "删除全部内核",
    "restore":             "恢复配置",
    "toolbar_show":        "工具栏显示切换",
    "all_proxies_stream_test": "流媒体解锁测试",
}

async def snap(pg, tag, note=""):
    await pg.screenshot(path=f"{OUT}/{tag}.png", full_page=True)
    if note:
        print(f"    [shot] {tag}.png  {note}")

async def probe(pg, name, click_fn, wait_ms=2500):
    """在页面上执行一次点击，收集该动作引发的一切网络活动。"""
    seen = []
    def on_resp(r):
        if f"/openclash/{name}" in r.url or name in r.url:
            seen.append((r.status, r.url.split("openclash/")[-1][:60]))
    pg.on("response", on_resp)
    toasts = []
    def on_console(m):
        if m.type in ("error", "warning"):
            t = m.text
            if "9090" in t or "WebSocket" in t:
                return  # 内核 ws 连不上是已知噪声，单独处理
            toasts.append(f"{m.type}: {t[:110]}")
    pg.on("console", on_console)
    try:
        await click_fn()
    except Exception as e:
        pg.remove_listener("response", on_resp)
        pg.remove_listener("console", on_console)
        return {"endpoint": name, "status": "CLICK_FAILED", "err": str(e)[:120]}
    await pg.wait_for_timeout(wait_ms)
    # 检查页面上是否有 LuCI 的 toast 反馈
    toast_txt = ""
    for sel in (".alert-message", ".cbi-modal", ".toast-message", "div[class*=toast]"):
        try:
            el = await pg.query_selector(sel)
            if el and (await el.is_visible()):
                toast_txt = (await el.inner_text())[:160]
                break
        except Exception:
            pass
    pg.remove_listener("response", on_resp)
    pg.remove_listener("console", on_console)
    return {
        "endpoint": name,
        "responses": seen,
        "toast": toast_txt,
        "console": toasts[:4],
    }

async def main():
    results = []
    async with async_playwright() as p:
        b = await p.chromium.launch(headless=True)
        ctx = await b.new_context(viewport={"width": 1500, "height": 1100})
        pg = await ctx.new_page()
        ws_err = []
        pg.on("console", lambda m: ws_err.append(m.text) if "9090" in m.text else None)

        # 登录
        await pg.goto(f"{BASE}/cgi-bin/luci/", wait_until="networkidle", timeout=60000)
        if await pg.query_selector("#luci_username"):
            await pg.fill("#luci_username", "root")
            await pg.fill("#luci_password", "password")
            await pg.press("#luci_password", "Enter")
            await pg.wait_for_load_state("networkidle", timeout=60000)
        print("登录后:", pg.url, "|", await pg.title())
        await snap(pg, "10_ready", "点击前的基线状态")

        # ---- 1. Quick Action 的 Close Connect（close_all_connection）----
        print("\n[1] close_all_connection  (UI: Quick Action / Close Connect)")
        async def click_close():
            el = await pg.query_selector("text=Close Connect")
            if el:
                await el.click()
            else:
                raise RuntimeError("找不到 Close Connect 按钮")
        r = await probe(pg, "close_all_connection", click_close)
        results.append(r); await snap(pg, "11_close_conn", "点击后")

        # ---- 2. Reload Firewall ----
        print("[2] reload_firewall  (UI: Running Status 区的⟳ 按钮组)")
        # 页面顶部工具条有一排图标按钮，逐一探测title
        btns = await pg.query_selector_all("button, .cbi-button, input[type=button]")
        found = False
        for i, bt in enumerate(btns):
            t = (await bt.get_attribute("title") or "") + " " + (await bt.inner_text() or "")
            if "firewall" in t.lower() or "reload" in t.lower():
                print(f"    命中按钮 #{i}: title={t.strip()[:60]!r}")
        r = await probe(pg, "reload_firewall", lambda: click_by_title(pg, ["firewall", "reload firewall", "重载防火墙"]))
        results.append(r); await snap(pg, "12_reload_fw", "点击后")

        # ---- 3. Flush / clean logs（del_log / del_start_log）----
        print("[3] del_log + del_start_log  (UI: Server Logs 页的删除按钮)")
        await pg.goto(f"{BASE}/cgi-bin/luci/admin/services/openclash/log", wait_until="networkidle", timeout=60000)
        await snap(pg, "13_logpage", "Server Logs 页")
        r1 = await probe(pg, "del_start_log", lambda: click_by_title(pg, ["del", "delete", "删除", "清空", "clean"]), wait_ms=3000)
        results.append(r1); await snap(pg, "14_del_log", "删除日志后")

        # ---- 4. 内核相关页（core_download / remove_all_core / one_key_update）----
        print("[4] core_download / remove_all_core / one_key_update  (UI: Plugin Settings 或 Server Logs 的内核区)")
        await pg.goto(f"{BASE}/cgi-bin/luci/admin/services/openclash/client", wait_until="networkidle", timeout=60000)
        # 只探测，不真点（会触发 12MB 下载 / 删内核，破坏环境）
        btns = await pg.query_selector_all("button, .cbi-button")
        titles = []
        for bt in btns[:40]:
            t = ((await bt.get_attribute("title") or "") + "|" + (await bt.inner_text() or "")).strip()
            if t and t != "|":
                titles.append(t)
        print(f"    client 页按钮 {len(titles)} 个:", "; ".join(titles[:14]))
        await snap(pg, "15_client_buttons", "client 页按钮清单")

        # ---- 5. restore / toolbar_show / stream test ----
        print("[5] restore / toolbar_show / all_proxies_stream_test")
        r5 = await probe(pg, "toolbar_show", lambda: click_by_title(pg, ["toolbar", "工具栏"]), wait_ms=2000)
        results.append(r5)
        r6 = await probe(pg, "all_proxies_stream_test", lambda: click_by_title(pg, ["stream", "解锁", "流媒体"]), wait_ms=2000)
        results.append(r6)
        await snap(pg, "16_misc", "其他动作后")

        # ---- 汇总 ----
        print("\n" + "=" * 70)
        print("结果汇总")
        print("=" * 70)
        for r in results:
            if r.get("status") == "CLICK_FAILED":
                print(f"[{r['endpoint']:24}] 点击失败: {r['err']}")
                continue
            codes = [c for c, _ in r["responses"]]
            print(f"[{r['endpoint']:24}] 响应={codes or '（页面未发出该请求）'}  toast={r['toast']!r}")
            for c in r["console"]:
                print(f"{'':26} console {c}")
        print("\n9090 WebSocket 报错次数:", len(ws_err))
        json.dump(results, open(f"{OUT}/502_results.json", "w", encoding="utf-8"), ensure_ascii=False, indent=2)
        await b.close()

async def click_by_title(pg, keywords):
    """按 title/文本关键字点第一个命中的按钮；找不到就抛错。"""
    btns = await pg.query_selector_all("button, .cbi-button, .cbi-button-remove, input[type=button], input[type=submit], a.btn")
    for bt in btns:
        t = ((await bt.get_attribute("title") or "") + " " +
             (await bt.get_attribute("value") or "") + " " +
             (await bt.inner_text() or "")).lower()
        if any(k.lower() in t for k in keywords):
            await bt.click()
            return
    raise RuntimeError(f"页面上找不到含 {keywords} 的按钮（共 {len(btns)} 个按钮）")

asyncio.run(main())
