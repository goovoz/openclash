#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
分析上游 OpenClash 前端的「兼容面」—— 即路线 B 的 Lua 运行时必须实现哪些函数。

为什么需要它：
  路线 B 的前提是「上游视图一行不改」。要做到这一点，我们必须精确知道上游
  到底调用了 luci/nixio 的哪些函数，一个不多一个不少。
  上游每日同步后重跑本脚本，若出现新的模块/函数，即为**兼容面扩张告警**：
  必须先在运行时里补上实现，再合入上游代码，否则页面会在运行期 500。

统计口径（两类都要抓，缺一不可）：
  1) 直接调用：`luci.dispatcher.build_url(...)`、`require("luci.sys").call(...)`
  2) 别名调用：`local fs = require "nixio.fs"` 之后的 `fs.readfile(...)`
     上游大量使用这种写法，只统计第 1 类会严重漏算。

用法：
  python3 scripts/analyze-frontend-api.py [luasrc 目录]
  python3 scripts/analyze-frontend-api.py --json    # 输出 JSON，便于 CI 比对
"""

import json
import os
import re
import sys
from collections import Counter, defaultdict

# ---------------------------------------------------------------------------
# 模板语法统计：.htm 文件是 LuCI 模板，需要模板引擎支持这些标记
# ---------------------------------------------------------------------------
TPL_MARKS = {
    "<%+": "include 子模板（把另一个模板渲染进来）",
    "<%=": "输出表达式结果（自动 XML 转义）",
    "<%-": "输出表达式结果（不转义，用于注入 HTML/JS）",
    "<%:": "输出 i18n 翻译后的字符串（等价 translate(...)）",
    "<%#": "注释，不输出",
    "<% ": "Lua 语句块",
    "<%":  "Lua 语句块（紧凑写法）",
}

# `local NAME = require "MOD"` / `local NAME = require("MOD")` / `local NAME, X = require "MOD"`
RE_LOCAL_REQUIRE = re.compile(
    r"""local\s+([A-Za-z_][\w,\s]*?)\s*=\s*require\s*\(?\s*["']([^"']+)["']"""
)
# 直接 `require "MOD"`（含 require("MOD").func）
RE_REQUIRE = re.compile(r"""require\s*\(?\s*["']([^"']+)["']""")


def iter_files(root):
    for dirpath, _dirnames, filenames in os.walk(root):
        for fn in filenames:
            if fn.endswith(".htm") or fn.endswith(".lua"):
                yield os.path.join(dirpath, fn)


def analyse(root):
    alias_of = {}                                  # 别名 -> 模块名
    direct_calls = Counter()                       # 模块.函数 -> 次数（直接调用）
    alias_calls = Counter()                        # 模块.函数 -> 次数（别名调用）
    modules_required = Counter()                   # 模块 -> require 次数
    files_of_module = defaultdict(set)             # 模块 -> 使用它的文件集合
    tpl_marks = Counter()
    calls_endpoints = []                           # controller 里注册的 call() 端点

    for path in iter_files(root):
        rel = os.path.relpath(path, root).replace(os.sep, "/")
        try:
            text = open(path, "r", encoding="utf-8", errors="replace").read()
        except OSError:
            continue

        # --- 1) 收集 require 与其别名 -------------------------------------
        for names, mod in RE_LOCAL_REQUIRE.findall(text):
            for nm in (n.strip() for n in names.split(",")):
                if nm and nm != "_":
                    alias_of[nm] = mod
                    modules_required[mod] += 1
                    files_of_module[mod].add(rel)
        for mod in RE_REQUIRE.findall(text):
            modules_required[mod] += 1
            files_of_module[mod].add(rel)

        # --- 2) 直接调用：luci.x.y / nixio.x.y ----------------------------
        for m in re.finditer(r"\b((?:luci|nixio)\.[a-z_0-9]+(?:\.[a-z_0-9]+)+)", text):
            direct_calls[m.group(1)] += 1

        # --- 3) 别名调用：ALIAS.method -----------------------------------
        for alias, mod in alias_of.items():
            for m in re.finditer(r"\b%s\.([a-z_0-9]+)" % re.escape(alias), text):
                alias_calls["%s.%s" % (mod, m.group(1))] += 1

        # --- 4) 模板语法 --------------------------------------------------
        if path.endswith(".htm"):
            for mark in TPL_MARKS:
                tpl_marks[mark] += text.count(mark)

        # --- 5) controller 的 call() 端点 --------------------------------
        if rel == "controller/openclash.lua":
            for m in re.finditer(r"""entry\s*\(\s*\{?["']([^"']+)["']""", text):
                calls_endpoints.append(m.group(1))

    return {
        "alias_of": alias_of,
        "direct_calls": direct_calls,
        "alias_calls": alias_calls,
        "modules_required": modules_required,
        "files_of_module": files_of_module,
        "tpl_marks": tpl_marks,
        "calls_endpoints": calls_endpoints,
    }


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    as_json = "--json" in sys.argv

    here = os.path.dirname(os.path.abspath(__file__))
    root = args[0] if args else os.path.join(
        here, "..", "upstream", "luci-app-openclash", "luasrc"
    )
    if not os.path.isdir(root):
        sys.stderr.write("找不到前端目录: %s\n" % root)
        return 2

    r = analyse(root)

    # 合并直接调用与别名调用
    total = Counter(r["direct_calls"])
    for k, v in r["alias_calls"].items():
        total[k] += v

    # 只保留 luci./nixio. 前缀的，并按模块聚合
    by_module = defaultdict(Counter)
    for sym, cnt in total.items():
        parts = sym.split(".")
        if parts[0] not in ("luci", "nixio"):
            continue
        mod = ".".join(parts[:-1])
        by_module[mod][parts[-1]] += cnt

    if as_json:
        out = {
            "modules": {m: dict(sorted(c.items())) for m, c in sorted(by_module.items())},
            "require_counts": dict(r["modules_required"].most_common()),
            "template_marks": dict(r["tpl_marks"].most_common()),
            "call_endpoints": r["calls_endpoints"],
        }
        print(json.dumps(out, ensure_ascii=False, indent=2))
        return 0

    print("=" * 78)
    print("上游前端兼容面分析  root=%s" % os.path.abspath(root))
    print("=" * 78)

    print("\n## 1. 必须实现的模块与函数（按调用次数排序）\n")
    print("  %-34s %s" % ("模块.函数", "次数"))
    print("  " + "-" * 52)
    rows = sorted(
        ((m + "." + f, c) for m, fs in by_module.items() for f, c in fs.items()),
        key=lambda x: (-x[1], x[0]),
    )
    for sym, cnt in rows:
        print("  %-34s %d" % (sym, cnt))
    print("  " + "-" * 52)
    print("  合计 %d 个函数符号，%d 次调用，分布在 %d 个模块"
          % (len(rows), sum(c for _, c in rows), len(by_module)))

    print("\n## 2. require 的模块清单\n")
    for mod, cnt in r["modules_required"].most_common():
        print("  %-28s require %-4d 文件 %d" % (mod, cnt, len(r["files_of_module"][mod])))

    print("\n## 3. 模板语法使用统计（.htm）\n")
    for mark, cnt in r["tpl_marks"].most_common():
        if cnt:
            print("  %-6s %-6d %s" % (mark, cnt, TPL_MARKS[mark]))

    print("\n## 4. controller 中注册的 call() 端点（%d 个）\n" % len(r["calls_endpoints"]))
    for ep in r["calls_endpoints"]:
        print("  %s" % ep)

    print("\n## 5. 别名映射（local X = require \"Y\"）\n")
    for alias, mod in sorted(r["alias_of"].items()):
        print("  %-16s -> %s" % (alias, mod))

    return 0


if __name__ == "__main__":
    sys.exit(main())
