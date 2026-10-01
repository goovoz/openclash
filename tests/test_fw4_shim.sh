#!/usr/bin/env bash
# =============================================================================
# openclash-rt  fw4 垫片单元测试
# -----------------------------------------------------------------------------
# 验证 runtime/net/fw4 的四件事（对应 docs/03-路径契约.md §2.3）：
#
#   A. §2.3.2 骨架正确性 —— 7 个 base chain，type/hook/priority 逐项正确
#   B. §2.3.2 幂等性 —— 重复 check 不重复创建、不报错
#   C. §2.3.2 反向断言 —— nat_output 必须【不】被垫片创建；若被外部创建则报错
#   D. §2.3.5 include 契约 —— reload 时执行 firewall.*=include 的 type=script 脚本
#   E. dry-run 不触碰系统
#
# 依赖 tests/mock/bin/nft（最小 nftables 模拟器）。
#
# 用法： bash tests/test_fw4_shim.sh
# =============================================================================
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

# ⚠️ 不要用 ${TMPDIR}：在 Windows/MSYS 沙箱中它可能被设为 Windows 盘符路径
# （C:/Users/.../Temp），拼出的路径会被安全策略判为 "embedded drive prefix"
# 而拒绝 rm，导致状态清理静默失败、用例之间互相污染。
# 硬编码 /tmp 由 MSYS 正确映射，是最稳的选择。
WORK="/tmp/ocrt-fw4.$$"
rm -rf "$WORK" 2>/dev/null || true
mkdir -p "$WORK"

export PATH="$HERE/mock/bin:$PATH"

FW4="$ROOT/runtime/net/fw4"
NFT="$HERE/mock/bin/nft"
# 固定 nft 可执行文件，避免 MSYS 上的 /usr/bin/nft 之类的意外命中
export OPENCLASH_RT_NFT="$NFT"
# 骨架落盘目录指向工作区，避免写 /etc
export OPENCLASH_RT_SKELETON_DIR="$WORK/nftables.d"
mkdir -p "$OPENCLASH_RT_SKELETON_DIR"

PASS=0; FAIL=0
it()  { printf '\n\033[1m── %s\033[0m\n' "$1"; }
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
no()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1"; printf '        want=[%s] got=[%s]\n' "$3" "$2"; fi; }

cleanup() { rm -rf "$WORK" 2>/dev/null; }
trap cleanup EXIT

# 从 mock 状态里读某个链的定义体
chain_body() {
	local c="$1"
	[ -f "$MOCK_NFT_STATE/inet.fw4/$c.chain" ] && cat "$MOCK_NFT_STATE/inet.fw4/$c.chain" || printf ''
}
has_chain() { [ -f "$MOCK_NFT_STATE/inet.fw4/$1.chain" ]; }
has_table() { [ -f "$MOCK_NFT_STATE/inet.fw4/table" ]; }

# 状态隔离采用「分配式」：每次需要干净状态就换一个全新目录，
# 而不是 rm 掉旧目录。这样既不依赖 rm 的沙箱策略，也不会出现
# 「清理失败 → 用例互相污染」的连锁假失败。
STATE_SEQ=0
new_state() {
	STATE_SEQ=$((STATE_SEQ + 1))
	export MOCK_NFT_STATE="$WORK/nft-state.$STATE_SEQ"
	mkdir -p "$MOCK_NFT_STATE"
}

# =============================================================================
it "A1  从零建立骨架"
new_state
bash "$FW4" check >"$WORK/out.txt" 2>"$WORK/err.txt"
rc=$?
chk "check 退出码" "$rc" "0"
if has_table; then ok "table inet fw4 已建立"; else no "table inet fw4 已建立"; fi

# §2.3.2 权威清单：7 个链（nat_output 除外）
for c in input forward output dstnat srcnat mangle_prerouting mangle_output; do
	if has_chain "$c"; then ok "基础链存在: $c"; else no "基础链存在: $c"; fi
done

it "A2  type / hook / priority 逐项正确"
S_EXPECT="filter input 0"
chk "input     = type filter hook input     priority 0" \
	"$(chain_body input | grep -oE 'type [a-z]+ hook [a-z]+ priority -?[0-9]+')" \
	"type filter hook input priority 0"
