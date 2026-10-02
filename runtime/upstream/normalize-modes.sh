#!/usr/bin/env bash
# =============================================================================
# 把「带 shebang 的脚本」的可执行位归一到 0755
# -----------------------------------------------------------------------------
# 为什么必须有这一步（不是洁癖，是实测出来的静默故障）：
#
#   上游 OpenWrt 的 ipkg 直接从 git 工作区 `$(CP) root/*` 打包，脚本的可执行位
#   由**上游仓库里的 100755** 保证。我们的链路是
#       sync-upstream.sh 稀疏检出
#     -> 在 core.filemode=false 的主机（Windows）上提交
#     -> CI / 目标机检出
#   中间任何一环都会把它们压平成 100644。实测打出的 .deb 里
#       /etc/init.d/openclash                 -rw-r--r--
#       /usr/share/openclash/*.sh   （25 个） -rw-r--r--
#       /usr/share/openclash/*.lua  （ 8 个） -rw-r--r--
#   全部没有可执行位。
#
#   后果不是"少一个 chmod"。上游是**直接执行**这些文件的，例如：
#       openclash_update.sh:91  /usr/share/openclash/openclash_core.sh "Meta" "$1" "$2" >/dev/null 2>&1
#       yml_groups_set.sh:330   /usr/share/openclash/yml_proxys_set.sh "$CONFIG_FILE" >/dev/null 2>&1
#       yml_groups_get.sh:252   /usr/share/openclash/yml_proxys_get.sh "$CONFIG_FILE" >/dev/null 2>&1
#       openclash_watchdog.sh:396  /usr/share/openclash/openclash_oix_checkin.lua >/dev/null 2>&1
#       openclash.sh:37            $(/usr/share/openclash/openclash_urlencode.lua "$1")
#   0644 下这些调用全是 Permission denied，而调用点几乎都带 `>/dev/null 2>&1`
#   —— 症状是「内核下载失败 / 订阅不更新 / 配置生成不出来」，**一条报错都没有**。
#   这类"静默失效 + 症状指向别处"的故障正是本项目最贵的那种，必须从源头消除。
#
#   另外 /etc/init.d/openclash 直接影响启动：本包 systemd 单元写的是
#       ExecStart=/etc/init.d/openclash boot
#   0644 会让服务**根本起不来**，而 journalctl 只会留一句 exit code 203/EXEC。
#
# 为什么按「文件自己有没有 shebang」判定，而不是记一份清单：
#   清单会漂。上游每次同步都可能增删脚本（这次是 33 个，下次可能是 40 个），
#   记清单等价于给自己挖一个"新增的脚本忘了加进清单"的坑。shebang 是文件
#   **自己声明**的"我是可执行入口"，以它为准不会漏，也不会误伤数据文件。
#
# 为什么两个调用点（build-deb.sh / tests/e2e/linux/run-e2e.sh）共用本脚本：
#   两处都要做同一件事，各写一遍就会各自漂移 —— 一处改了判据另一处忘了，
#   于是 e2e 绿着而实际包是坏的（正是上面那种静默故障）。共用一份实现，
#   判据与日志才有单一事实来源。
#
# 用法：
#   runtime/upstream/normalize-modes.sh --dir <目录>         归一（原地 chmod）
#   runtime/upstream/normalize-modes.sh --check <目录>       只校验不改动
#   runtime/upstream/normalize-modes.sh --file <路径> [...]  只处理指定文件
#
# 退出码：--check 时"存在缺位的 shebang 脚本"返回 1；其余情形 0。
#
# ⚠️ stdout / stderr 的分工（与 pin-lua-interpreter.sh 同一条纪律）：
#     **人类可读的日志一律走 stderr；stdout 只输出一个整数**（被归一的处数）。
#     这样调用方 `n="$(...)"` 拿到的就一定是干净的数字。
# =============================================================================
set -euo pipefail

# ⚠️ MODE 初值必须是空串，**不能**写成 `MODE="${1:-}"`：
#   $1 在这里是 `--dir` / `--check` 这样的**选项**，把它当作初始模式会让
#   `MODE="${MODE:-norm}"` 永远取不到默认值（MODE 已非空且等于 "--dir"），
#   于是落到 case 的 *) 分支报「未知模式：--dir」。实测踩到过。
MODE=""
TARGET=""
EXPLICIT_FILES=()

log()  { printf '\033[1;36m[norm-mode]\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[1;33m[norm-mode]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[norm-mode]\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
	# 自锚定范围：从第 2 行到闭合的 `# ====...` 行，避免写死行号导致帮助溢出
	sed -n '2,/^# =\{10,\}$/p' "$0" | sed 's/^# \{0,1\}//' >&2
}

