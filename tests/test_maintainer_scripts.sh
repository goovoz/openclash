#!/usr/bin/env bash
# =============================================================================
# 维护者脚本测试（postinst / prerm / postrm）
# -----------------------------------------------------------------------------
# 被测对象：packaging/debian/{postinst,prerm,postrm}
#
# 为什么这条链路值得单独一套测试：
#   这三个脚本**不受任何其它套件的自然覆盖** —— 它们只在 dpkg 安装/卸载时执行，
#   要真跑需要 root + 一次真实安装（那是 tests/e2e/linux 的范围）。而历史上正是
#   这片空白里藏了一个真缺陷：
#
#     postinst 用 `[ ! -e /sbin/uci ]` 守卫之后才创建 /sbin/uci，
#     可 postrm 的 purge 分支里却有一句**无条件**的 `rm -f /sbin/uci`。
#
#   于是如果 /sbin/uci 属于**别的包**（或用户手工放的真实 uci），postinst 会
#   正确地跳过创建 —— 但 purge 时那句无条件 rm 会把它删掉。用户看到的现象是
#   "我卸载了 openclash-rt，怎么 B 工具的 uci 命令不见了"，而报错现场离真因极远。
#   总体行为是"不建、但会删"，正是不对称守卫能造出的最坏组合。
#
#   修法不是"再补一个 if"，而是引入**所有权凭据**：postinst 在真正创建链接时
#   写下标记文件（内容 = 链接指向的目标），卸载端只有在
#   「标记存在」**且**「/sbin/uci 仍是链接且仍指向当初那个目标」**同时**成立时
#   才删除。这套测试钉住的就是这个凭据协议。
#
# 测试手法（刻意的选择）：
#   把维护者脚本里的 `rm_sbin_uci_if_ours()` 函数**原文抽取**出来，只把其中的
#   绝对路径 /sbin/uci 改写到临时沙箱，再 source 后跑行为矩阵。
#   不重写一份判断逻辑 —— 那样测的是"我重写的版本"，而不是真跑的那份代码。
#   同一份抽取结果还被用于断言 prerm 与 postrm 里的两份实现**逐字节相同**：
#   同一个函数在两个文件里各写一份，迟早漂移（本项目已在 lua 钉定那一步踩过
#   一次"两份实现会漂移"，因此这里主动加锁）。
#
# 覆盖：
#   A. 所有权谓词行为矩阵（标记 × 链接形态 共 7 组）—— 需要真符号链接
#   B. 两份实现逐字节一致；标记路径三处一致
#   C. 静态纪律（无守卫 rm / usrmerge 判定 / 禁止 ln -sf 自环 / 写标记）
#   D. 调用点（prerm 的 remove|deconfigure 分支确实调用了清理函数）
#   E. 语法（三个脚本 sh -n）
#
# 用法： bash tests/test_maintainer_scripts.sh
# =============================================================================
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
D="$ROOT/packaging/debian"
POSTINST="$D/postinst"
PRERM="$D/prerm"
POSTRM="$D/postrm"

# ⚠️ 硬编码 /tmp：${TMPDIR} 在本沙箱是 Windows 盘符路径，会被安全策略拒绝
WORK="/tmp/ocrt-maint.$$"
rm -rf "$WORK" 2>/dev/null || true
mkdir -p "$WORK"
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

PASS=0; FAIL=0; SKIP=0
it()  { printf '\n\033[1m── %s\033[0m\n' "$1"; }
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
no()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; }
sk()  { SKIP=$((SKIP+1)); printf '  \033[33mSKIP\033[0m  %s\n' "$1"; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "want=[$3] got=[$2]"; fi; }

for f in "$POSTINST" "$PRERM" "$POSTRM"; do
	[ -f "$f" ] || { printf '\033[31m[fatal]\033[0m 缺少 %s\n' "$f"; exit 1; }
done

# 抽取清理函数原文（从函数头到第一个顶格 `}`）
_extract_fn() { sed -n '/^rm_sbin_uci_if_ours() {$/,/^}$/p' "$1"; }

# 去掉**整行注释**后再计数。
# ⚠️ 这一步是必需的，不是洁癖：本仓库的注释里刻意引用了被禁止的写法本身 ——
#    postrm 的注释里就写着旧实现那句 `rm -f /sbin/uci` 和 `ln -sf /usr/sbin/uci`，
#    postinst 的注释里也写着 `[ /sbin -ef /usr/sbin ]`。直接 grep 会把这些
#    **讲解性引用**当成真实代码数进来，于是断言全变噪声。
#    （本套件第一版就因此误报 4 条 FAIL。）sed 的逐行替换不改变行数，
#    所以下面要配合 `_fn_range` 的行号范围使用时也不会错位。
_no_comment() { sed 's/^[[:space:]]*#.*$//' "$1"; }

