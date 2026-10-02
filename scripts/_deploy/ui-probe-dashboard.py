"""
mihomo 内核面板（zashboard / metacubexd）功能失效诊断。

现象（用户实测，2026-10-02）：面板能点进去，但
  - 节点测速：转圈没反应
  - 自动选择里的节点切换：点击没反应
  - 设置里的按钮：点击没反应

这些功能的共同点：**都要经WebSocket 连内核 controller**
（测速走 /proxies/{name}/delay 的 WS 响应，节点切换走 PUT /proxies/{name}，
设置走 PATCH /configs）。REST GET 能通不代表 WS 也能用，
所以要分别验证。

用法：
    export OCRT_DEBIAN_URL=http://<host>:9080
    export OCRT_DEBIAN_PWD='<pwd>'
    python scripts/_deploy/ui-probe-dashboard.py
"""
import asyncio
import json
import os
import sys
import urllib.parse

sys.path.insert(0, os.path.abspath("scripts/_deploy"))
from credentials import DEBIAN_URL, DEBIAN_PWD, DEBIAN_USER, SEL_DEBIAN
from playwright.async_api import async_playwright

UIS = ["zashboard", "metacubexd"]

PROBE = """() => {
    const r = {ws: [], fetchLog: []};
    // 页面里是否已有 ws 连接对象（无法枚举，但能看 performance 资源）
    const res = performance.getEntriesByType('resource')
        .filter(e => /\\/proxies|\\/configs|\\/traffic|\\/connections|ws/i.test(e.name))
        .slice(0, 12)
        .map(e => ({name: e.name.slice(-52), dur: Math.round(e.duration),
                     size: e.transferSize}));
    r.resources = res;
    r.url = location.href.slice(-40);
    r.text = document.body.innerText.replace(/\\s+/g, ' ').slice(0, 300);
    r.hasDelayBtn = !!document.querySelector('[class*=delay], [class*=test]');
    r.buttons = Array.from(document.querySelectorAll('button, [role=button]'))
        .slice(0, 8).map(b => (b.innerText || b.getAttribute('aria-label') || '').trim().slice(0, 18))
        .filter(Boolean);
    return r;
}"""


async def main():
    async with async_playwright() as pw:
        b = await pw.chromium.launch(headless=True, args=["--disable-images"])
        ctx = await b.new_context(viewport={"width": 1500, "height": 1000})
        page = await ctx.new_page()
        page.set_default_timeout(90000)

        api_hits = []
        ws_attempts = []
        errs = []

        def on_req(r):
            u = r.url
            if any(k in u for k in ("/proxies", "/configs", "/traffic", "/connections", "/group")):
                api_hits.append((r.method, u.replace("http://172.20.0.101:9090", "")[:64]))

        def on_ws(w):
            ws_attempts.append(("WS", w.url.replace("http://172.20.0.101:9090", "")[:64]))

        def on_resp(r):
            if r.status >= 400:
                errs.append(f"{r.status} {r.url.replace('http://172.20.0.101:9090','')[:60]}")

        page.on("request", on_req)
        page.on("websocket", on_ws)
        page.on("response", on_resp)
        page.on("pageerror", lambda e: errs.append("pageerror: " + str(e)[:140]))
        page.on("console",
                lambda m: errs.append("console: " + m.text[:140]) if m.type == "error" else None)

        # 登录 LuCI
        await page.goto(DEBIAN_URL + "/cgi-bin/luci/", wait_until="domcontentloaded",
                        timeout=60000)
        await page.fill(SEL_DEBIAN[0], DEBIAN_USER)
        await page.fill(SEL_DEBIAN[1], DEBIAN_PWD)
        await page.press(SEL_DEBIAN[1], "Enter")
        try:
            await page.wait_for_load_state("networkidle", timeout=40000)
        except Exception:
            pass

        for ui in UIS:
            print(f"\n{'='*62}\n{ui}\n{'='*62}")
            api_hits.clear()
            ws_attempts.clear()
            errs.clear()
            url = f"{DEBIAN_URL}/cgi-bin/luci/admin/services/openclash/{ui}/#/proxies"
            # 先拿到带 host/port/secret 的真实跳转 URL
            await page.goto(DEBIAN_URL + "/cgi-bin/luci/admin/services/openclash/client",
                            wait_until="domcontentloaded", timeout=90000)
            await page.wait_for_timeout(3000)
            real = await page.evaluate(
                """(ui) => {
                    const b = document.getElementById('_web' + (ui==='zashboard'?'z':'m'));
                    if (b && b.onclick) { try { return b.onclick.toString().slice(0,200); } catch(e){} }
                    return null;
                }""", ui)
            # 直接构造面板 URL（带 host/port/secret）
            q = urllib.parse.urlencode({
                "hostname": "172.20.0.101", "port": "9090", "secret": "fZcNXw03"})
            real_url = f"http://172.20.0.101:9090/ui/{ui}/?{q}#/proxies"
            try:
                await page.goto(real_url, wait_until="domcontentloaded", timeout=60000)
                await page.wait_for_timeout(7000)
                r = await page.evaluate(PROBE)
                print("  最终 URL :", r["url"])
                print("  可见文本 :", r["text"][:180])
                print("  按钮     :", r["buttons"][:8])
                print("  测速按钮 :", r["hasDelayBtn"])
                print("\n  WebSocket 尝试:")
                for _, u2 in ws_attempts[:5]:
                    print("   ", u2)
                if not ws_attempts:
                    print("    **无 WS 连接** ← 这就是测速/切换/设置全失效的原因")
                print("\n  API 请求:")
                for m, u2 in api_hits[:10]:
                    print(f"    {m} {u2}")
                if errs:
                    print("\n  错误:")
                    for e in errs[:6]:
                        print("   ", e)
            except Exception as e:
                print("  失败:", str(e)[:120])
        await b.close()


asyncio.run(main())
