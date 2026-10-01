#!/usr/bin/env bash
# =============================================================================
# 把上游脚本对「系统 lua」的依赖，钉死到一个**绝对路径的 Lua 5.1**
# -----------------------------------------------------------------------------
# 为什么必须有这一步（证据见 docs/04-ubus依赖图谱.md §2.3）：
#
#   OpenWrt 上系统的 `lua` 只可能是 5.1，所以上游脚本可以放心地写
#     #!/usr/bin/lua          （8 个 openclash_*.lua）
#     lua /usr/share/openclash/openclash_version.lua   （openclash_core.sh:57 等）
#   我们为 Lua 5.1 编译的 nixio.so / lucihttp.so / ubus.so / luci.ip.so 也就能
#   被正确加载。
#
#   Debian/Ubuntu 上这个前提**不成立**：
#     Debian 用 update-alternatives 的 `lua-interpreter` 组提供 /usr/bin/lua，
#     候选优先级   lua5.1 = 110  <  lua5.2 = 120  ≈ lua5.3 = 120  <  lua5.4 = 130
#     于是只要这台机器上还装着 lua5.4，/usr/bin/lua 就指向 5.4。我们的 5.1
#     二进制模块在 5.4 下会以 `undefined symbol: lua_...` / ABI 不符的方式失败，
#     而症状和「Lua 搜索路径没桥接对」几乎一样 —— 都是"加载失败"。
#     两种故障必须从源头区分开，不能留到排障时猜。
#
#   还有一种更隐蔽的形态：`#!/usr/bin/env lua`（luci-base 的 rpcd 脚本就是），
#   `env` 走的也是 PATH，同样会被 lua5.4 劫持 —— 本脚本一并处理。
#
# 为什么是「改写为绝对路径」而不是「注册 update-alternatives」：
#   1) 注册 alternatives 会改动**全系统**的 `lua` 默认解释器，对用户不礼貌；
#      更关键的是：该组若已被置为 manual 模式，新注册的高优先级候选**不会**
#      自动生效 —— 等于没有保证。绝对路径没有这个盲区。
#   2) 不碰系统既有的 alternatives 组，与 lua5.1 包互不干扰，卸载也无需回滚。
#
# 用法：
#   runtime/upstream/pin-lua-interpreter.sh --dir <目录>            改写（原地）
#   runtime/upstream/pin-lua-interpreter.sh --dir <目录> --dry-run   只报告不改
#   runtime/upstream/pin-lua-interpreter.sh --check <目录>          只校验不变量
#   runtime/upstream/pin-lua-interpreter.sh --file <路径>           只处理指定文件
#   runtime/upstream/pin-lua-interpreter.sh --file <路径> --check   只校验指定文件
#   runtime/upstream/pin-lua-interpreter.sh --list
#
# 为什么需要 --file（两个理由都是实测出来的，不是"顺手加的灵活性"）：
#
#   a) **上游存在没有扩展名的 lua 入口**。
#      `luci-base/htdocs/cgi-bin/luci`（整个 Web UI 的 CGI 入口）与
#      `luci-base/root/usr/libexec/rpcd/luci`（rpcd 的 Lua 插件）都叫 `luci`，
#      **没有扩展名**；而 --dir 是按 EXTS（默认 "lua sh"）做 `-name '*.<ext>'`
#      过滤的 —— 也就是说 --dir **永远选不到这两个文件**，它们的
#      `#!/usr/bin/lua`（以及 `#!/usr/bin/env lua`）会被静默漏掉。
#
#   b) **vendored 第三方树里存在"散文里恰好出现 lua 一词"的注释**。
#      实测 `vendor/luci/luci-lib-nixio/root/usr/lib/lua/nixio/fs.lua` 的 `--[[`
#      块注释第 2 行就是 `nixio - Linux I/O library for lua`；axTLS 的示例文件里
#      还有 `-- > [lua] axssl s_server -?`。对整棵 vendor 树跑宽判据会**必然失败**
#      （实测 3 个文件误报）。而我们的契约只覆盖「**我们安装、且会被执行**的入口」，
#      不是整棵第三方源码树 —— 所以正确做法是按**显式路径**钉定，而不是放宽判据
#      （放宽会连带削弱 upstream/openclash 那棵树上的告警能力）。
#
# ⚠️ `--file` 与 `--dir` / `--check <目录>` **不能混用**：两者的范围语义重叠，
#    混用会得到一个说不清的扫描范围 —— 直接拒绝比猜更安全。
#
# 环境变量：
#   LUA_BIN   目标解释器（默认 /usr/bin/lua5.1）
#   EXTS      参与扫描的扩展名，空格分隔（默认 "lua sh"）
#   V=1       逐条打印被改写的行
#
# ⚠️ stdout / stderr 的分工（本仓库踩过两次这个坑，务必保持）：
#     **人类可读的日志一律走 stderr；stdout 只输出一个整数**（被改写的处数）。
#     这样调用方 `n="$(...)"` 拿到的就一定是干净的数字。若把日志写进 stdout，
#     命令替换会把日志一起当成返回值 —— 之前 vlog 与 fetch_openwrt_lib 都因此
#     产出过带 ANSI 转义的多行"返回值"。
# =============================================================================
set -euo pipefail