# 标记常量取值（用于断言三个脚本写的是同一个路径）
_mark_of() { sed -nE 's/^[[:space:]]*SBIN_UCI_MARK=(.*)$/\1/p' "$1" | sed -n '1p'; }

# 在"去注释"文本上按固定串取首个匹配行号（找不到则空）
_first_ln() { _no_comment "$2" | grep -nF -- "$1" | cut -d: -f1 | sed -n '1p'; }

# 在"去注释"文本上按固定串计数
_count() { _no_comment "$2" | grep -cF -- "$1" || true; }

# 在"去注释"文本上按 ERE 计数
_count_e() { _no_comment "$2" | grep -cE -- "$1" || true; }

# 函数在文件中的行号范围 → "start end"（找不到则空）
_fn_range() {
	awk '
		/^rm_sbin_uci_if_ours\(\) \{$/ { s = NR }
		s && NR > s && /^\}$/ { print s, NR; exit }
	' "$1"
}

# 某行号是否落在函数区间 [start,end] 内
_in_range() {   # <行号> <"start end">
	[ -n "$2" ] || return 1
	# `$2` 故意不加引号：它本身是 "start end" 两个 token，split 后成为 $2/$3
	# shellcheck disable=SC2086
	set -- "$1" $2
	[ "$1" -ge "$2" ] && [ "$1" -le "$3" ]
}

# 某个分支（如 remove|deconfigure)）内部是否出现了指定调用。
# 用 index() 而不是 ~ 匹配：分支名里含 `|`，当正则会被当成 alternation。
# 输入先过一遍 _no_comment：否则注释里对分支名或调用的引用会把判定带偏。
_call_in_branch() {   # <文件> <分支起始子串> <要查找的调用>
	_no_comment "$1" | awk -v startpat="$2" -v call="$3" '
		!inb && index($0, startpat) > 0 { inb = 1; next }
		inb && $0 ~ /^[[:space:]]*;;$/ { inb = 0 }
		inb && index($0, call) > 0 { found = 1 }
		END { print (found ? "yes" : "no") }
	'
}

# 首个匹配行的行号（找不到则空）—— 见上面 _first_ln 的定义

PRERM_FN="$(_extract_fn "$PRERM")"
POSTRM_FN="$(_extract_fn "$POSTRM")"

# =============================================================================
it "A. 所有权谓词行为矩阵"
# =============================================================================
# 能力探测：MSYS/Git Bash 的 `ln -s` 会退化成"复制成普通文件"，`[ -L ]` 恒假，
# 于是"链接指向哪里"这个维度根本无法构造。
# 这种情况**明确跳过**而不是假装通过 —— 假装通过会让这条覆盖在本地永远绿、
# 到 CI 上第一次跑才红，是最坏的形态。
# 需要真符号链接；CI（ubuntu-latest）满足，本机（MSYS）不满足。
SYMLINK_OK=no
if ln -s probe "$WORK/.symprobe" 2>/dev/null && [ -L "$WORK/.symprobe" ]; then
	SYMLINK_OK=yes
fi
rm -f "$WORK/.symprobe" 2>/dev/null || true

if [ -z "$PRERM_FN" ]; then
	no "A 能从 prerm 抽取到 rm_sbin_uci_if_ours（用例前提）" "抽取结果为空"
elif [ "$SYMLINK_OK" != "yes" ]; then
	sk "A 本机 ln -s 不产生真符号链接（MSYS 行为），无法构造「链接指向哪里」这一维度"
	sk "A 已跳过 7 组共 14 条行为断言；它们在 CI（Linux）上会真实执行，本机回归保护由 C 组静态断言承担"
