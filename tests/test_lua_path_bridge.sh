#!/usr/bin/env bash
# =============================================================================
# Lua 搜索路径桥接测试
# -----------------------------------------------------------------------------
# 被测对象：runtime/lua/lua-path-bridge.sh
#
# 为什么测试里要注入假 ln / readlink / lua5.1：
#   本机（Windows/MSYS）**不能创建 POSIX 软链** —— `ln -s` 默认落成 0 字节
#   普通文件，即便开 MSYS=winsymlinks:nativestrict，readlink 也认不出来。
#   而桥接脚本的核心价值恰恰是"软链是否建对了地方、指向了正确的目标"。
#   所以这里注入一对**共享状态**的假实现：
#     · 假 ln      ：把 `-sfn TARGET PATH` 记进状态文件
#     · 假 readlink：从状态文件里查 PATH
#   这样软链语义在文件系统上被完整模拟，--check/--apply/--remove 的判断
#   逻辑全部可测；同时因为断言的是"记录下来的 ln 调用参数"，比断言
#   readlink 更直接（能抓出"目标写错"这类问题）。
#   本机同样没有 lua5.1，所以注入假 lua，把 cpath/path **硬编码**进去
#   （不能靠环境变量传：被测脚本故意用 `env -i` 起解释器以拿到编译期默认值，
#   环境变量会被清掉）。
#
# 覆盖：
#   A. 链接规格：软链总数、位置、**目标必须是绝对路径**
#   B. --stagedir：打进 .deb 的那一版
#   C. --check：就绪/缺失/以及"Lua 默认路径本来就含 /usr/lib/lua"的短路
#   D. --apply：只在实测到且已存在的目录里补链；/usr/share 不放 .so 类
#   E. --remove：只删自己建的，且二次确认目标一致
#   F. 路径模板解析的边界（/?/init.lua、loadall.so、不存在的目录）
#   G. 静态纪律
#
# 用法： bash tests/test_lua_path_bridge.sh
# =============================================================================
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BRIDGE="$ROOT/runtime/lua/lua-path-bridge.sh"

# ⚠️ 硬编码 /tmp：${TMPDIR} 在本沙箱是 Windows 盘符路径，会被安全策略拒绝
WORK="/tmp/ocrt-bridge.$$"
rm -rf "$WORK" 2>/dev/null || true
mkdir -p "$WORK/bin" "$WORK/root"

PASS=0; FAIL=0
it()  { printf '\n\033[1m── %s\033[0m\n' "$1"; }
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
no()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "want=[$3] got=[$2]"; fi; }
has() { if printf '%s\n' "$2" | grep -qF -- "$3"; then ok "$1"; else no "$1" "输出里没有：$3"; fi; }
not() { if printf '%s\n' "$2" | grep -qF -- "$3"; then no "$1" "输出里不该有：$3"; else ok "$1"; fi; }
# 计数：变量可能是空串，`printf '%s\n' ""` 会产出一行空行，直接 grep -c 会得到 1。
# 所以统一用 `| grep -c .` 只数非空行。
nz()  { printf '%s\n' "$1" | grep -c . || true; }

cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

LN_STATE="$WORK/ln.state"
export FAKE_LN_STATE="$LN_STATE"
: >"$LN_STATE"

# --- 假 ln ---------------------------------------------------------------
# 用「真实存在的 0 字节文件，内容是目标路径」来代表软链。
#
# ⚠️ 这里曾经只用一份"内存里的调用记录"，结果 --remove 测试**永远失败**：
#    被测脚本的 --remove 走的是**真实 rm -f**，rm 不会去更新那份内存记录，
#    于是 readlink 仍然报"软链还在"。教训是：模拟层必须落在被测代码**真正
#    操作的那个介质**上。改用真实文件后，rm 的效果自然可观测。
# ⚠️ 所有传入路径都必须在 $WORK 之下（被测脚本在被注入 ROOT_PREFIX 时满足，
#    测试自己造的那条"外来软链"也要放进去），否则会写到宿主真实文件系统。
cat >"$WORK/bin/ln" <<'EOF'
#!/bin/sh
# 只支持被测脚本使用的那一种调用：ln -sfn TARGET PATH
[ "$1" = "-sfn" ] || { echo "fake-ln: 不支持的参数 $*" >&2; exit 2; }
target="$2"; path="$3"
mkdir -p "$(dirname "$path")" 2>/dev/null || true
# 覆盖：先摘掉旧记录，再写文件（模拟 -f）
if [ -f "$FAKE_LN_STATE" ]; then
	grep -v "^$path	" "$FAKE_LN_STATE" >"$FAKE_LN_STATE.n" 2>/dev/null || true
	mv -f "$FAKE_LN_STATE.n" "$FAKE_LN_STATE" 2>/dev/null || : >"$FAKE_LN_STATE"
