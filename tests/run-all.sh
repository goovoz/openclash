#!/usr/bin/env bash
# =============================================================================
# 本地测试总入口（聚合 tests/test_*.sh）
# -----------------------------------------------------------------------------
# 为什么需要它：
#   各套件是独立可执行的（也应当保持独立，便于单点调试），但它们的历史写法
#   不同，汇总行有两种风格：
#       · `  PASS: 47    FAIL: 0`          （早期 5 套）
#       · `  PASS 49   FAIL 0   SKIP 0`    （lua 相关的 2 套）
#   于是"跑一遍全部看看绿没绿"这件事没法用一行 shell 拼出来 —— 实测中
#   手工拼的聚合命令把这两派都数成了 0，还因为总耗时超时被 SIGTERM，
#   给出"测试挂住了"的错误信号。这个脚本把这件事固化下来，避免每次重踩。
#
# 用法：
#   bash tests/run-all.sh                # 跑全部
#   bash tests/run-all.sh -k lua         # 只跑名字含 lua 的
#   bash tests/run-all.sh -l             # 只列出会跑哪些
#   bash tests/run-all.sh -v             # 透传完整输出（调试单个套件时用）
#   bash tests/run-all.sh --timeout 600  # 单个套件超时（默认 300s）
#
# 退出码：0 = 全部通过；1 = 至少一个套件失败或有断言 FAIL。
#
# 说明：本脚本只跑 mock 单元套件。真实 Linux 的端到端套件在
#       tests/e2e/linux/run-e2e.sh，需要 root，故意不纳入这里。
# =============================================================================
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

# ⚠️ 固定用 /tmp：${TMPDIR} 在 Windows 沙箱里是盘符路径，会被安全策略拒绝
WORK="/tmp/ocrt-runall.$$"
rm -rf "$WORK" 2>/dev/null || true
mkdir -p "$WORK"
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

FILTER=""
LISTONLY=0
VERBOSE=0
TIMEOUT=300

while [ $# -gt 0 ]; do
	case "$1" in
		-k|--filter)  FILTER="${2:?需要模式}"; shift 2 ;;
		-k=*|--filter=*) FILTER="${1#*=}"; shift ;;
		-l|--list)    LISTONLY=1; shift ;;
		-v|--verbose) VERBOSE=1; shift ;;
		--timeout)    TIMEOUT="${2:?需要秒数}"; shift 2 ;;
		--timeout=*)  TIMEOUT="${1#*=}"; shift ;;
		-h|--help)    sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*) printf '未知参数：%s\n' "$1" >&2; exit 2 ;;
	esac
done

# 套件清单：按文件名排序，顺序稳定（输出可 diff）
SUITES=()
while IFS= read -r f; do
	[ -n "$f" ] || continue
	b="$(basename "$f")"
	if [ -n "$FILTER" ]; then
		case "$b" in *"$FILTER"*) ;; *) continue ;; esac
	fi
	SUITES+=("$f")
done < <(ls "$HERE"/test_*.sh 2>/dev/null | sort)

if [ "${#SUITES[@]}" -eq 0 ]; then
	printf '\033[33m[warn]\033[0m 没有匹配的测试套件'; [ -n "$FILTER" ] && printf '（模式：%s）' "$FILTER"; printf '\n'
	exit 1
fi

if [ "$LISTONLY" = "1" ]; then
	for f in "${SUITES[@]}"; do printf '  %s\n' "${f#$ROOT/}"; done
	exit 0
fi

