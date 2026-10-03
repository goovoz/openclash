#!/usr/bin/env python3
"""实测 Overwrite Settings 的 interface_name（Bind Network Interface）能否保存。

用户反馈：2026-10-03 「Overwrite Settings 中 Bind Network Interface
不能保存 eth0」。

现象背后的已知事实（SSH 侧已确认）：
  - model 里 `interface_name` 是 `s:taboption("settings", ListValue, ...)`，
    选项来自 `ls -l /sys/class/net/`，因此 UI 上有 eth0 / lo / 0 三项
  - 但 `/etc/config/openclash` 的主 section 里**既没有 interface_name
    也没有 log_level**（model 里两者都有 o.default = "0"）

所以要验的是「UI 上选了 eth0 -> 保存 -> uci 里有没有 interface_name」。
用curl 全表单提交（见 curl-add-full.sh 的教训：最小 POST 会因其他
option 的 formvalue 为 nil 而整体 FORM_INVALID）。

用法：
    OCRT_BASE=http://127.0.0.1:9080 OCRT_PWD=password \\
        curl-iface-save.sh [value]
"""
import base64
import http.cookiejar
import os
import re
import subprocess
import sys
import urllib.parse
import urllib.request
import uuid

BASE = os.environ.get("OCRT_BASE", "http://127.0.0.1:9080").rstrip("/")
PWD = os.environ.get("OCRT_PWD", "password")
WANT = sys.argv[1] if len(sys.argv) > 1 else "eth0"
FIELD = "cbid.openclash.m.interface_name"


def sh(cmd):
    return subprocess.run(cmd, shell=True, capture_output=True,
                          text=True).stdout.strip()


def opener():
    return urllib.request.build_opener(
        urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))


def collect(page, token, override):
    """收集全部成功控件，并把 FIELD 的值改成 override。"""
    fields = [("token", token), ("cbi.submit", "1")]
    seen = {"token", "cbi.submit"}

    for m in re.finditer(r"<input\b[^>]*>", page, re.I):
        tag = m.group(0)
        nm = re.search(r'name="([^"]+)"', tag)
        if not nm:
            continue
        name = html_unescape(nm.group(1))
        typ = (re.search(r'type="([^"]+)"', tag, re.I)
               or [None, "text"])[1].lower()
        val = html_unescape(
            (re.search(r'value="([^"]*)"', tag, re.I) or [None, ""])[1])
        if typ in ("checkbox", "radio"):
            if not re.search(r"\bchecked\b", tag, re.I):
                continue
            val = val or "1"
        elif typ == "submit":
            continue                       # 不点任何按钮
        elif typ not in ("text", "password", "hidden"):
            continue
        if name == FIELD:
            val = override                # 强制改成目标值
        if name in seen:
            continue
        seen.add(name)
        fields.append((name, val))

    for m in re.finditer(
            r"<textarea\b[^>]*name=\"([^\"]+)\"[^>]*>(.*?)</textarea>",
            page, re.I | re.S):
        name = html_unescape(m.group(1))
        if name in seen:
            continue
        seen.add(name)
        fields.append((name, html_unescape(m.group(2))))
    return fields


def html_unescape(s):
    import html
    return html.unescape(s)


def multipart(fields):
    bd = "----ocrt" + uuid.uuid4().hex
    parts = [f'--{bd}\r\nContent-Disposition: form-data; name="{k}"'
             f'\r\n\r\n{v}\r\n' for k, v in fields]
    return ("".join(parts) + f"--{bd}--\r\n").encode("utf-8", "replace"), \
        f"multipart/form-data; boundary={bd}"


def main():
    op = opener()
    op.open(BASE + "/cgi-bin/luci/",
            data=urllib.parse.urlencode(
                {"luci_username": "root", "luci_password": PWD}).encode(),
            timeout=60).read()

    url = f"{BASE}/cgi-bin/luci/admin/services/openclash/config-overwrite"
    page = op.open(url, timeout=180).read().decode("utf-8", "replace")
    tm = re.search(r'name="token"[^>]*value="([0-9a-f]+)"', page)
    if not tm:
        print("!! 没拿到 token")
        return 1
    token = tm.group(1)

    # 当前页面上该字段的形态
    m = re.search(r'<select\b[^>]*name="' + re.escape(FIELD) + r'"[^>]*>(.*?)</select>',
                  page, re.I | re.S)
    if m:
        sel = re.search(r'<option\b[^>]*selected[^>]*value="([^"]*)"', m.group(1), re.I)
        sel2 = re.search(r'<option\b[^>]*value="([^"]*)"[^>]*selected', m.group(1), re.I)
        cur = (sel or sel2)
        opts = re.findall(r'value="([^"]*)"', m.group(1))
        print(f"字段: {FIELD}")
        print(f"当前选中: {cur.group(1) if cur else '(无selected)'} "
              f"-> 目标: {WANT}")
        print(f"选项: {opts[:6]}")
    else:
        print(f"!! 页面上找不到 {FIELD}（不是 select？）")

    fields = collect(page, token, WANT)
    print(f"回填控件={len(fields)} （含 {FIELD}={WANT}）")

    body, ctype = multipart(fields)
    r = op.open(urllib.request.Request(url, data=body,
                                       headers={"Content-Type": ctype}),
                timeout=180)
    out = r.read().decode("utf-8", "replace")
    print(f"响应={r.status} X-CBI-State={r.headers.get('X-CBI-State')} "
          f"字节={len(out)}")

    got = sh("uci -q get openclash.config.interface_name")
    print(f"\n>>> uci get openclash.config.interface_name = {got!r}")
    if got == WANT:
        print("判定: 保存成功 OK")
        return 0
    print("判定: 保存失败 FAIL")
    # 看看文件里有没有这一行
    print("配置文件里搜索:", sh(
        "grep -n interface_name /etc/config/openclash || echo '(none)'"))
    return 1


sys.exit(main())