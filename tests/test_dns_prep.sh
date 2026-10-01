#!/usr/bin/env bash
# =============================================================================
# openclash-rt  DNS 适配层测试（prepare-tmp + dnsmasq-adapter）
# -----------------------------------------------------------------------------
# 覆盖两个「上游假定存在、Debian 不提供」的关键环节：
#
#   P. prepare-tmp.sh   —— /tmp 易失路径准备
#      P1  生成 /tmp/etc/dnsmasq.conf.main，且 conf-dir 去掉尾斜杠后
#          正好等于目标目录（上游 init.d:22 的 ${VAR%*/} 语义）
#      P2  resolv.conf 镜像：保留非回环 DNS、剔除回环 DNS
#      P3  提取不到可用 DNS 时使用兜底
#      P4  crontabs / 日志文件就位
#      P5  幂等（systemd ExecStartPre 每次启动都会调用）
#
#   D. dnsmasq-adapter.sh —— UCI → /etc/dnsmasq.d
#      D1  只翻译 OpenClash 会写的那 6 个选项
#      D2  列表型 server 逐条展开
#      D3  布尔量的开/关语义（noresolv=1 → no-resolv；filter_aaaa=0 → 不输出）
#      D4  幂等 + 变更时保留 .prev
#      D5  一个选项都没有时不产出误导性的空指令
#
#   E. 端到端：prepare-tmp 调用适配器后，片段落在指定目录
#
# 依赖 tests/mock/bin/uci。
# 用法： bash tests/test_dns_prep.sh
# =============================================================================
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

# ⚠️ 不要用 ${TMPDIR}：Windows/MSYS 沙箱下它可能是 Windows 盘符路径，
# 会被安全策略判为 "embedded drive prefix" 而拒绝 rm。硬编码 /tmp 最稳。
WORK="/tmp/ocrt-dns.$$"
rm -rf "$WORK" 2>/dev/null || true
mkdir -p "$WORK"

PREP="$ROOT/runtime/net/prepare-tmp.sh"
ADAPTER="$ROOT/runtime/net/dnsmasq-adapter.sh"
MOCK_UCI="$HERE/mock/bin/uci"

PASS=0; FAIL=0
it()  { printf '\n\033[1m── %s\033[0m\n' "$1"; }
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
no()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "want=[$3] got=[$2]"; fi; }
has() { if grep -q -- "$2" "$1" 2>/dev/null; then ok "$1: $3"; else no "$1: $3" "$(tr '\n' '|' <"$1" 2>/dev/null | head -c 200)"; fi; }
hasnt() { if grep -q -- "$2" "$1" 2>/dev/null; then no "$1: $3" "意外命中 $2"; else ok "$1: $3"; fi; }

cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

# =============================================================================
it "P1  prepare-tmp：dnsmasq conf-dir 喂料"
# =============================================================================
R="$WORK/root"
mkdir -p "$R"
cat >"$WORK/resolv.conf" <<'EOF'
# 上游 DNS（模拟 systemd-resolved + 真实 DNS 混排）
nameserver 127.0.0.53
nameserver 8.8.8.8
nameserver 2001:4860:4860::8888
search lan
EOF

# 不存在的适配器，本组只验证 prepare-tmp 自身
env OPENCLASH_RT_ROOT_PREFIX="$R" \
    OPENCLASH_RT_RESOLV_SRC="$WORK/resolv.conf" \
    OPENCLASH_RT_ADAPTER="$WORK/no-such-adapter" \
    bash "$PREP" >"$WORK/p1.out" 2>&1
chk "prepare-tmp 退出码" "$?" "0"