chk "forward   = type filter hook forward   priority 0" \
	"$(chain_body forward | grep -oE 'type [a-z]+ hook [a-z]+ priority -?[0-9]+')" \
	"type filter hook forward priority 0"
chk "output    = type filter hook output    priority 0" \
	"$(chain_body output | grep -oE 'type [a-z]+ hook [a-z]+ priority -?[0-9]+')" \
	"type filter hook output priority 0"
chk "dstnat    = type nat hook prerouting    priority -100" \
	"$(chain_body dstnat | grep -oE 'type [a-z]+ hook [a-z]+ priority -?[0-9]+')" \
	"type nat hook prerouting priority -100"
chk "srcnat    = type nat hook postrouting   priority 100" \
	"$(chain_body srcnat | grep -oE 'type [a-z]+ hook [a-z]+ priority -?[0-9]+')" \
	"type nat hook postrouting priority 100"
chk "mangle_prerouting = type filter hook prerouting priority -150" \
	"$(chain_body mangle_prerouting | grep -oE 'type [a-z]+ hook [a-z]+ priority -?[0-9]+')" \
	"type filter hook prerouting priority -150"
chk "mangle_output     = type filter hook output     priority -150" \
	"$(chain_body mangle_output | grep -oE 'type [a-z]+ hook [a-z]+ priority -?[0-9]+')" \
	"type filter hook output priority -150"

for c in input forward output dstnat srcnat mangle_prerouting mangle_output; do
	if grep -q 'policy accept' "$MOCK_NFT_STATE/inet.fw4/$c.chain" 2>/dev/null; then
		ok "policy accept: $c（服务器场景不可用 drop）"
	else
		no "policy accept: $c"
	fi
done

it "B1  幂等：第二次 check 不新增、不报错"
BEFORE="$(ls "$MOCK_NFT_STATE/inet.fw4" | sort | tr '\n' ' ')"
bash "$FW4" check >"$WORK/out2.txt" 2>"$WORK/err2.txt"
rc=$?
AFTER="$(ls "$MOCK_NFT_STATE/inet.fw4" | sort | tr '\n' ' ')"
chk "第二次 check 退出码" "$rc" "0"
chk "链清单未变化" "$AFTER" "$BEFORE"
chk "第二次 check 无错误输出" "$(cat "$WORK/err2.txt")" ""
chk "第二次 check 无「已创建」提示（证明未重复建链）" \
	"$(grep -c '已创建基础链' "$WORK/err2.txt" 2>/dev/null)" "0"

it "C1  反向断言：垫片【不】创建 nat_output（§2.3.2）"
if has_chain nat_output; then
	no "nat_output 不应被垫片创建（上游 set_firewall 自建，抢建会留下无 hook 死链）"
else
	ok "垫片未创建 nat_output（正确）"
fi
chk "nat_output 不在骨架清单里" \
	"$(bash "$FW4" dry-run 2>/dev/null | grep -c 'chain nat_output' || true)" "0"

it "C2  若 nat_output 被外部抢先创建，check 必须报错"
# 本用例独占一个干净状态，避免污染后面的 D/E
new_state
bash "$FW4" check >/dev/null 2>&1
# 模拟「别的工具先建了 nat_output」
bash "$NFT" 'add chain inet fw4 nat_output { type nat hook output priority -1; }' 2>/dev/null
bash "$FW4" check >"$WORK/out3.txt" 2>"$WORK/err3.txt"
rc=$?
if [ "$rc" -ne 0 ]; then ok "check 返回非 0"; else no "check 返回非 0"; fi
if grep -q 'nat_output' "$WORK/err3.txt"; then ok "错误信息指出 nat_output"; else no "错误信息指出 nat_output"; fi

it "D1  include 契约：reload 执行 firewall.*=include 的 script"
# D/E 使用全新状态，与 C2 的污染彻底隔离
new_state
# 伪造 uci：只实现 fw4 垫片实际用到的两条调用形态
#   uci -q show firewall
#   uci -q get firewall.<sec>.<opt>
mkdir -p "$WORK/bin"
cat >"$WORK/bin/uci" <<'UCI'
#!/usr/bin/env bash
# 剥掉 -q / -n / -S 等全局开关
while [ "$#" -gt 0 ]; do
	case "$1" in
		-q|-n|-S|-N|-d*|-c|-P|-t) shift ;;
		*) break ;;
	esac
