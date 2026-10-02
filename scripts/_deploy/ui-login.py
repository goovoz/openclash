import asyncio, sys
from playwright.async_api import async_playwright

BASE = "http://172.20.0.101:9080"
OUT = r"C:/Users/HHH/WorkBuddy/Worktrees/openclash 改造任意服务器端/main-a538dd5b/.ui-shots"

async def main():
    async with async_playwright() as p:
        b = await p.chromium.launch(headless=True)
        ctx = await b.new_context(viewport={"width": 1500, "height": 1000})
        pg = await ctx.new_page()
        # 收集所有请求/响应与控制台错误
        log = []
        pg.on("console", lambda m: log.append(f"[console.{m.type}] {m.text}"))
        pg.on("pageerror", lambda e: log.append(f"[pageerror] {e}"))
        pg.on("response", lambda r: log.append(f"[resp] {r.status} {r.url}"))

        await pg.goto(f"{BASE}/cgi-bin/luci/", wait_until="networkidle", timeout=60000)
        print("URL after load:", pg.url)
        print("TITLE:", await pg.title())
        await pg.screenshot(path=f"{OUT}/01_login.png", full_page=True)

        # 登录表单
        if await pg.query_selector("#luci_username") is not None:
            await pg.fill("#luci_username", "root")
            await pg.fill("#luci_password", "password")
            await pg.screenshot(path=f"{OUT}/02_filled.png", full_page=True)
            # 点击登录按钮
            btn = await pg.query_selector("input[type=submit], button[type=submit]")
            if btn:
                await btn.click()
            else:
                await pg.press("#luci_password", "Enter")
            await pg.wait_for_load_state("networkidle", timeout=60000)
            print("URL after login:", pg.url)
            print("TITLE after login:", await pg.title())
            await pg.screenshot(path=f"{OUT}/03_after_login.png", full_page=True)
        else:
            print("!! 未找到登录表单")

        print("\n--- 事件日志（最后 30 条）---")
        for l in log[-30:]:
            print(l)
        await b.close()

asyncio.run(main())