DM="$R/tmp/etc/dnsmasq.conf.main"
if [ -f "$DM" ]; then
	ok "生成 $DM"
	RAW="$(awk -F= '/^conf-dir=/{print $2}' "$DM")"
	# 复刻上游 init.d:22 的 DNSMASQ_CONF_DIR=${VAR%*/}
	STRIPPED="${RAW%*/}"
	chk "conf-dir 原始值（与 OpenWrt dnsmasq 生成器同形态：单目录、无尾斜杠）" "$RAW" "$R/etc/dnsmasq.d"
	chk "经 \${VAR%*/} 后等于目标目录（上游语义）" "$STRIPPED" "$R/etc/dnsmasq.d"
	# 反例：若误写成 "目录/,*.conf"，%*/ 无法匹配，结果会带着通配符
	BAD="$R/etc/dnsmasq.d/,*.conf"
	chk "反例：带通配符的写法无法被 %*/ 修正（证明必须用单目录形式）" "${BAD%*/}" "$BAD"
else
	no "生成 $DM"
fi

# =============================================================================
it "P2  prepare-tmp：resolv.conf 镜像（保留非回环、剔除回环）"
# =============================================================================
R2="$R/tmp/resolv.conf.d/resolv.conf.auto"
R1="$R/tmp/resolv.conf.auto"
for f in "$R2" "$R1"; do
	if [ -s "$f" ]; then
		has  "$f" '^nameserver 8\.8\.8\.8$'           "保留 IPv4 非回环 DNS"
		has  "$f" '^nameserver 2001:4860:4860::8888$' "保留 IPv6 非回环 DNS"
		hasnt "$f" '^nameserver 127\.'                "剔除回环 DNS（否则 dnsmasq 自环）"
		hasnt "$f" '^search '                         "不搬运 search 指令"
	else
		no "$f 非空"
	fi
done

# =============================================================================
it "P3  prepare-tmp：无可用 DNS 时使用兜底"
# =============================================================================
R3="$WORK/root3"
mkdir -p "$R3"
printf 'nameserver 127.0.0.53\nnameserver ::1\n' >"$WORK/loopback-only.conf"
env OPENCLASH_RT_ROOT_PREFIX="$R3" \
    OPENCLASH_RT_RESOLV_SRC="$WORK/loopback-only.conf" \
    OPENCLASH_RT_ADAPTER="$WORK/no-such-adapter" \
    OPENCLASH_RT_FALLBACK_DNS="1.1.1.1 9.9.9.9" \
    bash "$PREP" >"$WORK/p3.out" 2>&1
F3="$R3/tmp/resolv.conf.d/resolv.conf.auto"
if [ -s "$F3" ]; then
	chk "仅回环时使用兜底 DNS" "$(tr '\n' ' ' <"$F3" | sed 's/ *$//')" \
		"nameserver 1.1.1.1 nameserver 9.9.9.9"
	has "$WORK/p3.out" '使用兜底' "日志中说明使用了兜底"
else
	no "仅回环时仍产出 resolv 文件"
fi

# =============================================================================
it "P4  prepare-tmp：crontabs / 日志文件就位"
# =============================================================================
[ -f "$R/etc/crontabs/root" ] && ok "已创建 /etc/crontabs/root（消除 tail 报错噪声）" \
	|| no "已创建 /etc/crontabs/root"
[ -f "$R/tmp/openclash.log" ] && ok "已创建 /tmp/openclash.log" || no "已创建 /tmp/openclash.log"
[ -f "$R/tmp/openclash_start.log" ] && ok "已创建 /tmp/openclash_start.log" || no "已创建 /tmp/openclash_start.log"

# =============================================================================
it "P5  prepare-tmp：幂等"
# =============================================================================
B_DM="$(cat "$DM" 2>/dev/null)"; B_R2="$(cat "$R2" 2>/dev/null)"
env OPENCLASH_RT_ROOT_PREFIX="$R" \
    OPENCLASH_RT_RESOLV_SRC="$WORK/resolv.conf" \
    OPENCLASH_RT_ADAPTER="$WORK/no-such-adapter" \
    bash "$PREP" >/dev/null 2>&1
chk "重复执行后 dnsmasq.conf 不变" "$(cat "$DM" 2>/dev/null)" "$B_DM"
chk "重复执行后 resolv.conf.auto 不变" "$(cat "$R2" 2>/dev/null)" "$B_R2"

