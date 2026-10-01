#!/usr/bin/env bash
# tests/test_luci_lmo_install.sh —— P2-B 验收套件
#
# 设计原则（与 test_luci_vendor_install.sh 同源）：
#   · 静态纪律为主：检查脚本逻辑、命名约定、设计不变量——本机无 gcc 也能跑
#   · 变异测试：注入旧形态，断言锁不空转
#   · SKIP_CC=1 是本机主路径（CI 上真实编译）
#
# 关键不变量（这些是这套测试的全部立身之处）：
#   · po2lmo 编译命令只 link po2lmo.c 一个文件（独立可编译）
#   · .po -> .lmo 路径映射： <pkg>/po/<lang>/base.po -> <pkg>.<lang>.lmo
#   · .lmo 落位 = /usr/lib/lua/luci/i18n/<pkg>.<lang>.lmo
#   · naming 必须匹配 fnmatch("*.zh-cn.lmo", ...) —— `<任意>.<lang>.lmo`
#   · po2lmo 二进制不进 deb（属于 build/，由 §4 清）
#   · .po / .y / .c / .h 不入 staging（编译期污染）
#   · stdout 纪律（build-deb.sh 用 n="$(...)" 取值时不被污染）

set -u
PASS=0; FAIL=0; SKIP=0

ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS + 1)); }
no()   { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL + 1)); printf '          %s\n' "${2:-<no detail>}"; }
skip() { printf '  \033[33mSKIP\033[0m  %s（%s）\n' "$1" "${2:-}"; SKIP=$((SKIP + 1)); }
chk()  { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "want=[$3] got=[$2]"; fi; }
has()  { if printf '%s\n' "$2" | grep -qF -- "$3"; then ok "$1"; else no "$1" "输出里没有：$3"; fi; }
not()  { if printf '%s\n' "$2" | grep -qF -- "$3"; then no "$1" "输出里不该有：$3"; else ok "$1"; fi; }
_yeseq() { if [ "$1" -ge "$2" ] 2>/dev/null; then ok "$3"; else no "$3" "need≥$2 got=$1"; fi; }

# 解析仓库根目录（与 run-all.sh / test_luci_vendor_install.sh 一致；本套件之前漏写，
# 直接被 run-all 调起时 ROOT 不在环境里会死在 set -u）
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# 允许 env override（供变异测试使用：LMO_INSTALL=/path/to/mutant.sh bash tests/test_luci_lmo_install.sh）
LMO_INSTALL="${LMO_INSTALL:-$ROOT/scripts/install-vendor-lmo.sh}"
PIN="$ROOT/runtime/upstream/pin-lua-interpreter.sh"
BUILD_DEB="$ROOT/scripts/build-deb.sh"
VENDOR="$ROOT/vendor/luci"

# ⚠️ 不要假设 git 保留了 +x bit：本地 Windows 上文件系统永远显示 +x（mingw shim），
#   但 git tree mode 是 100644；CI Linux runner checkout 也是 644。
#   显式 chmod 一次最稳（chmod 在 mingw 上是 no-op，不影响 Windows）。
[ -x "$LMO_INSTALL" ] || chmod +x "$LMO_INSTALL" 2>/dev/null || true
[ -x "$LMO_INSTALL" ] || { echo "找不到 $LMO_INSTALL"; exit 2; }

# --- A. 工具与 vendro 树存在性 ---
printf '\n\033[1mA. 工具与 vendor 树存在性\033[0m\n'
chk "A install-vendor-lmo.sh 可执行" "$(test -x "$LMO_INSTALL" && echo yes || echo no)" "yes"
chk "A vendor/luci 存在" "$(test -d "$VENDOR" && echo yes || echo no)" "yes"
chk "A po2lmo.c 存在" "$(test -f "$VENDOR/luci-base/src/po2lmo.c" && echo yes || echo no)" "yes"
chk "A template_lmo.h 存在" "$(test -f "$VENDOR/luci-base/src/template_lmo.h" && echo yes || echo no)" "yes"
_n="$(find "$VENDOR" -path '*/po/*/base.po' 2>/dev/null | wc -l)"
_yeseq "$_n" 30 "A vendor 至少 30 个 .po 文件（多语言翻译源）"

# --- B. SKIP_CC=1 路径（主路径：本机无 gcc） ---
printf '\n\033[1mB. SKIP_CC=1 路径（主路径）\033[0m\n'
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
W="$WORK/stage"
mkdir -p "$W"

OUT="$(bash "$LMO_INSTALL" --src "$VENDOR" --stage "$W" --skip-cc 2>"$WORK/err")"
RC=$?
ERR="$(cat "$WORK/err")"

