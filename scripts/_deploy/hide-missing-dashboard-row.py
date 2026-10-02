"""在 switch_dashboard.htm 里，面板目录不存在时隐藏整行。

背景（2026-10-02 真机实测，Debian 12 @ 172.20.0.101:9080）：

Overviews 的 Control Panel 按钮由 openclash.lua:1373
    metacubexd = fs.isdirectory("/usr/share/openclash/ui/metacubexd")
控制 —— 目录改名后按钮**自动隐藏**（实测：_webm Metacubexd 已隐藏）。

但 Plugin Settings → Dashboard Settings 里的
「Metacubexd Version」/「Yacd Version」等**整行仍然显示**，
只是按钮变灰。原因是 view/openclash/switch_dashboard.htm 的
既有逻辑只做：
    if (!status[name.toLowerCase()]) {
        defaultEl.firstElementChild.disabled = true;
        deleteEl.firstElementChild.disabled  = true;
    }
—— 只禁用按钮，不隐藏行。

本脚本在模板里追加一段：目录不存在时把该行（.cbi-value）整体隐藏。
不改上游 settings.lua，不改 openclash.lua，只改这一个自定义模板。

用法：
    python3 hide-missing-dashboard-row.py <模板路径> [--dry]
"""
import io
import re
import sys

MARK = "/* [openclash-rt] 面板目录不存在时隐藏整行 */"


def patch(path, dry=False):
    with io.open(path, encoding="utf-8", errors="replace") as f:
        s = f.read()

    if MARK in s:
        return "already"

    anchor = """        if (!status[name.toLowerCase()]) {
            defaultEl.firstElementChild.disabled = true;
            deleteEl.firstElementChild.disabled  = true;
        }"""
    if anchor not in s:
        return "anchor-missing"

    add = anchor + """

        // [openclash-rt] 面板目录不存在时隐藏整行
        // 上游只禁用按钮，但外层 .cbi-value 行仍显示（表现为
        // 「Metacubexd Version」这一行还在，只是 Delete 变灰）。
        // 用户要求「不显示」，故这里连行一起隐藏。
        // 判据复用 status[name.toLowerCase()] —— 它来自
        // openclash.lua 的 fs.isdirectory("/usr/share/openclash/ui/<name>")。
        if (!status[name.toLowerCase()]) {
            var row = switchEl.closest('.cbi-value');
            if (row) { row.style.display = 'none'; }
        }"""

    s = s.replace(anchor, add, 1)
    if not dry:
        with io.open(path, "w", encoding="utf-8", newline="") as f:
            f.write(s)
    return "patched"


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    dry = "--dry" in sys.argv
    if not args:
        print(__doc__)
        return 1
    p = args[0]
    r = patch(p, dry=dry)
    print("结果: %s" % r)
    if r == "patched" and not dry:
        with io.open(p, encoding="utf-8", errors="replace") as f:
            s = f.read()
        m = re.search(r"/\* \[openclash-rt\][^*]*\*/", s, re.S)
        if m:
            print("已插入标记:\n%s" % m.group(0)[:300])
    return 0


sys.exit(main())
