"""
openclash-rt · Deb 与 OpenWrt 两台机器的 Overviews 页面对照截图

用途：用户反馈「Debian 上 Overviews 之后的界面都没完全显示」，
需要与 OpenWrt 原生环境逐项对照，找出缺失的部分。

用法： python scripts/_deploy/ui-compare-overviews.py
"""
import asyncio
from playwright.async_api import async_playwright

OUT = r"C:/Users/HHH/WorkBuddy/Worktrees/openclash 改造任意服务器端/main-a538dd5b/.ui-shots"

TARGETS = [
    # (标签, base, login_path, user, password)
    ("debian", "http://172.20.0.101:9080",
     "/cgi-bin/luci/", "root", "password"),
    ("openwrt", "http://172.20.0.2",
     "/cgi-bin/luci/", "root", "DAM%ms7f"),
]

async def shot(pg, tag, name, full=True):
    path = f"{OUT}/cmp_{tag}_{name}.png"
    try:
        await pg.screenshot(path=path, full_page=full)
        return path
    except Exception as e:
        print(f"    截图失败 {name}: {str(e)[:80]}")
        return None

async def login_and_probe(pg, tag, base, login_path, user, pwd):
    print(f"\n{'='*60}")
    print(f"[{tag}] {base}")
    print('='*60)
    await pg.goto(base + login_path, wait_until="domcontentloaded", timeout=60000)

    # OpenWrt 的 LuCI 登录框是 luci_username/luci_password；Debian 侧同构
    # 两边LuCI 世代不同，登录框 id 不一致：
    #   Debian 侧（我们自建宿主，openwrt-21.02 世代）→ #luci_username
    #   OpenWrt 侧（ImmortalWrt 24.10 + ArgonTheme）→ #cbi-input-user
    for user_sel, pwd_sel in (("#luci_username", "#luci_password"),
                              ("#cbi-input-user", "#cbi-input-password"),
                              ("input[name=luci_username]", "input[name=luci_password]")):
        if await pg.query_selector(user_sel) is not None:
            await pg.fill(user_sel, user)
            await pg.fill(pwd_sel, pwd)
            await pg.press(pwd_sel, "Enter")
            break
        try:
            await pg.wait_for_load_state("networkidle", timeout=45000)
        except Exception:
            pass
    print(f"  登录后 URL: {pg.url}")
    print(f"  标题      : {await pg.title()}")
    await shot(pg, tag, "01_after_login")

    # 统计页面结构
    stats = await pg.evaluate("""() => {
        const q = s => document.querySelectorAll(s).length;
        return {
            body_len: document.body.innerHTML.length,
            tables: q('table'),
            trs: q('tr'),
            tds: q('td'),
            ths: q('th'),
            cbi_value: q('.cbi-value'),
            cbi_section: q('.cbi-section'),
            h2: Array.from(document.querySelectorAll('h2')).map(e=>e.innerText.trim()),
            h3: Array.from(document.querySelectorAll('h3')).map(e=>e.innerText.trim()),
            imgs: Array.from(document.querySelectorAll('img')).map(
                e => ({src: (e.getAttribute('src')||'').slice(-40), w: e.naturalWidth})),
            links: Array.from(document.querySelectorAll('a')).length,
            // 空 td（可能没渲染出来的数据格）
            empty_td: Array.from(document.querySelectorAll('td')).filter(
                e => !e.innerText.trim() && !e.querySelector('img,input,select')).length,
        };
    }""")
    print(f"  body {stats['body_len']} 表格{stats['tables']}行{stats['trs']} "
          f"单元格{stats['tds']} 空单元格{stats['empty_td']} 链接{stats['links']}")
    print(f"  h2: {stats['h2']}")
    print(f"  h3: {stats['h3'][:14]}")
    broken = [i for i in stats['imgs'] if i['w'] == 0]
    print(f"  图片 {len(stats['imgs'])} 张，其中加载失败 {len(broken)} 张")
    for b in broken[:8]:
        print(f"      失败: {b['src']}")
    return stats

async def main():
    async with async_playwright() as p:
        b = await p.chromium.launch(headless=True)
        for tag, base, lp, u, pw in TARGETS:
            ctx = await b.new_context(viewport={"width": 1600, "height": 1200})
            pg = await ctx.new_page()
            errs = []
            pg.on("console", lambda m: errs.append(m.text[:120]) if m.type == "error" else None)
            pg.on("pageerror", lambda e: errs.append(f"pageerror: {str(e)[:120]}"))
            try:
                await login_and_probe(pg, tag, base, lp, u, pw)
                if errs:
                    print(f"  控制台错误 {len(errs)} 条:")
                    for e in errs[:6]:
                        print(f"      {e}")
            except Exception as e:
                print(f"[{tag}] 失败: {str(e)[:200]}")
            finally:
                await ctx.close()
        await b.close()

asyncio.run(main())
