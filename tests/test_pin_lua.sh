#!/usr/bin/env bash
# =============================================================================
# lua 解释器钉定测试
# -----------------------------------------------------------------------------
# 被测对象：runtime/upstream/pin-lua-interpreter.sh
#           （以及 scripts/build-deb.sh 里对它的调用）
#
# 背景（为什么这条链路值得单独一套测试）：
#   上游有 11 处假定「`lua` 命令解析到 Lua 5.1」。OpenWrt 上成立，Debian 上
#   不成立 —— /usr/bin/lua 由 update-alternatives 组 lua-interpreter 提供，
#   优先级 lua5.1=110 < lua5.4=130，于是机器上只要有 lua5.4，我们为 5.1 编译
#   的 .so 就会在运行时加载失败，且症状与「搜索路径没桥接对」几乎一样。
#
#   这条链路的**正确性**恰恰体现在两个很容易被"简化"掉的性质上：
#     ① stdout 必须只有那个整数（被日志污染过一次就废）；
#     ② 遇到没测绘过的调用形态必须**失败**，而不是尽力而为地改写。
#   这两点都不是"跑起来不报错"能证明的，所以逐条断言。
#
# 覆盖：
#   A. 真实上游树端到端：11 处、stdout 干净
#   B. 幂等：重跑得 0 处且 rc=0（不是失败）
#   C. --check 两个方向：已钉定=0；未钉定=1 且列出 file:line
#   D. shebang 形态矩阵（含 /usr/bin/env lua、CRLF 行尾）
#   E. 未识别形态：必须失败，且**整棵树**未被改动（跨文件原子性）
#   F. dry-run：报告但不落盘
#   G. stdout/stderr 分工
#   H. 隔离性：源树（upstream/）不被改动
#   I. 静态纪律（bash -n / 无 mktemp / 两遍式顺序 / build-deb.sh 真的在调用它）
#   J. 边界：不存在的目录、空目录、文件类型过滤
#   K. --file 显式路径模式（无扩展名入口：cgi-bin/luci、rpcd/luci）
#
# 用法： bash tests/test_pin_lua.sh
# =============================================================================
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PIN="$ROOT/runtime/upstream/pin-lua-interpreter.sh"
BUILD_DEB="$ROOT/scripts/build-deb.sh"
UP_ROOT="$ROOT/upstream/luci-app-openclash/root"
UP_SRC="$UP_ROOT/usr/share/openclash"

# ⚠️ 硬编码 /tmp：${TMPDIR} 在本沙箱是 Windows 盘符路径，会被安全策略拒绝
WORK="/tmp/ocrt-pinlua.$$"
rm -rf "$WORK" 2>/dev/null || true
mkdir -p "$WORK"

PASS=0; FAIL=0
it()  { printf '\n\033[1m── %s\033[0m\n' "$1"; }
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
no()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "want=[$3] got=[$2]"; fi; }
has() { if printf '%s\n' "$2" | grep -qF -- "$3"; then ok "$1"; else no "$1" "输出里没有：$3"; fi; }
not() { if printf '%s\n' "$2" | grep -qF -- "$3"; then no "$1" "输出里不该有：$3"; else ok "$1"; fi; }

# 跑被测脚本：stdout 存 $OUT，stderr 存 $ERR，返回码存 $RC
run_pin() {
	OUT="$(bash "$PIN" "$@" 2>"$WORK/.err")"; RC=$?
	ERR="$(<"$WORK/.err")"
	return 0
}

cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

# -----------------------------------------------------------------------------
# 前置：上游树（CI 里先跑 sync-upstream.sh；本地可能没有）
# -----------------------------------------------------------------------------
if [ ! -d "$UP_SRC" ]; then
	printf '\033[31m[fatal]\033[0m 缺少 %s\n' "$UP_SRC"
	printf '        请先运行： bash scripts/sync-upstream.sh\n'
	exit 1
fi

# 上游源的基线校验和：H 组用来证明"读源但从不写源"
_up_hash() {
	find "$UP_SRC" -type f \( -name '*.lua' -o -name '*.sh' \) -print0 2>/dev/null \
		| sort -z | xargs -0 cat 2>/dev/null | cksum | tr -d ' '
}
UP_HASH_BEFORE="$(_up_hash)"