fi
printf '%s\t%s\n' "$path" "$target" >>"$FAKE_LN_STATE"
printf '%s' "$target" >"$path"
EOF

# --- 假 readlink：读那个 0 字节文件 --------------------------------------
cat >"$WORK/bin/readlink" <<'EOF'
#!/bin/sh
path="$1"
# 真 rm 删掉之后这里自然失败 —— 这正是我们要的行为
[ -f "$path" ] || exit 1
cat "$path"
EOF

chmod +x "$WORK/bin/ln" "$WORK/bin/readlink"

# --- 假 lua5.1（cpath/path 硬编码，因为 --probe 用 env -i 清环境）-----------
# 参数形式见被测脚本：lua5.1 -e '<chunk>'
make_fake_lua() {   # <文件路径> <cpath> <path>
	cat >"$1" <<EOF
#!/bin/sh
# \$2 = -e 后面的 chunk
chunk="\$2"
case "\$chunk" in
	*package.cpath*)
		printf '%s\n' '$2'
		printf '%s\n' '$3'
		;;
	*_VERSION*)
		printf '%s' 'Lua 5.1'
		;;
	*local\ mods=*)
		# require 校验：把 chunk 里内联的模块名逐个回显为 OK。
		# 这样能验证"模块清单有没有被正确内联"（曾经写成靠 ... 接参数，
		# 那样模块名会全部丢失）。
		printf '%s\n' "\$chunk" | tr ',' '\n' | sed -n "s/^.*'\([^']*\)'/\1/p" | while read -r m; do
			[ -n "\$m" ] && printf 'OK   %s\n' "\$m"
		done
		;;
esac
exit 0
EOF
	chmod +x "$1"
}

# 默认 cpath/path：模拟 Debian 的真实默认值（依据 Debian #671286）
DEF_CPATH='./?.so;/usr/local/lib/lua/5.1/?.so;/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;/usr/lib/lua/5.1/?.so;/usr/local/lib/lua/5.1/loadall.so'
DEF_PATH='./?.lua;/usr/local/share/lua/5.1/?.lua;/usr/local/share/lua/5.1/?/init.lua;/usr/share/lua/5.1/?.lua;/usr/share/lua/5.1/?/init.lua'
make_fake_lua "$WORK/bin/lua5.1" "$DEF_CPATH" "$DEF_PATH"

# --- 假 dpkg-architecture：让「无 multiarch 探测」可控 ----------------------
# 被测脚本：[ -n "$MULTIARCH" ] || MULTIARCH="$(dpkg-architecture -qDEB_HOST_MULTIARCH)"
# 默认无 multiarch 的用例（run_bridge "" ...）若**不** mock，真机 Debian 上
# dpkg-architecture 会回 x86_64-linux-gnu，让该用例凭空多出 3 条软链。
# 这里给「模拟无 multiarch」一个真无可探测的位：
#   FAKE_DPKG_NO_MULTIARCH=1 时：dpkg-architecture 退 0 但啥也不输出。
#   未设该变量时：输出 FAKE_DPKG_MULTIARCH 的值（默认 x86_64-linux-gnu）。
cat >"$WORK/bin/dpkg-architecture" <<'EOF'
#!/bin/sh
# 极简实现：只支持 -qDEB_HOST_MULTIARCH 这一种调用
[ "$1" = "-qDEB_HOST_MULTIARCH" ] || exit 1
if [ -n "${FAKE_DPKG_NO_MULTIARCH:-}" ]; then exit 0; fi
printf '%s\n' "${FAKE_DPKG_MULTIARCH:-x86_64-linux-gnu}"
EOF
chmod +x "$WORK/bin/dpkg-architecture"

export PATH="$WORK/bin:$PATH"

