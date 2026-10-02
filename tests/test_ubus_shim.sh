#!/usr/bin/env bash
# =============================================================================
# tests/test_ubus_shim.sh —— ubus 命令垫片行为契约测试
# -----------------------------------------------------------------------------
# 目标：把 runtime/net/ubus（拦截 `call service list`）的行为钉死。
#
# 为什么单独一套：OpenClash 的 watchdog / 订阅更新用
#   ubus call service list '{"name":"openclash"}'
# 检查内核/任务是否运行。但 service 对象由真 procd 注册、本项目用 systemd 替代，
# 真 ubus 返回 "Command failed: Not found" → watchdog 误判内核没运行 →
# enable=0 + stop 杀掉刚启动的内核。垫片用进程存在性回答 running，其余透传。
#
# 覆盖维度：
#   A) 拦截 call service list：name=openclash 时按 pidof clash 回答 running
#   B) 拦截 name=openclash_update：按 pidof openclash_update.sh 回答
#   C) 透传：非 call service list 的调用 exec 到真 ubus（用 --help 验证不拦截）
#   D) JSON 形态：返回 {"name":{"instances":{"instance1":{"running":true}}}}
#      jsonfilter 能提取 @.name.instances.*.running
#   E) 变异测试：拦截判断若错（不识别 service list），透传路径被破坏
#
# 用法：bash tests/test_ubus_shim.sh
# 环境：无需真 ubusd；测试用 mock 真 ubus（OPENCLASH_RT_UBUS_REAL 指向 mock）
# =============================================================================
set -u
set -o pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SHIM="$ROOT/runtime/net/ubus"

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

# mock 真 ubus：记录被透传的调用
MOCK_UBUS=$(mktemp)
cat > "$MOCK_UBUS" <<'EOF'
#!/bin/sh
echo "REAL_UBUS_CALLED: $*"
exit 0
EOF
chmod +x "$MOCK_UBUS"

# mock pidof：垫片用 `pidof clash` / `pidof openclash_update.sh` 判断进程，
# 测试不能依赖系统真实进程状态（真机上内核可能在跑），故 mock pidof。
# 用 PIDOF_RESULT 环境变量控制返回值：非空 → 模拟进程存在（返回 1 个 PID）。
MOCK_BIN_DIR=$(mktemp -d)
cat > "$MOCK_BIN_DIR/pidof" <<'EOF'
#!/bin/sh
if [ -n "${PIDOF_RESULT:-}" ]; then
	echo "12345"
	exit 0
fi
exit 1
EOF
chmod +x "$MOCK_BIN_DIR/pidof"

run_shim() {
	PATH="$MOCK_BIN_DIR:$PATH" OPENCLASH_RT_UBUS_REAL="$MOCK_UBUS" bash "$SHIM" "$@"
}

# -----------------------------------------------------------------------------
# A：拦截 call service list，按进程存在性回答
# -----------------------------------------------------------------------------
# A1 无 clash 进程 → running=false
r=$(run_shim call service list '{"name":"openclash"}')
chk "A1 无内核 running=false" "$(printf '%s' "$r" | grep -q '"running":false' && echo 0 || echo 1)" "got=$r"

# A2 JSON 形态正确（jsonfilter 能提取）
r=$(run_shim call service list '{"name":"openclash"}')
running=$(printf '%s' "$r" | "$ROOT/runtime/net/jsonfilter" -e '@.openclash.instances.*.running' 2>/dev/null)
chk "A2 jsonfilter 能提取 running" "$([ "$running" = "false" ] && echo 0 || echo 1)" "running=$running"

# A3 有 clash 进程 → running=true（PIDOF_RESULT 非空模拟进程存在）
r=$(PIDOF_RESULT=1 run_shim call service list '{"name":"openclash"}')
chk "A3 有内核 running=true" "$(printf '%s' "$r" | grep -q '"running":true' && echo 0 || echo 1)" "got=$r"

# A4 name=openclash_update 被识别
r=$(run_shim call service list '{"name":"openclash_update"}')
chk "A4 name=openclash_update 被识别" "$(printf '%s' "$r" | grep -q 'openclash_update' && echo 0 || echo 1)" "got=$r"

# B：name 解析（JSON 里的 name 提取）
r=$(run_shim call service list '{"name": "openclash"}')
chk "B1 带空格 JSON 也能解析 name" "$(printf '%s' "$r" | grep -q 'openclash' && echo 0 || echo 1)" "got=$r"

# C：透传（非 call service list）
r=$(run_shim list)
chk "C1 ubus list 透传到真 ubus" "$(printf '%s' "$r" | grep -q 'REAL_UBUS_CALLED' && echo 0 || echo 1)" "got=$r"

r=$(run_shim call uci get '{"config":"luci"}')
chk "C2 call uci 透传" "$(printf '%s' "$r" | grep -q 'REAL_UBUS_CALLED' && echo 0 || echo 1)" "got=$r"

# D：拦截不泄漏（call service list 不应调用真 ubus）
r=$(run_shim call service list '{"name":"openclash"}')
chk "D1 拦截不调用真 ubus" "$(printf '%s' "$r" | grep -q 'REAL_UBUS_CALLED' && echo 1 || echo 0)" "got=$r"

# -----------------------------------------------------------------------------
# E：变异测试（锁不空转）
# -----------------------------------------------------------------------------
# 变异：把拦截条件 $1 != call 改成永远为真（拦截失效，全部透传）
MUT_SHIM=$(mktemp)
sed 's|\[ "\$1" != "call" \]|\[ 1 = 1 \]|' "$SHIM" > "$MUT_SHIM"
r_bad=$(OPENCLASH_RT_UBUS_REAL="$MOCK_UBUS" bash "$MUT_SHIM" call service list '{"name":"openclash"}' 2>/dev/null)
chk "E1 变异后拦截失效（透传到真 ubus）" "$(printf '%s' "$r_bad" | grep -q 'REAL_UBUS_CALLED' && echo 0 || echo 1)" "got=$r_bad"
rm -f "$MUT_SHIM"

rm -f "$MOCK_UBUS"

printf 'PASS %d FAIL %d SKIP %d\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]
