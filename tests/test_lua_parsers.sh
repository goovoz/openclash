#!/usr/bin/env bash
# =============================================================================
# P1（Lua C 模块）构建脚本测试
# -----------------------------------------------------------------------------
# 本机（Windows 沙箱）**没有 C 工具链**，因此这里不验证"编出来的 .so 能不能
# 加载"（那是 CI 上 ubuntu-latest 的活）。这里验证的是**在无工具链条件下
# 也完全可验证**的三类东西：
#
#   A. 上游构建文件解析器的正确性
#      把 upstream 的 Makefile / CMakeLists.txt 当输入，断言解析出的源文件
#      清单与事实一致，并且**每个源文件都真实存在**。
#      这是整个 P1 里最容易出错、也最值得测的部分：解析器读空或读错会导致
#      "少编一个模块"，而症状要到运行期某个功能才炸，极难定位。
#
#   B. 产物路径契约
#      断言构建脚本声明的安装路径与上游硬编码的路径一致。上游在
#      luci-app-openclash/Makefile 与 postrm 里用绝对路径操作
#      /usr/lib/lua/luci/**，路径错了会被 `>/dev/null 2>&1` 静默吞掉。
#
#   C. 静态纪律
#      不含 mktemp（本沙箱 TMPDIR 是盘符路径，会挂死）、不写 vendor/、
#      日志不污染命令替换的 stdout —— 这三条都是本项目实际踩过的坑。
#
# 用法： bash tests/test_lua_parsers.sh
# =============================================================================
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
VENDOR="$ROOT/vendor"

BUILD_SH="$ROOT/runtime/lua/build-lua-modules.sh"
PARSERS_SH="$ROOT/runtime/lua/lib/upstream-parsers.sh"
# 与 runtime/ubus/build-ubus.sh 共用的公共构建辅助（P1.5 抽出）
COMMON_SH="$ROOT/runtime/lib/build-common.sh"

PASS=0; FAIL=0; SKIP=0
it()  { printf '\n\033[1m── %s\033[0m\n' "$1"; }
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
no()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; }
sk()  { SKIP=$((SKIP+1)); printf '  \033[33mSKIP\033[0m  %s\n' "$1"; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "want=[$3] got=[$2]"; fi; }

# 前置：vendor 树必须已拉取
if [ ! -f "$VENDOR/libnl-tiny/CMakeLists.txt" ] || [ ! -f "$VENDOR/luci/luci-base/src/Makefile" ]; then
	printf '\033[33m[SKIP]\033[0m vendor/ 树不完整，先运行 scripts/fetch-luci-vendor.sh\n'
	exit 0
fi

# shellcheck source=../runtime/lua/lib/upstream-parsers.sh
. "$PARSERS_SH"

# 计数小工具：把多行变成一行便于比对
j() { tr '\n' ' ' | sed 's/ $//'; }

# =============================================================================
it "A1. libnl-tiny：SET(SOURCES) 解析（CMake 语法，收尾 ) 与末条目同行）"
# =============================================================================
A1="$(_cmake_setlist "$VENDOR/libnl-tiny/CMakeLists.txt" SOURCES)"
chk "A1 源文件数 = 14（上游 CMakeLists 的 SET(SOURCES) 条目数）" "$(printf '%s\n' "$A1" | grep -c .)" "14"
chk "A1 首条 = attr.c" "$(printf '%s\n' "$A1" | head -1)" "attr.c"
chk "A1 末条 = unl.c（验证收尾 ) 被正确剥离）" "$(printf '%s\n' "$A1" | tail -1)" "unl.c"
miss=""
for s in $A1; do [ -f "$VENDOR/libnl-tiny/$s" ] || miss="$miss $s"; done
chk "A1 全部 14 个源文件真实存在" "${miss:-<无缺失>}" "<无缺失>"