# 一个"干净的、未钉定的"工作副本，供各用例复用
fresh_copy() {   # <目标目录>
	rm -rf "$1"; mkdir -p "$1"
	cp -a "$UP_SRC/." "$1/"
}

# =============================================================================
it "A. 真实上游树：端到端改写"
# =============================================================================
A="$WORK/A"; fresh_copy "$A"
run_pin --dir "$A"
chk "A 返回码为 0" "$RC" "0"
# ⚠️ 失败时**必须**把被测脚本的 stderr 打到测试自己的输出里。
#    这条链路已被接到 sync-upstream.yml 的「每日同步冲突告警」上：上游一旦改了
#    「调用系统 lua」的写法，run_pin 会以非零退出，而 pin-lua-interpreter.sh
#    恰恰在失败时打印 file:line 与两种出路 —— 那是唯一能告诉人"该改哪里"的信息。
#    若把它吞进 $ERR 不输出，CI 日志里就只剩 `want=[0] got=[1]`，告警等于无效。
if [ "$RC" != 0 ]; then
	printf '        ├─ 被测脚本 stderr（诊断，勿删）：\n'
	printf '%s\n' "$ERR" | sed 's/^/        │ /'
fi
chk "A stdout 恰为整数 11" "$OUT" "11"

# 逐条核对：8 个 shebang + 3 处显式调用，一处不少、一处不多
_sb="$(grep -rl '^#!/usr/bin/lua5\.1$' "$A" 2>/dev/null | wc -l | tr -d ' ')"
_calls="$(grep -rhoE '(^|[^[:alnum:]_./])/usr/bin/lua5\.1 /usr/share/openclash/' "$A" 2>/dev/null | wc -l | tr -d ' ')"
chk "A shebang 被改写的文件数 = 8" "$_sb" "8"
chk "A 显式调用被改写的处数 = 3" "$_calls" "3"
chk "A 裸露的 '#!/usr/bin/lua' 残留 = 0" "$(grep -rlE '^#!/usr/bin/lua$' "$A" 2>/dev/null | wc -l | tr -d ' ')" "0"

# watchdog 那处藏在 Ruby 字符串里，且带两层转义（\" 与 \\\"）。这里刻意**不**
# 做整行匹配 —— 那既脆又会在上游微调空白时误报。改成分三条断言，各自证明
# 一个必须保住的性质：命令被钉定、Ruby 插值没坏、外层转义没坏。
WD_LINE="$(grep -h 'openclash_sub_parser' "$A/openclash_watchdog.sh")"
has "A watchdog：命令已钉到绝对路径" "$WD_LINE" \
	'/usr/bin/lua5.1 /usr/share/openclash/openclash_sub_parser.lua'
has "A watchdog：Ruby 插值 #{path} 未被破坏" "$WD_LINE" '#{path}'
has "A watchdog：外层转义 syscall = \" 未被破坏" "$WD_LINE" 'syscall = \"'

# A2：**真实 staging 布局**。这一组守的是一个很容易漏的真实差异 ——
#   build-deb.sh 传给 --dir 的不是 $UP_SRC，而是 staging 的 usr/share/openclash，
#   而后者还多了从 etc/openclash/ 与 etc/uci-defaults/ 拷进来的文件（默认配置
#   与 uci-defaults 脚本）。
#   若那些多出来的文件里恰好出现 "lua" 这个词，宽判据就会把计数抬高 → 触发
#   "未识别形态" → **真实构建直接失败**。本机实测它们干净，但必须固化，
#   否则将来上游往 uci-defaults 里加一行注释就可能让打包挂掉，且原因难查。
A2="$WORK/A2"; rm -rf "$A2"; mkdir -p "$A2/usr/share/openclash"
cp -a "$UP_SRC/." "$A2/usr/share/openclash/"
cp -a "$UP_ROOT/etc/openclash/."    "$A2/usr/share/openclash/defaults/"     2>/dev/null || true
cp -a "$UP_ROOT/etc/uci-defaults/." "$A2/usr/share/openclash/uci-defaults/" 2>/dev/null || true

_n_src="$(find "$UP_SRC"  -type f \( -name '*.lua' -o -name '*.sh' \) 2>/dev/null | wc -l | tr -d ' ')"
_n_a2="$(find "$A2"       -type f \( -name '*.lua' -o -name '*.sh' \) 2>/dev/null | wc -l | tr -d ' ')"
chk "A2 staging 确实比源目录多了文件（用例前提）" \
	"$([ "$_n_a2" -gt "$_n_src" ] && echo more || echo not-more)" "more"