# =============================================================================
it "D1  adapter：只翻译 OpenClash 托管的那 6 个选项"
# =============================================================================
DB="$WORK/uci.db"
DEST="$WORK/dnsmasq.d"
: >"$DB"
{
	printf '#SECTION openclash.config=openclash\n'
	printf 'openclash.config.enable=0\n'
	printf '#SECTION dhcp.main=dnsmasq\n'
	printf 'dhcp.main.domainneeded=1\n'
	printf 'dhcp.main.localuse=1\n'
	printf 'dhcp.main.cachesize=0\n'
	printf 'dhcp.main.filter_aaaa=0\n'
	printf 'dhcp.main.domain=lan\n'
} >"$DB"

run_adapter() {
	env MOCK_UCI_DB="$DB" OPENCLASH_RT_UCI="$MOCK_UCI" \
	    OPENCLASH_RT_DNSMASQ_DIR="$DEST" bash "$ADAPTER" "$@"
}

# ⚠️ 直接调用 mock uci 时必须显式带上 MOCK_UCI_DB，
#    否则改动会落到默认 DB，而适配器读的是测试 DB —— 断言会假失败。
muci() { env MOCK_UCI_DB="$DB" "$MOCK_UCI" "$@"; }

run_adapter >"$WORK/d1.out" 2>&1
chk "adapter 退出码" "$?" "0"
SNIP="$DEST/00-openclash-rt-uci.conf"
if [ -f "$SNIP" ]; then
	ok "生成 $SNIP"
	has   "$SNIP" '^local-service$' "localuse=1 → local-service"
	has   "$SNIP" '^cache-size=0$'  "cachesize=0 → cache-size=0"
	hasnt "$SNIP" 'filter-aaaa'     "filter_aaaa=0 → 不输出（dnsmasq 默认即关）"
	hasnt "$SNIP" 'domain=lan'      "未托管选项 domain 不越界翻译"
	hasnt "$SNIP" 'domain-needed'   "未托管选项 domainneeded 不越界翻译"
else
	no "生成 $SNIP" "$(tr '\n' '|' <"$WORK/d1.out" | head -c 200)"
fi

# =============================================================================
it "D2  adapter：列表型 server 逐条展开"
# =============================================================================
muci -q add_list 'dhcp.main.server=127.0.0.1#7874' 2>/dev/null
muci -q add_list 'dhcp.main.server=223.5.5.5' 2>/dev/null
muci -q set      'dhcp.main.noresolv=1' 2>/dev/null
run_adapter >/dev/null 2>&1
has "$SNIP" '^server=127\.0\.0\.1#7874$' "server 列表第 1 项（带端口，DNS 接管）"
has "$SNIP" '^server=223\.5\.5\.5$'      "server 列表第 2 项"
has "$SNIP" '^no-resolv$'                "noresolv=1 → no-resolv"

# =============================================================================
it "D3  adapter：resolvfile 与布尔量的关断"
# =============================================================================
muci -q set 'dhcp.main.resolvfile=/tmp/resolv.conf.d/resolv.conf.auto' 2>/dev/null
muci -q set 'dhcp.main.noresolv=0' 2>/dev/null
muci -q set 'dhcp.main.filter_aaaa=1' 2>/dev/null
run_adapter >/dev/null 2>&1
has   "$SNIP" '^resolv-file=/tmp/resolv\.conf\.d/resolv\.conf\.auto$' "resolvfile → resolv-file"
hasnt "$SNIP" '^no-resolv$' "noresolv=0 → 不输出 no-resolv"
has   "$SNIP" '^filter-aaaa$' "filter_aaaa=1 → filter-aaaa"

# =============================================================================
it "D4  adapter：幂等 + 变更时保留 .prev"
# =============================================================================
PREV="$SNIP.prev"
rm -f "$PREV" 2>/dev/null
S1="$(cat "$SNIP")"
run_adapter >/dev/null 2>&1
chk "内容不变时不重写（无 .prev 产生）" "$([ -f "$PREV" ] && echo yes || echo no)" "no"
chk "内容保持不变" "$(cat "$SNIP")" "$S1"