while [ $# -gt 0 ]; do
	case "$1" in
		--dir)      MODE="${MODE:-norm}"; TARGET="${2:?--dir 需要一个目录}"; shift 2 ;;
		--dir=*)    MODE="${MODE:-norm}"; TARGET="${1#*=}"; shift ;;
		--check)
			MODE=check
			case "${2:-}" in
				""|-*) ;;
				*)     TARGET="$2"; shift ;;
			esac
			shift ;;
		--check=*)  MODE=check; TARGET="${1#*=}"; shift ;;
		--file)     MODE="${MODE:-norm}"; EXPLICIT_FILES+=( "${2:?--file 需要一个文件路径}" ); shift 2 ;;
		--file=*)   MODE="${MODE:-norm}"; EXPLICIT_FILES+=( "${1#*=}" ); shift ;;
		-h|--help)  usage; exit 0 ;;
		*)          die "未知参数：$1（用法见 --help）" ;;
	esac
done

[ -n "$MODE" ] || { usage; die "缺少目标：--dir <目录>、--check <目录> 或 --file <路径>"; }

if [ "${#EXPLICIT_FILES[@]}" -gt 0 ] && [ -n "$TARGET" ]; then
	die "--file 与 --dir / --check <目录> 不能混用（范围语义重叠）"
fi

# -----------------------------------------------------------------------------
# 文件枚举
# -----------------------------------------------------------------------------
FILES=()
if [ "${#EXPLICIT_FILES[@]}" -gt 0 ]; then
	for _p in "${EXPLICIT_FILES[@]}"; do
		[ -e "$_p" ] || die "--file 指定的路径不存在：$_p"
		[ -f "$_p" ] || die "--file 指定的不是普通文件：$_p"
		FILES+=( "$_p" )
	done
	SCOPE_DESC="${#FILES[@]} 个显式指定的文件"
else
	[ -n "$TARGET" ] || { usage; die "缺少目标目录"; }
	[ -d "$TARGET" ] || die "目录不存在：$TARGET"
	# 只挑普通文件、跳过软链：chmod 跟着软链会改到链指向的目标上去
	while IFS= read -r -d '' _f; do
		FILES+=( "$_f" )
	done < <(find "$TARGET" -type f ! -type l -print0 2>/dev/null | sort -z)
	SCOPE_DESC="$TARGET"
fi

# 与 pin-lua-interpreter.sh 同一条纪律：扫描到 0 个文件不能算通过。
# 「什么都没检查」却报成功，是本仓库踩过的 "dns_prep 0/0 被当成绿色" 那一类缺陷。
if [ "${#FILES[@]}" -eq 0 ]; then
	die "在 $SCOPE_DESC 里没有找到任何文件 —— 扫描到 0 个文件不能算通过。
     常见原因：--dir 传成了不存在的子目录，或上游拷贝那一步没产出内容。"
fi

# -----------------------------------------------------------------------------
# shebang 判定：文件头两个字节必须是 `#!`
# -----------------------------------------------------------------------------
# 用 `head -c 2` 而不是 `grep -m1 '^#!'`：
#   · 后者要读整个文件（这里最大的是 189KB 的 init.d/openclash，量级无所谓，
#     但它是**文本**匹配，遇到 UTF-8 BOM 或非文本也不会报错，判据含糊）；
#   · 前者是纯字节判定，语义正好等于 shebang 的定义（内核 exec 也是看这两个字节）。
_has_shebang() {
	[ "$(head -c 2 "$1" 2>/dev/null)" = '#!' ]
}

case "$MODE" in
	check)
		_bad=0
		for f in "${FILES[@]}"; do
			_has_shebang "$f" || continue
			if [ ! -x "$f" ]; then
				[ "$_bad" -eq 0 ] && warn "以下带 shebang 的脚本缺少可执行位（会被 exec / 直接调用拒绝）："
				printf '    %s  %s\n' "$(stat -c %A "$f" 2>/dev/null)" "$f" >&2
				_bad=$((_bad + 1))
			fi
		done
		if [ "$_bad" -ne 0 ]; then
			die "$SCOPE_DESC 里 $_bad 个 shebang 脚本缺可执行位"
		fi
		log "可执行位判据通过：${#FILES[@]} 个文件里所有 shebang 脚本均为可执行"
		printf '0\n'
		exit 0
		;;
	norm)
		_n=0
		for f in "${FILES[@]}"; do
			_has_shebang "$f" || continue
			# 已经是 0755 就别碰：减少不必要的 mtime 变更，也让计数只反映"真正修了的"
			if [ ! -x "$f" ]; then
				chmod 0755 "$f"
				_n=$((_n + 1))
			fi
		done
		log "可执行位归一：${#FILES[@]} 个文件中修了 $_n 个 -> 0755（范围 $SCOPE_DESC）"
		# stdout 只留这一个整数（见文件头 stdout/stderr 分工说明）
		printf '%s\n' "$_n"
		;;
	*) die "未知模式：$MODE" ;;
esac