run_pin --dir "$A2"
chk "A2 rc=0（多出来的文件不触发未识别告警）" "$RC" "0"
chk "A2 改写数仍为 11（计数不漂移）" "$OUT" "11"
run_pin --check "$A2"
chk "A2 全部文件通过残留判据（含 defaults/ 与 uci-defaults/）" "$RC" "0"
has "A2 判据覆盖到了全部文件而不只是源目录" "$ERR" "残留判据通过：$_n_a2 个文件"

it "B. 幂等：对已钉定的树重跑"
run_pin --dir "$A"
chk "B 返回码为 0（不是失败）" "$RC" "0"
chk "B stdout 恰为 0" "$OUT" "0"
has "B 明确说明是幂等重跑" "$ERR" "已是钉定状态"
# 幂等重跑不得再次改写（否则会变成 /usr/bin/lua5.1 叠罗汉）
chk "B 未产生叠加的 lua5.1" "$(grep -rho 'lua5\.1' "$A" 2>/dev/null | grep -c 'lua5\.1' || true)" "11"

it "C. --check 两个方向"
run_pin --check "$A"
chk "C 已钉定的树：rc=0" "$RC" "0"
chk "C 已钉定的树：stdout=0" "$OUT" "0"

C="$WORK/C"; fresh_copy "$C"
run_pin --check "$C"
chk "C 未钉定的树：rc=1" "$RC" "1"
has "C 未钉定的树：列出 pending 位置" "$ERR" "openclash_core.sh"
has "C 未钉定的树：报出不通过" "$ERR" "未通过残留判据"
run_pin --check "$C"
chk "C --check 是只读的（rc 仍为 1，说明没顺手改）" "$RC" "1"
chk "C --check 未改动文件" \
	"$(grep -c '^#!/usr/bin/lua$' "$C/openclash_version.lua" 2>/dev/null || true)" "1"

it "D. shebang 形态矩阵"
D="$WORK/D"; mkdir -p "$D"
printf '#!/usr/bin/lua\nprint(1)\n'        > "$D/d1.lua"
printf '#!/usr/bin/env lua\nprint(2)\n'    > "$D/d2.lua"
printf '#!/usr/local/bin/lua\nprint(3)\n'  > "$D/d3.lua"
printf '#!lua\nprint(4)\n'                 > "$D/d4.lua"
printf '#!/bin/sh\necho ok\n'              > "$D/d5.lua"
printf 'x = 1\n'                           > "$D/d6.lua"
run_pin --dir "$D"
chk "D 四个 shebang 全部改写" "$OUT" "4"
chk "D /usr/bin/env lua -> 绝对路径" "$(head -1 "$D/d2.lua" | tr -d '\r')" "#!/usr/bin/lua5.1"
chk "D /usr/local/bin/lua -> 绝对路径" "$(head -1 "$D/d3.lua" | tr -d '\r')" "#!/usr/bin/lua5.1"
chk "D 裸 #!lua -> 绝对路径" "$(head -1 "$D/d4.lua" | tr -d '\r')" "#!/usr/bin/lua5.1"
chk "D 无关 shebang 不被动" "$(head -1 "$D/d5.lua" | tr -d '\r')" "#!/bin/sh"
chk "D 无 shebang 的文件首行不变" "$(head -1 "$D/d6.lua" | tr -d '\r')" "x = 1"

# CRLF 行尾：上游今天全是 LF（已实测），但贡献者在 Windows 上编辑很容易引入
# CRLF。`[[:space:]]*$` 让规则能吃下 '\r'，所以这里固化这个行为，避免将来
# 有人"优化"掉那个 [[:space:]]* 而让 CRLF 变成"未识别形态"。
D2="$WORK/D2"; mkdir -p "$D2"
printf '#!/usr/bin/lua\r\nprint(1)\r\n' > "$D2/crlf.lua"
run_pin --dir "$D2"
chk "D CRLF 行尾的 shebang 也能改写（rc=0）" "$RC" "0"
chk "D CRLF 行尾的 shebang 也能改写（1 处）" "$OUT" "1"