muci -q del 'dhcp.main.filter_aaaa' 2>/dev/null
run_adapter >/dev/null 2>&1
if [ -f "$PREV" ]; then ok "内容变化时生成 .prev（便于回滚排障）"; else no "内容变化时生成 .prev"; fi
hasnt "$SNIP" '^filter-aaaa$' "删除选项后片段同步移除"

# =============================================================================
it "D5  adapter：无托管选项时不输出误导性指令"
# =============================================================================
DB2="$WORK/uci2.db"; DEST2="$WORK/dnsmasq2.d"
{
	printf '#SECTION openclash.config=openclash\n'
	printf 'openclash.config.enable=0\n'
	printf '#SECTION dhcp.main=dnsmasq\n'
	printf 'dhcp.main.domainneeded=1\n'
} >"$DB2"
env MOCK_UCI_DB="$DB2" OPENCLASH_RT_UCI="$MOCK_UCI" \
    OPENCLASH_RT_DNSMASQ_DIR="$DEST2" bash "$ADAPTER" >/dev/null 2>&1
S2="$DEST2/00-openclash-rt-uci.conf"
if [ -f "$S2" ]; then
	ok "仍生成文件（保持可解释）"
	# 不能出现任何真正生效的指令
	ACTIVE="$(grep -vcE '^\s*(#|$)' "$S2")"
	chk "除注释外无任何生效指令" "$ACTIVE" "0"
else
	no "无托管选项时仍生成空片段"
fi

# =============================================================================
it "D6  adapter：uci 不可用时静默退出（不阻断启动）"
# =============================================================================
env OPENCLASH_RT_UCI="$WORK/definitely-not-a-uci" \
    OPENCLASH_RT_DNSMASQ_DIR="$WORK/dnsmasq3.d" \
    bash "$ADAPTER" >"$WORK/d6.out" 2>&1
chk "缺 uci 时退出码 0（不阻断 systemd 启动流程）" "$?" "0"

# =============================================================================
it "E1  端到端：prepare-tmp 触发适配器"
# =============================================================================
# 把真实适配器接到 prepare-tmp 的 ROOT_PREFIX 沙箱里
R4="$WORK/root4"
mkdir -p "$R4/usr/lib/openclash-rt"
cp "$ADAPTER" "$R4/usr/lib/openclash-rt/dnsmasq-adapter.sh"
DB3="$WORK/uci3.db"
{
	printf '#SECTION openclash.config=openclash\n'
	printf 'openclash.config.enable=0\n'
	printf '#SECTION dhcp.main=dnsmasq\n'
	printf 'dhcp.main.server=127.0.0.1#7874\n'
	printf 'dhcp.main.noresolv=1\n'
} >"$DB3"

env OPENCLASH_RT_ROOT_PREFIX="$R4" \
    OPENCLASH_RT_RESOLV_SRC="$WORK/resolv.conf" \
    OPENCLASH_RT_ADAPTER="$R4/usr/lib/openclash-rt/dnsmasq-adapter.sh" \
    MOCK_UCI_DB="$DB3" OPENCLASH_RT_UCI="$MOCK_UCI" \
    OPENCLASH_RT_DNSMASQ_DIR="$R4/etc/dnsmasq.d" \
    bash "$PREP" >"$WORK/e1.out" 2>&1
chk "prepare-tmp 带适配器退出码" "$?" "0"
E_SNIP="$R4/etc/dnsmasq.d/00-openclash-rt-uci.conf"
if [ -f "$E_SNIP" ]; then
	ok "prepare-tmp 已把 UCI 翻译内容落盘"
	has "$E_SNIP" '^server=127\.0\.0\.1#7874$' "端到端：DNS 接管指令就位"
else
	no "prepare-tmp 已把 UCI 翻译内容落盘" "$(tr '\n' '|' <"$WORK/e1.out" | head -c 200)"
fi

# =============================================================================
printf '\n\033[1m════════════════════════════════════════\033[0m\n'
printf '  PASS: \033[32m%d\033[0m    FAIL: \033[31m%d\033[0m\n' "$PASS" "$FAIL"
printf '\033[1m════════════════════════════════════════\033[0m\n'
[ "$FAIL" -eq 0 ] || exit 1
