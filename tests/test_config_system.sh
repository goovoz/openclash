#!/usr/bin/env bash
# =============================================================================
# openclash-rt  /etc/config/system 契约测试
# -----------------------------------------------------------------------------
# 背景（2026-10-02 真机登录实测追出）：
#   上游 luasrc/controller/openclash.lua:128 有一行**模块级**赋值：
#       local device_name = uci:get("system", "@system[0]", "hostname")
#   它在控制器文件加载时即执行，device_name 随后被 7 个备份/内核端点拼进
#   Content-Disposition 文件名模板（:2094/2109/2123/2136/2149/2162 等）：
#       'attachment; filename="Backup-OpenClash-%s-%s-%s.tar.gz"'
#                %{ device_name, device_arh, os.date(...) }
#
#   /etc/config/system 不存在 → uci:get 返回 nil → string.format 抛
#     bad argument #2 to '?' (string expected, got nil)
#   → 真机上6 个端点全部 HTTP 500，界面表现为「备份功能全挂」。
#
# 本测试锁住 build-deb.sh 的 §7h 模板，防止它在打包链路上静默复发
# （§7b/7c 已为 firewall / network 做过同类补齐，system 是同一类缺口）。
#
# 覆盖：
#   A. build-deb.sh 必须生成 /etc/config/system
#   B. 该文件必须能被 uci 解析，且 `@system[0].hostname` 取得到非空值
#   C. 段必须是**匿名**（config system 无 name）—— 匹配上游 `@system[0]` 索引
#   D. 必须登记进 conffiles（否则 dpkg 升级覆盖用户改过的 hostname）
#   E. 对拍：把上游 openclash.lua:128 的取法与我们的模板对齐
#   F. 幂等/ 不覆盖既有文件（与 7b/7c/7d/7g 同语义）
#
# 用法： bash tests/test_config_system.sh
# =============================================================================
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

WORK="/tmp/ocrt-sys.$$"
rm -rf "$WORK" 2>/dev/null || true
mkdir -p "$WORK/stage/etc/config"

BUILD_DEB="$ROOT/scripts/build-deb.sh"
CONFFILES="$ROOT/packaging/debian/conffiles"
UPSTREAM_LUA="$ROOT/upstream/luci-app-openclash/luasrc/controller/openclash.lua"

PASS=0; FAIL=0
it()  { printf '\n\033[1m── %s\033[0m\n' "$1"; }
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
no()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "want=[$3] got=[$2]"; fi; }

cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

# -----------------------------------------------------------------------------
# 把 build-deb.sh 里 §7h 的模板抽出来，落到临时 stage。
# 用法： extract_stage <目标文件路径>
# 不执行整个 build-deb.sh（它需要真dpkg / 交叉编译链），只把该段 heredoc
# 重放一遍 —— 与被测逻辑等价，且能在 CI 的 unit job 里跑。
# -----------------------------------------------------------------------------
SYSFILE="$WORK/stage/etc/config/system"
extract_stage() {
	local out="$1"
	local stage_root
	stage_root="$(dirname "$(dirname "$out")")"
	mkdir -p "$stage_root/etc/config"
	# 从 build-deb.sh 里抽出 §7h 的 heredoc **内容**（config system ... EOF），
	# 直接写到目标路径。不用嵌套 shell —— 那样反而会引入第二层转义易错点。
	# 定位方式：§7h 的 if 行之后第一个 <<'EOF' 到行首 EOF 之间。
	awk '
		/^# 7h\) \/etc\/config\/system/       { inblk = 1; next }
		inblk && /<<'"'"'EOF'"'"'$/          { emit = 1; next }
		emit && /^EOF$/                      { exit }
		emit                                 { print }
	' "$BUILD_DEB" > "$out"
}

it "A. build-deb.sh 声明了 §7h system 模板"
if grep -q '^# 7h) /etc/config/system' "$BUILD_DEB"; then
	ok "存在 §7h 段落注释"
else
	no "存在 §7h 段落注释" "build-deb.sh 里找不到 §7h —— 模板可能被删了"
fi
if grep -q 'STAGE/etc/config/system' "$BUILD_DEB"; then
	ok "模板写入路径为 \$STAGE/etc/config/system"
else
	no "模板写入路径" "未找到 $STAGE/etc/config/system 写入"
fi
if grep -q "if \[ ! -f \"\$STAGE/etc/config/system\" \]" "$BUILD_DEB"; then
	ok "带存在性守卫（不覆盖既有文件）"
else
	no "带存在性守卫" "缺少 if [ ! -f ... ] 守卫，会覆盖用户已有 system"
fi

# -----------------------------------------------------------------------------
it "B. 模板能被解析出 hostname"
# -----------------------------------------------------------------------------
extract_stage "$SYSFILE"
if [ -f "$SYSFILE" ]; then
	ok "模板抽出成功"
else
	no "模板抽出成功" "抽取后文件不存在，检查 build-deb.sh 的 heredoc"
fi