LUA_BIN="${LUA_BIN:-/usr/bin/lua5.1}"
EXTS="${EXTS:-lua sh}"

log()  { printf '\033[1;36m[pin-lua]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[pin-lua]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[pin-lua]\033[0m %s\n' "$*" >&2; exit 1; }
vlog() { [ "${V:-0}" = "1" ] && printf '\033[2m[pin-lua]\033[0m %s\n' "$*" >&2 || true; }

# -----------------------------------------------------------------------------
# 规则定义（单一事实来源，--list 与改写共用，避免文档与实现漂移）
# -----------------------------------------------------------------------------
# 规则 1：shebang。三种形态一并覆盖 ——
#   #!/usr/bin/lua        （上游 openclash_*.lua）
#   #!/usr/bin/env lua    （luci-base 的 rpcd/luci；env 走 PATH，同样会被劫持）
#   #!lua                 （极少见，但改写成本为零）
# 必须锚定整行（`$`），否则会误伤 `#!/usr/bin/lua5.1`。
SHEBANG_RE='^#![[:space:]]*(/usr/bin/env[[:space:]]+|/usr/local/bin/|/usr/bin/)?lua[[:space:]]*$'

# 规则 2：命令位置上的裸 `lua <绝对路径>`（显式调用，只改 shebang 覆盖不到）。
# 前一个字符不能是 字母/数字/下划线/点/斜杠 —— 这条排除类同时保证了：
#   · `/usr/bin/lua5.1 /path` 不会被二次匹配（前面是 `/`），改写天然幂等；
#   · `lua5.1 /path` 不会被匹配（`lua` 后面紧跟 `5` 而非空格）。
BARE_CALL_RE='(^|[^[:alnum:]_./])lua[[:space:]]+/'

