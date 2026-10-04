#!/usr/bin/env python3
"""把 wiki.metacubex.one 的页面 HTML 抽成纯文本。

wiki 是静态生成的（MkDocs Material），正文在 <article> 里；直接
WebFetch 拿不到（工具对 SPA 返回空），所以自己剥标签。

用法： html2text.py <page.html> [max_chars]
"""
import html as H
import re
import sys


def extract(path, max_chars=6000):
    with open(path, encoding="utf-8", errors="replace") as f:
        s = f.read()
    m = re.search(r"<article[^>]*>(.*?)</article>", s, re.S)
    body = m.group(1) if m else s
    body = re.sub(r"<script.*?</script>", "", body, flags=re.S)
    body = re.sub(r"<style.*?</style>", "", body, flags=re.S)
    # 代码块保留缩进
    body = re.sub(r"<br\s*/?>", "\n", body)
    body = re.sub(r"</(p|div|li|tr|h\d|pre|td|th)>", "\n", body)
    txt = H.unescape(re.sub(r"<[^>]+>", "", body))
    txt = re.sub(r"[ \t]+\n", "\n", txt)
    txt = re.sub(r"\n{3,}", "\n\n", txt).strip()
    return txt[:max_chars]


if __name__ == "__main__":
    path = sys.argv[1]
    limit = int(sys.argv[2]) if len(sys.argv) > 2 else 6000
    print(extract(path, limit))