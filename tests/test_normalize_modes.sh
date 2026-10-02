#!/usr/bin/env bash
# =============================================================================
# 「带 shebang 的脚本必须有可执行位」测试
# -----------------------------------------------------------------------------
# 被测对象：runtime/upstream/normalize-modes.sh
#
# 为什么值得单独立一套件：
#   这不是 chmod 洁癖。上游 OpenWrt 的 ipkg 直接从 git 工作区 CP，可执行位靠
#   上游仓库的 100755 保证；而我们的链路
#       sync-upstream.sh 稀疏检出 → 在 core.filemode=false 的主机上提交 → 检出
#   会把它们**全压成 100644**。实测未修之前打出的 .deb 里
#       /etc/init.d/openclash                  -rw-r--r--
#       /usr/share/openclash/*.sh   （25 个）   -rw-r--r--
#       /usr/share/openclash/*.lua  （ 8 个）   -rw-r--r--
#   而上游是**直接执行**这些文件的（不是 source）：
#       openclash_update.sh:91  /usr/share/openclash/openclash_core.sh "Meta" "$1" "$2" >/dev/null 2>&1
#       yml_groups_set.sh:330   /usr/share/openclash/yml_proxys_set.sh "$CONFIG_FILE" >/dev/null 2>&1
#       openclash.sh:37         $(/usr/share/openclash/openclash_urlencode.lua "$1")
#   0644 下全部 Permission denied；而调用点几乎都带 `>/dev/null 2>&1`，于是
#   症状是「内核下载失败 / 订阅不更新」且**一条报错都没有**。这类静默故障
#   必须被机器守住，不能靠人记得 chmod。
#
#   缺口是 e2e 的 `--deb` 那一跑实测出来的（PASS 126 / FAIL 1：
#   「/etc/init.d/openclash 可执行」），本套件把它下沉到单元层，
#   这样 Windows 上也能守，不必每次都打一个 8MB 的包。
#
# 覆盖：
#   A. 归一行为：带 shebang 的补 0755；无 shebang 的**不动**（不误伤数据文件）
#   B. 幂等：二次运行归一处数为 0，且输出仍是整数
#   C. --check：全绿时 rc=0；缺位时 rc≠0 且**不改动任何文件**
#   D. 0 文件 = 硬失败（与 pin-lua 同一条纪律："什么都没检查"不能报成功）
#   E. stdout/stderr 分工：stdout 只有一个整数，日志全走 stderr
#   F. --file 与 --dir 互斥；--file 可对无扩展名文件（cgi-bin/luci 这类）生效
#   G. 静态纪律：两个调用点（build-deb.sh / run-e2e.sh）都真的调了它
#
# 用法： bash tests/test_normalize_modes.sh
# =============================================================================
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
NORM="${NORM:-$ROOT/runtime/upstream/normalize-modes.sh}"

# ⚠️ 硬编码 /tmp：${TMPDIR} 在 Windows 沙箱里是盘符路径，会被安全策略拒绝
WORK="/tmp/ocrt-normmode.$$"
rm -rf "$WORK" 2>/dev/null || true
mkdir -p "$WORK"
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
no()   { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; }
chk()  { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "want=[$3] got=[$2]"; fi; }
has()  { case "$2" in *"$3"*) ok "$1" ;; *) no "$1" "未在输出中找到 [$3]" ;; esac; }

[ -f "$NORM" ] || { printf '\033[31m[fail]\033[0m 找不到被测脚本：%s\n' "$NORM" >&2; exit 2; }
[ -x "$NORM" ] || chmod +x "$NORM" 2>/dev/null || true

# -----------------------------------------------------------------------------
# A. 归一行为
# -----------------------------------------------------------------------------
printf '\n\033[1m── A  归一：只动带 shebang 的，且只动缺位的\033[0m\n'

D="$WORK/tree"; mkdir -p "$D/sub"
printf '#!/bin/sh\necho hi\n'            >"$D/a.sh";      chmod 0644 "$D/a.sh"
printf '#!/usr/bin/lua5.1\nprint(1)\n'   >"$D/b.lua";     chmod 0644 "$D/b.lua"
printf 'no shebang here\n'               >"$D/data.txt";  chmod 0644 "$D/data.txt"
printf 'key=value\n'                     >"$D/sub/c.conf";chmod 0644 "$D/sub/c.conf"
printf '#!/bin/bash\ntrue\n'             >"$D/sub/d.sh";  chmod 0644 "$D/sub/d.sh"
# 已经是 0755 的 shebang 脚本：不该被重复计数（也不该被动 mtime）
printf '#!/bin/sh\ntrue\n'               >"$D/e.sh";      chmod 0755 "$D/e.sh"