# -----------------------------------------------------------------------------
# 残留判据（改写后必须为 0）——刻意比上面的改写规则**更宽**
# -----------------------------------------------------------------------------
# 关键设计：**改写规则窄，残留判据宽**。
#
#   改写规则只覆盖已经穷尽测绘、且改写绝对安全的形态（shebang + `lua <绝对路径>`）。
#   残留判据则匹配「命令行位置上一切裸 lua」——包括我们**没有**改写过的形态，
#   例如 `lua -e '...'`、`lua "$f"`、`command -v lua`。
#
#   为什么要这么不对称：改写规则一旦写宽，就会去动"字符串/注释里恰好含 lua
#   这个词"的位置（例如 `echo "lua is nice"`），把无害文本改坏；而残留判据不
#   改写任何东西，最坏后果只是**多报**，人一眼就能判断。
#
#   于是结果正是「上游同步 + 冲突告警」要的形态：
#     · 已知形态  -> 自动改写，静默通过；
#     · 未知形态  -> 构建**失败**并打印 file:line，交人复核后补一条规则，
#                    而不是打出一个"看起来没问题、实际按系统 lua 版本随机行为"
#                    的包。
#
# 正则说明（实测对上游 8 个 .lua + 全部 .sh 只命中已知的 11 处，无误报）：
#   分支 1  `^#!.*lua\s*$`           shebang 形态（含 /usr/bin/env lua）
#                                   不会误伤 `#!/usr/bin/lua5.1`：因为 lua 后面
#                                   紧跟 `5` 而非行尾。
#   分支 2  `(^|[^[:alnum:]_./-])lua([^[:alnum:]_.-]|$)`   命令位置的 lua
#                                   前置类排除 `/`，所以 `/usr/bin/lua5.1` 里那个
#                                   lua 不会被匹配（这是"改写后能归零"的根本原因）；
#                                   后置类排除 alnum/`_`/`.`/`-`，从而 `lua5.1`、
#                                   `lua-xx`、`luci` 都不会被误判。
RESIDUAL_RE='^#![[:space:]]*.*lua[[:space:]]*$|(^|[^[:alnum:]_./-])lua([^[:alnum:]_.-]|$)'

# -----------------------------------------------------------------------------
# ⚠️ sed 的分隔符必须避开正则里用到的字符
# -----------------------------------------------------------------------------
# 上面两条正则都用 `|` 表示 alternation（grep -E 语义）。若 sed 也用 `|` 当
# 分隔符，sed 会把正则里的 `|` 误判为表达式结束，报
#     sed: -e expression #1, char NN: unknown option to `s'
# 这里统一改用 `,` —— 正则与替换文本里都不含它。
# 下面这条断言把「分隔符不能出现在正则里」变成机器可检的约束，而不是注释。
SED_DELIM=','
case "$SHEBANG_RE$BARE_CALL_RE" in
	*"$SED_DELIM"*) die "正则里出现了 sed 分隔符 '$SED_DELIM'，请改用别的分隔符" ;;
esac

DO_LIST=0
MODE=""
TARGET=""
EXPLICIT_FILES=()

while [ $# -gt 0 ]; do
	case "$1" in
		--dir)      MODE=pin;    TARGET="${2:?--dir 需要一个目录}"; shift 2 ;;
		--dir=*)    MODE=pin;    TARGET="${1#*=}"; shift ;;
		--check)
			MODE=check
			# `--check` 的目录参数**可省**：不跟路径时表示"校验 --file 指定的那些
			# 文件"。判据是下一个 token 是否以 `-` 开头（即它是另一个选项）或不存在。
			# 这样 `--check <目录>` 与 `--check --file <路径>` 两种写法都成立，且
			# 与既有的 `--check <目录>` 调用点完全兼容。
			case "${2:-}" in
				""|-*) ;;
				*)     TARGET="$2"; shift ;;
			esac
			shift ;;
		--check=*)  MODE=check; TARGET="${1#*=}"; shift ;;
		# ⚠️ `--file` 刻意**不设置** MODE：否则 `--check --file A` 里的 `--file`
		#    会把 MODE 从 check 覆盖成 pin，于是"校验"变成"改写"—— 那是最危险的
		#    一类 bug（验证动作产生副作用）。MODE 的补全放在下面统一做。
		--file)     EXPLICIT_FILES+=( "${2:?--file 需要一个文件路径}" ); shift 2 ;;
		--file=*)   EXPLICIT_FILES+=( "${1#*=}" ); shift ;;
		--dry-run)  DRY_RUN=1; shift ;;
		--list)     DO_LIST=1; shift ;;
		-h|--help)
			# 打印文件头注释块：用**自锚定范围**（从第 2 行到闭合的 `# ====...` 行），
			# 而不是写死行号 —— 否则头部长一寸，帮助文本就悄悄溢出到代码里。
			sed -n '2,/^# =\{10,\}$/p' "$0" | sed 's/^# \{0,1\}//' >&2
			exit 0 ;;
		*)          die "未知参数：$1" ;;
	esac