# =============================================================================
it "A2. lucihttp：ADD_LIBRARY 解析（两个库不能混淆）"
# =============================================================================
A2C="$(_cmake_addlib "$VENDOR/lucihttp/CMakeLists.txt" liblucihttp)"
A2L="$(_cmake_addlib "$VENDOR/lucihttp/CMakeLists.txt" liblucihttp-lua)"
chk "A2 core 库源文件数 = 3" "$(printf '%s\n' "$A2C" | grep -c .)" "3"
chk "A2 core 含 lib/multipart-parser.c" "$(printf '%s\n' "$A2C" | grep -c '^lib/multipart-parser\.c$')" "1"
# 关键回归：`ADD_LIBRARY(liblucihttp ` 是 `ADD_LIBRARY(liblucihttp-lua ` 的前缀，
# 不加分隔符判断会把 lua.c 也算进 core 库（或反之），把两个 .so 的源混在一起
chk "A2 lua 绑定库源文件数 = 1" "$(printf '%s\n' "$A2L" | grep -c .)" "1"
chk "A2 lua 绑定库 = lib/lua.c" "$(printf '%s\n' "$A2L")" "lib/lua.c"
chk "A2 core 库**不**含 lib/lua.c（两个 ADD_LIBRARY 未混淆）" \
	"$(printf '%s\n' "$A2C" | grep -c 'lua\.c$')" "0"
chk "A2 core 库**不**含 lib/ucode.c（ucode 路线已否决，刻意排除）" \
	"$(printf '%s\n' "$A2C" | grep -c 'ucode')" "0"
miss=""
for s in $A2C $A2L; do [ -f "$VENDOR/lucihttp/$s" ] || miss="$miss $s"; done
chk "A2 全部 4 个源文件真实存在" "${miss:-<无缺失>}" "<无缺失>"

# =============================================================================
it "A3. nixio：NIXIO_OBJ 解析（\$(if \$(NIXIO_TLS),...) 是主要陷阱）"
# =============================================================================
A3="$(_make_varlist "$VENDOR/luci/luci-lib-nixio/src/Makefile" NIXIO_OBJ)"
chk "A3 总数 = 19（16 个基础 + 3 个 TLS）" "$(printf '%s\n' "$A3" | grep -c .)" "19"
chk "A3 非 TLS 对象数 = 16" "$(printf '%s\n' "$A3" | grep -cv '^tls-')" "16"
chk "A3 无 make 语法污染 token（\$(if / \$(NIXIO_TLS) / 尾随逗号）" \
	"$(printf '%s\n' "$A3" | grep -cE '\$|[,)]')" "0"
# ★ 这条是实测抓到的真 bug 的回归测试：
#   `sub(/[\\)]+$/,"")` 只剥 `)` 不剥 `,`，于是 `tls-socket.o,)` 剥成
#   `tls-socket.o,`，以逗号结尾就匹配不上 `\.o$` 而被丢弃。
#   它只在 NIXIO_TLS=openssl 时暴露，默认构建完全看不出来。
chk "A3 TLS 三件套齐全（tls-crypto / tls-context / tls-socket）" \
	"$(printf '%s\n' "$A3" | grep '^tls-' | sort | j)" \
	"$(printf 'tls-crypto.o\ntls-context.o\ntls-socket.o\n' | sort | j)"
chk "A3 首条 = nixio.o" "$(printf '%s\n' "$A3" | head -1)" "nixio.o"
chk "A3 含 user.o（最后一条基础对象）" "$(printf '%s\n' "$A3" | grep -c '^user\.o$')" "1"
miss=""
for s in $A3; do [ -f "$VENDOR/luci/luci-lib-nixio/src/${s%.o}.c" ] || miss="$miss $s"; done
chk "A3 全部 19 个源文件真实存在（含 3 个 TLS 的 .c）" "${miss:-<无缺失>}" "<无缺失>"

# =============================================================================
it "A4. ip / jsonc：单对象变量解析"
# =============================================================================
chk "A4 IP_OBJ = ip.o" "$(_make_varlist "$VENDOR/luci/luci-lib-ip/src/Makefile" IP_OBJ | j)" "ip.o"
chk "A4 JSONC_OBJ = jsonc.o" "$(_make_varlist "$VENDOR/luci/luci-lib-jsonc/src/Makefile" JSONC_OBJ | j)" "jsonc.o"
chk "A4 ip.c 存在" "$([ -f "$VENDOR/luci/luci-lib-ip/src/ip.c" ] && echo yes)" "yes"
chk "A4 jsonc.c 存在" "$([ -f "$VENDOR/luci/luci-lib-jsonc/src/jsonc.c" ] && echo yes)" "yes"
# IP_OBJ 与 IP_LIB 在同一文件里，确认变量边界没串
chk "A4 解析 IP_OBJ 不会把 IP_LIB 的 ip.so 带进来" \
	"$(_make_varlist "$VENDOR/luci/luci-lib-ip/src/Makefile" IP_OBJ | grep -c '\.so')" "0"