n="$(bash "$NORM" --dir "$D" 2>/dev/null)"
chk "A1 归一处数 = 3（a.sh / b.lua / sub/d.sh 缺位；已 0755 的 e.sh 不计入）" "$n" "3"
chk "A2 a.sh -> 可执行"      "$([ -x "$D/a.sh" ] && echo y || echo n)" "y"
chk "A3 b.lua -> 可执行"     "$([ -x "$D/b.lua" ] && echo y || echo n)" "y"
chk "A4 sub/d.sh -> 可执行（递归到子目录）" "$([ -x "$D/sub/d.sh" ] && echo y || echo n)" "y"
chk "A5 e.sh 保持 0755"      "$(stat -c %A "$D/e.sh" 2>/dev/null)" "-rwxr-xr-x"
chk "A6 data.txt **未**被加可执行位（无 shebang 不误伤）" \
	"$([ -x "$D/data.txt" ] && echo y || echo n)" "n"
chk "A7 sub/c.conf **未**被加可执行位" \
	"$([ -x "$D/sub/c.conf" ] && echo y || echo n)" "n"

# -----------------------------------------------------------------------------
# B. 幂等
# -----------------------------------------------------------------------------
printf '\n\033[1m── B  幂等：二次运行归一处数为 0\033[0m\n'
n2="$(bash "$NORM" --dir "$D" 2>/dev/null)"
chk "B1 二次运行归一处数 = 0" "$n2" "0"
chk "B2 二次运行后 a.sh 仍可执行" "$([ -x "$D/a.sh" ] && echo y || echo n)" "y"

# -----------------------------------------------------------------------------
# C. --check：判据与副作用分离
# -----------------------------------------------------------------------------
printf '\n\033[1m── C  --check：缺位时 rc≠0，且绝不改动文件\033[0m\n'
printf '#!/bin/sh\ntrue\n' >"$D/f.sh"; chmod 0644 "$D/f.sh"

if bash "$NORM" --check "$D" >/dev/null 2>&1; then
	no "C1 --check 在存在缺位脚本时必须返回非零"
else
	ok "C1 --check 在存在缺位脚本时返回非零"
fi
chk "C2 --check **不**修改文件（f.sh 仍是 0644）" \
	"$([ -x "$D/f.sh" ] && echo y || echo n)" "n"

err="$(bash "$NORM" --check "$D" 2>&1 >/dev/null)"
has "C3 --check 的报错里点名了缺位文件" "$err" "f.sh"
has "C4 --check 的报错说明了后果（会被 exec / 直接调用拒绝）" "$err" "exec"

bash "$NORM" --dir "$D" >/dev/null 2>&1
if bash "$NORM" --check "$D" >/dev/null 2>&1; then
	ok "C5 归一后 --check 通过"
else
	no "C5 归一后 --check 通过"
fi
chk "C6 --check 通过时 stdout 也是单个整数" "$(bash "$NORM" --check "$D" 2>/dev/null)" "0"

# -----------------------------------------------------------------------------
# D. 0 文件 = 硬失败（"什么都没检查"不能报成功）
# -----------------------------------------------------------------------------
printf '\n\033[1m── D  0 文件 = 硬失败（与 pin-lua 同一条纪律）\033[0m\n'
E="$WORK/empty"; mkdir -p "$E"
if bash "$NORM" --dir "$E" >/dev/null 2>&1; then
	no "D1 空目录下必须失败（不能报成功）"
else
	ok "D1 空目录下失败（0 文件不算通过）"
fi
has "D2 报错里点明「0 个文件不算通过」（不是静默成功）" \
	"$(bash "$NORM" --dir "$E" 2>&1 >/dev/null)" "0 个文件"
if bash "$NORM" --dir "$WORK/does-not-exist" >/dev/null 2>&1; then
	no "D3 目录不存在时必须失败"
else
	ok "D3 目录不存在时失败"
fi

# -----------------------------------------------------------------------------
# E. stdout / stderr 分工
# -----------------------------------------------------------------------------
printf '\n\033[1m── E  stdout 只留整数，人类日志全走 stderr\033[0m\n'
printf '#!/bin/sh\ntrue\n' >"$D/g.sh"; chmod 0644 "$D/g.sh"
so="$(bash "$NORM" --dir "$D" 2>/dev/null)"
case "$so" in
	*[!0-9]*) no "E1 stdout 里只有数字" "got=[$so]" ;;
	*)        ok "E1 stdout 里只有数字（got=$so）" ;;
esac
se="$(bash "$NORM" --dir "$D" 2>&1 >/dev/null)"
has "E2 人类可读日志走 stderr" "$se" "可执行位归一"