else
	# 把函数里的绝对路径改写到沙箱，其余一字不改，然后 source 掉
	SB_ROOT="$WORK/fs"
	_src="$(printf '%s\n' "$PRERM_FN" | sed "s,/sbin/uci,$SB_ROOT/uci,g")"
	printf '%s\n' "$_src" > "$WORK/pred.sh"
	# shellcheck source=/dev/null
	. "$WORK/pred.sh"

	_TGT=/usr/sbin/uci          # 标记里记录的"当初指向"
	_OTHER=/usr/bin/other-uci   # 别的东西

	# 每个用例：重建沙箱 → 按 setup 造现场 → 调真实的清理函数 → 看链接是否还在
	#
	# got 的语义是"函数是否把链接从存在变成不存在"——也就是"**改变了什么**"。
	# 不是「链接当前在不在」（"现在不存在" 在不同 setup 下含义完全不同）。
	#
	# 旧版用 `if [ ! -e uci ] && [ ! -L uci ]; then got=gone; fi` 当 got，
	# 把「setup 本来就没建链接」也判成 gone → case 6 / 7 在真机上永远 FAIL，
	# 因为它们的 setup 没造 uci，函数执行后 uci 也不存在，被旧逻辑判 gone，
	# 但 want 却是 kept（意思是"无副作用"）。MSYS 上整组被 SKIP，所以这条
	# 缺陷在 MSYS 上从未暴露。
	#
	# 修法：分别记录 setup 前 vs setup 后的 uci 存在性，以"setup 后 vs 函数后"
	# 的差异为 got。这样 case 6 / 7 的"setup 后 = no、函数后 = no"会判 kept。
	_case() {   # <描述> <期望 gone|kept> <setup>
		local desc="$1" want="$2" setup="$3" rc=0 got=kept
		rm -rf "$SB_ROOT"; mkdir -p "$SB_ROOT"
		# 故意不加 local：清理函数要读它（就是被测代码依赖的那个全局）
		SBIN_UCI_MARK="$SB_ROOT/.mark"
		[ -e "$SB_ROOT/uci" ] || [ -L "$SB_ROOT/uci" ] && _PRE=yes || _PRE=no
		eval "$setup"
		[ -e "$SB_ROOT/uci" ] || [ -L "$SB_ROOT/uci" ] && _POST_SETUP=yes || _POST_SETUP=no
		rm_sbin_uci_if_ours
		rc=$?
		[ -e "$SB_ROOT/uci" ] || [ -L "$SB_ROOT/uci" ] && _POST=yes || _POST=no
		# got = 函数是否**改变了** uci 的存在性
		if [ "$_POST_SETUP" = "$_POST" ]; then got=kept; else got=gone; fi
		chk "A $desc → 结果应为 $want" "$got" "$want"
		chk "A $desc → 返回码 0（set -e 下不得中断维护者脚本）" "$rc" "0"
	}

	# 1. 无标记（= 不是本包建的）→ 必须原样留下。这是最核心的一条：
	#    没有凭据概念时，purge 会把这个链接/文件直接删掉。
	_case "无标记 + 链接存在（非本包创建）" kept \
		"ln -s '$_TGT' \"\$SB_ROOT/uci\""
	# 2. 凭据齐全且链接仍是当初那个目标 → 删
	_case "有标记 + 指向记录目标（本包创建）" gone \
		"ln -s '$_TGT' \"\$SB_ROOT/uci\"; printf '%s\n' '$_TGT' >\"\$SBIN_UCI_MARK\""
	# 3. 标记在，但链接被改指到别处 → 不删（已不是我们的东西）
	_case "有标记 + 链接被改指别处" kept \
		"ln -s '$_OTHER' \"\$SB_ROOT/uci\"; printf '%s\n' '$_TGT' >\"\$SBIN_UCI_MARK\""
	# 4. 标记在，但 /sbin/uci 是**真实文件**而非链接 → 不删（换成真文件即视为接管）
	_case "有标记 + 是真实文件（非链接）" kept \
		": >\"\$SB_ROOT/uci\"; printf '%s\n' '$_TGT' >\"\$SBIN_UCI_MARK\""
	# 5. 标记存在但内容为空 → 不删。空标记说明写入曾被截断，此时无凭据可依，须保守。
	_case "有标记但内容为空" kept \
		"ln -s '$_TGT' \"\$SB_ROOT/uci\"; : >\"\$SBIN_UCI_MARK\""
	# 6. 标记在但链接已消失 → 无事可做，且必须返回 0
	_case "有标记 + 链接不存在（幂等）" kept \
		"printf '%s\n' '$_TGT' >\"\$SBIN_UCI_MARK\""
	# 7. 什么都没有 → 无事可做，且必须返回 0
	_case "无标记 + 链接不存在" kept ":"

	# 反向确认：路径改写确实生效（否则上面可能测的是个碰巧无害的空壳）
	chk "A 抽取结果里已不含裸 /sbin/uci（路径改写生效）" \
		"$(printf '%s\n' "$_src" | grep -c '/sbin/uci' || true)" "0"
	chk "A 抽取结果里出现了沙箱路径（改写目标正确）" \
		"$(printf '%s\n' "$_src" | grep -cF "$SB_ROOT/uci" || true)" "3"