# 在被测脚本里，"假 lua 的 cpath 含哪些目录"必须对应到 **假 root 下真实存在
# 的目录**，否则 --apply 会（正确地）跳过它们。所以先在假 root 里铺好目录。
mkroot() {
	local r="$1"
	mkdir -p "$r/usr/lib/lua/luci/template" "$r/usr/lib/lua/nixio" \
	         "$r/usr/lib/lua/5.1" \
	         "$r/usr/lib/x86_64-linux-gnu/lua/5.1" \
	         "$r/usr/share/lua/5.1"
	: >"$r/usr/lib/lua/nixio.so"
	: >"$r/usr/lib/lua/lucihttp.so"
	: >"$r/usr/lib/lua/luci/ip.so"
	: >"$r/usr/lib/lua/luci/jsonc.so"
	: >"$r/usr/lib/lua/luci/template/parser.so"
	: >"$r/usr/lib/lua/nixio/fs.lua"
	: >"$r/usr/lib/lua/nixio/util.lua"
}
mkroot "$WORK/root"

# 以显式 multiarch 运行桥接。
#
# ⚠️ multiarch 必须作为**位置参数**传进来，不能写成 `DEB_HOST_MULTIARCH=x bridge ...`：
#    bash 对函数调用做前缀赋值时，该变量会在函数返回后**保留在调用者的环境里**
#    （这是 bash 的已知行为，与外部命令不同）。之前就因此让后续的 --apply
#    拿到了空的 multiarch，凭空少了一段软链，测试报出莫名其妙的 5 vs 8。
run_bridge() {   # <multiarch> <args...>
	local ma="$1"; shift
	DEB_HOST_MULTIARCH="$ma" \
	OPENCLASH_RT_ROOT_PREFIX="$WORK/root" \
	OPENCLASH_RT_LN="$WORK/bin/ln" \
	OPENCLASH_RT_READLINK="$WORK/bin/readlink" \
	bash "$BRIDGE" "$@" 2>&1
}
bridge() { run_bridge "x86_64-linux-gnu" "$@"; }

# 「探测也探测不到」的形态：被测脚本会 [ -n "$MULTIARCH" ] || fallback 到
# dpkg-architecture。本 helper 同时清掉 DEB_HOST_MULTIARCH、让 dpkg-architecture
# mock 返回空（FAKE_DPKG_NO_MULTIARCH=1），用来断言「无 multiarch 时退化 5 条」
# 这类语义。
run_bridge_noarch() {
	DEB_HOST_MULTIARCH="" FAKE_DPKG_NO_MULTIARCH=1 \
	OPENCLASH_RT_ROOT_PREFIX="$WORK/root" \
	OPENCLASH_RT_LN="$WORK/bin/ln" \
	OPENCLASH_RT_READLINK="$WORK/bin/readlink" \
	bash "$BRIDGE" "$@" 2>&1
}

# 不带 root prefix 的调用（--stagedir 模式自己带 STAGE 路径）
run_bridge_noroot() {   # <multiarch> <args...>
	local ma="$1"; shift
	DEB_HOST_MULTIARCH="$ma" OPENCLASH_RT_ROOT_PREFIX="" \
	OPENCLASH_RT_LN="$WORK/bin/ln" \
	OPENCLASH_RT_READLINK="$WORK/bin/readlink" \
	bash "$BRIDGE" "$@" 2>&1
}

# 已记录的软链：读登记表，但**只报告此刻仍存在于磁盘上的**那些，
# 这样真实 rm 的效果就能被看见。
links() {
	[ -f "$LN_STATE" ] || return 0
	local p t
	while IFS='	' read -r p t; do
		[ -n "$p" ] && [ -f "$p" ] && printf '%s -> %s\n' "$p" "$t"
	done <"$LN_STATE"
}

# 清空"系统状态"，而不只是清空登记表。
#
# ⚠️ 教训：这里最初只做 `: >"$LN_STATE"`，结果 C2（"缺一条软链时 --check 应
#    返回 1"）**永远失败**。原因是模拟层是**真实文件**，而被测脚本的 --check
#    走的是 readlink（= cat 文件），它看到的是文件系统而不是我们的登记表 ——
#    登记表清了、文件还在，--check 自然仍报"齐全"。
#    这和 E 阶段踩的坑是同一件事的镜像：模拟层必须落在被测代码**真正读写的
#    那个介质**上。所以这里必须把文件真删掉。
reset_links() {
	local p t
	if [ -f "$LN_STATE" ]; then
		while IFS='	' read -r p t; do
			[ -n "$p" ] && rm -f "$p" 2>/dev/null
		done <"$LN_STATE"
	fi
	: >"$LN_STATE"
}

