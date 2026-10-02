#!/usr/bin/env python3
"""表单字段提取 / 新增段对比（配合 curl-add-full.sh 使用）。

拆成独立 .py 是为了避开 shell 里嵌 python heredoc 的引号地狱
—— 上一版把 python 代码写在bash heredoc 里，注释中的 $(...) 被
shell 展开，把登录那一步搞坏了（全部 403）。

两种模式：

  提取： form-fields.py <page.html> <sectiontype> <token>
         输出 "name<TAB>value" 行，供 curl -F 回填

  对比： form-fields.py --diff <before.html> <after.html>
         输出新增段名
"""
import html
import re
import sys

# 主 section 的段名。本 runtime 的 luci-uci 用 section 名 "m"
# （见 settings 页HTML 里 cbid.openclash.m.*），旧版本是 "openclash"，
# 两个都排除，避免主 section 的一百多个 option 造成假阳性。
MAIN = {"m", "openclash"}


def sections(text):
    return {n for n in re.findall(r"cbid\.openclash\.([A-Za-z_0-9]+)\.", text)
            if n not in MAIN}


def collect(page, sec, token):
    """收集页面里所有成功控件，返回 [(name, value)]。"""
    fields = [("token", token), ("cbi.submit", "1")]
    seen = {"token", "cbi.submit"}

    for m in re.finditer(r"<input\b[^>]*>", page, re.I):
        tag = m.group(0)
        nm = re.search(r'name="([^"]+)"', tag)
        if not nm:
            continue
        name = html.unescape(nm.group(1))
        typ = (re.search(r'type="([^"]+)"', tag, re.I)
               or [None, "text"])[1].lower()
        val = html.unescape(
            (re.search(r'value="([^"]*)"', tag, re.I) or [None, ""])[1])

        if typ in ("checkbox", "radio"):
            if not re.search(r"\bchecked\b", tag, re.I):
                continue
            val = val or "1"
        elif typ == "submit":
            # 只保留本section 的 Add 按钮（其余 submit 浏览器不会带）
            if f"cbi.cts.openclash.{sec}." not in name:
                continue
            val = val or "Add"
        elif typ not in ("text", "password", "hidden"):
            continue

        if name in seen:
            continue
        seen.add(name)
        fields.append((name, val))

    for m in re.finditer(
            r"<textarea\b[^>]*name=\"([^\"]+)\"[^>]*>(.*?)</textarea>",
            page, re.I | re.S):
        name = html.unescape(m.group(1))
        if name in seen:
            continue
        seen.add(name)
        fields.append((name, html.unescape(m.group(2))))

    return fields


def main():
    if len(sys.argv) >= 2 and sys.argv[1] == "--diff":
        before = open(sys.argv[2], encoding="utf-8",
                      errors="replace").read()
        after = open(sys.argv[3], encoding="utf-8", errors="replace").read()
        b, a = sections(before), sections(after)
        new = sorted(a - b)
        print(f"点击前段数={len(b)} 点击后段数={len(a)}")
        print(f"新增段={new or '(无)'}")
        print("判定: " + ("Add 生效 OK" if new else "无新段（若 302 则为跳转编辑页）"))
        return 0 if new else 1

    page = open(sys.argv[1], encoding="utf-8", errors="replace").read()
    fields = collect(page, sys.argv[2], sys.argv[3])
    for k, v in fields:
        # curl -F 里换行会破坏参数，用单空格压平
        v = v.replace("\r", " ").replace("\n", " ")
        print(f"{k}\t{v}")
    return 0


sys.exit(main())