"""
openclash-rt · OpenClash 客户端页（Overviews）逐区块对照

用户反馈：Debian 上「Overviews 之后的界面都没完全显示」。
本脚本在两台机器上打开 client 页，把页面按区块切开对比，找出：
  - 区块是否存在（DOM 层面）
  - 区块是否为空（有容器但没内容）
  - XHR 请求哪些失败了
  - 关键文本是否缺失

用法： python scripts/_deploy/ui-compare-client.py
"""
import asyncio, os, sys, os, sys, json
from playwright.async_api import async_playwright

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from credentials import targets, SEL_DEBIAN, SEL_OPENWRT

OUT = r"C:/Users/HHH/WorkBuddy/Worktrees/openclash 改造任意服务器端/main-a538dd5b/.ui-shots"
CLIENT = "/cgi-bin/luci/admin/services/openclash/client"

TARGETS = targets(need_openwrt=True)

# client.lua 里定义的区块标题（上游 OpenClash 的Dashboard 分区）
KNOWN_BLOCKS = [
    "Access Check", "IP Address", "Running Status", "Quick Action",
    "Traffic", "Connection", "Memory", "CPU", "Version", "Update",
]

async def analyze(pg, tag):
    return await pg.evaluate("""(known) => {
        const txt = document.body.innerText;
        // 找所有可能的区块容器
        const sels = ['.cbi-section', '.cbi-map', 'fieldset', 'h2', 'h3', '.cbi-value'];
        const found = {};
        for (const s of sels) found[s] = document.querySelectorAll(s).length;

        // 逐个已知标题判断「在不在」
        const blocks = {};
        for (const b of known) blocks[b] = txt.includes(b);

        // 所有 XHR（openclash 端点）
        const xhr = [];
        // 采集表格行的可见文本
        const rows = Array.from(document.querySelectorAll('tr')).map(tr => {
            const tds = Array.from(tr.querySelectorAll('td,th'))
                .map(td => (td.innerText || '').trim().replace(/\\s+/g, ' ').slice(0, 40));
            return tds;
        });
        // 可见文本长度（判断「整页都没渲染」）
        return {
            text_len: txt.length,
            text_head: txt.slice(0, 1200),
            sels: found,
            blocks: blocks,
            rows: rows.slice(0, 40),
            row_count: rows.length,
        };
    }""", KNOWN_BLOCKS)

async def run_one(pg, tag, base, sels, user, pwd):
    print(f"\n{'='*62}\n[{tag}] {base}\n{'='*62}")
    api_hits = []
    pg.on("response", lambda r: api_hits.append((r.status, r.url.split("/")[-1][:48]))
          if "/openclash/" in r.url or "rpc" in r.url else None)
    errs = []
    pg.on("pageerror", lambda e: errs.append(str(e)[:140]))

    await pg.goto(base + "/cgi-bin/luci/", wait_until="domcontentloaded", timeout=60000)
    u, p_ = sels
    if await pg.query_selector(u) is not None:
        await pg.fill(u, user); await pg.fill(p_, pwd)
        await pg.press(p_, "Enter")
        try: await pg.wait_for_load_state("networkidle", timeout=40000)
        except Exception: pass

    await pg.goto(base + CLIENT, wait_until="domcontentloaded", timeout=60000)
    try: await pg.wait_for_load_state("networkidle", timeout=40000)
    except Exception: pass
    await pg.wait_for_timeout(3000)

    print(f"  URL   : {pg.url}")
    print(f"  标题  : {await pg.title()}")
    a = await analyze(pg, tag)
    print(f"  可见文本 {a['text_len']} 字节   表格行 {a['row_count']}")
    print(f"  DOM计数: {a['sels']}")
    print("\n  区块存在性:")
    for k, v in a['blocks'].items():
        print(f"      {'有' if v else '缺'}  {k}")
    print(f"\n  表格前 12 行:")
    for r in a['rows'][:12]:
        if any(r): print(f"      {[c for c in r if c]}")
    print(f"\n  openclash 端点响应（前 18）:")
    for st, u2 in api_hits[:18]:
        mark = "" if st == 200 else "  <<<"
        print(f"      {st} {u2}{mark}")
    bad = [(s, u2) for s, u2 in api_hits if s >= 400]
    if bad:
        print(f"  **失败端点 {len(bad)} 个**:")
        for s, u2 in bad[:12]:
            print(f"      {s} {u2}")
    if errs:
        print(f"  JS 错误 {len(errs)}:")
        for e in errs[:4]: print(f"      {e}")
    print(f"\n  可见文本前 700 字:\n{'-'*58}")
    print(a['text_head'][:700])
    await pg.screenshot(path=f"{OUT}/cmp2_{tag}_client.png", full_page=True)
    return a

async def main():
    async with async_playwright() as pw:
        b = await pw.chromium.launch(headless=True)
        out = {}
        for tag, base, sels, u, p in TARGETS:
            ctx = await b.new_context(viewport={"width": 1600, "height": 1400})
            pg = await ctx.new_page()
            try:
                out[tag] = await run_one(pg, tag, base, sels, u, p)
            except Exception as e:
                print(f"[{tag}] 失败: {str(e)[:200]}")
            finally:
                await ctx.close()
        await b.close()

    # 差异摘要
    if len(out) == 2:
        print(f"\n\n{'#'*62}\n差异摘要（OpenWrt 有 / Debian 无）\n{'#'*62}")
        ob = out['openwrt']['blocks']; db = out['debian']['blocks']
        only_ow = [k for k in ob if ob[k] and not db.get(k)]
        only_db = [k for k in db if db[k] and not ob.get(k)]
        print(f"  OpenWrt 有而 Debian 缺: {only_ow or '（无）'}")
        print(f"  Debian 有而 OpenWrt 缺: {only_db or '（无）'}")
        print(f"  OpenWrt 可见文本 {out['openwrt']['text_len']} vs Debian {out['debian']['text_len']}")
        print(f"  OpenWrt 表格行 {out['openwrt']['row_count']} vs Debian {out['debian']['row_count']}")

asyncio.run(main())