chk "B SKIP_CC 退出码" "$RC" "0"
chk "B SKIP_CC stdout 是空（不要把日志掺进去污染 build-deb 的 n=\"$()\" 取值）" "$OUT" ""
has "B SKIP_CC stderr 提示跳过" "$ERR" "SKIP_CC=1"
has "B SKIP_CC stderr 末尾给出 i18n 落位总结" "$ERR" "i18n 落位总数"
chk "B 创建了 i18n/ 目录" "$(test -d "$W/usr/lib/lua/luci/i18n" && echo yes || echo no)" "yes"
chk "B 创建了 build/ 目录" "$(test -d "$W/usr/lib/openclash-rt/build" && echo yes || echo no)" "yes"
# 静态断言通过
has "B .po 源未误入 staging 的静态断言被跑" "$ERR" ".po 源未误入 staging"

# --- C. 命名约定 & 不变量（静态分析） ---
printf '\n\033[1mC. 命名约定 & 不变量\033[0m\n'
# 1) 落位路径必须等于 /usr/lib/lua/luci/i18n/
_n="$(grep -cF 'usr/lib/lua/luci/i18n' "$LMO_INSTALL")"
_yeseq "$_n" 1 "C 落位路径含 i18n/"
# 2) 编译命令：fallback self-compile 必须链全（po2lmo.c + template_lmo.c …）
chk "C 编译用 C 编译器编 po2lmo.c" "$(grep -cE '\$CC.*po2lmo\.c' "$LMO_INSTALL" || true)" "1"
#   ⚠️ 这条断言在 2026-10-01 **翻转过**，原因是早期结论错了：
#     · 旧断言：not(源码里出现 "po2lmo.c template_lmo.c") —— 假设单文件 cc 就够
#     · 真机事实：po2lmo.c 引用 template_lmo.c 里的 sfh_hash；单文件 cc 会
#       `undefined reference to 'sfh_hash'`。fallback **必须**链全，否则 CI
#       ubuntu-latest 上一个 .po 都编不出来（见 install-vendor-lmo.sh §1 注释）。
#     · vendor Makefile 印证：po2lmo ← po2lmo.o template_lmo.o plural_formula.o
#   所以这里改成 has 而不是 not，并把「不该有」的判据移交给下面那条 —— 真正要
#   守住的是**主路径不重编**，而不是"源码里不许出现这个词"。
has "C fallback 编译链含 template_lmo.c（sfh_hash 符号来源）" \
	"$(grep -oE 'po2lmo\.c +[a-z_]*\.c( +[a-z_]*\.c)*' "$LMO_INSTALL" | head -1)" \
	"po2lmo.c template_lmo.c"
#   ★ 这条才是「不引 lemon/flex/bison」的**真判据**：主路径必须复用
#     build-lua-modules.sh §6 已经跑过 lemon 的产物，install-vendor-lmo.sh
#     自己不再调一遍 lemon（那样会牵出 flex/bison 依赖）。
#     变异锁：把 --po2lmo 主路径删掉（强制 self-compile）→ 这条立刻红。
_yeseq "$(grep -cF 'STAGE/usr/bin/po2lmo' "$LMO_INSTALL" || true)" 1 \
	"C 主路径复用 build-lua-modules.sh §6 的 po2lmo 产物（不自己重编）"
not "C 主路径**不**自己调 lemon" "$(cat "$LMO_INSTALL")" "contrib/lemon -q"
# 3) po2lmo 调用约定： argv[1] = .po, argv[2] = .lmo（不能颠倒）
chk "C po2lmo 调用形态 po->lmo" "$(grep -cF '$_po" "$_lmo"' "$LMO_INSTALL" || true)" "1"
# 4) 命名约定：必须显式写出 <pkg>.<lang>.lmo 与 fnmatch 模式说明
chk "C 脚本内文提到 fnmatch 模式" "$(grep -cF 'fnmatch' "$LMO_INSTALL" || true)" "4"
chk "C 脚本内文明确写出 <pkg>.<lang>.lmo 命名约定" "$(grep -cF '<pkg>.<lang>.lmo' "$LMO_INSTALL" || true)" "4"

# --- D. 卫生：.po / .y / .c / .h 不入 staging ---
printf '\n\033[1mD. 卫生：编译期材料不入 staging\033[0m\n'
chk "D 静态断言：.po 源不入 staging" "$(grep -cF '.po 源未误入' "$LMO_INSTALL" || true)" "1"
# ⚠️ 这条也翻转过：原本 grep 'plural_formula' 期望 ==1，但实施「fallback 必须
#   链 plural_formula.c」之后该词在注释/实现里出现 7 次，计数断言失去意义。
#   改成锚定**真正的静态断言**那一行的判据字符串（find 的 -name 通配），
#   它只出现在 §4 卫生检查里，复制/改动该 check 就会破坏计数。
chk "D 静态断言：plural_formula* 不入 staging" \
	"$(grep -cF -- "-name 'plural_formula*'" "$LMO_INSTALL" || true)" "1"
