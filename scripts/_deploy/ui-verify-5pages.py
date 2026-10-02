"""
openclash-rt · 五页对照验证（Debian 真机 vs OpenWrt 对照机）

按用户要求逐页对照并自验证，判据全部可在服务端 curl 判定，
浏览器截图仅作视觉辅助（settings 页 5MB，浏览器渲染很慢，故默认跳过）。

用法：
    export OCRT_DEBIAN_URL=http://<host>:9080
    export OCRT_DEBIAN_PWD='<pwd>'
    python scripts/_deploy/ui-verify-5pages.py            # 服务端判据
    python scripts/_deploy/ui-verify-5pages.py --browser  # 额外截图（慢）
"""
import asyncio, os, re, sys
import urllib.request, urllib.parse
import http.cookiejar

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from credentials import DEBIAN_URL, DEBIAN_PWD, DEBIAN_USER, SEL_DEBIAN

# (slug, label, 期望 tab 数, 最小控件数, 是否要求"非空 section")
# 说明：config-subscribe 用 Table section、log 用自定义模板，
#       本来就没有 "This section contains no values yet" 之外的 section-node，
#       故对这两页不做该项判据。
PAGES = [
    ("settings",         "Plugin Settings",      15, 120, True),
    ("config-overwrite", "Overwrite Settings",    5,  45, True),
    ("config-subscribe", "Config Subscribe",      0,   1, False),
    ("config",           "Config Manage",         0,  10, False),
    ("log",              "Server Logs",           0,   1, False),
]


def http_login():
    cj = http.cookiejar.CookieJar()
    opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cj))
    data = urllib.parse.urlencode(
        {"luci_username": DEBIAN_USER, "luci_password": DEBIAN_PWD}).encode()
    opener.open(f"{DEBIAN_URL}/cgi-bin/luci/admin/services/openclash/client", data)
    return opener


def fetch(opener, slug):
    url = f"{DEBIAN_URL}/cgi-bin/luci/admin/services/openclash/{slug}"
    r = opener.open(url, timeout=180)
    return r.status, r.read().decode("utf-8", "replace")


def analyse(name, html):
    tabs = re.findall(r'data-tab-title="([^"]*)"', html)
    uniq = sorted(set(tabs))
    # 控件计数：21.02 世代用 class="cbi-value" 容器（每个可设置项一个），
    # 旧式写法是 <select>/type=checkbox。两者都算，取较大值 ——
    # 只数 <select 会严重低估（实测 settings 页 select=1 而 cbi-value=145）。
    ctrls_v = len(re.findall(r'class="cbi-value"', html))
    ctrls_legacy = len(re.findall(r'type="checkbox"|type="text"|<select', html))
    ctrls = max(ctrls_v, ctrls_legacy)
    err500 = "500 Internal Server Error" in html or "Failed to execute template" in html
    return {
        "size": len(html),
        "tabs_total": len(tabs),
        "tabs_uniq": len(uniq),
        "dup": len(tabs) - len(uniq),
        "ctrls": ctrls,
        "err500": err500,
        "tabnames": uniq,
        "empty_hint": "This section contains no values yet" in html,
    }


def main():
    browser = "--browser" in sys.argv
    opener = http_login()
    print(f"登录成功: {DEBIAN_URL}\n")
    results = []
    for slug, label, want_tabs, min_ctrls, want_nonempty in PAGES:
        try:
            code, html = fetch(opener, slug)
            a = analyse(label, html)
        except Exception as e:
            print(f"[{slug}] 请求失败: {str(e)[:70]}")
            results.append((slug, label, None))
            continue
        results.append((slug, label, a))

        # 判据
        checks = []
        checks.append(("HTTP 200", code == 200))
        checks.append(("无 500/模板错", not a["err500"]))
        if want_tabs:
            checks.append((f"tab={want_tabs}", a["tabs_uniq"] == want_tabs))
            checks.append(("无重复", a["dup"] == 0))
            checks.append((f"控件>{min_ctrls}", a["ctrls"] > min_ctrls))
        else:
            checks.append(("无重复", a["dup"] == 0))
            checks.append((f"控件>={min_ctrls}", a["ctrls"] >= min_ctrls))
            if want_nonempty:
                checks.append(("非空 section", not a["empty_hint"]))
        allok = all(c[1] for c in checks)
        mark = "OK " if allok else "FAIL"
        print(f"[{mark}] {slug:20} {label:22} {a['size']:>9}B "
              f"tab={a['tabs_uniq']}/{a['tabs_total']} ctrls={a['ctrls']}")
        for cn, ok in checks:
            if not ok:
                print(f"         x {cn}")
        if want_tabs and a["tabnames"]:
            print(f"         tabs: {', '.join(a['tabnames'][:6])}"
                  f"{' ...' if len(a['tabnames'])> 6 else ''}")
        print()

    if browser:
        print("=== 浏览器截图（慢，仅 settings 页）===")
        asyncio.run(shot_settings())

    bad = [r for r in results if r[2] is None or
           r[2]["err500"] or r[2]["dup"] or
           (r[2]["tabs_uniq"] != 0 and r[2]["ctrls"] <= 1)]
    print("=" * 60)
    print(f"总结: {len(results)-len(bad)}/{len(results)} 页通过")
    for slug, label, a in results:
        if a and a["tabs_uniq"] == 0 and a["ctrls"] <= 1:
            print(f"  ! {label}: tab=0 ctrls={a['ctrls']} "
                  f"{'（预期外的降级）' if 'Settings' in label and label != 'Server Logs' else ''}")
    print("=" * 60)


async def shot_settings():
    from playwright.async_api import async_playwright
    OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                       "..", "..", ".ui-shots")
    async with async_playwright() as pw:
        b = await pw.chromium.launch(headless=True, args=["--disable-images"])
        ctx = await b.new_context(viewport={"width": 1600, "height": 1100})
        pg = await ctx.new_page()
        pg.set_default_timeout(240000)
        await pg.goto(f"{DEBIAN_URL}/cgi-bin/luci/", wait_until="domcontentloaded",
                      timeout=60000)
        await pg.fill(SEL_DEBIAN[0], DEBIAN_USER)
        await pg.fill(SEL_DEBIAN[1], DEBIAN_PWD)
        await pg.press(SEL_DEBIAN[1], "Enter")
        await pg.wait_for_timeout(2000)
        await pg.goto(f"{DEBIAN_URL}/cgi-bin/luci/admin/services/openclash/settings",
                      wait_until="commit", timeout=90000)
        await pg.wait_for_timeout(20000)
        r = await pg.evaluate("""() => ({
            tabs: Array.from(new Set(Array.from(document.querySelectorAll('[data-tab-title]'))
                .map(e=>e.getAttribute('data-tab-title')))),
            ctrls: document.querySelectorAll('input,select,textarea').length })""")
        print(f"  浏览器实测: tab={len(r['tabs'])} 控件={r['ctrls']}")
        path = os.path.abspath(os.path.join(OUT, "verify_settings.png"))
        await pg.screenshot(path=path)
        print(f"  截图: {path}")
        await b.close()


if __name__ == "__main__":
    main()