# =============================================================================
it "A. 链接规格（--print：确认位置与目标）"
# =============================================================================
reset_links
OUT="$(run_bridge "x86_64-linux-gnu" --print)"
# 假 root 里没有 /usr/lib/lua/5.1 与 /usr/share/lua/5.1，但 --print 只判断
# **目标**是否存在（不判断链接所在目录），所以 8 条都应列出
chk "A --print 列出 8 条软链" "$(printf '%s\n' "$OUT" | grep -c -- '->')" "8"
has "A .so 侧：多架构目录里放 luci/"  "$OUT" "/usr/lib/x86_64-linux-gnu/lua/5.1/luci -> /usr/lib/lua/luci"
has "A .so 侧：多架构目录里放 nixio.so" "$OUT" "/usr/lib/x86_64-linux-gnu/lua/5.1/nixio.so -> /usr/lib/lua/nixio.so"
has "A .so 侧：多架构目录里放 lucihttp.so" "$OUT" "/usr/lib/x86_64-linux-gnu/lua/5.1/lucihttp.so -> /usr/lib/lua/lucihttp.so"
has "A .so 侧双份覆盖：/usr/lib/lua/5.1/luci" "$OUT" "/usr/lib/lua/5.1/luci -> /usr/lib/lua/luci"
has "A .lua 侧：/usr/share/lua/5.1/luci" "$OUT" "/usr/share/lua/5.1/luci -> /usr/lib/lua/luci"
has "A .lua 侧：/usr/share/lua/5.1/nixio" "$OUT" "/usr/share/lua/5.1/nixio -> /usr/lib/lua/nixio"
# 这一条是设计核心：Debian 政策要求架构无关的 .lua 放 /usr/share，
# 所以 .lua 侧必须有独立的一份软链，不能指望 /usr/lib。
chk "A .lua 侧不含 .so（/usr/share 只放纯 Lua 类）" \
	"$(printf '%s\n' "$OUT" | grep -c '/usr/share/lua/5.1/.*\.so')" "0"
# 这一条测的是"multiarch 探测不到时不能崩，也不能造出 /usr/lib/lib/"
OUT2="$(run_bridge_noarch --print)"
chk "A 无 multiarch 时退化为 5 条（不产生 /usr/lib/<triple>/）" \
	"$(printf '%s\n' "$OUT2" | grep -c -- '->')" "5"
not "A 无 multiarch 时不产生 /usr/lib/lib/ 这种双重目录" "$OUT2" "/usr/lib/lib/"

# =============================================================================
it "B. --stagedir：打进 .deb 的那一版"
# =============================================================================
reset_links
STAGE="$WORK/stage"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -a "$WORK/root/." "$STAGE/"
OUT="$(run_bridge_noroot "x86_64-linux-gnu" --stagedir "$STAGE")"
chk "B --stagedir 建了 8 条" "$(nz "$(links)")" "8"
LNK="$(links)"
# ★ 最关键的一条：软链目标必须是**安装后的最终绝对路径**，不能带 staging 前缀。
#   若写成 "$STAGE/usr/lib/lua/luci"，装到 / 之后就是死链。
has "B 目标是不带 staging 前缀的绝对路径" "$LNK" \
	"$STAGE/usr/share/lua/5.1/luci -> /usr/lib/lua/luci"
not "B 目标里不含 staging 目录" "$LNK" "$STAGE/usr/lib/lua/luci"
has "B 多架构目录被创建出来" "$([ -d "$STAGE/usr/lib/x86_64-linux-gnu/lua/5.1" ] && echo yes)" "yes"

# 目标不存在时不建链（P1 阶段 luci/ 还没装）：
reset_links
STAGE2="$WORK/stage2"
rm -rf "$STAGE2"; mkdir -p "$STAGE2/usr/lib/x86_64-linux-gnu/lua/5.1"
OUT="$(run_bridge_noroot "x86_64-linux-gnu" --stagedir "$STAGE2")"
chk "B 目标不存在时不建悬空软链（0 条）" "$(nz "$(links)")" "0"
has "B 并给出可操作的提示" "$OUT" "没有创建任何软链"

# =============================================================================
it "C. --check：就绪 / 缺失 / 默认路径已含模块根"
# =============================================================================
# C1 软链齐全 → 0
reset_links
bridge --apply >/dev/null 2>&1 || true
bridge --check >/dev/null 2>&1
chk "C1 软链齐全时 --check 返回 0" "$?" "0"