# -----------------------------------------------------------------------------
# F. --file：无扩展名文件（cgi-bin/luci 这类）与互斥性
# -----------------------------------------------------------------------------
printf '\n\033[1m── F  --file：无扩展名入口同样生效\033[0m\n'
printf '#!/usr/bin/lua5.1\nprint(1)\n' >"$WORK/luci"; chmod 0644 "$WORK/luci"
nf="$(bash "$NORM" --file "$WORK/luci" 2>/dev/null)"
chk "F1 --file 对无扩展名文件生效（归一处数 1）" "$nf" "1"
chk "F2 无扩展名文件变为可执行" "$([ -x "$WORK/luci" ] && echo y || echo n)" "y"
if bash "$NORM" --dir "$D" --file "$WORK/luci" >/dev/null 2>&1; then
	no "F3 --file 与 --dir 混用必须被拒绝"
else
	ok "F3 --file 与 --dir 混用被拒绝（范围语义重叠）"
fi
if bash "$NORM" >/dev/null 2>&1; then
	no "F4 不给目标时必须失败"
else
	ok "F4 不给目标时失败并打印用法"
fi

# -----------------------------------------------------------------------------
# G. 静态纪律：两个调用点都真的调了它
# -----------------------------------------------------------------------------
printf '\n\033[1m── G  静态纪律：两个调用点都在，判据不漂移\033[0m\n'
# ⚠️ 这里刻意用 `bash .*normalize-modes\.sh` 而不是只数 `normalize-modes.sh`：
#   后者会把 packaging-adaptations.txt 里那条**说明文字**也数进来（那是一条文档，
#   不是调用），计数于是虚高、且改文档就会让断言变红 —— 那是在测文档而不是测代码。
chk "G1 build-deb.sh 调用了 normalize-modes.sh（否则打出的包仍是 0644）" \
	"$(grep -cE 'bash .*normalize-modes\.sh' "$ROOT/scripts/build-deb.sh" || true)" "1"
chk "G2 build-deb.sh 对 /etc/init.d/openclash 用 install -m 0755（systemd ExecStart 依赖它）" \
	"$(grep -cE 'install -m 0755 .*etc/init\.d/openclash' "$ROOT/scripts/build-deb.sh" || true)" "1"
chk "G3 run-e2e.sh 也调用了同一份（两处共用一份实现，判据不会漂）" \
	"$(grep -cE 'bash .*normalize-modes\.sh' "$ROOT/tests/e2e/linux/run-e2e.sh" || true)" "1"
# 用 -F：`$f` 是字面的 shell 变量名，绝不能让 grep 把它当正则锚点
chk "G4 e2e 的 L2 里有「上游直接执行」的可执行位断言" \
	"$(grep -cF 'chk "可执行 /usr/share/openclash/$f' "$ROOT/tests/e2e/linux/run-e2e.sh" || true)" "1"
# 判据必须是 shebang，不能退化成"按扩展名"—— 后者会漏掉无扩展名入口。
# ⚠️ 计数前必须剥注释：本脚本自己的文件头注释里就写了 `head -c 2`，
#    不剥会数成 2（本仓库已在别处踩过两次"注释里的字符串也被 grep 命中"）。
chk "G5 判据是 shebang（head -c 2），不是按扩展名猜" \
	"$(grep -vE '^[[:space:]]*#' "$NORM" | grep -c 'head -c 2' || true)" "1"
not_has() { case "$2" in *"$3"*) no "$1" "不该出现 [$3]" ;; *) ok "$1" ;; esac; }
not_has "G6 实现里没有按 .sh/.lua 扩展名硬编码（会漏无扩展名入口）" \
	"$(grep -vE '^[[:space:]]*#' "$NORM")" "-name '*.sh'"
# 回归锁：MODE 初值一度写成 `MODE="${1:-}"`，把第一个**选项**（--dir）当成模式，
# 于是所有调用都落到 *) 分支报「未知模式：--dir」，stdout 为空 ——
# 症状是"调用方拿到空字符串"，而不是"脚本报错"，极易误判成 stdout 被污染。
chk "G7 MODE 初值是空串（不能取 \$1，否则 --dir 被当成模式）" \
	"$(grep -cF 'MODE=""' "$NORM" || true)" "1"
not_has "G8 实现里没有把 \$1 当 MODE 初值" "$(grep -vE '^[[:space:]]*#' "$NORM")" 'MODE="${1:-}"'

# =============================================================================
printf '\n\033[1m════════════════════════════════════════\033[0m\n'
printf '  \033[32mPASS %d\033[0m   \033[31mFAIL %d\033[0m\n' "$PASS" "$FAIL"
printf '\033[1m════════════════════════════════════════\033[0m\n'
[ "$FAIL" -eq 0 ] || exit 1
exit 0
