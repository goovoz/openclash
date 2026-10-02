"""分析 clash 配置文件的结构完整性（判断内核能否启动）。"""
import collections
import io
import re
import sys

path = sys.argv[1] if len(sys.argv) > 1 else "/etc/openclash/config/pqjc.yaml"
s = io.open(path, encoding="utf-8", errors="replace").read()
lines = s.split("\n")

print(f"文件: {path}")
print(f"大小: {len(s)} 字符 / {len(lines)} 行")
print()

tops = [(i + 1, l.split(":")[0]) for i, l in enumerate(lines)
        if re.match(r"^[a-zA-Z-]+:", l)]
print("顶层键（行号: 键名）:")
for n, k in tops:
    print(f"   {n:5}: {k}")

need = ["proxies", "proxy-groups", "rules"]
have = {k for _, k in tops}
print()
print("clash 必需段检查:")
for k in need:
    print(f"   {k:14} {'有' if k in have else '**缺失**'}")

# 收集 rules 引用的策略名
pat = re.compile(
    r'^\s*-\s*["\']?(?:DOMAIN|DOMAIN-SUFFIX|DOMAIN-KEYWORD|IP-CIDR|IP-CIDR6|'
    r'GEOIP|IP-ASCII|GEOSITE|RULE-SET|MATCH|PROCESS-NAME|PROCESS-PATH|'
    r'DST-PORT|SRC-IP-CIPR|IN-PORT|IN-TYPE)[^,]*,\s*([^,"\']+)')
groups = collections.Counter()
for l in lines:
    m = pat.match(l)
    if m:
        groups[m.group(1).strip()] += 1

print()
print("rules 引用的策略名 TOP 12:")
for g, c in groups.most_common(12):
    print(f"   {c:5}x  {g}")
print()
print(f"共引用 {len(groups)} 个不同策略名")

# 与 proxy-groups 定义比对
defined = set()
ing = False
for l in lines:
    if re.match(r"^proxy-groups:", l):
        ing = True
        continue
    if ing and re.match(r"^[a-zA-Z-]+:", l):
        break
    if ing:
        m = re.match(r"^\s*-\s*name:\s*(.+)", l)
        if m:
            defined.add(m.group(1).strip().strip('"\''))
print(f"proxy-groups 定义了 {len(defined)} 个组")
missing = sorted(g for g in groups if g not in defined and g not in ("DIRECT", "REJECT"))
if defined or missing:
    print()
    print("rules 引用但未定义的组:")
    for g in missing[:20]:
        print(f"   {g}  ({groups[g]} 条规则)")
else:
    print()
    print("!! proxy-groups 段不存在 → 所有被 rules 引用的组都「未定义」")
    print("   示例:", ", ".join(list(groups)[:8]))