done
DRY_RUN="${DRY_RUN:-0}"
# 只给 `--file` 而没给模式时，默认是"改写"
if [ "${#EXPLICIT_FILES[@]}" -gt 0 ] && [ -z "$MODE" ]; then
	MODE=pin
fi

if [ "$DO_LIST" = 1 ]; then
	{
		printf '目标解释器 : %s\n' "$LUA_BIN"
		printf '扫描扩展名 : %s\n' "$EXTS"
		printf '\n改写规则：\n'
		printf '  [1] shebang  -> #!%s\n' "$LUA_BIN"
		printf '      匹配: %s\n' "$SHEBANG_RE"
		printf '  [2] 裸调用   -> %s <绝对路径>\n' "$LUA_BIN"
		printf '      匹配: %s\n' "$BARE_CALL_RE"
		printf '\n残留判据（--check，改写后必须为 0）：\n'
		printf '  匹配: %s\n' "$RESIDUAL_RE"
		printf '  —— 比改写规则**更宽**：命中但未被改写的，即为"未识别的调用形态"，\n'
		printf '     会直接构建失败并列出 file:line，交人复核，而不是静默放行。\n'
	} >&2
	exit 0
fi

[ -n "$MODE" ] || die "缺少目标：--dir <目录>、--check <目录> 或 --file <路径>"
# 范围互斥：--file（显式路径）与 --dir/--check <目录>（按扩展名枚举）语义重叠
if [ "${#EXPLICIT_FILES[@]}" -gt 0 ] && [ -n "$TARGET" ]; then
	die "--file 与 --dir / --check <目录> 不能混用（范围语义重叠，容易搞错扫描范围）"
fi
if [ "${#EXPLICIT_FILES[@]}" -eq 0 ] && [ -z "$TARGET" ]; then
	die "缺少目标：请给 --dir <目录>（或 --check <目录>），或用 --file <路径> 指定文件"
fi
# TARGET 只在"目录模式"下有值（--file 模式下为空），故目录校验必须带条件
if [ -n "$TARGET" ] && [ ! -d "$TARGET" ]; then
	die "目录不存在：$TARGET"
fi

# -----------------------------------------------------------------------------
# sed 规则自检：用一个合成样本先把"改写表达式本身"验一遍
# -----------------------------------------------------------------------------
# 为什么值得：上面两条 sed 表达式一旦成立性被破坏（分隔符冲突、漏了 -E、
# 正则写成 BRE 等），报错会发生在**处理真实文件时**，而且 sed 的错误信息
# （"unknown option to `s'" / "invalid reference \1"）不会告诉你是哪条规则、
# 更不会提示"上游可能改过写法"。先在合成样本上跑一遍，能把"表达式坏了"与
# "上游内容变了"这两类失败彻底分开 —— 二者的排查方向完全相反。
#
# 实现上刻意**不落临时文件**：把同一组 -e 表达式通过管道喂给非 -i 的 sed 即可，
# 表达式逐字相同，却省掉了创建/删除临时文件（在受限环境下 rm 一个带盘符的
# 临时路径反而会引入新的失败面）。
_selftest_sed() {
	local out rc=0
	out="$(printf '%s\n' '#!/usr/bin/lua' 'lua /usr/share/openclash/x.lua "a"' \
		| sed -E \
			-e "s${SED_DELIM}$SHEBANG_RE${SED_DELIM}#!$LUA_BIN${SED_DELIM}" \
			-e "s${SED_DELIM}$BARE_CALL_RE${SED_DELIM}\1$LUA_BIN /${SED_DELIM}g" \
		2>&1)" || rc=$?
	if [ "$rc" != 0 ]; then
		die "sed 规则自检失败：表达式无法执行（分隔符冲突？漏了 -E？）
     sed 输出：$out"
	fi
	case "$out" in
		*"#!$LUA_BIN"*) ;;
		*) die "sed 规则自检失败：shebang 形态未被改写。实际得到：$out" ;;
	esac
	case "$out" in
		*"$LUA_BIN /usr/share/openclash/x.lua"*) ;;
		*) die "sed 规则自检失败：裸 lua 调用未被改写。实际得到：$out" ;;
	esac
	vlog "sed 规则自检通过"
}
[ "$MODE" = pin ] && _selftest_sed