# =============================================================================
it "A5. luci-base：make 规则依赖解析 + lemon 生成物识别"
# =============================================================================
MKB="$VENDOR/luci/luci-base/src/Makefile"
A5P="$(_make_rule_objs "$MKB" parser.so)"
A5L="$(_make_rule_objs "$MKB" po2lmo)"
chk "A5 parser.so 对象数 = 5" "$(printf '%s\n' "$A5P" | grep -c .)" "5"
chk "A5 parser.so 含 template_lualib.o（Lua 绑定，必须有）" \
	"$(printf '%s\n' "$A5P" | grep -c '^template_lualib\.o$')" "1"
chk "A5 parser.so 含 plural_formula.o（lemon 生成，必须有）" \
	"$(printf '%s\n' "$A5P" | grep -c '^plural_formula\.o$')" "1"
chk "A5 po2lmo 对象数 = 3" "$(printf '%s\n' "$A5L" | grep -c .)" "3"

# 两个目标的并集 = 6 个唯一 .c
UNION="$(printf '%s\n%s\n' "$A5P" "$A5L" | sed 's/\.o$/.c/' | sort -u)"
chk "A5 并集 = 6 个唯一 .c" "$(printf '%s\n' "$UNION" | grep -c .)" "6"

miss=""; gen=0
for s in $UNION; do
	if [ -f "$VENDOR/luci/luci-base/src/$s" ]; then continue; fi
	if [ "$s" = "plural_formula.c" ]; then gen=1; continue; fi
	miss="$miss $s"
done
chk "A5 唯一缺失的是生成物 plural_formula.c（由 lemon 产出）" "${miss:-<无缺失>}" "<无缺失>"
chk "A5 plural_formula.c 在清单里（即确实需要 lemon 这一步）" "$gen" "1"
chk "A5 lemon 源码 contrib/lemon.c 存在" \
	"$([ -f "$VENDOR/luci/luci-base/src/contrib/lemon.c" ] && echo yes)" "yes"
chk "A5 plural_formula.y 存在" \
	"$([ -f "$VENDOR/luci/luci-base/src/plural_formula.y" ] && echo yes)" "yes"
chk "A5 mkversion.sh 存在" \
	"$([ -f "$VENDOR/luci/luci-base/src/mkversion.sh" ] && echo yes)" "yes"

# =============================================================================
it "A6. 解析器"读不出 = 空"，调用方才能据此硬失败"
# =============================================================================
chk "A6 不存在的变量 → 空" "$(_make_varlist "$MKB" NOSUCH_OBJ | grep -c .)" "0"
chk "A6 不存在的规则 → 空" "$(_make_rule_objs "$MKB" nosuch_target | grep -c .)" "0"
chk "A6 不存在的 SET 块 → 空" "$(_cmake_setlist "$VENDOR/libnl-tiny/CMakeLists.txt" NOSUCH | grep -c .)" "0"
chk "A6 不存在的 ADD_LIBRARY → 空" "$(_cmake_addlib "$VENDOR/lucihttp/CMakeLists.txt" nosuchlib | grep -c .)" "0"

# =============================================================================
it "B1. 产物清单：--list 必须能无工具链运行，且路径合契约"
# =============================================================================
LIST="$(bash "$BUILD_SH" --list 2>/dev/null)" || LIST=""
chk "B1 --list 在本机（无 cc/cmake/lua）可正常退出" "$([ -n "$LIST" ] && echo yes || echo no)" "yes"
chk "B1 产物条数 = 11" "$(printf '%s\n' "$LIST" | grep -c '^usr/')" "11"

# 上游硬编码路径的契约（upstream/luci-app-openclash/Makefile:143-146, postrm:128-129）
for want in \
	"usr/lib/lua/nixio.so" \
	"usr/lib/lua/lucihttp.so" \
	"usr/lib/lua/nixio/fs.lua" \
	"usr/lib/lua/nixio/util.lua" \
	"usr/lib/lua/luci/ip.so" \
	"usr/lib/lua/luci/jsonc.so" \
	"usr/lib/lua/luci/template/parser.so" \
	"usr/lib/lua/luci/version.lua" \
	"usr/bin/po2lmo"
do
	if printf '%s\n' "$LIST" | grep -q "^$want"; then
		ok "B1 契约路径存在：/$want"
	else
		no "B1 契约路径存在：/$want" "未在 --list 中"
	fi
done