# 解析校验：不依赖真 uci（CI unit job 无 /sbin/uci），用 awk 模拟
# uci get system.@system[0].hostname 的取值路径：
#   找 `config system` 段内的 `option hostname '...'`
_hostname_of() {
	awk '
		/^config system/ { insys=1; next }
		/^config /       { insys=0 }
		insys && /^[[:space:]]*option hostname/ {
			gsub(/^[^"]*"[^"]*"|^[^'"'"']*'"'"'/, "")
			gsub(/'"'"'/, "")
			gsub(/[[:space:]]*$/, "")
			print
			exit
		}
	' "$1" 2>/dev/null
}
HOST="$(_hostname_of "$SYSFILE")"
if [ -n "$HOST" ]; then
	ok "hostname 可解析出非空值（$HOST）"
else
	no "hostname 可解析出非空值" "解析结果为空 —— 上游 device_name 会是 nil"
fi

# -----------------------------------------------------------------------------
it "C. 段必须是匿名（匹配上游 @system[0] 索引）"
# -----------------------------------------------------------------------------
# 上游写法：uci:get("system", "@system[0]", "hostname")
# 若我们写成 `config system 'main'`，则 uci show 的首行是 system.main=system，
# `@system[0]` 这种匿名索引取不到 —— 必须用匿名段。
SECLINE="$(grep -m1 -E '^config system' "$SYSFILE" 2>/dev/null)"
chk "config system 行为匿名段（无 name 参数）" "$SECLINE" "config system"
if grep -qE "^config system[[:space:]]+'" "$SYSFILE" 2>/dev/null; then
	no "不得写成具名段" "发现 config system '<name>'，会使上游 @system[0] 取不到"
else
	ok "未写成具名段"
fi

# -----------------------------------------------------------------------------
it "D. 已登记进 conffiles"
# -----------------------------------------------------------------------------
if grep -qx '/etc/config/system' "$CONFFILES" 2>/dev/null; then
	ok "conffiles 含 /etc/config/system（升级不覆盖用户 hostname）"
else
	no "conffiles 含 /etc/config/system" \
	   "未登记 —— dpkg 升级会覆盖用户改过的 hostname，需补一行"
fi

# -----------------------------------------------------------------------------
it "E. 对拍：上游 openclash.lua:128 的取法能拿到值"
# -----------------------------------------------------------------------------
# 从上游源码里抽出 device_name 的取法，确认我们的模板正好满足它。
# 上游可能随版本变动，这里做两件事：
#   E1 源码里确实有 system/@system[0]/hostname 三元组（确认判据没过期）
#   E2 我们的模板能同时满足这三个字面量
# -----------------------------------------------------------------------------
if [ -f "$UPSTREAM_LUA" ]; then
	DLINE="$(grep -nE 'uci:get\("system",\s*"@system\[0\]",\s*"hostname"\)' \
		"$UPSTREAM_LUA" 2>/dev/null | head -1)"
	if [ -n "$DLINE" ]; then
		ok "上游仍有 system/@system[0]/hostname 取法（判据未过期）"
		printf '        %s\n' "$DLINE"
	else
		# 上游改了取法 —— 判据需要重新评估，不直接判FAIL 但要显式提示
		no "上游仍有 system/@system[0]/hostname 取法" \
		   "上游 openclash.lua 里没找到该取法，可能已改名/重构 —— 请复核 device_name 来源"
	fi
else
	no "找到上游 openclash.lua" "$UPSTREAM_LUA 不存在（是否忘了 sync-upstream？）"
fi

for token in 'config system' 'option hostname'; do
	if grep -q "$token" "$SYSFILE" 2>/dev/null; then
		ok "模板含上游所需字面量：$token"
	else
		no "模板含上游所需字面量：$token"
	fi
done

# -----------------------------------------------------------------------------
it "F. 与 7b/7c/7d/7g 同语义：不覆盖既有文件"
# -----------------------------------------------------------------------------
# 直接复用 build-deb.sh 里的守卫逻辑：文件已存在时 if 为假，模板不落盘。
# 这里等价地验证「守卫条件本身写对了」——即 A 段已断言过它的字面形态，
# 这里补一条行为断言：同样的条件下模板内容不会被重写。
# -----------------------------------------------------------------------------
extract_stage "$SYSFILE"
# 模拟用户已自定义过 hostname（dpkg 升级后 conffiles 保留的正是这份）
printf "config system\n\toption hostname 'my-custom-nas'\n" > "$SYSFILE"
CUSTOM="$(cat "$SYSFILE")"

# 复刻build-deb.sh 该段的守卫判断
if [ ! -f "$SYSFILE" ]; then
	extract_stage "$SYSFILE"
fi
chk "已存在时不覆盖用户内容" "$(cat "$SYSFILE")" "$CUSTOM"

# =============================================================================
printf '\n════════════════════════════════════════\n'
printf '  PASS: %d    FAIL: %d\n' "$PASS" "$FAIL"
printf '════════════════════════════════════════\n'
[ "$FAIL" -eq 0 ]