# -----------------------------------------------------------------------------
# 文件枚举
#   目录模式：只挑指定扩展名，且**只挑文本文件**
#             -type f 之外加 `! -l`：避免 sed -i 跟着软链改到别处（staging 树里可能有）
#   显式模式：路径由调用方给定，**刻意不过滤扩展名**（这正是 --file 的存在理由之一：
#             cgi-bin/luci 与 rpcd/luci 都没有扩展名），但仍挡住软链与目录。
# -----------------------------------------------------------------------------
FILES=()
if [ "${#EXPLICIT_FILES[@]}" -gt 0 ]; then
	for _p in "${EXPLICIT_FILES[@]}"; do
		[ -e "$_p" ] || die "--file 指定的路径不存在：$_p"
		# 与目录模式同样的理由：sed -i 会跟着软链改到别处去
		[ -L "$_p" ] && die "--file 不接受软链：$_p"
		[ -f "$_p" ] || die "--file 指定的不是普通文件：$_p"
		# 去重：同一路径给两次会让第 1 遍把它计两次，TOTAL 于是虚高。
		# （第 1 遍是只读的，所以同一个文件第二次算出来的 narrow 与第一次相同。）
		_dup=0
		for _q in "${FILES[@]}"; do
			[ "$_q" = "$_p" ] && _dup=1 && break
		done
		[ "$_dup" = "1" ] || FILES+=( "$_p" )
	done
	SCOPE_DESC="${#FILES[@]} 个显式指定的文件"
else
	_find_expr=()
	for e in $EXTS; do
		_find_expr+=( -o -name "*.$e" )
	done
	_find_expr=( "${_find_expr[@]:1}" )   # 去掉开头多出来的 -o

	while IFS= read -r -d '' _f; do
		FILES+=( "$_f" )
	done < <(find "$TARGET" -type f ! -type l \( "${_find_expr[@]}" \) -print0 2>/dev/null | sort -z)
	SCOPE_DESC="$TARGET"
fi

# 扫描到 0 个文件必须**硬失败**，不能只是 warn。
# 理由：这与本项目此前踩过的 "dns_prep 0/0 被当成绿色" 是同一类缺陷 ——
# 一个"什么都没检查"的结果绝不能报成功。真实触发场景很具体：调用方把 $TARGET
# 传成了某个不存在的子目录、或上游拷贝那一步没产出内容、或 --file 路径写错，
# 于是这里"通过"，而打出的包会保留原始的裸 `lua` 调用，装到装有 lua5.4 的
# 机器上就静默失效。
if [ "${#FILES[@]}" -eq 0 ]; then
	die "在 $SCOPE_DESC 里没有找到可处理的文件 —— 扫描到 0 个文件不能算通过。
     常见原因：--dir 传成了不存在的子目录、上游源码那一步没产出内容、
     或 --file 写错了路径。请先确认目标里确实有交付给运行时的脚本，再重跑。"
fi

