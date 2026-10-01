#!/usr/bin/env bash
# =============================================================================
# openclash-rt  上游脚本加载路径集成测试
# -----------------------------------------------------------------------------
# 分两部分：
#
#  Part A —— rc.common 契约测试（合成 init 脚本）
#     用一个不做事、只打标记的 init 脚本，逐条验证 rc.common 对动作的派发
#     与上游 stop_service / reload_service / restart / boot 覆盖是否生效。
#     快、确定、无外部依赖。
#
#  Part B —— 真实上游脚本加载测试
#     让 **未经修改** 的上游 /etc/init.d/openclash（3848 行）在本兼容层下
#     完整加载并派发，验证 source 期与 start_service 入口。
#     enable=1 的完整启动不在此覆盖（桩 uci 在非 Linux 环境极慢），
#     由 tests/e2e/linux 在真实 Debian 环境完成。
#
# 用法： bash tests/test_upstream_load.sh
#        OCRT_DEEP_PROBE=1 bash tests/test_upstream_load.sh   # 启用深度探测
# =============================================================================
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
UPSTREAM="$ROOT/upstream/luci-app-openclash/root"

# ⚠️ 不要用 ${TMPDIR}：Windows/MSYS 沙箱下它可能被设为 Windows 盘符路径，
# 会被安全策略判为 "embedded drive prefix" 而拒绝 rm。硬编码 /tmp 最稳。
WORK="/tmp/ocrt-load.$$"
rm -rf "$WORK" 2>/dev/null || true
F="$WORK/root"
mkdir -p "$F/etc/init.d" "$F/etc/config" "$F/lib/functions" "$F/lib/config" \
         "$F/usr/share/openclash" "$WORK"

export PATH="$HERE/mock/bin:$PATH"
export IPKG_INSTROOT="$F"
export MOCK_UCI_DB="$WORK/uci.db"
export OPENCLASH_RT_ROOT="$WORK/rt"
export OPENCLASH_RT_UNIT_DIR="$WORK/units"
export MOCK_SYSTEMD_STATE="$WORK/systemd-state"
export OPENCLASH_RT_LOG="$WORK/rt.log"
mkdir -p "$OPENCLASH_RT_ROOT" "$OPENCLASH_RT_UNIT_DIR" "$MOCK_SYSTEMD_STATE"

# --- 组装假根 ---------------------------------------------------------------
cp "$ROOT/runtime/procd/rc.common"            "$F/etc/rc.common"
cp "$ROOT/runtime/shell/functions.sh"         "$F/lib/functions.sh"
cp "$ROOT/runtime/shell/functions/network.sh" "$F/lib/functions/network.sh"
cp "$ROOT/runtime/shell/service.sh"           "$F/lib/functions/service.sh"
cp "$ROOT/runtime/procd/procd.sh"             "$F/lib/functions/procd.sh"
cp "$ROOT/runtime/shell/config/uci.sh"        "$F/lib/config/uci.sh"
cp "$ROOT/tests/mock/bin/uci"                 "$WORK/uci-real"
RC="$F/etc/rc.common"

printf '#SECTION openclash.config=openclash\nopenclash.config.enable=0\n' >"$MOCK_UCI_DB"

PASS=0; FAIL=0
it()  { printf '\n\033[1m── %s\033[0m\n' "$1"; }
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
no()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1"; printf '        want=%s got=%s\n' "$3" "$2"; fi; }
has() { if grep -qF -- "$2" "$3" 2>/dev/null; then ok "$1"; else no "$1"; printf '        未找到: %s\n' "$2"; fi; }

cleanup() { rm -rf "$WORK" 2>/dev/null; }
trap cleanup EXIT

run_init() {
	local init="$1" action="$2"; shift 2
	( cd "$F" && IPKG_INSTROOT="$F" timeout "${OCRT_ACTION_TIMEOUT:-30}" \
		bash "$RC" "$init" "$action" "$@" ) >"$WORK/out.txt" 2>"$WORK/err.txt"
	echo $?
}

# =============================================================================
#
#  Part A —— rc.common 契约测试
#
# =============================================================================
SYN="$F/etc/init.d/synth"
cat >"$SYN" <<'SYNTH'
#!/bin/sh /etc/rc.common
START=99
STOP=15
USE_PROCD=1

start_service() {
	echo "SYNTH:start_service"
	procd_open_instance "synth-core"
	procd_set_param command /bin/sleep 3600
	procd_close_instance
}
stop_service()  { echo "SYNTH:stop_service arg=[$*]"; }
reload_service(){ echo "SYNTH:reload_service arg=[$*]"; }
restart()       { echo "SYNTH:restart arg=[$*]"; stop_service "$@"; start "$@"; }
boot()          { echo "SYNTH:boot arg=[$*]"; }
SYNTH
chmod +x "$SYN" 2>/dev/null

it "A1  rc.common 动作派发"
rc="$(run_init "$SYN" help)"
chk "help 退出码" "$rc" "0"
has "help 输出用法" "Available commands:" "$WORK/out.txt"
has "help 含 running（USE_PROCD 生效）" "running" "$WORK/out.txt"

rc="$(run_init "$SYN" start)"
chk "start 退出码" "$rc" "0"
has "start -> start_service" "SYNTH:start_service" "$WORK/out.txt"

rc="$(run_init "$SYN" stop)"
chk "stop 退出码" "$rc" "0"
has "stop -> stop_service" "SYNTH:stop_service" "$WORK/out.txt"

rc="$(run_init "$SYN" reload firewall)"
chk "reload 退出码" "$rc" "0"
has "reload -> reload_service 且透传参数" "SYNTH:reload_service arg=[firewall]" "$WORK/out.txt"