it "E. 未识别形态必须失败，且不改动文件（原子性）"
E="$WORK/E"; mkdir -p "$E"
# 形态：已经钉定过 shebang，但出现我们没测绘过的调用写法
printf '#!/usr/bin/lua5.1\nx=$(lua -e "print(1)")\n' > "$E/e1.sh"
printf '#!/usr/bin/lua5.1\ny=$(lua "$f")\n'           > "$E/e2.sh"
E1_SUM="$(cksum < "$E/e1.sh")"
run_pin --dir "$E"
chk "E 未识别形态：rc=1" "$RC" "1"
chk "E 失败时 stderr 非空（否则上层无诊断可打印）" \
	"$([ -n "$ERR" ] && echo yes || echo no)" "yes"
has "E 报出「未识别的 lua 依赖形态」" "$ERR" "未识别的 lua 依赖形态"
has "E 指出具体行号（lua -e 那行）" "$ERR" 'x=$(lua -e "print(1)")'
has "E 给出两种出路（补规则 / 收窄判据）" "$ERR" "收窄 RESIDUAL_RE"
# 原子性：检查发生在改写之前，所以文件必须**逐字节未变**
chk "E 文件未被改动（原子性）" "$(cksum < "$E/e1.sh")" "$E1_SUM"

# 混杂：既有已知形态又有未识别形态 —— 同样必须整体失败，不得"改一半"
E3="$WORK/E3"; mkdir -p "$E3"
printf '#!/usr/bin/lua\nlua /usr/share/openclash/a.lua\nexec lua -e "x"\n' > "$E3/mix.sh"
E3_SUM="$(cksum < "$E3/mix.sh")"
run_pin --dir "$E3"
chk "E 混杂形态：rc=1" "$RC" "1"
has "E 混杂形态：报出宽窄计数差" "$ERR" "窄规则覆盖 2 处，宽判据命中 3 处"
chk "E 混杂形态：文件逐字节未变（不得改一半）" "$(cksum < "$E3/mix.sh")" "$E3_SUM"

# -----------------------------------------------------------------------------
# E4：**跨文件**原子性 —— 这是"两遍式重构"的真正回归测试。
#   构造：a-known.sh 排在最前且只含已知形态；z1/z2 排在后面且各含一处未识别形态。
#   旧实现（边检查边改写）下，for 循环会**先改写 a-known.sh**，再在 z1 上失败 ——
#   于是树被留在"一半已钉定、一半没动"的状态，而失败信息只提到 z1，使用者完全
#   不知道 a-known.sh 已经被动过。本机实测那次中止时已有 7 个文件被改。
#   两遍式必须在体检阶段就把 z1/z2 全部找出来，从而 a-known.sh 逐字节不变。
#   同时验证"一次列全所有违规文件"（单报第一个会让上游同步排查变成挤牙膏）。
# -----------------------------------------------------------------------------
E4="$WORK/E4"; mkdir -p "$E4"
printf '#!/usr/bin/lua\nprint(1)\n'      > "$E4/a-known.sh"
printf '#!/usr/bin/lua5.1\nlua -e "x"\n' > "$E4/z1-unknown.sh"
printf '#!/usr/bin/lua5.1\nlua -e "y"\n' > "$E4/z2-unknown.sh"
E4_A_SUM="$(cksum < "$E4/a-known.sh")"
E4_Z1_SUM="$(cksum < "$E4/z1-unknown.sh")"
run_pin --dir "$E4"
chk "E 跨文件：rc=1" "$RC" "1"
has "E 跨文件：声明整树原子（可无回滚重跑）" "$ERR" "整树原子"
chk "E 跨文件：排序在前的已知形态文件逐字节未变（旧单遍实现在此必失败）" \
	"$(cksum < "$E4/a-known.sh")" "$E4_A_SUM"
chk "E 跨文件：违规文件同样未变" "$(cksum < "$E4/z1-unknown.sh")" "$E4_Z1_SUM"
has "E 跨文件：一次列全所有违规文件（z1）" "$ERR" "z1-unknown.sh"
has "E 跨文件：一次列全所有违规文件（z2）" "$ERR" "z2-unknown.sh"
has "E 跨文件：汇总给出违规文件总数" "$ERR" "2 个文件含**未识别的 lua 依赖形态**"