# -----------------------------------------------------------------------------
# 用同一套判据对**同一范围**再校验一次
# -----------------------------------------------------------------------------
# 供"0 命中"的歧义判定与最终全局复核使用。
# ⚠️ 不能简单写成 `bash "$0" --check "$TARGET"`：--file 模式下 TARGET 是空的，
#    子进程会因为"缺少目标"而立刻退出（rc≠0），于是**所有**校验都会被误判成
#    "不通过" —— 而"不通过"在 0 命中分支里意味着直接把构建打断。所以这里必须
#    把范围原样传下去。
_check_again() {
	if [ -n "$TARGET" ]; then
		bash "$0" --check "$TARGET"
	else
		_args=()
		for _p in "${EXPLICIT_FILES[@]}"; do
			_args+=( --file "$_p" )
		done
		bash "$0" --check "${_args[@]}"
	fi
}

# -----------------------------------------------------------------------------
# --check：只校验残留判据，不改任何东西（幂等，可随时跑）
# -----------------------------------------------------------------------------
if [ "$MODE" = check ]; then
	_bad=0
	for f in "${FILES[@]}"; do
		if grep -qE "$RESIDUAL_RE" "$f" 2>/dev/null; then
			if [ "$_bad" = 0 ]; then
				warn "以下位置仍存在「命令位置的裸 lua」（即仍依赖系统 lua 的版本）："
			fi
			grep -nE "$RESIDUAL_RE" "$f" 2>/dev/null | sed "s|^|    ${f}:|" >&2
			_bad=$((_bad + 1))
		fi
	done
	if [ "$_bad" != 0 ]; then
		die "$_bad 个文件未通过残留判据（应全部指向 $LUA_BIN）"
	fi
	log "残留判据通过：${#FILES[@]} 个文件均已指向 $LUA_BIN"
	printf '0\n'
	exit 0
fi

# -----------------------------------------------------------------------------
# --dir：原地改写（两遍式：先整树体检，再落盘）
# -----------------------------------------------------------------------------
# 为什么必须是两遍，而不是"边检查边改写"：
#   单遍实现下，失败发生在 for 循环中途 —— 排序在失败文件**之前**的文件已经
#   被 sed 改过了。于是"发现未识别形态即中止，文件未被改动"这句话是**假的**：
#   树会被留在"一半已钉定、一半没动"的状态，而失败信息只提到一个文件，使用者
#   完全无从知道其余文件已被动过。本机实测一次真实场景，中止时已有 7 个文件被改。
#
#   两遍式把「判断」与「写入」彻底分开：
#     第 1 遍（只读）  枚举整棵树，逐文件比较窄规则命中数与宽判据命中数，
#                      登记违规清单与待改写清单；**不写任何文件**。
#     第 2 遍（写入）  只对第 1 遍就确认安全的文件落 sed。
#   任何违规都在进入第 2 遍之前 die，所以失败时扫描范围内**逐字节没有任何变化**
#   （目录模式 = $TARGET；--file 模式 = 那些显式路径）。
#   代价是每个文件多扫一遍（量级几十个文件，可忽略）。上层依赖这个性质：
#   CI 的「每日同步冲突告警」与 build-deb.sh 的失败处理都假设"失败 = 树没被动过"，
#   因而可以"修完规则直接重跑"，不需要回滚半成品。这条不能为省一遍扫描而放弃。

# ---- 第 1 遍：只读体检（全程不写任何文件） ----
TOTAL=0
PLAN_FILES=()
PLAN_COUNTS=()
VIOL_FILES=()
VIOL_NARROW=()
VIOL_BROAD=()