fi

# =============================================================================
it "B. 两份实现一致 + 标记路径三处一致"
# =============================================================================
chk "B prerm 里能抽到 rm_sbin_uci_if_ours" "$([ -n "$PRERM_FN" ] && echo yes)" "yes"
chk "B postrm 里能抽到 rm_sbin_uci_if_ours" "$([ -n "$POSTRM_FN" ] && echo yes)" "yes"
# 同一个函数在两个文件里各写一份 → 迟早漂移。这里逐字节锁死。
chk "B 两份抽取结果逐字节相同" "$PRERM_FN" "$POSTRM_FN"

_MI="$(_mark_of "$POSTINST")"
_MP="$(_mark_of "$PRERM")"
_MQ="$(_mark_of "$POSTRM")"
chk "B 标记路径：postinst 与 prerm 一致" "$_MP" "$_MI"
chk "B 标记路径：postinst 与 postrm 一致" "$_MQ" "$_MI"
chk "B 标记路径是绝对路径" \
	"$(case "$_MI" in /*) echo yes ;; *) echo no ;; esac)" "yes"
chk "B 标记路径写在 /usr/lib/openclash-rt 下（prerm 阶段才读得到）" \
	"$(case "$_MI" in /usr/lib/openclash-rt/*) echo yes ;; *) echo no ;; esac)" "yes"

# =============================================================================
it "C. 静态纪律"
# =============================================================================
# C1 —— 本套件的**核心断言**，它单独就能抓住那个真缺陷：
#   每一处 `rm -f /sbin/uci` 都必须落在 rm_sbin_uci_if_ours 函数体范围内。
#   旧实现的 postrm 里有一句裸的、位于函数外的 `rm -f /sbin/uci`。
for f in "$PRERM" "$POSTRM"; do
	_base="$(basename "$f")"
	_rng="$(_fn_range "$f")"
	chk "C $_base：能定位 rm_sbin_uci_if_ours 的行号范围" \
		"$([ -n "$_rng" ] && echo yes)" "yes"
	_outside=0
	while IFS= read -r _ln; do
		[ -n "$_ln" ] || continue
		_in_range "$_ln" "$_rng" || _outside=$((_outside + 1))
	done < <(_no_comment "$f" | grep -n 'rm -f /sbin/uci' | cut -d: -f1)
	chk "C $_base：函数体之外不存在 rm -f /sbin/uci（旧缺陷的回归锁）" "$_outside" "0"
	chk "C $_base：确实有且仅有 1 处受保护的 rm -f /sbin/uci" \
		"$(_count 'rm -f /sbin/uci' "$f")" "1"
done

# C2 —— usrmerge 判定：必须比较 inode，不能只看 readlink /sbin
chk "C postinst 用 -ef 比较 inode 判 usrmerge" \
	"$(_count '[ /sbin -ef /usr/sbin ]' "$POSTINST")" "1"
chk "C postinst 不用裸 'readlink /sbin' 当判据（它分不清真实目录与链接）" \
	"$(_count_e 'readlink /sbin$' "$POSTINST")" "0"

# C3 —— 禁止 ln -sf ... /sbin/uci：usrmerge 下 /sbin/uci 与 /usr/sbin/uci 是同一
#        路径，`ln -sf` 会造出指向自己的链接，ln 报 "are the same file" 并非零
#        退出，在 set -e 下直接让 postinst 失败（dpkg 报配置错误）。
#        带 `-f` 的形态一律禁止；允许的是受 usrmerge 分支保护的 `ln -s`。
chk "C postinst 里没有 'ln -sf ... /sbin/uci' 这种自环形态" \
	"$(_count_e 'ln -s[f]+ [^|]*/sbin/uci' "$POSTINST")" "0"