# libnl-tiny 的落位目录由 multiarch 探测决定：有探测结果就用
# /usr/lib/<triple>/，探测不到（非 Debian 机器上跑 --list）才回退 /usr/lib。
# 下面这条用显式覆盖来测，才能在本机得到确定性结果 —— 而它正是
# "@MULTIARCH@ 占位符没被替换" 那个 bug 的回归测试。
LIST2="$(DEB_HOST_MULTIARCH=aarch64-linux-gnu bash "$BUILD_SH" --list 2>/dev/null)" || LIST2=""
# ⚠️ 路径后面的描述文字是同一行（printf '%-56s %s'），所以不能直接用 `路径$`
#    结尾锚点，必须接受"路径后跟空格或行尾"。
chk "B1 指定 DEB_HOST_MULTIARCH 后 libnl-tiny 落在 /usr/lib/<triple>/ 下" \
	"$(printf '%s\n' "$LIST2" | grep -cE '^usr/lib/aarch64-linux-gnu/libnl-tiny\.so\.1\.0\.0( |$)')" "1"
chk "B1 同上，SONAME 链接也落在 /usr/lib/<triple>/ 下" \
	"$(printf '%s\n' "$LIST2" | grep -cE '^usr/lib/aarch64-linux-gnu/libnl-tiny\.so\.1( |$)')" "1"
chk "B1 覆盖 multiarch 后不残留 x86_64 之类硬编码" \
	"$(printf '%s\n' "$LIST2" | grep -c 'x86_64-linux-gnu')" "0"
chk "B1 本机无探测结果时回退 /usr/lib（**不**产生 /usr/lib/lib/ 双重目录）" \
	"$(printf '%s\n' "$LIST" | grep -c '^usr/lib/lib/')" "0"
# ★ 回归：曾经把 SONAME（libnl-tiny.so.1）当词根再拼一次版本号，得到
#   libnl-tiny.so.1.1.0.0。功能上能跑，名字是错的。
chk "B1 真实库文件名恰好是 libnl-tiny.so.1.0.0（无双重版本号）" \
	"$(printf '%s\n' "$LIST" | grep -cE 'libnl-tiny\.so\.1\.1\.')" "0"
chk "B1 libnl-tiny 的 SONAME 链接也被声明" \
	"$(printf '%s\n' "$LIST" | grep -cE '^usr/lib/([^/]+/)?libnl-tiny\.so\.1( |$)')" "1"

# =============================================================================
it "B2. 产物清单：不该出现的东西"
# =============================================================================
# 合并方案：上游拆 liblucihttp.so + lucihttp.so 两个共享库，我们合成一个。
# 若清单里出现 liblucihttp.so，说明合并方案被改回去了但没更新清单。
chk "B2 不含 liblucihttp.so（已合并进 lucihttp.so）" \
	"$(printf '%s\n' "$LIST" | grep -c 'liblucihttp\.so')" "0"
chk "B2 不含 ucode 相关产物（路线 A 已否决）" \
	"$(printf '%s\n' "$LIST" | grep -c 'ucode')" "0"
# @MULTIARCH@ 必须在 --list 前就被替换掉，否则装出来的路径字面上带 @…@
chk "B2 无 @MULTIARCH@ 占位符残留" \
	"$(printf '%s\n' "$LIST" | grep -c '@MULTIARCH@')" "0"
chk "B2 未把 multiarch 硬编码成 x86_64（必须由探测决定）" \
	"$(printf '%s\n' "$LIST2" | grep -c 'x86_64-linux-gnu')" "0"
# libnl-tiny 的头文件是编译期依赖，不该装进运行时包
chk "B2 不装 libnl-tiny 头文件（编译期依赖，不入运行时包）" \
	"$(printf '%s\n' "$LIST" | grep -c 'include')" "0"

# =============================================================================
it "C1. 静态纪律：语法与 mktemp"
# =============================================================================
for f in "$BUILD_SH" "$PARSERS_SH"; do
	if bash -n "$f" 2>/dev/null; then ok "C1 bash -n 通过：$(basename "$f")"
	else no "C1 bash -n 通过：$(basename "$f")" "$(bash -n "$f" 2>&1 | head -2)"; fi
done
# mktemp 在本沙箱会返回盘符路径（TMPDIR=C:\Users\...\Temp），后续 mv/rm 会被
# 安全策略判为 embedded drive prefix 并**挂死**。全项目统一不用 mktemp。
chk "C1 build-lua-modules.sh 不含 mktemp" \
	"$(grep -c 'mktemp' "$BUILD_SH" || true)" "0"