for f in "${FILES[@]}"; do
	# 两个计数刻意用**不同宽度**的判据（理由见上方「残留判据」注释）：
	#   narrow = 窄规则命中 = 我们将要改写的处数
	#   broad  = 宽判据命中 = 该文件里一切"命令位置的裸 lua"
	# 宽判据的正则包含窄规则的正则，故恒有 broad >= narrow。
	# 用 grep -c 而不是 grep -q：兼得计数与判空。
	# `|| true` 是必需的：grep 无匹配时返回 1，在 set -e 下会让命令替换失败。
	narrow="$(grep -cE "$SHEBANG_RE|$BARE_CALL_RE" "$f" 2>/dev/null || true)"
	broad="$(grep -cE "$RESIDUAL_RE" "$f" 2>/dev/null || true)"
	narrow="${narrow:-0}"; broad="${broad:-0}"
	[ "$broad" -gt 0 ] || continue

	# broad > narrow ⇒ 文件里存在**我们没测绘过**的写法。登记为违规，不猜、不改。
	if [ "$broad" -gt "$narrow" ]; then
		VIOL_FILES+=( "$f" )
		VIOL_NARROW+=( "$narrow" )
		VIOL_BROAD+=( "$broad" )
		continue
	fi

	PLAN_FILES+=( "$f" )
	PLAN_COUNTS+=( "$narrow" )
	TOTAL=$((TOTAL + narrow))
done

CHANGED="${#PLAN_FILES[@]}"

# ---- 违规：一次列全所有文件，然后失败（此刻整树仍未动） ----
# 为什么把所有违规文件都报出来，而不是只报第一个：上游同步场景下，一次上游改动
# 可能同时引入多处新写法。只报第一个会让排查变成"改一处 -> 重跑 -> 又冒一处"的
# 挤牙膏，而每轮重跑都要几分钟。一次列全才能一轮改完。
if [ "${#VIOL_FILES[@]}" -gt 0 ]; then
	{
		echo "在 $SCOPE_DESC 里发现 ${#VIOL_FILES[@]} 个文件含**未识别的 lua 依赖形态**。"
		echo "本次运行是**整树原子**的：体检在改写之前完成，下面列出的位置一处未被改动，"
		echo "范围内也**没有任何文件**被改动 —— 修完规则直接重跑即可，无需回滚。"
		for i in "${!VIOL_FILES[@]}"; do
			echo ""
			echo "  ${VIOL_FILES[$i]}"
			echo "    窄规则覆盖 ${VIOL_NARROW[$i]} 处，宽判据命中 ${VIOL_BROAD[$i]} 处"
			grep -nE "$RESIDUAL_RE" "${VIOL_FILES[$i]}" 2>/dev/null | sed 's/^/      /' || true
		done
		echo ""
		echo "两种出路，取决于人工确认的结果："
		echo "  (a) 它确实在**调用系统 lua**（如 lua -e '...'）"
		echo "      -> 到本脚本「规则定义」补一条改写规则（BARE_CALL_RE 或新增一条）；"
		echo "  (b) 它只是**字符串/注释里恰好出现了 lua 这个词**（如 echo \"lua is nice\"）"
		echo "      -> 不要改文件，而应收窄 RESIDUAL_RE，让判据不再命中这类文本。"
		echo "宁可多报也不能漏报：漏报的后果是运行时按系统 lua 版本随机行为，"
		echo "表现为 .so 加载失败，且与「搜索路径没桥接对」极难区分。"
	} >&2
	die "未识别的 lua 依赖形态：${#VIOL_FILES[@]} 个文件（详见上方清单）"
fi

# ---- dry-run：体检已完成，直接汇报（不落盘） ----
# 注意 dry-run 也走"0 命中"的歧义判定：一个 dry-run 报出 "0 处 / rc=0"、而树其实
# 处于"上游改了调用写法"的状态，是最容易误导人的输出形态（看着一切正常）。因此
# 下面与真实运行共用同一套判据，不另开一条宽松路径。
if [ "$DRY_RUN" = "1" ]; then
	if [ "$TOTAL" = 0 ]; then
		if _check_again >/dev/null 2>&1; then
			warn "dry-run：无需改写，$SCOPE_DESC 已是钉定状态（幂等重跑）"
			printf '0\n'
			exit 0
		fi
		die "dry-run：一处 lua 依赖都没命中，且残留判据也不通过
     —— 上游布局/调用写法变了，请复核本脚本头部「规则定义」并更新正则"
	fi
	for i in "${!PLAN_FILES[@]}"; do
		warn "[dry-run] ${PLAN_FILES[$i]}（命中 ${PLAN_COUNTS[$i]} 处）"
		grep -nE "$SHEBANG_RE|$BARE_CALL_RE" "${PLAN_FILES[$i]}" 2>/dev/null \
			| sed 's/^/        /' >&2 || true
	done
	warn "dry-run 结束：将改写 $TOTAL 处，涉及 $CHANGED 个文件（未落盘）"
	printf '%s\n' "$TOTAL"
	exit 0
