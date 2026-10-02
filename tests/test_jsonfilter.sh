#!/usr/bin/env bash
# =============================================================================
# tests/test_jsonfilter.sh —— jsonfilter 垫片行为契约测试
# -----------------------------------------------------------------------------
# 目标：把 runtime/net/jsonfilter（OpenWrt jsonfilter → jq 桥接）的行为钉死。
#
# 为什么单独一套：jsonfilter 是 OpenWrt 专有工具，上游 openclash_core/update/
# watchdog 三个脚本用它解析 JSON（内核版本号、ubus 运行态）。Debian 没有，我们用
# jq 桥接。这条垫片的正确性直接决定「内核能否下载」「watchdog 能否判断内核状态」，
# 是 P5 链路的关键一环，必须钉死成可执行断言。
#
# 覆盖维度：
#   A) 纯路径提取   @.a.b.c → 标量值
#   B) .* 一层通配  @.a.instances.*.running → 遍历对象值/数组元素
#   C) 数组下标     保留 [0]
#   D) 无匹配 → 空（jq 的 null 必须被 grep -vx 过滤掉，否则上游 [ -z ] 误判）
#   E) -i 文件 与 stdin 两种输入
#   F) 变异测试：.* 若只替 * 不替 . 会产出 .instances.[]?（多一个点），锁不空转
#
# 用法：bash tests/test_jsonfilter.sh
# 环境：需 jq（Debian 有；CI 的 test job 也装）
# =============================================================================
set -u
set -o pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SHIM="$ROOT/runtime/net/jsonfilter"

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

# 前置：jq 可用
if ! command -v jq >/dev/null 2>&1; then
	printf 'SKIP jq 不可用（jsonfilter 垫片依赖 jq）\n' >&2
	SKIP=$((SKIP+1))
	printf 'PASS %d FAIL %d SKIP %d\n' "$PASS" "$FAIL" "$SKIP"
	exit 0
fi

# -----------------------------------------------------------------------------
# A/B/C/D：核心行为
# -----------------------------------------------------------------------------
# A1 纯路径（stdin）
r=$(printf '{"master":{"latest":{"core_meta":"alpha-ge183c58"}}}' | "$SHIM" -e '@.master.latest.core_meta')
chk "A1 纯路径提取标量" "$([ "$r" = "alpha-ge183c58" ] && echo 0 || echo 1)" "got=$r"

# A2 纯路径（-i 文件）
TMP=$(mktemp)
printf '{"a":{"b":{"c":"v1.0"}}}' > "$TMP"
r=$("$SHIM" -i "$TMP" -e '@.a.b.c')
chk "A2 -i 文件纯路径" "$([ "$r" = "v1.0" ] && echo 0 || echo 1)" "got=$r"
rm -f "$TMP"

# B1 .* 通配（对象值遍历，ubus service list 形态）
r=$(printf '{"openclash":{"instances":{"instance1":{"running":true}}}}' | "$SHIM" -e '@.openclash.instances.*.running')
chk "B1 .* 通配遍历对象值" "$([ "$r" = "true" ] && echo 0 || echo 1)" "got=$r"

# B2 .* 通配（数组元素）
r=$(printf '{"a":{"b":[{"x":1},{"x":2}]}}' | "$SHIM" -e '@.a.b.*.x' | tr '\n' ' ')
chk "B2 .* 通配遍历数组元素" "$([ "$r" = "1 2 " ] && echo 0 || echo 1)" "got=$r"

# C1 数组下标保留
r=$(printf '{"a":[{"x":1},{"x":2}]}' | "$SHIM" -e '@.a[1].x')
chk "C1 数组下标 [1]" "$([ "$r" = "2" ] && echo 0 || echo 1)" "got=$r"

# D1 无匹配 → 空（关键：jq 的 null 必须被过滤成空）
r=$(printf '{"a":1}' | "$SHIM" -e '@.nonexistent.path')
chk "D1 无匹配返回空" "$([ -z "$r" ] && echo 0 || echo 1)" "got=[$r]"

# D2 值为 null → 空（jsonfilter 对 null 值也返回空）
r=$(printf '{"a":null}' | "$SHIM" -e '@.a')
chk "D2 null 值返回空" "$([ -z "$r" ] && echo 0 || echo 1)" "got=[$r]"

# -----------------------------------------------------------------------------
# F：变异测试（锁不空转）
# -----------------------------------------------------------------------------
# 变异：把 .* → []? 的替换改成只替 * 不替 .（产生 .instances.[]? 多一个点）
MUT_SHIM=$(mktemp)
sed 's|e="${e//\\\.\\\*/\[\]?}"|e="${e//\*/[]?}"|' "$SHIM" > "$MUT_SHIM" 2>/dev/null
# 若 sed 没命中（正则以不同写法），用更直接的变异
if ! grep -q '\[\]?' "$MUT_SHIM" || diff -q "$MUT_SHIM" "$SHIM" >/dev/null 2>&1; then
	# sed 没改成功，换一种：直接把 .* 替换逻辑破坏掉
	sed 's/\.\\\*/XXXX/g' "$SHIM" > "$MUT_SHIM"
fi
r_bad=$(printf '{"openclash":{"instances":{"instance1":{"running":true}}}}' | bash "$MUT_SHIM" -e '@.openclash.instances.*.running' 2>/dev/null)
chk "F1 变异后 .* 通配失效" "$([ "$r_bad" != "true" ] && echo 0 || echo 1)" "mutated got=[$r_bad]"
rm -f "$MUT_SHIM"

printf 'PASS %d FAIL %d SKIP %d\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