# C2 缺一条 → 1
reset_links
if bridge --check >/dev/null 2>&1; then
	no "C2 软链缺失时 --check 返回 1" "却返回了 0"
else
	ok "C2 软链缺失时 --check 返回 1"
fi

# C3 假 lua 的默认 cpath 里本来就含 /usr/lib/lua → 短路，无需桥接
#    这个场景是真实存在的：若某天 Debian 把 /usr/lib/lua 加进默认 cpath，
#    或用户用自编 Lua，我们就不该再往系统里塞软链。
make_fake_lua "$WORK/bin/lua5.1" '/usr/lib/lua/?.so;./?.so' '/usr/lib/lua/?.lua;./?.lua'
reset_links
OUT="$(run_bridge "x86_64-linux-gnu" --check)"; RC=$?
chk "C3 默认路径已含 /usr/lib/lua 时 --check 返回 0（即使一条软链都没有）" "$RC" "0"
has "C3 并明确说明无需桥接" "$OUT" "无需桥接"
chk "C3 该场景下没有新建任何软链" "$(nz "$(links)")" "0"
# 复原假 lua
make_fake_lua "$WORK/bin/lua5.1" "$DEF_CPATH" "$DEF_PATH"

# =============================================================================
it "D. --apply：按实测路径兜底"
# =============================================================================
# 假 root 里只有 /usr/lib/x86_64-linux-gnu/lua/5.1、/usr/lib/lua/5.1 与
# /usr/share/lua/5.1 存在；/usr/local/lib/lua/5.1 与 /usr/local/share/lua/5.1
# **不存在** → 必须跳过，不能凭空造目录（造了也没用，只会留垃圾）。
reset_links
OUT="$(bridge --apply)" ; RC=$?
chk "D --apply 返回 0" "$RC" "0"
LNK="$(links)"
# 3（多架构 cpath）+ 3（/usr/lib/lua/5.1，Debian 默认 cpath 里也有）
# + 2（/usr/share/lua/5.1，纯 Lua）= 8
chk "D 只在 3 个已存在且被搜索的目录里补链（3 + 3 + 2 = 8 条）" "$(nz "$LNK")" "8"
not "D 不往不存在的 /usr/local 目录里塞东西" "$LNK" "/usr/local/"
not "D 不把 loadall.so 当成目录" "$LNK" "loadall"
has "D 多架构目录里放 luci/" "$LNK" "/usr/lib/x86_64-linux-gnu/lua/5.1/luci -> /usr/lib/lua/luci"
has "D /usr/lib/lua/5.1 里也放一份（Debian 默认 cpath 的另一段）" "$LNK" \
	"/usr/lib/lua/5.1/nixio.so -> /usr/lib/lua/nixio.so"
has "D /usr/share 里放纯 Lua 的 nixio/" "$LNK" "/usr/share/lua/5.1/nixio -> /usr/lib/lua/nixio"
# 同一条规则：/usr/share 下不该出现 .so 类
chk "D /usr/share 下不放 .so 类" \
	"$(printf '%s\n' "$LNK" | grep -c '/usr/share/.*\.so')" "0"
# loadall.so 的模板形态是 `.../loadall.so`（没有 ?），不能被当成目录。
# ⚠️ links() 输出的是 `path -> target` 这种**给人看**的格式，不是制表符分隔，
#    所以要先按 ` -> ` 切掉目标再取目录；曾经用 `awk -F'\t'` 取 $1，拿到的
#    是整行，dirname 于是收到 `->` 当成选项，报一堆 "unknown option -- >"。
chk "D 目标目录数 = 3" \
	"$(printf '%s\n' "$LNK" | sed 's/ -> .*$//' | xargs -n1 dirname | sort -u | grep -c .)" "3"
has "D 写了状态清单（供 --remove 用）" \
	"$([ -f "$WORK/root/var/lib/openclash-rt/lua-path-bridge.list" ] && echo yes)" "yes"

# =============================================================================
it "E. --remove：只删自己建的，且二次确认目标一致"
# =============================================================================
# 先塞一条「别人的」软链（目标不同），确认 --remove 不碰它
"$WORK/bin/ln" -sfn /somewhere/else "$WORK/root/usr/share/lua/5.1/foreign" >/dev/null 2>&1
OUT="$(bridge --remove)"; RC=$?
chk "E --remove 返回 0" "$RC" "0"
LNK="$(links)"
chk "E 自己建的 8 条被清掉" \
	"$(printf '%s\n' "$LNK" | grep -v 'foreign' | grep -c . || true)" "0"
