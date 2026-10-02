"""
Control Panel 面板按钮（Metacubexd / Zashboard 等）点击行为诊断。

背景：用户反馈 Overviews 的 Control Panel 里这些面板按钮点了没反应，
且「本来是能点进去的」，后来变点不动。

已查明结构（真机 DOM）：
    <div class="dashboard-buttons">
      <button class="dashboard-btn hidden" id="_web"><input ... value="Yacd"
              onclick="event.preventDefault(); event.stopPropagation(); return false;"></button>
      <button class="dashboard-btn" id="_webm"><input ... value="Metacubexd"
              onclick="event.preventDefault(); event.stopPropagation(); return false;"></button>
      <button class="dashboard-btn" id="_webz"><input ... value="Zashboard" ...></button>
      <button class="dashboard-btn" id="_webo">...</button>
    </div>
按钮本身没有 action，全靠 status.htm 里的 JS 通过
ocGetDashboardBaseURL / ocBuildDashboardURL（定义在 common.js）拼接 URL。
onclick 里的 return false 只是阻止 button 元素的默认提交，
真正功能应该由 addEventListener 接管。

用法：
    export OCRT_DEBIAN_URL=http://<host>:9080
    export OCRT_DEBIAN_PWD='<pwd>'
    python scripts/_deploy/ui-probe-panel-btn.py
"""
import asyncio
import os
import sys

sys.path.insert(0, os.path.abspath("scripts/_deploy"))
from credentials import DEBIAN_URL, DEBIAN_PWD, DEBIAN_USER, SEL_DEBIAN
from playwright.async_api import async_playwright

BUTTONS = [("_web", "Yacd"), ("_webm", "Metacubexd"),
           ("_webz", "Zashboard"), ("_webo", "外部控制器")]

PROBE = """() => {
    const r = {};
    r.fnBase = typeof window.ocGetDashboardBaseURL;
    r.fnBuild = typeof window.ocBuildDashboardURL;
    r.hasDomCache = typeof window.DOMCache;
    r.buttons = [];
    const ids = ['_web','_webm','_webz','_webo'];
    for (const id of ids) {
        const b = document.getElementById(id);
        if (!b) { r.buttons.push({id: id, exists: false}); continue; }
        const inp = b.querySelector('input');
        r.buttons.push({
            id: id,
            exists: true,
            disabled: b.disabled === true,
            hidden: b.classList.contains('hidden'),
            value: inp ? inp.value : null,
            // 关键：有没有 addEventListener 绑定的痕迹无法直接查，
            // 但可以看 onclick 属性与 dataset
            onclick: (b.getAttribute('onclick') || '').slice(0, 70),
        });
    }
    return r;
}"""


async def main():
    async with async_playwright() as pw:
        b = await pw.chromium.launch(headless=True, args=["--disable-images"])
        ctx = await b.new_context(viewport={"width": 1500, "height": 1100})
        pg = await ctx.new_page()
        pg.set_default_timeout(90000)
        reqs = []
        pg.on("request", lambda r: reqs.append((r.method, r.url[:100])))
        errs = []
        pg.on("pageerror", lambda e: errs.append("pageerror: " + str(e)[:170]))
        pg.on("console",
              lambda m: errs.append("console: " + m.text[:170]) if m.type == "error" else None)

        await pg.goto(DEBIAN_URL + "/cgi-bin/luci/", wait_until="domcontentloaded",
                      timeout=60000)
        await pg.fill(SEL_DEBIAN[0], DEBIAN_USER)
        await pg.fill(SEL_DEBIAN[1], DEBIAN_PWD)
        await pg.press(SEL_DEBIAN[1], "Enter")
        try:
            await pg.wait_for_load_state("networkidle", timeout=40000)
        except Exception:
            pass
        await pg.goto(DEBIAN_URL + "/cgi-bin/luci/admin/services/openclash/client",
                      wait_until="domcontentloaded", timeout=90000)
        await pg.wait_for_timeout(7000)

        r = await pg.evaluate(PROBE)
        print("=== 依赖函数 ===")
        print(f"  ocGetDashboardBaseURL : {r['fnBase']}")
        print(f"  ocBuildDashboardURL  : {r['fnBuild']}")
        print(f"  DOMCache            : {r['hasDomCache']}")
        print("\n=== 面板按钮状态 ===")
        for x in r["buttons"]:
            if not x.get("exists"):
                print(f"  {x['id']:8} 不存在")
            else:
                print(f"  {x['id']:8} value={str(x.get('value')):14} "
                      f"disabled={x.get('disabled')} hidden={x.get('hidden')}")
                print(f"           onclick={x.get('onclick')}")

        # 逐个点击，看是否产生跳转
        print("\n=== 逐个点击 ===")
        for bid, label in BUTTONS:
            el = await pg.query_selector(f"#{bid} input")
            if not el:
                print(f"  {label:14} 按钮不存在")
                continue
            reqs.clear()
            before_pages = len(ctx.pages)
            try:
                await el.click(force=True, timeout=15000)
                await pg.wait_for_timeout(4000)
            except Exception as e:
                print(f"  {label:14} 点击异常 {str(e)[:60]}")
                continue
            posts = [u for m, u in reqs if m != "GET"][:3]
            got_new_page = len(ctx.pages) > before_pages
            print(f"  {label:14} POST={posts or '无'}  新标签页={got_new_page}")
            for extra in ctx.pages[before_pages:]:
                print(f"      新页 URL: {extra.url[:100]}")
                await extra.close()
                break
            if not posts and not got_new_page:
                print(f"      → 点击后无任何跳转/请求")

        if errs:
            print("\n=== JS 错误 ===")
            for e in errs[:8]:
                print("  ", e)
        await b.close()


asyncio.run(main())