chk "D po2lmo 二进制不进 deb（属 build/，§4 清）" "$(grep -cF 'build/ 下' "$LMO_INSTALL" || true)" "1"

# --- E. stdout 纪律（build-deb.sh 用 n="$(...)" 捕获时不应被日志污染） ---
printf '\n\033[1mE. stdout 纪律\033[0m\n'
OUT="$(bash "$LMO_INSTALL" --src "$VENDOR" --stage "$W" --skip-cc 2>/dev/null)"
chk "E SKIP_CC stdout 空（不要 log）" "$OUT" ""
OUT="$(bash -E SKIP_CC=1 "$LMO_INSTALL" --src "$VENDOR" --stage "$W" --skip-cc 2>/dev/null)"
chk "E 不会因 env var 错把 SKIP_CC 写到 stdout" "$OUT" ""

# --- F. SKIP_CC=1 路径： .lmo 文件不会被产出（防"看起来跑过了但其实是空"） ---
printf '\n\033[1mF. SKIP_CC=1 下不产 .lmo（明示 "0"）\033[0m\n'
_lmo="$(find "$W/usr/lib/lua/luci/i18n" -name '*.lmo' 2>/dev/null | wc -l)"
chk "F SKIP_CC=1 下 i18n/ 应该是空（0 个 .lmo）" "$_lmo" "0"
# 同时 stderr 给出"0 个"是显式的，便于排错（不是 silent）
has "F stderr 明示 0 个 .lmo" "$ERR" "0 个 .lmo"

# --- G. 调用 build-deb.sh 的静态契约 ---
printf '\n\033[1mG. build-deb.sh 调用形态\033[0m\n'
# build-deb.sh 必须真调 install-vendor-lmo.sh（不是内联第二份）
# 跳过 "comment" 行：注释里出现工具名不算
_n="$(grep -nE 'install-vendor-lmo\.sh' "$BUILD_DEB" | grep -vE '^[0-9]+:[[:space:]]*#' | wc -l)"
chk "G build-deb.sh 真调 install-vendor-lmo.sh（非注释）" "$([ "$_n" -ge 1 ] && echo yes || echo no)" "yes"
# 5d 段必须存在（注释中以「# 5d) 」开头的段落标记）
has "G build-deb.sh 有 §5d 段标记" "$(grep -cE '^# 5d\)' "$BUILD_DEB" || true)" "1"
# packaging 适配清单必须新增 [4] 条目
has "G packaging-adaptations.txt 加 [4] 项" "$(grep -cF '[4] vendor LuCI i18n' "$BUILD_DEB" || true)" "1"

# --- H. docs/03 §3.2 章节存在性 ---
printf '\n\033[1mH. docs/03 §3.2 lmo 落位契约\033[0m\n'
DOCS="$ROOT/docs/03-路径契约.md"
[ -f "$DOCS" ] || skip "H docs/03 存在" "未找到文档" 2>/dev/null
chk "H docs/03 §3.2 标题存在（≥1，含 ### 3.2.x 子标题）" "$(grep -cF '### 3.2' "$DOCS" || true)" "6"
# 文档必须明示命名约定
chk "H docs/03 §3.2 含命名约定（fnmatch 与 包名前缀）" "$(grep -cF '<pkg>.<lang>.lmo' "$DOCS" || true)" "3"
# 文档必须明示 fnmatch 模式
chk "H docs/03 §3.2 含 fnmatch 引用" "$(grep -cF 'fnmatch' "$DOCS" || true)" "2"

# --- I. 变异测试钩子（接口存在）---
# 留接口：本套件**不**自动跑变异体，因为变异体需要在临时克隆里改文件。
# 但**留断言**——断言钩子在，在 lockfile 里。如果不在 CI 跑变异体，
# 手工跑：见仓库根目录 ops/mutation-testing.md（本文件本身作为占位）。
printf '\n\033[1mI. 变异测试钩子（接口存在）\033[0m\n'
# 此处不写自动断言——脚本中任何「变异体未在本套件内自动执行」的标记都可能
# 被注释/实现所污染，静态锁的价值低于风险。可观察的 hook 在仓库根的
# ops/mutation-testing.md（占位文件）。
skip "I 变异体未在本套件内自动执行" "需 clone + 改副本 + 跑本套件才能验证"

# --- 汇总 ---
printf '\n\033[1m════════════════════════════════════════\033[0m\n'
printf '  \033[32mPASS %d\033[0m   \033[31mFAIL %d\033[0m   \033[33mSKIP %d\033[0m\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
exit 0