chk "C1 upstream-parsers.sh 不含 mktemp" \
	"$(grep -c 'mktemp' "$PARSERS_SH" || true)" "0"

# =============================================================================
it "C2. 静态纪律：vendor/ 只读、日志不污染 stdout"
# =============================================================================
# 设计红线：vendor/ 是只读 L1 树。任何对它的写/删都会让"上游代码原样可 diff"
# 这条承诺失效，也让每日同步产生假冲突。
chk "C2 不向 \$VENDOR 写入（无 cp/mkdir/install 目标为 \$VENDOR）" \
	"$(grep -cE '^(cp|mkdir|install|mv|rm|ln)[^#]*\$VENDOR' "$BUILD_SH" || true)" "0"
chk "C2 有 _copy_src（源码副本机制，即 vendor 只读的保障）" \
	"$(grep -c '^_copy_src()' "$BUILD_SH" || true)" "1"

# P1.5 起，实现搬到 runtime/lib/build-common.sh（与 build-ubus.sh 共用）。
# 这里断言两件事，缺一不可：
#   a) 公共层里 vlog 仍然写 stderr；
#   b) 本脚本确实 source 了公共层（否则 a 就是空头支票）。
# vlog 曾写成 stdout，而 _copy_src / _compile_objs 的返回值靠 stdout 传递
# （`bd="$(_copy_src ...)"`），日志被当成返回值 → 莫名其妙的路径不存在。
chk "C2 vlog 重定向到 stderr（公共层）" \
	"$(grep -c '^vlog() {.*>&2' "$COMMON_SH" || true)" "1"
chk "C2 build-lua-modules.sh 引入公共层" \
	"$(grep -cE '^\. *"\$ROOT/runtime/lib/build-common.sh"' "$BUILD_SH" || true)" "1"
chk "C2 公共层声明了 _copy_src / vlog 以外的必要件" \
	"$(grep -cE '^bc_(copy_src|compile_objs|install_file|assert_srcs|init_lua|init_toolchain)\(\)' "$COMMON_SH" || true)" "6"

# =============================================================================
it "C3. 静态纪律：require 校验的模块清单必须内联"
# =============================================================================
# `lua -e 'code' a b c` 里的 a b c 进的是全局 arg 表，**不是** chunk 的 `...`。
# 用 `local mods={...}` 去接位置参数会拿到空表，校验就变成"什么都没测"却报告成功。
chk "C3 模块清单以 {<内联>} 形式写进 Lua 源码" \
	"$(grep -c 'local mods={' "$BUILD_SH" || true)" "1"
chk "C3 没有用 Lua 变参去接模块名" \
	"$(grep -cE 'local mods *= *\{ *\.\.\.' "$BUILD_SH" || true)" "0"
bad="$({ grep -E 'LUA_BIN.*-e "\$prog"' "$BUILD_SH" || true; } | grep -c 'mods' || true)"
chk "C3 lua -e 的调用行不含模块名（否则会走 arg 表而非 ...）" "$bad" "0"
chk "C3 lua 调用确实传了 -e \"\$prog\"" \
	"$(grep -cE 'LUA_BIN.*-e "\$prog"' "$BUILD_SH" || true)" "1"

# =============================================================================
it "C4. 静态纪律：Lua 5.1 是硬断言而不是注释"
# =============================================================================
# 拿 5.3/5.4 的头编出来的 .so 在 5.1 解释器里 require 会报 undefined symbol，
# 所以必须在构建期就把版本挡住，而不是写一句"请用 5.1"的注释。
# ⚠️ 这里原本写成 grep -cF 'LUA_VERSION_NUM[ \t]+501' —— `-F`（固定字符串）
#   配合了 regex 元字符 `[ \t]+`，**永远匹配不到**，但该断言期望 1，于是长期恒红。
#   2026-10-01 修：锚定真判据那一行的**字面**形态（build-common.sh:118 的
#   grep -qE '^#[[:space:]]*define[[:space:]]+LUA_VERSION_NUM[[:space:]]+501'），
#   它在公共层里唯一出现；die 文案里那句 "未找到 LUA_VERSION_NUM 501" 不含
#   define 段，不会被数进来。
chk "C4 断言 LUA_VERSION_NUM 501（公共层）" \
	"$(grep -cF 'define[[:space:]]+LUA_VERSION_NUM[[:space:]]+501' "$COMMON_SH" || true)" "1"