it "F. dry-run 只报告不落盘"
F="$WORK/F"; fresh_copy "$F"
F_SUM="$(grep -rlE '^#!/usr/bin/lua$' "$F" 2>/dev/null | wc -l | tr -d ' ')"
run_pin --dir "$F" --dry-run
chk "F dry-run：rc=0" "$RC" "0"
chk "F dry-run：报出 11 处" "$OUT" "11"
chk "F dry-run：文件确实没被改" \
	"$(grep -rlE '^#!/usr/bin/lua$' "$F" 2>/dev/null | wc -l | tr -d ' ')" "$F_SUM"
has "F dry-run：输出里标明未落盘" "$ERR" "未落盘"

it "G. stdout / stderr 分工（本仓库踩过两次）"
G="$WORK/G"; fresh_copy "$G"
run_pin --dir "$G"
# stdout 必须**只有一个 token 且是纯数字**：多一个空格/换行/ANSI 都会让
# 调用方的 `n="$(...)"` 拿到被污染的值。
chk "G stdout 只有 1 行" "$(printf '%s\n' "$OUT" | grep -c . || true)" "1"
chk "G stdout 是纯数字" "$(printf '%s' "$OUT" | tr -d '0-9' | grep -c . || true)" "0"
chk "G stdout 不含 ANSI 转义" "$(printf '%s' "$OUT" | grep -c $'\033' || true)" "0"
chk "G stdout 不含人类日志字样" "$(printf '%s' "$OUT" | grep -c 'pin-lua' || true)" "0"
# stderr 的行数不写死：--dir 成功路径会输出 1 行，而它内部还会再调一次
# --check，后者成功时也往 stderr 写 1 行。断言"至少 1 行"即可，写死数字
# 会让将来任何一条日志的增删都变成误报。
chk "G 日志确实走了 stderr（>= 1 行带 [pin-lua] 前缀）" \
	"$([ "$(printf '%s' "$ERR" | grep -c 'pin-lua' || true)" -ge 1 ] && echo yes || echo no)" "yes"
run_pin --list
chk "G --list 的 stdout 为空（全走 stderr）" "$OUT" ""
has "G --list 的 stderr 含改写规则" "$ERR" "改写规则"
has "G --list 的 stderr 含残留判据" "$ERR" "残留判据"

it "H. 隔离性：源树不被改动"
chk "H upstream/ 源树校验和不变" "$(_up_hash)" "$UP_HASH_BEFORE"
# 反向确认：源树里确实仍是未钉定的原始形态（否则上面的检查没意义）
chk "H 源树仍保留原始 '#!/usr/bin/lua'（8 个文件）" \
	"$(grep -rlE '^#!/usr/bin/lua$' "$UP_SRC" 2>/dev/null | wc -l | tr -d ' ')" "8"
chk "H 源树里没有 lua5.1 字样" \
	"$(grep -rl 'lua5\.1' "$UP_SRC" 2>/dev/null | wc -l | tr -d ' ')" "0"

it "I. 静态纪律"
if bash -n "$PIN" 2>/dev/null; then ok "I bash -n 通过"; else no "I bash -n 通过" "$(bash -n "$PIN" 2>&1 | head -2)"; fi
chk "I 不落临时文件（无 mktemp）" "$(grep -c 'mktemp' "$PIN" || true)" "0"
chk "I 用 sed -i -E（BRE 会让 \\1 报 invalid reference）" \
	"$(grep -cE '^\s*sed -i -E' "$PIN" || true)" "1"
chk "I 定义了 sed 分隔符碰撞的机器可检断言" \
	"$(grep -c '正则里出现了 sed 分隔符' "$PIN" || true)" "1"
chk "I 自检在改写之前执行" \
	"$(grep -cE '^\[ "\$MODE" = pin \] && _selftest_sed' "$PIN" || true)" "1"
chk "I 默认 LUA_BIN 是 /usr/bin/lua5.1" \
	"$(grep -cE '^LUA_BIN="\$\{LUA_BIN:-/usr/bin/lua5\.1\}"' "$PIN" || true)" "1"