fi

# ---- 第 2 遍：落盘（只处理第 1 遍已确认安全的文件） ----
for i in "${!PLAN_FILES[@]}"; do
	f="${PLAN_FILES[$i]}"
	before="${PLAN_COUNTS[$i]}"

	# ⚠️ 只做「行内定点替换」，不重写整行：
	#    上游脚本里有大量 sed/awk 表达式本身含 `/` 与特殊字符，任何"整行重建"
	#    都有可能破坏它们。两条 -e 分别对应规则 1 与规则 2。
	#
	# 两个必须同时满足的条件，缺一个都会失败（都实测踩过）：
	#   · `-E`：上面两条正则是按 **ERE** 写的（给 grep -E 用）。sed 默认是 BRE，
	#     在 BRE 里 `(` `)` 是字面字符、没有捕获组，于是规则 2 的 RHS `\1` 会报
	#         sed: -e expression #2: invalid reference \1 on `s' command's RHS
	#     加上 -E 后，"同一份正则既给 grep -E 又给 sed"才真正成立（单一事实来源）。
	#   · 分隔符用 $SED_DELIM（不是 `|`）：正则在用 `|` 表示 alternation，
	#     拿 `|` 当分隔符会让 sed 提前认为表达式结束，报
	#         sed: -e expression #1: unknown option to `s'
	sed -i -E \
		-e "s${SED_DELIM}$SHEBANG_RE${SED_DELIM}#!$LUA_BIN${SED_DELIM}" \
		-e "s${SED_DELIM}$BARE_CALL_RE${SED_DELIM}\1$LUA_BIN /${SED_DELIM}g" \
		"$f"

	if [ "${V:-0}" = "1" ]; then vlog "改写 $f（$before 处）"; fi

	# 逐文件复核：改写后该文件不应再有任何残留（用**宽**判据，顺带确认
	# 本次 sed 没有把 lua 改写成另一种仍会被判据命中的形态）。
	after="$(grep -cE "$RESIDUAL_RE" "$f" 2>/dev/null || true)"
	[ "${after:-0}" = "0" ] || die "改写后 $f 仍残留 ${after} 处（规则不匹配，请检查）"
done

# 0 命中其实是两种**方向完全相反**的情况，必须区分，不能一律当失败：
#   a) 这棵树之前已经被钉定过（幂等重跑）              -> 正常，静默通过
#   b) 上游把调用换成了我们没见过的写法（改写没命中）  -> 必须失败
# 判据就是同一套残留判据：能通过 = a)，不能通过 = b)。
if [ "$TOTAL" = 0 ]; then
	if _check_again >/dev/null 2>&1; then
		warn "无需改写：$SCOPE_DESC 已是钉定状态（幂等重跑）"
		printf '0\n'
		exit 0
	fi
	die "一处 lua 依赖都没命中，且残留判据也不通过
     —— 上游布局/调用写法变了，请复核本脚本头部「规则定义」并更新正则"
fi

# 全局复核（--check 的同一套判据），避免"逐文件过了但漏了某个扩展名"的情况
_check_again >/dev/null

log "已钉定 $TOTAL 处 -> $LUA_BIN（涉及 $CHANGED 个文件）"
# stdout 只留这一个整数（见文件头 stdout/stderr 分工说明）
printf '%s\n' "$TOTAL"
