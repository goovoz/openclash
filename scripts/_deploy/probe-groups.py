"""
诊断 mihomo 内核代理组的「切换无效」与「测速转圈」问题。

用户现象（2026-10-02 22:00，Debian 12 @ 172.20.0.101:9090，zashboard）：
  1. 「自动选择」组（截图显示 URLTest (68)）点其他节点后会**跳回第一个**
  2. 点节点上的 ⚡ 图标测速**只转圈**

这两类都是内核 API 层面的行为，先用 REST 直接验证，可区分
「内核/配置问题」与「面板前端问题」。

用法（在真机 root 下）：
    python3 probe-groups.py <secret> [host:port]
"""
import json
import sys
import urllib.error
import urllib.parse
import urllib.request

SECRET = sys.argv[1]
HOST = sys.argv[2] if len(sys.argv) > 2 else "127.0.0.1:9090"
BASE = "http://%s" % HOST


def api(path, method="GET", body=None, timeout=20):
    url = BASE + path
    data = None
    if body is not None:
        data = json.dumps(body).encode()
    req = urllib.request.Request(url, data=data, method=method)
    req.add_header("Authorization", "Bearer " + SECRET)
    req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read().decode("utf-8", "replace")
            try:
                return r.status, json.loads(raw)
            except Exception:
                return r.status, raw
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")[:200]
    except Exception as e:
        return 0, str(e)[:200]


def main():
    st, d = api("/proxies")
    if st != 200 or not isinstance(d, dict):
        print("读取 /proxies 失败: %s %s" % (st, str(d)[:120]))
        return 1
    proxies = d.get("proxies", {})

    print("=" * 66)
    print("代理组概览")
    print("=" * 66)
    groups = []
    for name, v in proxies.items():
        t = v.get("type")
        if t in ("URLTest", "Selector", "Fallback", "LoadBalance"):
            groups.append((name, t, v))
            print("  %-11s %-30s now=%-26s all=%d" %
                  (t, name[:29], str(v.get("now"))[:25],
                   len(v.get("all") or [])))
    if not groups:
        print("  （无组）")
        return 1

    # 逐个测「切换」：PUT /proxies/<组>{"name": "<另一个节点>"}
    print()
    print("=" * 66)
    print("测「切换节点」：PUT /proxies/<组> {name}")
    print("=" * 66)
    for name, t, v in groups:
        if t != "Selector":
            # URLTest / Fallback 是自动类型，本质上不接受手动锁定
            print("  %-30s 类型=%-11s 自动类型，跳过" % (name[:29], t))
            continue
        opts = [x for x in (v.get("all") or []) if x != v.get("now")]
        if not opts:
            print("  %-30s 无其他候选" % name[:29])
            continue
        target = opts[0]
        st, r = api("/proxies/" + urllib.parse.quote(name, safe=""),
                    method="PUT", body={"name": target})
        time_txt = "ok" if st == 204 or st == 200 else "失败"
        st2, v2 = api("/proxies/" + urllib.parse.quote(name, safe=""))
        now = (v2 or {}).get("now") if isinstance(v2, dict) else "?"
        ok = "成功" if now == target else "未生效"
        print("  %-30s PUT->%-20s %s  now=%-22s %s"
              % (name[:29], target[:19], time_txt, str(now)[:21], ok))

    # 测速：GET /proxies/<节点>/delay?url=...&timeout=...
    print()
    print("=" * 66)
    print("测「测速」：GET /proxies/<节点>/delay")
    print("=" * 66)
    for name, t, v in groups[:3]:
        members = [x for x in (v.get("all") or [])][:3]
        for m in members:
            q = urllib.parse.quote(name, safe="")
            p = urllib.parse.quote(m, safe="")
            st, r = api("/proxies/%s/delay?timeout=5000&url=%s"
                        % (q, urllib.parse.quote(
                            "http://www.gstatic.com/generate_204", safe="")))
            body = str(r)[:70] if not isinstance(r, dict) else \
                "delay=%s" % r.get("delay")
            print("  %-24s %s  %s  %s" % (name[:23], m[:22], st, body))
    return 0


sys.exit(main())
