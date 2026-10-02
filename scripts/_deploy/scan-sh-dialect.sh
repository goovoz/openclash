#!/usr/bin/env bash
# =============================================================================
# openclash-rt  上游 .sh 的 shebang↔ 方言一致性扫描
# -----------------------------------------------------------------------------
# 背景（2026-10-02 真机实测两次踩坑）：
#   1) uci-defaults:79 `source "/etc/openwrt_release"` —— 上游 shebang 是
#      `#!/bin/sh`，但 OpenClash 的 /etc/init.d 用 sh 跑它→ dash 无 source。
#   2) openclash_history_get.sh:43 同样问题：shebang `#!/bin/sh` 却用 source。
#      真机实测 sh → RC=127（命令找不到），bash → RC=0。
#
# 为什么会「在 OpenWrt 上没事」：busybox ash **支持** source 作为内建，
# 所以上游在 OpenWrt 上跑得通；换到 Debian 的 dash 就炸。这是
# 「L1 上游假定 OpenWrt 环境」的典型样本。
#
# 本脚本对每个上游 .sh 做：
#   1. 读 shebang，判定声明的解释器
#   2. 扫 bash-only 方言特征（source / [[ / == / =~ / 数组 / read -a / <<< 等）
#   3. **实跑对比**：sh vs bash 各跑一次（带timeout，喂无害参数），比对 RC
#   4. 分级输出：声明与实跑不一致 = 高危
#
# 用法： bash scripts/_deploy/scan-sh-dialect.sh [本地或已安装的 openclash 目录]
#        不传参数则扫 /usr/share/openclash（真机上跑）
# =============================================================================
set -u

TARGET="${1:-/usr/share/openclash}"
TIMEOUT_S="${TIMEOUT_S:-10}"
WORKDIR="$(mktemp -d 2>/dev/null || echo "/tmp/shdialect.$$")"
mkdir -p "$WORKDIR" 2>/dev/null || true
trap 'rm -rf "$WORKDIR" 2>/dev/null || true' EXIT

# bash-only 构造（dash 全部不支持或不语义一致）
BASH_ONLY_PATTERNS='(^|[[:space:]])source[[:space:]]
|(^|[[:space:]])\.[[:space:]]+["$/{]
|\[\[
|(^|[[:space:]])==[[:space:]]
|=~
|(^|[[:space:]])read[[:space:]]+-a
|(^|[[:space:]])declare[[:space:]]
|(^|[[:space:]])local[[:space:]]+-[a-z]
|(^|[[:space:]])mapfile
|(^|[[:space:]])readarray
|\$\{[a-zA-Z_][a-zA-Z0-9_]*\[@\]
|\$\{[a-zA-Z_][a-zA-Z0-9_]*\[[0-9]+\]
|(^|[[:space:]])shopt[[:space:]]
|(^|[[:space:]])set[[:space:]]+-o[[:space:]]+pipefail
|&>(?!\s*$)
|(^|[[:space:]])function[[:space:]]+[a-zA-Z_]'

if [ ! -d "$TARGET" ]; then
	printf '目标目录不存在: %s\n' "$TARGET" >&2
	exit 1
fi

printf '\n扫描目标: %s\n' "$TARGET"
SCRIPT_COUNT="$(find "$TARGET" -name '*.sh' 2>/dev/null | wc -l | head -1)"
printf '共 %s 个 .sh\n' "$SCRIPT_COUNT"
printf '\n%-36s %-8s %-5s %-5s %s\n' "文件" "shebang" "sh" "bash" "方言特征 / 判定"
printf -- '%.0s-' {1..100}; printf '\n'

HIGH_RISK=0
DIALECT=0
OK=0

# 用文件列表而非 while read，避免 find 输出里的 CR/尾空格干扰
LIST="$WORKDIR/scripts.lst"
find "$TARGET" -name '*.sh' 2>/dev/null | sort > "$LIST"

while IFS= read -r f; do
	[ -z "$f" ] && continue
	rel="${f#$TARGET/}"
	rel="$(printf '%s' "$rel" | tr -d '\r' | cut -c1-36)"
	shebang="$(head -1 "$f" 2>/dev/null | tr -d '\r')"
	case "$shebang" in
		*bash*)     decl="bash" ;;
		*/bin/sh*)  decl="sh" ;;
		*ash*)      decl="ash" ;;
		*)          decl="none" ;;
	esac

	# 方言特征命中项（注意 grep -c 会多行输出，必须 head -1 取单值）
	hits=""
	for pat in 'source ' '\[\[' '==' '=~' 'read -a' 'declare ' 'mapfile' 'readarray' 'shopt ' 'pipefail' 'function [a-zA-Z_]'; do
		n="$(grep -cE "$pat" "$f" 2>/dev/null | head -1)"
		n="${n:-0}"
		[ "$n" != "0" ] && hits="$hits ${pat%% *}($n)"
	done
	[ -z "$hits" ] && hits=" -"

	# 实跑对比（只对声明为 sh/ash 的做，bash 的必然一致）
	rc_sh="-"; rc_bash="-"
	if [ "$decl" = "sh" ] || [ "$decl" = "ash" ]; then
		timeout "$TIMEOUT_S" sh "$f" </dev/null >/dev/null 2>&1
		rc_sh=$?
		timeout "$TIMEOUT_S" bash "$f" </dev/null >/dev/null 2>&1
		rc_bash=$?
	fi

	# 定级
	flag=""
	if [ "$rc_sh" != "-" ] && [ "$rc_sh" != "$rc_bash" ]; then
		flag="<<< 高危"
		HIGH_RISK=$((HIGH_RISK+1))
	elif [ -n "${hits# -}" ]; then
		DIALECT=$((DIALECT+1))
		flag="(含方言)"
	else
		OK=$((OK+1))
	fi

	printf '%-36s %-8s %-5s %-5s %s %s\n' \
		"$rel" "$decl" "$rc_sh" "$rc_bash" "$hits" "$flag"
done < "$LIST"

printf -- '%.0s-' {1..100}; printf '\n'
printf '一致且无方言特征: %d\n' "$OK"
printf '含 bash 方言（实跑一致）: %d\n' "$DIALECT"
printf '** sh 与 bash 实跑行为不一致（高危）: %d**\n' "$HIGH_RISK"
printf '\n注：实跑比对用空stdin + 无参调用，反映的是「脚本能否被该解释器解析并启动」。\n'
printf '    高危项通常意味着 shebang 声明与实际方言不符 —— 在 OpenWrt 上被\n'
printf '    busybox ash 掩盖（ash 支持 source），换Debian dash 就炸。\n'
printf '    修法只能从调用侧规避（显式用 bash，或直接执行靠 shebang），\n'
printf '    因为 shebang 属 L1 上游，不可修改。\n'
