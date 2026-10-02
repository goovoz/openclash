"""
openclash-rt · Plugin Settings 页双机逐区块对照

Overviews 页已确认两边结构一致。用户要求对照 Plugin Settings
（settings.lua，是 OpenClash 最大的一张 CBI 表单，~63KB lua）——
它的区块多、最容易暴露「部分区块没渲染」的问题。

做法：把页面按 CBI section切开，逐块比对标题 + 控件数 + 控件类型，
并列出两边「有/无」的区块差集。

用法： python scripts/_deploy/ui-compare-settings.py
"""
import asyncio, os, sys, os, sys, json
from playwright.async_api import async_playwright

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from credentials import targets, SEL_DEBIAN, SEL_OPENWRT

OUT = r"C:/Users/HHH/WorkBuddy/Worktrees/openclash 改造任意服务器端/main-a538dd5b/.ui-shots"
PAGE = "/cgi-bin/luci/admin/services/openclash/settings"

TARGETS = targets(need_openwrt=True)

# 提取页面结构：每个 .cbi-section 的标题 + 内部控件构成
PROBE = """() => {
    const secs = Array.from(document.querySelectorAll('.cbi-section, fieldset'));
    const out = secs.map(s => {
        const h = s.querySelector('h2, h3, legend, .cbi-section-title');
        const title = h ? h.innerText.trim().replace(/\\s+/g, ' ') : '<无标题>';
        const ctrls = {
            checkbox: s.querySelectorAll('input[type=checkbox]').length,
            radio:    s.querySelectorAll('input[type=radio]').length,
            text:     s.querySelectorAll('input[type=text]').length,
            password: s.querySelectorAll('input[type=password]').length,
            select:   s.querySelectorAll('select').length,
            textarea: s.querySelectorAll('textarea').length,
            button:   s.querySelectorAll('button, input[type=submit]').length,
            label:    s.querySelectorAll('label').length,
        };
        const total = Object.values(ctrls).reduce((a, b) => a + b, 0);
        return { title, total, ctrls };
    });
    // 空 section（有容器但一个控件都没有）= 渲染失败的强信号
    const empty = secs.filter(s => {
        const c = s.querySelectorAll('input,select,textarea,button').length;
        return c === 0;
    }).map(s => {
        const h = s.querySelector('h2, h3, legend');
        return h ? h.innerText.trim() : '<无标题>';
    });
    return {
        sections: out,
        empty_sections: empty,
        text_len: document.body.innerText.length,
        // 页面里出现的所有 Label 文本（便于比对哪几项缺失）
        labels: Array.from(document.querySelectorAll('label, .cbi-value-title'))
            .map(e => e.innerText.trim().replace(/\\s+/g, ' '))
            .filter(t => t && t.length < 60),
    };
}"""

async def run_one(pg, tag, base, sels, user, pwd):
    print(f"\n{'='*64}\n[{tag}] {base}\n{'='*64}")
    api = []
    pg.on("response", lambda r: api.append((r.status, r.url.split("/")[-1].split("?")[0][:44]))
          if "/openclash/" in r.url else None)
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)[:130]))

    await pg.goto(base + "/cgi-bin/luci/", wait_until="domcontentloaded", timeout=180000)
    u, p_ = sels
    if await pg.query_selector(u) is not None:
        await pg.fill(u, user); await pg.fill(p_, pwd)
        await pg.press(p_, "Enter")
        try: await pg.wait_for_load_state("networkidle", timeout=120000)
        except Exception: pass

    await pg.goto(base + PAGE, wait_until="domcontentloaded", timeout=180000)
    try: await pg.wait_for_load_state("networkidle", timeout=120000)
    except Exception: pass
    await pg.wait_for_timeout(6000)

    print(f"  URL  : {pg.url}")
    print(f"  标题 : {await pg.title()}")
    d = await pg.evaluate(PROBE)
    print(f"  可见文本 {d['text_len']} 字节   section数 {len(d['sections'])}   "
          f"label数 {len(d['labels'])}")
    print(f"\n  {'区块标题':46} {'控件':>4}  构成")
    for s in d['sections']:
        c = s['ctrls']
        comp = " ".join(f"{k[:4]}{v}" for k, v in c.items() if v)
        print(f"    {s['title'][:46]:46} {s['total']:>4}  {comp[:44]}")
    if d['empty_sections']:
        print(f"\n  **空 section（渲染失败信号）{len(d['empty_sections'])} 个**:")
        for t in d['empty_sections'][:14]:
            print(f"      {t}")
    bad = [(s, u2) for s, u2 in api if s >= 400]
    if bad:
        print(f"\n  **失败端点 {len(bad)}** (前 12):")
        for s, u2 in bad[:12]:
            print(f"      {s} {u2}")
    if errs:
        print(f"\n  JS 错误 {len(errs)}:")
        for e in errs[:5]: print(f"      {e}")
    await pg.screenshot(path=f"{OUT}/set_{tag}.png", full_page=True)
    print(f"\n  截图: {OUT}/set_{tag}.png")
    return d

async def main():
    async with async_playwright() as pw:
        b = await pw.chromium.launch(headless=True)
        got = {}
        for tag, base, sels, u, p in TARGETS:
            ctx = await b.new_context(viewport={"width": 1600, "height": 1200})
            pg = await ctx.new_page()
            try:
                got[tag] = await run_one(pg, tag, base, sels, u, p)
            except Exception as e:
                print(f"[{tag}] 失败: {str(e)[:200]}")
            finally:
                await ctx.close()
        await b.close()

    if len(got) < 2:
        return
    db, ow = got['debian'], got['openwrt']
    print(f"\n\n{'#'*64}\n差异摘要\n{'#'*64}")
    print(f"  section 数:  OpenWrt {len(ow['sections'])}  vs  Debian {len(db['sections'])}")
    print(f"  label 数  :  OpenWrt {len(ow['labels'])}  vs  Debian {len(db['labels'])}")
    print(f"  可见文本  :  OpenWrt {ow['text_len']}  vs  Debian {db['text_len']}")
    print(f"  空section :  OpenWrt {len(ow['empty_sections'])}  vs  Debian {len(db['empty_sections'])}")

    tdb = [s['title'] for s in db['sections']]
    tow = [s['title'] for s in ow['sections']]
    print(f"\n  区块标题差集:")
    only_ow = [t for t in tow if t not in tdb]
    only_db = [t for t in tdb if t not in tow]
    print(f"    OpenWrt 有而 Debian 缺({len(only_ow)}):")
    for t in only_ow[:20]: print(f"       {t}")
    print(f"    Debian 有而 OpenWrt 缺({len(only_db)}):")
    for t in only_db[:20]: print(f"       {t}")

    ldb, low = set(db['labels']), set(ow['labels'])
    miss = [t for t in ow['labels'] if t not in ldb]
    print(f"\n  Label 差集（OpenWrt 有 / Debian 无）共 {len(miss)} 项，前 30:")
    for t in miss[:30]:
        print(f"       {t}")
    json.dump({k: {'sections': v['sections'], 'labels': v['labels'],
                   'empty': v['empty_sections']} for k, v in got.items()},
              open(f"{OUT}/settings_compare.json", "w", encoding="utf-8"),
              ensure_ascii=False, indent=2)

asyncio.run(main())