# 断言「唯一的版本断言在公共层，且构建脚本确实引入了它」。
# 早先这里数的是 BUILD_SH 里 LUA_VERSION_NUM 的出现次数 == 0 —— 但注释里提一句
# 也算命中，这种断言会被无关改动误伤。改成数真正的 source 语句。
chk "C4 build-lua-modules.sh 引入公共层（version 断言的唯一出处）" \
	"$(grep -cE '^\. *"\$ROOT/runtime/lib/build-common.sh"' "$BUILD_SH" || true)" "1"
# 只看**紧邻下一行**：-A4 的窗口会把后面另一个 die（"找不到 liblua5.1.so"）
# 也圈进来，于是这条断言会因为无关改动而变成 2 —— 实测正是如此。
# 断言的本意只是"版本不对时走 die 而不是 warn"，锚定紧邻行即可。
gate="$(grep -A1 'LUA_VERSION_NUM.*lua\.h' "$COMMON_SH" | grep -c 'die ' || true)"
chk "C4 版本不符时是 die（硬失败）而非 warn" "$gate" "1"
chk "C4 版本不符时没有降级为 warn" \
	"$(grep -A1 'LUA_VERSION_NUM.*lua\.h' "$COMMON_SH" | grep -c 'warn' || true)" "0"
chk "C4 liblua.so 兜底候选会排除 5.2/5.3/5.4" \
	"$(grep -cF 'liblua.so:*5.[234]*' "$COMMON_SH" || true)" "1"
chk "C4 用绝对路径链 liblua 而不是 -llua（避免链到 5.4）" \
	"$(grep -cE '(^| )-llua( |$)' "$BUILD_SH" || true)" "0"

# =============================================================================
it "C5. nixio TLS 默认关闭的依据仍然成立"
# =============================================================================
# 默认 -DNO_TLS 的前提是"**Lua 代码里** 0 处调用 nixio.tls"。若上游将来开始
# 用 TLS，这条前提失效，必须改成默认开启 —— 这里把它变成可自动发现的断言。
#
# ⚠️ 必须限定 --include=*.lua/*.htm：不加限定会把 TLS 实现自己的 C 源码也算进来
#  （vendor/luci/luci-lib-nixio/src/nixio-tls.h 里有
#    `#define NIXIO_TLS_CTX_META "nixio.tls.ctx"`），得到 2 个假命中，
#    让人误以为 NO_TLS 会造成兼容损失。声称的是"Lua 调用点"，就只查 Lua。
TLSCALL="$(grep -rn --include='*.lua' --include='*.htm' \
	'nixio\.tls\|nixio\.TLSProvider' \
	"$VENDOR/luci" "$ROOT/upstream/luci-app-openclash" 2>/dev/null \
	| grep -v '/docsrc/' | grep -c . || true)"
chk "C5 vendor 与上游 **Lua 代码**中 nixio.tls 调用数 = 0（故 NO_TLS 零损失）" "$TLSCALL" "0"
chk "C5 TLS 的 C 源码确实在（证明上一条是"没人调用"而非"文件缺失"）" \
	"$([ -f "$VENDOR/luci/luci-lib-nixio/src/nixio-tls.h" ] && echo yes || echo no)" "yes"
chk "C5 默认分支（未设 NIXIO_TLS）走 -DNO_TLS" \
	"$(grep -cF 'if [ -z "${NIXIO_TLS:-}" ]' "$BUILD_SH" || true)" "1"
chk "C5 NIXIO_TLS=openssl 的链接参数已实现（-lssl -lcrypto）" \
	"$(grep -cF -- '-lssl -lcrypto' "$BUILD_SH" || true)" "1"
chk "C5 未启用 TLS 时会剔掉 tls-*.o（否则去编缺 openssl 头的源文件）" \
	"$(grep -cF 'tls-*.o|axtls-compat.o|cyassl-compat.o' "$BUILD_SH" || true)" "1"

# =============================================================================
printf '\n\033[1m════════════════════════════════════════\033[0m\n'
printf '  \033[32mPASS %d\033[0m   \033[31mFAIL %d\033[0m   \033[33mSKIP %d\033[0m\n' "$PASS" "$FAIL" "$SKIP"
printf '\033[1m════════════════════════════════════════\033[0m\n'
[ "$FAIL" -eq 0 ] || exit 1
printf '\n\033[0;90m说明：本测试不编译、不加载 .so（本机无 C 工具链）。\033[0m\n'
printf '\033[0;90m      "编出来能被 require" 由 CI 的 ubuntu-latest 任务验证。\033[0m\n'
exit 0