done
case "${1:-}" in
	show)
		shift
		if [ "${1:-}" = "firewall" ]; then
			printf 'firewall.openclash=include\n'
			printf 'firewall.openclash.type=script\n'
			printf 'firewall.openclash.path=%s\n' "$MOCK_INCLUDE_SCRIPT"
			printf 'firewall.other=include\n'
			printf 'firewall.other.type=include\n'
			printf 'firewall.other.path=%s\n' "$MOCK_INCLUDE_SCRIPT"
			exit 0
		fi
		exit 1
		;;
	get)
		shift
		case "${1:-}" in
			firewall.openclash)      echo include ;;
			firewall.openclash.type) echo script ;;
			firewall.openclash.path) echo "$MOCK_INCLUDE_SCRIPT" ;;
			firewall.other)          echo include ;;
			firewall.other.type)     echo include ;;
			firewall.other.path)     echo "$MOCK_INCLUDE_SCRIPT" ;;
			*) exit 1 ;;
		esac
		;;
	*) exit 1 ;;
esac
UCI
chmod +x "$WORK/bin/uci"

cat >"$WORK/include.sh" <<'INC'
#!/usr/bin/env bash
printf 'INCLUDE-RAN %s\n' "$(basename "$0")" >>"$MOCK_INCLUDE_MARK"
INC
chmod +x "$WORK/include.sh"

export MOCK_INCLUDE_SCRIPT="$WORK/include.sh"
export MOCK_INCLUDE_MARK="$WORK/include.mark"
: >"$MOCK_INCLUDE_MARK"
export OPENCLASH_RT_UCI="$WORK/bin/uci"

bash "$FW4" reload >"$WORK/out4.txt" 2>"$WORK/err4.txt"
rc=$?
chk "reload 退出码" "$rc" "0"
if grep -q 'INCLUDE-RAN' "$MOCK_INCLUDE_MARK" 2>/dev/null; then
	ok "include 脚本被 reload 执行"
else
	no "include 脚本被 reload 执行"
	cat "$WORK/err4.txt"
fi
# 只执行 type=script 的那个，type=include 的不执行
chk "只执行了 type=script 的 include（1 次）" "$(grep -c 'INCLUDE-RAN' "$MOCK_INCLUDE_MARK")" "1"
# reload 后骨架仍完好
bash "$FW4" check >/dev/null 2>&1
chk "reload 后 check 仍返回 0" "$?" "0"

it "D2  include 脚本不存在时不报致命错"
export MOCK_INCLUDE_SCRIPT="$WORK/does-not-exist.sh"
bash "$FW4" reload >"$WORK/out5.txt" 2>"$WORK/err5.txt"
rc=$?
chk "reload 退出码（缺脚本只警告）" "$rc" "0"
if grep -q '不存在，跳过' "$WORK/err5.txt"; then ok "给出「跳过」提示"; else no "给出「跳过」提示"; fi
unset OPENCLASH_RT_UCI

it "E1  dry-run 不触碰系统状态"
new_state
OUT="$(bash "$FW4" dry-run 2>&1)"
rc=$?
chk "dry-run 退出码" "$rc" "0"
if [ -z "$(ls -A "$MOCK_NFT_STATE" 2>/dev/null)" ]; then
	ok "dry-run 后 mock nft 状态仍为空"
else
	no "dry-run 后 mock nft 状态仍为空"
	ls -la "$MOCK_NFT_STATE"
fi
if printf '%s' "$OUT" | grep -q 'add chain inet fw4 input'; then
	ok "dry-run 输出了将执行的语句"
else
	no "dry-run 输出了将执行的语句"
fi
printf '%s\n' "$OUT" | grep -c 'add chain' | sed 's/^/        拟建链数: /'

# =============================================================================
printf '\n\033[1m════════════════════════════════════════\033[0m\n'
printf '  PASS: \033[32m%d\033[0m    FAIL: \033[31m%d\033[0m\n' "$PASS" "$FAIL"
printf '\033[1m════════════════════════════════════════\033[0m\n'
[ "$FAIL" -eq 0 ] || exit 1
