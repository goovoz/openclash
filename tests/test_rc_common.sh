#!/usr/bin/env bash
# =============================================================================
# tests/test_rc_common.sh —— rc.common shell 兼容垫片测试
# -----------------------------------------------------------------------------
# 目标：钉死 rc.common 的两处 shell 兼容处理，它们都是「看起来对、实际半废」型：
#
#   1. re-exec 到 bash：上游 init 脚本 shebang 是 #!/bin/sh /etc/rc.common，
#      内核用 /bin/sh（Debian=dash）执行 rc.common。但 OpenWrt 的 functions.sh
#      用 bash 方言（${var:0:-1}），dash 不支持 → rc.common 检测到非 bash 就
#      exec bash 重执行。
#   2. set +B（关闭 brace expansion）：bash 会把 nft 命令里的 `{tcp,udp}`
#      brace expand 成 `tcp udp`，nft 报 "unexpected th"。busybox ash 不 brace
#      expand、字面传给 nft 才对。set +B 让 bash 与 ash 行为对齐。
#
# 这两个锁的失效方式：
#   - re-exec 被删 → 上游脚本在 dash 下跑 → ${var:0:-1} 报 bad substitution
#   - set +B 被删 → nft 命令 {tcp,udp} 被展开 → DNS 重定向规则写不进
#     （P5 实测：openclash_dns_redirect chain 空，DNS 劫持失效）
#
# 覆盖维度：
#   A) 静态：rc.common 含 re-exec 逻辑（exec 到 bash）
#   B) 静态：rc.common 含 set +B 修复
#   C) 行为：通过 rc.common 执行一个 echo {tcp,udp} 的 init 脚本，验证输出
#      {tcp,udp} 保持字面（不被展开成 tcp udp）
#   D) 行为：re-exec 生效（init 脚本里 ${var:0:-1} 在 bash 下能跑）
#   E) 变异：去掉 set +B → {tcp,udp} 被展开（锁不空转）
#
# 用法：bash tests/test_rc_common.sh
# 环境：需 bash + dash（Debian 都有）；测试用临时 IPKG_INSTROOT 沙箱
# =============================================================================
set -u
set -o pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
RC_COMMON="$ROOT/runtime/procd/rc.common"

PASS=0
FAIL=0
SKIP=0

chk() {
	local name="$1" cond="$2" extra="${3:-}"
	if [ "$cond" = "0" ]; then
		PASS=$((PASS+1))
	else
		FAIL=$((FAIL+1))
		printf 'FAIL %s%s\n' "$name" "${extra:+ ($extra)}" >&2
	fi
}

# 前置：bash 可用
if ! command -v bash >/dev/null 2>&1; then
	printf 'SKIP bash 不可用\n' >&2
	SKIP=$((SKIP+1))
	printf 'PASS %d FAIL %d SKIP %d\n' "$PASS" "$FAIL" "$SKIP"
	exit 0
fi

# 沙箱：临时 IPKG_INSTROOT，放最小 functions.sh
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/lib/functions"
# 最小 functions.sh（rc.common 会 source 它；只需能 source 即可）
: > "$WORK/lib/functions.sh"
: > "$WORK/lib/functions/service.sh"
# 最小 init 脚本：echo 一个含 brace 的字符串 + 一个 bash 方言
# 注意：不设 USE_PROCD（否则 rc.common 会 source procd.sh 并走 procd 路径）
# 关键：BRACE 那行必须**不带引号**，否则 bash 的 brace expansion 不会发生
# （双引号内不 brace expand），测不出 set +B 的效果。
INIT="$WORK/init-test"
cat > "$INIT" <<'EOF'
#!/bin/sh /etc/rc.common
START=99
start() {
	echo BRACE:{tcp,udp}
	x="abcdef"
	echo "DIALECT:${x:0:2}"
	return 0
}
EOF
chmod +x "$INIT"

# -----------------------------------------------------------------------------
# A/B：静态锁
# -----------------------------------------------------------------------------
chk "A1 rc.common 含 re-exec（exec bash）" \
	"$(grep -q 'exec "\$_oc_rt_sh"' "$RC_COMMON" && echo 0 || echo 1)"

chk "B1 rc.common 含 set +B" \
	"$(grep -q 'set +B' "$RC_COMMON" && echo 0 || echo 1)"

chk "B2 set +B 有 case 保护（只在 bash 下生效）" \
	"$(grep -q 'case "\$-"' "$RC_COMMON" && echo 0 || echo 1)"

# -----------------------------------------------------------------------------
# C/D：行为锁（通过 dash 执行 rc.common，验证 re-exec + set+B）
# -----------------------------------------------------------------------------
# 用 dash 显式执行 rc.common（模拟内核 /bin/sh 的行为），init 脚本的 start()
# 会 echo BRACE:{tcp,udp}，验证输出里 brace 保持字面。
OUT=$(IPKG_INSTROOT="$WORK" dash "$RC_COMMON" "$INIT" start 2>&1)
RC=$?

chk "C1 rc.common 能正常执行 start" "$([ "$RC" = "0" ] && echo 0 || echo 1)" "rc=$RC out=$OUT"

# C2: {tcp,udp} 保持字面（不被 bash brace expand 成 tcp udp）
chk "C2 brace 保持字面 {tcp,udp}" \
	"$(printf '%s' "$OUT" | grep -q 'BRACE:{tcp,udp}' && echo 0 || echo 1)" "out=$OUT"

chk "C3 brace 未被展开成 tcp udp" \
	"$(printf '%s' "$OUT" | grep -q 'BRACE:tcp udp' && echo 1 || echo 0)" "out=$OUT"

# D1: bash 方言 ${x:0:2} 能跑（re-exec 到 bash 生效，dash 会报 bad substitution）
chk "D1 bash 方言可用（re-exec 生效）" \
	"$(printf '%s' "$OUT" | grep -q 'DIALECT:' && echo 0 || echo 1)" "out=$OUT"

# -----------------------------------------------------------------------------
# E：变异测试（锁不空转）
# -----------------------------------------------------------------------------
# 变异：去掉 set +B，验证 {tcp,udp} 被展开（证明锁有效）
MUT="$WORK/rc-common-mut"
sed 's/case "\$-" in\n\t\*B\*) set +B ;;\nesac//; s/set +B/set -B/' "$RC_COMMON" > "$MUT" 2>/dev/null
# 更稳的变异：直接把 set +B 行删掉
grep -v 'set +B' "$RC_COMMON" > "$MUT"
chmod +x "$MUT"

OUT_MUT=$(IPKG_INSTROOT="$WORK" dash "$MUT" "$INIT" start 2>&1)
# bash brace expansion 会把 BRACE:{tcp,udp} 展开成 "BRACE:tcp BRACE:udp"（两个词）
chk "E1 变异后 brace 被展开（锁不空转）" \
	"$(printf '%s' "$OUT_MUT" | grep -q 'BRACE:tcp.*BRACE:udp' && echo 0 || echo 1)" "mut_out=$OUT_MUT"

printf 'PASS %d FAIL %d SKIP %d\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
