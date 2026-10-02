#!/bin/bash
# Add 验证：模拟浏览器的**完整表单提交**（curl 版，不依赖浏览器）。
#
# 为什么要全表单：只发 token + cbi.submit + cbi.cts.* 会拿到
# X-CBI-State: -1（FORM_INVALID）—— 页��里所有 option 的 formvalue
# 都是 nil，required/带 validate 的 option 校验失败 ->
# AbstractValue.parse 把 map.save 打成 false -> Map.parse 开头提前
# return -> create 根本不执行。真实浏览器点 Add 会提交全部成功控件，
# 不会触发。这个差异曾让我误判「Add 又坏了」——实际是探针不对。
#
# HTML 规范里表单提交带所有**成功控件**：
#   text/password/hidden 值原样；checkbox/radio 只有 checked 的；
#   textarea 文本内容；submit 只有被点击的那个。
#
# 判据：响应 HTML 里出现新的 cbid.openclash.<段名>.。段名由 uci 生成
# （形如 cfgXXXXXX）。主 section 的段名在本 runtime 是 "m"，必须排除。
#
# 用法： OCRT_BASE=... OCRT_PWD=... curl-add-full.sh <slug> <sectiontype>
set -uo pipefail

SLUG="${1:-settings}"
SEC="${2:-lan_ac_traffic}"
BASE="${OCRT_BASE:-http://127.0.0.1:9080}"
PWD_="${OCRT_PWD:-password}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PG="$BASE/cgi-bin/luci/admin/services/openclash"

# 1) 登录（本机实测：直接 POST 口令即得 sysauth cookie）
curl -s -c "$TMP/jar" -o /dev/null \
     --data-urlencode "luci_username=root" \
     --data-urlencode "luci_password=$PWD_" \
     "$BASE/cgi-bin/luci/"

# 2) 取设置页 + CSRF token
curl -s -b "$TMP/jar" -o "$TMP/page.html" "$PG/$SLUG"
TOKEN=$(grep -o 'name="token"[^>]*value="[0-9a-f]*"' "$TMP/page.html" \
        | grep -o '[0-9a-f]\{32\}' | head -1)
if [ -z "$TOKEN" ]; then
    echo "!! 没拿到 token —— 登录失败？"
    exit 1
fi

# 3) 让 python 把页面控件转成 "name<TAB>value" 行
python3 "$(dirname "$0")/form-fields.py" "$TMP/page.html" "$SEC" "$TOKEN" \
        > "$TMP/fields.txt" || { echo "!! 控件解析失败"; exit 1; }
NFIELDS=$(wc -l < "$TMP/fields.txt")
if [ "$NFIELDS" -lt 2 ]; then
    echo "!! 只收集到 $NFIELDS 个字段，页面异常？"
    exit 1
fi

# 4) 提交（每个字段一个 -F）
CURL_ARGS=()
while IFS=$'\t' read -r k v; do
    CURL_ARGS+=(-F "${k}=${v}")
done < "$TMP/fields.txt"
curl -s -b "$TMP/jar" -D "$TMP/hdr.txt" -o "$TMP/resp.html" \
     "${CURL_ARGS[@]}" "$PG/$SLUG"

# 5) 报告
echo "页面字节=$(wc -c < "$TMP/page.html") 控件=$NFIELDS"
head -1 "$TMP/hdr.txt" | tr -d '\r'
grep -i "^x-cbi-state\|^location" "$TMP/hdr.txt" | tr -d '\r' | sed 's/^/  /'
echo "响应字节=$(wc -c < "$TMP/resp.html")"

python3 "$(dirname "$0")/form-fields.py" --diff \
        "$TMP/page.html" "$TMP/resp.html"