# C4 —— 创建动作必须**排在** usrmerge 判定之后（顺序错了风险就回来了）
_EF_LN="$(_first_ln '[ /sbin -ef /usr/sbin ]' "$POSTINST")"
_MKLN="$(_first_ln 'ln -s "$UCI_REAL" /sbin/uci' "$POSTINST")"
chk "C postinst 确实有创建 /sbin/uci 的动作" "$([ -n "$_MKLN" ] && echo yes)" "yes"
_ORDER=no
if [ -n "$_EF_LN" ] && [ -n "$_MKLN" ] && [ "$_EF_LN" -lt "$_MKLN" ]; then _ORDER=yes; fi
chk "C usrmerge 判定在创建链接之前（顺序反了自环风险就回来了）" "$_ORDER" "yes"

# C5 —— 已存在即不覆盖：真实文件与"指向别处的链接"两条分支都要有
chk "C postinst 有「是链接但不是我们的」分支" \
	"$(_count 'elif [ -L /sbin/uci ]' "$POSTINST")" "1"
chk "C postinst 有「已存在且非链接」分支" \
	"$(_count 'elif [ -e /sbin/uci ]' "$POSTINST")" "1"
chk "C postinst 对已存在非本包创建的情况会告警，而不是静默跳过" \
	"$(_count '本包不覆盖它' "$POSTINST")" "2"

# C6 —— 创建链接后必须留下凭据（两处：重装复用分支 + 新建分支）
chk "C postinst 在两个创建/复用分支都写了标记" \
	"$(_count '>"$SBIN_UCI_MARK"' "$POSTINST")" "2"

# C7 —— 找不到 uci 时必须告警。静默跳过会让上游脚本失去配置写入能力，
#        而症状出现在很远的地方（luci.model.uci 的 "Connection failed"）。
chk "C postinst 找不到 uci 时告警" \
	"$(_count '找不到 uci 可执行文件' "$POSTINST")" "1"

# C8 —— postrm purge 必须清掉标记文件本身（它不在 dpkg 文件清单里，dpkg 不管）
chk "C postrm 删除标记文件本身" \
	"$(_count 'rm -f "$SBIN_UCI_MARK"' "$POSTRM")" "1"

# C9 —— 同一套 /sbin/uci 策略还有**第二个落点**：e2e harness 里手工复刻的安装步骤。
#        它曾经用的也是 `ln -sf /usr/sbin/uci /sbin/uci`（与旧 postinst 同形）。
#        两处必须同语义 —— 否则 e2e 验证的是一段与生产不同的逻辑，postinst 改坏了
#        它还会继续绿着给出虚假安心。这条断言就是那个一致性的锁。
E2E="$ROOT/tests/e2e/linux/run-e2e.sh"
if [ -f "$E2E" ]; then
	chk "C e2e harness 里没有 'ln -sf ... /sbin/uci' 自环形态" \
		"$(_count_e 'ln -s[f]+ [^|]*/sbin/uci' "$E2E")" "0"
	chk "C e2e harness 复刻了 usrmerge 判定（与 postinst 同语义）" \
		"$(_count '[ ! /sbin -ef /usr/sbin ]' "$E2E")" "1"
else
	no "C 找到 e2e harness（C9 用例前提）" "$E2E"
fi

# =============================================================================
it "D. 调用点"
# =============================================================================
chk "D prerm 的 remove|deconfigure 分支内调用了清理函数" \
	"$(_call_in_branch "$PRERM" 'remove|deconfigure)' 'rm_sbin_uci_if_ours')" "yes"
chk "D prerm 的 upgrade 分支**不**清理（升级不得动 /sbin/uci）" \
	"$(_call_in_branch "$PRERM" 'upgrade|failed-upgrade)' 'rm_sbin_uci_if_ours')" "no"
chk "D postrm 的 purge 分支内调用了兜底清理" \
	"$(_call_in_branch "$POSTRM" 'purge)' 'rm_sbin_uci_if_ours')" "yes"

# =============================================================================
it "E. 语法"
# =============================================================================
for f in "$POSTINST" "$PRERM" "$POSTRM"; do
	if sh -n "$f" 2>/dev/null; then ok "E sh -n 通过： $(basename "$f")"
	else no "E sh -n 通过： $(basename "$f")" "$(sh -n "$f" 2>&1 | sed -n '1,2p' | tr '\n' '|')"; fi
done

# =============================================================================
printf '\n\033[1m════════════════════════════════════════\033[0m\n'
printf '  \033[32mPASS %d\033[0m   \033[31mFAIL %d\033[0m   \033[33mSKIP %d\033[0m\n' "$PASS" "$FAIL" "$SKIP"
printf '\033[1m════════════════════════════════════════\033[0m\n'
[ "$FAIL" -eq 0 ] || exit 1
exit 0
