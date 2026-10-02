"""给 metacubexd 面板写入后端地址（修「面板能打开但功能全失效」）。

问题：metacubexd 的后端地址被**内联硬编码**在 index.html / 200.html 的
Nuxt 配置里（`defaultBackendURL:""`），以及 config.js 的 onerror 兜底里。
两者都是空值 → 面板回退到浏览器同源 → API 请求打到
`/ui/metacubexd/configs` → 404 → 面板停在「连接到你的 Mihomo 后端」。

zashboard 没有这个问题（它没有 config.js，直接用 URL 参数）。

用法（在真机上跑）：
    python3 fix-metacubexd-backend.py <ui目录> <后端URL>
    例: python3 fix-metacubexd-backend.py \
          /usr/share/openclash/ui/metacubexd http://172.20.0.101:9090
"""
import io
import os
import sys


def patch(path, backend, dry=False):
    with io.open(path, encoding="utf-8", errors="replace") as f:
        s = f.read()
    orig = s
    # Nuxt 内联配置（双引号）
    s = s.replace('defaultBackendURL:""', 'defaultBackendURL:"%s"' % backend)
    # config.js / onerror 兜底（单引号）
    s = s.replace("defaultBackendURL:''", "defaultBackendURL:'%s'" % backend)
    s = s.replace("defaultBackendURL: ''", "defaultBackendURL: '%s'" % backend)
    if s == orig:
        return False
    if not dry:
        with io.open(path, "w", encoding="utf-8", newline="") as f:
            f.write(s)
    return True


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 1
    ui_dir, backend = sys.argv[1], sys.argv[2].rstrip("/")
    print("面板目录: %s" % ui_dir)
    print("后端地址: %s" % backend)

    targets = ["index.html", "200.html", "404.html", "config.js"]
    for fn in targets:
        p = os.path.join(ui_dir, fn)
        if not os.path.exists(p):
            print("  %-12s 跳过（不存在）" % fn)
            continue
        bak = p + ".bak"
        if not os.path.exists(bak):
            os.rename(p, bak)
        changed = patch(p, backend)
        print("  %-12s %s" % (fn, "已修改" if changed else "无需修改"))

    # 校验
    print("\n校验:")
    for fn in targets:
        p = os.path.join(ui_dir, fn)
        if not os.path.exists(p):
            continue
        with io.open(p, encoding="utf-8", errors="replace") as f:
            s = f.read()
        import re
        for m in re.findall(r"defaultBackendURL[^,;}]{0,50}", s)[:2]:
            print("  %-12s %s" % (fn, m.strip()))
    return 0


sys.exit(main())