# -----------------------------------------------------------------------------
# 从套件输出里抽取 PASS/FAIL/SKIP
# -----------------------------------------------------------------------------
# 只认**汇总行**，不数明细行：明细行的格式是 `  PASS  <文本>`，而汇总行一定
# 是 `PASS[:] <数字> ... FAIL[:] <数字>`。用正则同时要求"两边都带数字"，就把
# 明细行自然排除掉了（明细行的 PASS 后面跟的是文字）。取最后一条匹配，因为
# 汇总行永远在输出末尾。
_parse() {   # <输出文件> → "<pass> <fail> <skip>"
	# 注意：先剥 ANSI，否则 `\033[32mPASS` 与后面的数字之间隔了转义序列
	awk '
		{
			line = $0
			gsub(/\033\[[0-9;]*m/, "", line)
			if (line ~ /PASS[ \t]*:?[ \t]*[0-9]+/ && line ~ /FAIL[ \t]*:?[ \t]*[0-9]+/) {
				p = ""; f = ""; s = "0"
				if (match(line, /PASS[ \t]*:?[ \t]*[0-9]+/)) {
					t = substr(line, RSTART, RLENGTH); gsub(/[^0-9]/, "", t); p = t
				}
				if (match(line, /FAIL[ \t]*:?[ \t]*[0-9]+/)) {
					t = substr(line, RSTART, RLENGTH); gsub(/[^0-9]/, "", t); f = t
				}
				if (match(line, /SKIP[ \t]*:?[ \t]*[0-9]+/)) {
					t = substr(line, RSTART, RLENGTH); gsub(/[^0-9]/, "", t); s = t
				}
				lastp = p; lastf = f; lasts = s; found = 1
			}
		}
		END { if (found) print lastp, lastf, lasts; else print "- - -" }
	' "$1"
}

# 有 timeout(1) 就用，避免某个套件挂住把整个 CI 拖死
_has_timeout=0
command -v timeout >/dev/null 2>&1 && _has_timeout=1

TP=0; TF=0; TS=0; BAD=0

printf '\n\033[1m════════════════════════════════════════════════════════════\033[0m\n'
printf '\033[1m  openclash-rt  单元测试总览（%d 个套件）\033[0m\n' "${#SUITES[@]}"
printf '\033[1m════════════════════════════════════════════════════════════\033[0m\n'

for f in "${SUITES[@]}"; do
	name="$(basename "$f" .sh)"
	out="$WORK/$name.out"
	t0="$(date +%s 2>/dev/null || echo 0)"

	if [ "$_has_timeout" = "1" ]; then
		timeout "$TIMEOUT" bash "$f" >"$out" 2>&1
		rc=$?
	else
		bash "$f" >"$out" 2>&1
		rc=$?
	fi
	t1="$(date +%s 2>/dev/null || echo 0)"
	secs=$((t1 - t0))

	read -r p fl sk < <(_parse "$out")

	if [ "$p" = "-" ]; then
		printf '  \033[31m??\033[0m    %-30s \033[31m无法解析汇总行\033[0m  (rc=%s, %ss)\n' "$name" "$rc" "$secs"
		BAD=$((BAD + 1))
		if [ "$VERBOSE" = "1" ]; then sed 's/^/        /' "$out"; else printf '        %s\n' "$(tail -5 "$out" | tr '\n' '|' | head -c 300)"; fi
		continue
	fi

	TP=$((TP + p)); TF=$((TF + fl)); TS=$((TS + sk))

	# 判定：断言全绿 **且** 退出码为 0
	# （退出码单独看：有的套件会在 FAIL 时仍返回 0，也有相反情况，两个都查）
	if [ "$fl" -eq 0 ] && [ "$rc" -eq 0 ]; then
		printf '  \033[32mPASS\033[0m  %-30s %4s 通过' "$name" "$p"
		[ "$sk" -gt 0 ] && printf '，%s 跳过' "$sk"
		printf '  (%ss)\n' "$secs"
	else
		BAD=$((BAD + 1))
		printf '  \033[31mFAIL\033[0m  %-30s %s 失败 / %s 通过  (rc=%s, %ss)\n' "$name" "$fl" "$p" "$rc" "$secs"
		# 只摘 FAIL 行，噪声最小；-v 时给全量
		if [ "$VERBOSE" = "1" ]; then
			sed 's/^/        /' "$out"
		else
			grep -aE 'FAIL' "$out" | head -12 | sed 's/^/        /'
		fi
	fi
done

printf '\033[1m════════════════════════════════════════════════════════════\033[0m\n'
printf '  合计  \033[32mPASS %d\033[0m' "$TP"
printf '   \033[31mFAIL %d\033[0m' "$TF"
[ "$TS" -gt 0 ] && printf '   \033[33mSKIP %d\033[0m' "$TS"
printf '\n'
[ "$BAD" -gt 0 ] && printf '  \033[31m%d 个套件未全绿\033[0m\n' "$BAD"
printf '\033[1m════════════════════════════════════════════════════════════\033[0m\n'

[ "$BAD" -eq 0 ] || exit 1
exit 0