# 关键：build-deb.sh 必须真的在调用它，而不是各写一份会漂移的实现。
# ⚠️ 不能只数名字出现次数 —— 它在注释与"适配清单"里也会被提到（共 3 次）。
#    要断言的是**调用那一行**本身。
chk "I build-deb.sh 有调用它的命令行" \
	"$(grep -cE '^_lua_rewritten="\$\(bash .*pin-lua-interpreter\.sh' "$BUILD_DEB" || true)" "1"
chk "I 调用点在 staging 的 usr/share/openclash 上" \
	"$(grep -cE '^\s*--dir "\$STAGE/usr/share/openclash"\)"' "$BUILD_DEB" || true)" "1"
_hits="$(grep -c '工具：runtime/upstream/pin-lua-interpreter.sh' "$BUILD_DEB" || true)"
chk "I 适配清单里记录了工具路径（供上游同步比对，至少 1 处）" \
	"$([ "$_hits" -ge 1 ] && echo yes || echo no)" "yes"
# 旧的内联实现必须已经删干净（否则两套实现会漂移）
chk "I build-deb.sh 不再残留旧的内联改写" \
	"$(grep -c '_LUA_OLD_RE' "$BUILD_DEB" || true)" "0"

# --- 两遍式（先体检、后落盘）的静态纪律 ---
# 为什么在这里也要钉一遍：这两遍式的顺序**就是**那个原子性保证的全部依据，
# 而它极容易被后人"顺手合并成一个循环"地优化掉 —— 合并后所有 E 组用例依然
# 通过（单文件场景看不出来），只有跨文件场景才会暴露。用行号序来钉这个顺序。
_ln() { grep -nF -- "$1" "$PIN" | cut -d: -f1 | sed -n '1p'; }
_pass1_ln="$(_ln '---- 第 1 遍：只读体检')"
_pass2_ln="$(_ln '---- 第 2 遍：落盘')"
_viol_ln="$( _ln 'VIOL_FILES+=( "$f" )')"
_plan_ln="$( _ln 'PLAN_FILES+=( "$f" )')"
_sedi_ln="$( _ln 'sed -i -E')"
chk "I 存在「第 1 遍：只读体检」段落" "$([ -n "$_pass1_ln" ] && echo yes)" "yes"
chk "I 存在「第 2 遍：落盘」段落" "$([ -n "$_pass2_ln" ] && echo yes)" "yes"
_pinorder=no
if [ -n "$_viol_ln" ] && [ -n "$_plan_ln" ] && [ -n "$_sedi_ln" ] && [ -n "$_pass2_ln" ] \
	&& [ "$_viol_ln" -lt "$_pass2_ln" ] && [ "$_plan_ln" -lt "$_pass2_ln" ] \
	&& [ "$_pass2_ln" -lt "$_sedi_ln" ]; then
	_pinorder=yes
fi
chk "I 违规判定与清单登记都严格早于落盘（两遍式没被合并回单遍）" "$_pinorder" "yes"
# 旧措辞是不实的（单遍实现下中止时已改过若干文件），必须已删除
chk "I 已删除不实的「本次运行是原子的」措辞" \
	"$(grep -c '本次运行是原子的' "$PIN" || true)" "0"

# --- --file 模式的静态纪律 ---
# `--file` 分支**绝不能**设置 MODE：`--check --file A` 里的 --file 会把 MODE 从
# check 覆盖成 pin，于是"校验"变成"改写"。这属于"验证动作产生副作用"，
# 而且它会让 K 组那条 rc=0 断言**依然通过**，所以静态锁不可省。
chk "I --file 分支不设置 MODE（否则 --check --file 会变成改写）" \
	"$(grep -cE '^\s*--file\)\s+MODE=' "$PIN" || true)" "0"
# ⚠️ 判据必须锚到代码形态（`die "` 前缀），不能只搜"不能混用"这个说法 ——
#    工具头部注释里也写着"不能混用"，只搜说法会数出 2 而不是 1（本套件第一版
#    就因此误报 1 条）。这与 test_maintainer_scripts.sh 里"注释会引用被禁止写法"
#    是同一类陷阱。
chk "I 存在 --file 的范围互斥断言（代码里，不是只有注释）" \
	"$(grep -cF 'die "--file 与 --dir' "$PIN" || true)" "1"
# 复核点必须走 _check_again：直接 `bash "$0" --check "$TARGET"` 在 --file 模式下
# 会因为 TARGET 为空而一律失败，把"0 命中歧义判定"直接推成"构建失败"。
chk "I 定义了 _check_again 复核助手" \
	"$(grep -c '^_check_again() {' "$PIN" || true)" "1"
chk "I 三个复核点都改走 _check_again" \
	"$(grep -c '_check_again >/dev/null' "$PIN" || true)" "3"
chk "I 目录/显式两种范围在枚举处分流（SCOPE_DESC 同时服务于两者）" \
	"$(grep -c 'SCOPE_DESC=' "$PIN" || true)" "2"

it "J. 边界"
run_pin --dir "$WORK/does-not-exist"
chk "J 不存在的目录：rc=1" "$RC" "1"
has "J 不存在的目录：提示目录不存在" "$ERR" "目录不存在"

# 真正的空目录（不能拿 $WORK 当"空"用 —— 它下面全是各用例的副本）
# 断言 rc=1 而不是 0：扫描到 0 个文件必须失败。这与本项目此前
# "dns_prep 0/0 被当成绿色" 是同一类缺陷，专门在这一组守住。
JEMPTY="$WORK/J-empty"; mkdir -p "$JEMPTY"
run_pin --dir "$JEMPTY"
chk "J 空目录：rc=1（扫到 0 个文件不得算通过）" "$RC" "1"
has "J 空目录：解释为什么失败" "$ERR" "扫描到 0 个文件不能算通过"
run_pin --check "$JEMPTY"
chk "J 空目录 --check：同样 rc=1" "$RC" "1"

# 文件类型过滤：非 .lua/.sh 即使含 shebang 也不该被改（避免误伤数据文件）
J="$WORK/J"; mkdir -p "$J"
printf '#!/usr/bin/lua\n' > "$J/data.txt"
printf '#!/usr/bin/lua\n' > "$J/real.lua"
run_pin --dir "$J"
chk "J 只改 .lua/.sh（1 处）" "$OUT" "1"
chk "J .txt 未被改动" "$(head -1 "$J/data.txt" | tr -d '\r')" "#!/usr/bin/lua"
chk "J .lua 已被改动" "$(head -1 "$J/real.lua" | tr -d '\r')" "#!/usr/bin/lua5.1"

# =============================================================================
it "K. --file 显式路径模式（无扩展名入口）"
# =============================================================================
# 为什么单独一组：上游有两个**没有扩展名**的 lua 入口 ——
#   vendor/luci/luci-base/htdocs/cgi-bin/luci        （整个 Web UI 的 CGI 入口）
#   vendor/luci/luci-base/root/usr/libexec/rpcd/luci （rpcd 的 Lua 插件）
# `--dir` 是按 `-name '*.<ext>'` 过滤的，因此**永远选不到它们**；而对整棵 vendor
# 树跑宽判据又会被第三方散文误报（`nixio - Linux I/O library for lua`、axTLS 的
# `-- > [lua] axssl ...`）打断 —— 实测 3 个文件误报。所以能力必须落在"按显式路径
# 钉定"上，这一组就是它的守门测试。第一组断言（反证 --dir 选不到）是理解 K 组
# 存在意义的钥匙，别当成冗余。
LUCI_CGI="$ROOT/vendor/luci/luci-base/htdocs/cgi-bin/luci"
LUCI_RPC="$ROOT/vendor/luci/luci-base/root/usr/libexec/rpcd/luci"

if [ -f "$LUCI_CGI" ] && [ -f "$LUCI_RPC" ]; then
	K="$WORK/K"; rm -rf "$K"; mkdir -p "$K"
	cp "$LUCI_CGI" "$K/cgi-luci"    # 刻意保持"无扩展名"这一关键形态
	cp "$LUCI_RPC" "$K/rpcd-luci"

	# ⚠️ 判据只看 basename：路径里的 `ocrt-pinlua.$$` 自带一个点，直接对整条路径
	#    做 `case ... in *.*` 会恒真，这条"用例前提"就变成了永远通过的空断言。
	chk "K 用例前提：入口确实没有扩展名" \
		"$(case "$(basename "$K/cgi-luci")" in *.*) echo has-ext ;; *) echo no-ext ;; esac)" "no-ext"

	run_pin --dir "$K"
	chk "K 反证：--dir 选不到无扩展名入口（扫到 0 个文件 → 失败）" "$RC" "1"
	has "K 反证：失败原因就是「没有找到可处理的文件」" "$ERR" "没有找到可处理的文件"

	run_pin --file "$K/cgi-luci" --file "$K/rpcd-luci"
	chk "K --file 钉定 rc=0" "$RC" "0"
	chk "K --file 钉定 2 处（两个入口各一处）" "$OUT" "2"
	chk "K cgi 入口的 shebang 已钉定" "$(head -1 "$K/cgi-luci" | tr -d '\r')" "#!/usr/bin/lua5.1"
	chk "K rpcd 入口的 /usr/bin/env lua 也已钉定" "$(head -1 "$K/rpcd-luci" | tr -d '\r')" "#!/usr/bin/lua5.1"

	run_pin --check --file "$K/cgi-luci" --file "$K/rpcd-luci"
	chk "K --check --file 对已钉定文件 rc=0" "$RC" "0"

	run_pin --file "$K/cgi-luci" --file "$K/rpcd-luci"
	chk "K --file 幂等重跑 stdout=0" "$OUT" "0"

	# --check --file 必须是**只读**的。这条防的是一类很危险的实现错误：若 --file
	# 分支顺手写了 MODE=pin，`--check --file` 就会被静默降级成改写 —— 验证动作
	# 产生副作用，是最坏的一类 bug（而且它会让上面那条 rc=0 断言依然通过）。
	K_R="$WORK/K-readonly"; mkdir -p "$K_R"; cp "$LUCI_RPC" "$K_R/b"
	K_R_SUM="$(cksum < "$K_R/b")"
	run_pin --check --file "$K_R/b"
	chk "K --check --file 对未钉定文件 rc=1" "$RC" "1"
	has "K --check --file 报出具体行" "$ERR" '#!/usr/bin/env lua'
	chk "K --check --file 只读，逐字节未变（防 --file 覆盖 MODE）" \
		"$(cksum < "$K_R/b")" "$K_R_SUM"

	# --dry-run --file：报告但不落盘
	K_D="$WORK/K-dry"; mkdir -p "$K_D"; cp "$LUCI_CGI" "$K_D/cgi"
	run_pin --file "$K_D/cgi" --dry-run
	chk "K --dry-run --file rc=0" "$RC" "0"
	chk "K --dry-run --file 报出 1 处" "$OUT" "1"
	chk "K --dry-run --file 未改动文件" "$(head -1 "$K_D/cgi" | tr -d '\r')" "#!/usr/bin/lua"

	# 去重：同一路径给两次不得重复计数（重复计数会让被钉定处数虚高，
	# 而那个数字是 build-deb.sh 的日志与 CI 断言都依赖的）
	K_U="$WORK/K-uniq"; mkdir -p "$K_U"; cp "$LUCI_CGI" "$K_U/x"
	run_pin --file "$K_U/x" --file "$K_U/x"
	chk "K 同一路径给两次只算一次（去重）" "$OUT" "1"

	# 范围互斥：两种范围语义重叠，混用会得到一个说不清的扫描范围
	run_pin --dir "$K" --file "$K/cgi-luci"
	chk "K --file 与 --dir 混用 → rc=1" "$RC" "1"
	has "K 混用时给出明确拒绝理由" "$ERR" "不能混用"

	run_pin --file "$WORK/definitely-not-here.lua"
	chk "K 路径不存在 → rc=1" "$RC" "1"
	has "K 路径不存在时点名该路径" "$ERR" "definitely-not-here.lua"

	# 只给 --check 不给任何目标：必须失败。静默成功在这里尤其危险 ——
	# 调用方会把"校验通过"当成可以出包。
	run_pin --check
	chk "K 只给 --check 不给目标 → rc=1" "$RC" "1"
	has "K 缺目标时给出用法提示" "$ERR" "缺少目标"

	# stdout 纪律在 --file 模式下同样成立（调用方会 `n="$(...)"` 取这个数字）
	K_S="$WORK/K-stdout"; mkdir -p "$K_S"; cp "$LUCI_CGI" "$K_S/cgi"
	run_pin --file "$K_S/cgi"
	chk "K --file 的 stdout 是纯数字" \
		"$(printf '%s' "$OUT" | tr -d '0-9' | grep -c . || true)" "0"
	chk "K --file 的 stdout 只有 1 行" "$(printf '%s\n' "$OUT" | grep -c . || true)" "1"
else
	no "K 用例前提：vendor/luci 的两个入口存在" \
		"缺少 $LUCI_CGI 或 $LUCI_RPC（先运行 scripts/fetch-luci-vendor.sh）"
fi

# =============================================================================
printf '\n\033[1m════════════════════════════════════════\033[0m\n'
printf '  \033[32mPASS %d\033[0m   \033[31mFAIL %d\033[0m\n' "$PASS" "$FAIL"
printf '\033[1m════════════════════════════════════════\033[0m\n'
[ "$FAIL" -eq 0 ] || exit 1
exit 0