rc="$(run_init "$SYN" restart)"
chk "restart 退出码" "$rc" "0"
has "restart -> 上游覆盖实现" "SYNTH:restart" "$WORK/out.txt"

rc="$(run_init "$SYN" boot)"
chk "boot 退出码" "$rc" "0"
has "boot -> 上游覆盖实现" "SYNTH:boot" "$WORK/out.txt"

rc="$(run_init "$SYN" nonsense)"
has "未知命令回落 help" "Available commands:" "$WORK/out.txt"

it "A2  enable / disable / enabled 映射到 systemctl"
rc="$(run_init "$SYN" enable)"
chk "enable 退出码" "$rc" "0"
if [ -f "$MOCK_SYSTEMD_STATE/synth.service.enabled" ]; then
	ok "enable 落盘到 systemd 状态"
else no "enable 落盘到 systemd 状态"; fi

rc="$(run_init "$SYN" enabled)"
chk "enabled 退出码（已启用）" "$rc" "0"

rc="$(run_init "$SYN" disable)"
chk "disable 退出码" "$rc" "0"
rc="$(run_init "$SYN" enabled)"
chk "enabled 退出码（已禁用应为非 0）" "$rc" "1"

	it "A3  start 后半段：procd_close_service 真正拉起单元"
	rc="$(run_init "$SYN" start)"
	UNIT="$OPENCLASH_RT_UNIT_DIR/openclash-rt-synth-core.service"
	if [ -f "$UNIT" ]; then ok "生成单元 openclash-rt-synth-core.service"; else no "生成单元"; fi
	if [ -f "$MOCK_SYSTEMD_STATE/openclash-rt-synth-core.service.active" ]; then
		ok "单元被启动（procd_close_service 生效）"
	else no "单元被启动"; fi

rc="$(run_init "$SYN" running)"
chk "running 退出码（应运行中）" "$rc" "0"

rc="$(run_init "$SYN" stop)"
rc2="$(run_init "$SYN" running)"
chk "stop 后 running 应为非 0" "$rc2" "1"

# =============================================================================
#
#  Part B —— 真实上游脚本
#
# =============================================================================
if [ ! -d "$UPSTREAM" ]; then
	it "B  真实上游脚本"
	printf '  \033[33mSKIP\033[0m  上游代码缺失，请先执行 scripts/sync-upstream.sh\n'
else
	INIT="$F/etc/init.d/openclash"
	cp "$UPSTREAM/etc/init.d/openclash" "$INIT"
	cp "$UPSTREAM"/usr/share/openclash/* "$F/usr/share/openclash/" 2>/dev/null
	cp -r "$UPSTREAM"/usr/share/openclash/res "$F/usr/share/openclash/" 2>/dev/null
	cp -r "$UPSTREAM"/usr/share/openclash/ui  "$F/usr/share/openclash/" 2>/dev/null
	chmod +x "$INIT" 2>/dev/null

	it "B1  加载未修改的上游 init.d/openclash 并派发 help"
	rc="$(run_init "$INIT" help)"
	chk "help 退出码" "$rc" "0"
	has "help 输出" "Available commands:" "$WORK/out.txt"

	it "B2  start(enable=0) —— 完整加载 3848 行并进入上游 start_service"
	: >/tmp/openclash_start.log 2>/dev/null
	rc="$(run_init "$INIT" start)"
	chk "start 退出码 0" "$rc" "0"
	has "上游 log.sh 生效" "[Warning]" /tmp/openclash_start.log
	has "命中上游「已禁用」分支（证明 start_service 被调用）" \
		"OpenClash Now Disabled" /tmp/openclash_start.log

	it "B3  路径契约测绘（上游硬编码绝对路径）"
	if [ -s "$WORK/err.txt" ]; then
		printf '  \033[33mINFO\033[0m  上游以绝对路径 source，兼容层必须在真实系统提供这些路径：\n'
		# 只取形如 "/path/to/x.sh: line N:" 中行首的绝对路径，剔除临时目录片段
		grep -oE "^/[a-zA-Z0-9_/.-]+\.(sh|rb|lua)" "$WORK/err.txt" | sort -u | sed 's/^/        /'
		ok "已识别路径契约清单"
	else
		ok "本次加载未出现绝对路径缺失"
	fi

	it "B4  start(enable=1) 深度探测（信息性，默认跳过）"
	if [ "${OCRT_DEEP_PROBE:-0}" = "1" ]; then
		printf '#SECTION openclash.config=openclash\nopenclash.config.enable=1\n' >"$MOCK_UCI_DB"
		: >/tmp/openclash_start.log 2>/dev/null
		rc="$(run_init "$INIT" start)" || true
		REACHED="$(grep -oE "Step [0-9]+: .*" /tmp/openclash_start.log 2>/dev/null | tail -1)"
		printf '  \033[33mINFO\033[0m  rc=%s  推进到: %s\n' "$rc" "${REACHED:-未进入 Step 阶段}"
		printf '  \033[33mINFO\033[0m  生成单元数: %s\n' "$(ls "$OPENCLASH_RT_UNIT_DIR" 2>/dev/null | wc -l)"
		printf '#SECTION openclash.config=openclash\nopenclash.config.enable=0\n' >"$MOCK_UCI_DB"
	else
		printf '  \033[33mSKIP\033[0m  OCRT_DEEP_PROBE=1 启用\n'
	fi
fi

# =============================================================================
printf '\n\033[1m════════════════════════════════════════\033[0m\n'
printf '  PASS: \033[32m%d\033[0m    FAIL: \033[31m%d\033[0m\n' "$PASS" "$FAIL"
printf '\033[1m════════════════════════════════════════\033[0m\n'
[ "$FAIL" -eq 0 ] || exit 1