has "E 目标不一致的那条（别人的）软链被保留" "$LNK" \
	"$WORK/root/usr/share/lua/5.1/foreign -> /somewhere/else"
chk "E 状态清单被删除" \
	"$([ -f "$WORK/root/var/lib/openclash-rt/lua-path-bridge.list" ] && echo yes || echo no)" "no"
# 幂等：再删一次不应报错
OUT="$(bridge --remove)"; RC=$?
chk "E 重复 --remove 幂等（返回 0 且提示无需清理）" "$RC" "0"
has "E 重复 --remove 给出明确提示" "$OUT" "无需清理"

# =============================================================================
it "F. 路径模板解析的边界"
# =============================================================================
# 用一个"畸形但合法"的 cpath/path：包含 ?/init.lua、loadall.so、不存在的目录、
# 以及一个认不出的模板
make_fake_lua "$WORK/bin/lua5.1" \
	'./?.so;/usr/lib/x86_64-linux-gnu/lua/5.1/?.so;/nowhere/at/all/?.so;/usr/local/lib/lua/5.1/loadall.so;/weird/?/other.so' \
	'/usr/share/lua/5.1/?/init.lua;/usr/share/lua/5.1/?.lua;/nowhere/lua/?.lua'
reset_links
bridge --apply >/dev/null 2>&1
LNK="$(links)"
has "F ?/init.lua 形态被正确还原成目录" "$LNK" "/usr/share/lua/5.1/luci -> /usr/lib/lua/luci"
not "F loadall.so 不被当成目录" "$LNK" "loadall"
not "F 不存在的目录被跳过" "$LNK" "/nowhere/"
not "F 认不出的模板不瞎猜" "$LNK" "/weird/"
# 同一目录同时来自 ?/init.lua 与 ?.lua 两条模板，规格表内部不能出现重复行，
# 否则会建两遍（无害但说明 _lua_links 有冗余，早晚漂移）
chk "F 规格表内部对该目录无重复规格" \
	"$(bridge --print | grep -c '/usr/share/lua/5.1/luci ->')" "1"
chk "F 规格表总行数恒为 8（与探测结果无关）" \
	"$(bridge --print | grep -c -- '->')" "8"
make_fake_lua "$WORK/bin/lua5.1" "$DEF_CPATH" "$DEF_PATH"

# =============================================================================
it "G. 静态纪律"
# =============================================================================
if bash -n "$BRIDGE" 2>/dev/null; then ok "G bash -n 通过"; else no "G bash -n 通过" "$(bash -n "$BRIDGE" 2>&1 | head -2)"; fi
chk "G 不含 mktemp" "$(grep -c 'mktemp' "$BRIDGE" || true)" "0"
# ⚠️ 只数**赋值行**：这两个变量名在脚本文档注释里也会出现（说明如何注入），
#    裸 grep -c 会把注释算进去，得到 2 而不是 1。
chk "G ln 可注入（测试 seam）" \
	"$(grep -cE '^LN="\$\{OPENCLASH_RT_LN' "$BRIDGE" || true)" "1"
chk "G READLINK 可注入（测试 seam）" \
	"$(grep -cE '^READLINK="\$\{OPENCLASH_RT_READLINK' "$BRIDGE" || true)" "1"
# 排除注释行再查：文档里会提到 readlink，那不是调用
chk "G 非注释行里不再有裸 readlink 调用（全部走 \$READLINK）" \
	"$(grep -vE '^[[:space:]]*#' "$BRIDGE" | grep -cE '(^|[^"$A-Z_])readlink ' || true)" "0"
chk "G 非注释行里不再有裸 ln -sf 调用" \
	"$(grep -vE '^[[:space:]]*#' "$BRIDGE" | grep -cE '(^|[^"$A-Z_])ln -sf' || true)" "0"

# =============================================================================
printf '\n\033[1m════════════════════════════════════════\033[0m\n'
printf '  \033[32mPASS %d\033[0m   \033[31mFAIL %d\033[0m\n' "$PASS" "$FAIL"
printf '\033[1m════════════════════════════════════════\033[0m\n'
[ "$FAIL" -eq 0 ] || exit 1
exit 0
