#!/usr/bin/env bash
# =============================================================================
# 构建前端所需的 Lua C 模块（P1 运行时地基）
# -----------------------------------------------------------------------------
# 为什么需要这些 .so：
#   LuCI 的纯 Lua 代码并不能脱离 C 扩展运行。这些是**硬依赖**，不是可选加速：
#     · nixio        luci-lib-base/luasrc/http.lua、sys.lua、dispatcher.lua
#                    全部在模块顶层 `require "nixio"` / `require "nixio.fs"`
#     · lucihttp     luci-lib-base/luasrc/http.lua:8 与 util.lua:13 顶层 require
#     · luci.ip      luci-compat/luasrc/model/network.lua 与 settings.lua 用到
#     · luci.jsonc   luci.model.network 解析 /etc/board.json
#     · template.parser  luci.template 的模板引擎（C 实现，带 lmo 编译器）
#
# 产物与安装路径（**上游契约**，见下方 LUA_LIBDIR 说明）：
#   usr/lib/lua/nixio.so                    ← nixio 核心
#   usr/lib/lua/lucihttp.so                 ← liblucihttp 的 Lua 绑定
#   usr/lib/lua/nixio/fs.lua                ← nixio 的纯 Lua 部分（上游 root/）
#   usr/lib/lua/nixio/util.lua
#   usr/lib/lua/luci/ip.so
#   usr/lib/lua/luci/jsonc.so
#   usr/lib/lua/luci/template/parser.so
#   usr/lib/lua/luci/version.lua            ← mkversion.sh 生成
#   usr/lib/<multiarch>/libnl-tiny.so.1     ← ip.so 的 DT_NEEDED
#   usr/bin/po2lmo                          ← .po → .lmo（构建期工具）
#
# 三条设计原则（与项目其他部分一致）：
#   1. **vendor/ 永不写入**。所有编译都在 BUILDDIR 下的**源码副本**里做，
#      vendor/ 只是只读的 L1 树，可随时 diff/审计。
#   2. **源文件清单从上游构建文件里解析**，不手抄。上游增删一个 .c 我们自动
#      跟上；解析结果为空则**硬失败**，而不是静默编出缺文件的半成品。
#   3. **探测结果即真相**。lua.h 的版本、shadow 是否存在、liblua 在哪，
#      全部现场探测并断言，不依赖"Debian 上应该是……"这类记忆。
#
# 用法：
#   runtime/lua/build-lua-modules.sh --destdir <dir>       # 构建并落盘
#   runtime/lua/build-lua-modules.sh --list                # 只打印产物清单
#   runtime/lua/build-lua-modules.sh --destdir <dir> --verify
#   runtime/lua/build-lua-modules.sh --destdir <dir> --no-verify
#
# 常用环境变量：
#   CC / CFLAGS / LDFLAGS / BUILD_DIR / HOSTCC / V=1
#   PARSER_LINK_LUA=1   parser.so 也链接 liblua5.1（见 _build_luci_base 注释）
#   NIXIO_TLS=openssl   打开 nixio 的 TLS（默认关闭，见 _build_nixio 注释）
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VENDOR="$ROOT/vendor"

BUILDDIR="${BUILD_DIR:-$ROOT/packaging/build/lua-build}"
DEST=""

VERIFY="auto"          # auto | yes | no
DO_LIST=0

BUILD_TAG="lua"
# 公共辅助（日志、Lua 5.1 探测、源码副本、编译、安装）放在 runtime/lib/ 下，
# 与 runtime/ubus/build-ubus.sh 共用 —— 两边要做的是同一件事，复制两份必然漂移。
# shellcheck source=runtime/lib/build-common.sh
. "$ROOT/runtime/lib/build-common.sh"

while [ $# -gt 0 ]; do
	case "$1" in
		--destdir)   DEST="${2:?--destdir 需要一个目录}"; shift 2 ;;
		--destdir=*) DEST="${1#*=}"; shift ;;
		--verify)    VERIFY=yes; shift ;;
		--no-verify) VERIFY=no; shift ;;
		--list)      DO_LIST=1; shift ;;
		-h|--help)   sed -n '2,55p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*)           die "未知参数：$1" ;;
	esac
done

# -----------------------------------------------------------------------------
# multiarch 三元组（决定 libnl-tiny.so 落在 /usr/lib/<x86_64-linux-gnu>/ 还是 /usr/lib/）
# -----------------------------------------------------------------------------
MULTIARCH="${DEB_HOST_MULTIARCH:-}"
[ -n "$MULTIARCH" ] || MULTIARCH="$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || true)"
[ -n "$MULTIARCH" ] || MULTIARCH="$(cc -dumpmachine 2>/dev/null || true)"

# -----------------------------------------------------------------------------
# 产物路径常量
# -----------------------------------------------------------------------------
# LUA_LIBDIR = usr/lib/lua —— 这不是我们挑的目录，是**上游写死的**：
#   · L1 侧：upstream/luci-app-openclash/Makefile:146  `$(CP) luasrc/* $(1)/usr/lib/lua/luci/`
#            upstream Makefile:143-144  i18n → /usr/lib/lua/luci/i18n/
#            upstream postrm:128-129    sed -i ... "/usr/lib/lua/luci/model/network.lua"
#                                              /usr/lib/lua/luci/http.lua
#     这几处都是**绝对路径**且带 `>/dev/null 2>&1`，目录不存在就静默跳过 ——
#     上游对 luci-base 的运行时改写会悄悄失效，界面出问题但没有任何报错。
#   · L1 侧：luci-base/src/Makefile:30-32   parser.so → /usr/lib/lua/luci/template/
#   · L1 侧：luci-lib-ip/src/Makefile:13-14 ip.so     → /usr/lib/lua/luci/
#   所以本包必须把文件放在 /usr/lib/lua 下。Debian 的 lua5.1 默认搜索路径
#   并不含 /usr/lib/lua（只含 /usr/lib/<multiarch>/lua/5.1 与 /usr/share/lua/5.1），
#   「让 require 找得到」由 runtime/lua/lua-path-bridge.sh 在安装期解决。
LUA_LIBDIR="usr/lib/lua"

NIXIO_LUA_DIR="$LUA_LIBDIR/nixio"          # 纯 Lua 部分
NIXIO_SO="$LUA_LIBDIR/nixio.so"
LUCIHTTP_SO="$LUA_LIBDIR/lucihttp.so"
IP_SO="$LUA_LIBDIR/luci/ip.so"
JSONC_SO="$LUA_LIBDIR/luci/jsonc.so"
PARSER_SO="$LUA_LIBDIR/luci/template/parser.so"
VERSION_LUA="$LUA_LIBDIR/luci/version.lua"
PO2LMO="usr/bin/po2lmo"
# libnl-tiny 的命名遵循标准共享库约定，三个名字必须分开写清楚：
#   NL_SO_BASE    libnl-tiny.so        —— 词根，只用于给 -l 找（我们不装 -dev 链接）
#   NL_SO_SONAME  libnl-tiny.so.1      —— DT_SONAME，链接期与实际装载都认它
#   NL_SO         libnl-tiny.so.1.0.0  —— 真实文件
# ⚠️ 不要把 SONAME 当成"词根"去再拼一次版本号：曾经写成
#    "$NL_SO_NAME.$NL_SO_VER"（NL_SO_NAME 已含 .1）→ libnl-tiny.so.1.1.0.0。
#    功能上仍能跑（软链指向它），但文件名是错的，且与文档/测试不一致。
NL_SO_BASE="libnl-tiny.so"
NL_SOVER="1"
NL_SO_VERSION="1.0.0"
NL_SO_SONAME="$NL_SO_BASE.$NL_SOVER"
NL_SO_FILE="$NL_SO_BASE.$NL_SO_VERSION"
# multiarch 探测不到时（例如在非 Debian 机器上跑 --list）回退到 /usr/lib，
# **不要**写成 /usr/lib/${MULTIARCH:-lib}/ —— 那会产生 /usr/lib/lib/ 这种
# 双重目录，看着像笔误却会被真的装出来。
if [ -n "$MULTIARCH" ]; then NL_LIBDIR="usr/lib/$MULTIARCH"; else NL_LIBDIR="usr/lib"; fi
NL_SO="$NL_LIBDIR/$NL_SO_FILE"
NL_SO_LINK="$NL_LIBDIR/$NL_SO_SONAME"

# --list 用的声明式描述：路径|种类(F=文件 L=符号链接)|说明
ARTIFACT_TABLE=(
"$NIXIO_SO|F|nixio 核心（socket/fs/process/syslog）"
"$LUCIHTTP_SO|F|liblucihttp 的 Lua 绑定（luci-lib-base 顶层 require）"
"$NIXIO_LUA_DIR/fs.lua|F|nixio.fs 纯 Lua 部分"
"$NIXIO_LUA_DIR/util.lua|F|nixio.util 纯 Lua 部分"
"$IP_SO|F|luci.ip（依赖 libnl-tiny）"
"$JSONC_SO|F|luci.jsonc（依赖 libjson-c）"
"$PARSER_SO|F|luci.template.parser 模板引擎"
"$VERSION_LUA|F|luci.version（由 mkversion.sh 生成）"
"$NL_SO|F|libnl-tiny（ip.so 的 DT_NEEDED）"
"$NL_SO_LINK|L|libnl-tiny 的 SONAME 链接"
"$PO2LMO|F|po2lmo（构建期 i18n 工具）"
)

if [ "$DO_LIST" = 1 ]; then
	printf '%-56s %s\n' "路径（相对包根）" "说明"
	printf '%-56s %s\n' "--------------------------------------------------------" "----"
	for row in "${ARTIFACT_TABLE[@]}"; do
		printf '%-56s %s\n' "${row%%|*}" "${row##*|}"
	done
	exit 0
fi

[ -n "$DEST" ] || die "缺少 --destdir <dir>（.deb 打包时传 staging 树）"
mkdir -p "$DEST"
DEST="$(cd "$DEST" && pwd)"

# -----------------------------------------------------------------------------
# 工具链
# -----------------------------------------------------------------------------
bc_init_toolchain
HOSTCC="${HOSTCC:-cc}"
command -v "$HOSTCC" >/dev/null 2>&1 || die "找不到宿主 C 编译器：$HOSTCC（构建 po2lmo/lemon 用）"

# -----------------------------------------------------------------------------
# Lua 5.1 探测（含 LUA_VERSION_NUM 501 硬断言）
# -----------------------------------------------------------------------------
bc_init_lua

# -----------------------------------------------------------------------------
# 上游构建文件解析器
# -----------------------------------------------------------------------------
# 实现在 runtime/lua/lib/upstream-parsers.sh 里，与构建脚本分开是为了让
# tests/ 能在**没有 C 工具链**的机器上单独 source 它、对着真实 vendor 树
# 做断言（本项目的 Windows 开发机就属于这种环境）。
# shellcheck source=runtime/lua/lib/upstream-parsers.sh
. "$ROOT/runtime/lua/lib/upstream-parsers.sh"

# -----------------------------------------------------------------------------
# 公共辅助的薄别名
# -----------------------------------------------------------------------------
# 实现都在 runtime/lib/build-common.sh。这里保留短名字而不是把 _build_* 里的
# 调用点全部改名：那些调用点有几十处，改名只会制造一次大而无谓的 diff，
# 别名本身零成本、也不会漂移（它没有逻辑）。
_assert_srcs()  { bc_assert_srcs "$@"; }
_copy_src()     { bc_copy_src "$@"; }
_compile_objs() { bc_compile_objs "$@"; }
_install_file() { bc_install_file "$@"; }
_lua_bin()      { bc_find_lua_bin; }

_install_lua_files() {  # <绝对源目录> <destdir 内相对路径>
	local src="$1" out="$2" f n=0
	[ -d "$src" ] || die "缺少纯 Lua 源目录：$src"
	mkdir -p "$DEST/$out"
	for f in "$src"/*.lua; do
		[ -e "$f" ] || continue
		install -m 0644 "$f" "$DEST/$out/$(basename "$f")"
		log "  + /$out/$(basename "$f")"
		n=$((n + 1))
	done
	[ "$n" -gt 0 ] || die "$src 下没有 .lua 文件"
}

# =============================================================================
# 1. libnl-tiny —— ip.so 的链接依赖
# =============================================================================
# 为什么不能省：luci-lib-ip/src/ip.c 写的是 `#include <netlink/msg.h>`，
# 靠上游 Makefile 的 `-I$(STAGING_DIR)/usr/include/libnl-tiny/` 解析。
# Debian 有 libnl-3/libnl-3-dev，但那是**另一套 API**（签名与结构都不同），
# 头文件名对不上、ABI 也不兼容，不能替换。
#
# 为什么不用上游的 CMakeLists.txt：
#   a) 它开 `-Wall -Werror -Wextra`，2018 年的代码在 gcc 12+ 上很容易被
#      误报（-Warray-bounds / -Wstringop-overflow 的假阳性很常见）而构建失败；
#      add_definitions() 把 -Werror 放进 COMPILE_DEFINITIONS，命令行里排在
#      CMAKE_C_FLAGS 之后，用 -Wno-error 压不住。
#   b) GNUInstallDirs 在非 debhelper 环境下不一定给出多架构目录。
#   改为直接编译，但**源文件清单仍从 CMakeLists.txt 解析**。
_build_libnl_tiny() {
	log "libnl-tiny：$NL_SO_FILE（SONAME=$NL_SO_SONAME）"
	local bd
	bd="$(_copy_src "$VENDOR/libnl-tiny" libnl-tiny)"

	local list=() s
	while IFS= read -r s; do [ -n "$s" ] && list+=("$s"); done \
		<<<"$(_cmake_setlist "$bd/CMakeLists.txt" SOURCES)"

	if [ "${#list[@]}" -lt 10 ]; then
		die "从 libnl-tiny/CMakeLists.txt 的 SET(SOURCES ...) 只解析出 ${#list[@]} 个源文件
     （上游当前是 14 个）—— 上游结构变了，请更新 _cmake_setlist 的解析规则。"
	fi
	_assert_srcs "libnl-tiny" "$bd" "${list[@]}"

	EXTRA_CFLAGS=(-Iinclude -Wall)
	local objs=()
	while IFS= read -r s; do [ -n "$s" ] && objs+=("$s"); done \
		<<<"$(_compile_objs "$bd" "libnl-tiny" "${list[@]}")"

	vlog "libnl-tiny: ld"
	( cd "$bd" && "$CC" ${LD_ARR[@]+"${LD_ARR[@]}"} -shared \
		-Wl,-soname,"$NL_SO_SONAME" \
		-o "$NL_SO_FILE" "${objs[@]}" ) \
		|| die "libnl-tiny: 链接失败"

	_install_file "$bd" "$NL_SO_FILE" "$NL_SO" 0644
	mkdir -p "$DEST/$(dirname "$NL_SO_LINK")"
	ln -sfn "$NL_SO_FILE" "$DEST/$NL_SO_LINK"
	log "  + /$NL_SO_LINK -> $NL_SO_FILE"

	# 头文件只留在构建目录供 ip.so 编译期使用，**不装进包**：
	# 这是运行时包，往 /usr/include 塞一套私有头树会污染系统。
	NL_INC_DIR="$bd/include"
}

# =============================================================================
# 2. ip.so → /usr/lib/lua/luci/ip.so
# =============================================================================
_build_ip() {
	log "ip.so（luci.ip）"
	local bd
	bd="$(_copy_src "$VENDOR/luci/luci-lib-ip/src" luci-lib-ip)"

	local list=() s
	# 源文件清单直接读上游 Makefile 的 IP_OBJ，不手写
	while IFS= read -r s; do
		[ -n "$s" ] && list+=("${s%.o}.c")
	done <<<"$(_make_varlist "$bd/Makefile" IP_OBJ)"
	[ "${#list[@]}" -gt 0 ] || die "从 luci-lib-ip/src/Makefile 的 IP_OBJ 解析不出源文件"
	_assert_srcs "luci-lib-ip" "$bd" "${list[@]}"

	# -I$NL_INC_DIR：让 `#include <netlink/msg.h>` 命中刚编的 libnl-tiny，
	#                等价于上游的 -I$(STAGING_DIR)/usr/include/libnl-tiny/
	EXTRA_CFLAGS=(-I"$LUA_INC" -I"$NL_INC_DIR" -std=gnu99 -Wall)
	local objs=()
	while IFS= read -r s; do [ -n "$s" ] && objs+=("$s"); done \
		<<<"$(_compile_objs "$bd" "ip" "${list[@]}")"

	( cd "$bd" && "$CC" ${LD_ARR[@]+"${LD_ARR[@]}"} -shared -o ip.so "${objs[@]}" \
		"$DEST/$NL_SO" "$LUA_LIB" -lm ) \
		|| die "ip.so: 链接失败（检查 $DEST/$NL_SO）"

	_install_file "$bd" ip.so "$IP_SO" 0644
}

# =============================================================================
# 3. jsonc.so → /usr/lib/lua/luci/jsonc.so
# =============================================================================
# jsonc.c 用的是 `#include <json-c/json.h>`，Debian 的 libjson-c-dev 正好装在
# /usr/include/json-c/，所以**不需要**上游 Makefile 里那个
# `-I$(STAGING_DIR)/usr/include/json-c/`（上游那样写是因为 OpenWrt 的 json-c
# 头装在那个前缀下、代码里写的是 <json.h>）。
_build_jsonc() {
	log "jsonc.so（luci.jsonc）"
	if ! { command -v pkg-config >/dev/null 2>&1 && pkg-config --exists json-c 2>/dev/null; } \
	   && [ ! -f /usr/include/json-c/json.h ]; then
		die "找不到 json-c 头文件。请安装 libjson-c-dev"
	fi

	local bd
	bd="$(_copy_src "$VENDOR/luci/luci-lib-jsonc/src" luci-lib-jsonc)"

	local list=() s
	while IFS= read -r s; do
		[ -n "$s" ] && list+=("${s%.o}.c")
	done <<<"$(_make_varlist "$bd/Makefile" JSONC_OBJ)"
	[ "${#list[@]}" -gt 0 ] || die "从 luci-lib-jsonc/src/Makefile 的 JSONC_OBJ 解析不出源文件"
	_assert_srcs "luci-lib-jsonc" "$bd" "${list[@]}"

	EXTRA_CFLAGS=(-I"$LUA_INC" -std=gnu99 -Wall)
	local objs=()
	while IFS= read -r s; do [ -n "$s" ] && objs+=("$s"); done \
		<<<"$(_compile_objs "$bd" "jsonc" "${list[@]}")"

	( cd "$bd" && "$CC" ${LD_ARR[@]+"${LD_ARR[@]}"} -shared -o jsonc.so "${objs[@]}" \
		"$LUA_LIB" -lm -ljson-c ) \
		|| die "jsonc.so: 链接失败"

	_install_file "$bd" jsonc.so "$JSONC_SO" 0644
}

# =============================================================================
# 4. nixio.so → /usr/lib/lua/nixio.so
# =============================================================================
# 关于 TLS：上游支持 axtls/cyassl/openssl/none 四种，这里默认**关闭**
# （-DNO_TLS）。依据是实测的调用面：
#   grep -rn 'nixio\.tls\|nixio\.TLSProvider' vendor/luci/ upstream/
#   → 真实 Lua 代码里 0 处命中（只有 luci-lib-nixio/docsrc/ 的文档注释）
# 即关掉 TLS 对 LuCI 与 OpenClash 都是**零兼容损失**，却省掉 libssl-dev
# 依赖，并避开 nixio 的 OpenSSL 代码与 OpenSSL 3.x 的兼容问题（2021 年的
# 代码，OpenWrt 侧是靠补丁适配 OpenSSL 3 的）。需要时用 NIXIO_TLS=openssl。
_build_nixio() {
	local bd
	bd="$(_copy_src "$VENDOR/luci/luci-lib-nixio/src" luci-lib-nixio)"

	local objs_all=() s
	while IFS= read -r s; do [ -n "$s" ] && objs_all+=("$s"); done \
		<<<"$(_make_varlist "$bd/Makefile" NIXIO_OBJ)"
	[ "${#objs_all[@]}" -gt 0 ] || die "从 luci-lib-nixio/src/Makefile 的 NIXIO_OBJ 解析不出 .o"

	local csrcs=() tls
	for tls in "${objs_all[@]}"; do
		case "$tls" in
			# 未启用 TLS 时剔掉这些（上游把它们包在
			# `$(if $(NIXIO_TLS),...)` 里，解析器会一并取出）
			tls-*.o|axtls-compat.o|cyassl-compat.o)
				[ -n "${NIXIO_TLS:-}" ] || continue
				;;
		esac
		csrcs+=("${tls%.o}.c")
	done

	local extra=(-I"$LUA_INC" -std=gnu99 -Wall) link_extra=()
	if [ -z "${NIXIO_TLS:-}" ]; then
		extra+=(-DNO_TLS)
		log "nixio.so（无 TLS：实测 Lua 侧 0 处调用 nixio.tls）"
	else
		log "nixio.so（TLS=$NIXIO_TLS）"
		case "$NIXIO_TLS" in
			openssl) link_extra+=(-lssl -lcrypto) ;;
		esac
	fi

	# 上游用编译探测决定 NIXIO_SHADOW（探测失败才加 -DNO_SHADOW）。
	# 这里原样复刻，但把结果显式打出来 —— -DNO_SHADOW 会改变 nixio.user
	# 的行为，必须在构建日志里可见。
	if printf 'int main(void){ return !getspnam("root"); }' \
		| "$CC" "${CF_ARR[@]}" -include shadow.h -xc -o /dev/null - >/dev/null 2>&1; then
		log "  shadow 支持：开"
	else
		warn "shadow 探测失败，加 -DNO_SHADOW（nixio.user 将无法读 /etc/shadow）"
		extra+=(-DNO_SHADOW)
	fi

	_assert_srcs "luci-lib-nixio" "$bd" "${csrcs[@]}"

	EXTRA_CFLAGS=(${extra[@]+"${extra[@]}"})
	local objs=()
	while IFS= read -r s; do [ -n "$s" ] && objs+=("$s"); done \
		<<<"$(_compile_objs "$bd" "nixio" "${csrcs[@]}")"

	( cd "$bd" && "$CC" ${LD_ARR[@]+"${LD_ARR[@]}"} -shared -o nixio.so "${objs[@]}" \
		"$LUA_LIB" -lm -ldl -lcrypt ${link_extra[@]+"${link_extra[@]}"} ) \
		|| die "nixio.so: 链接失败"

	_install_file "$bd" nixio.so "$NIXIO_SO" 0644

	# 纯 Lua 部分：nixio.fs / nixio.util。
	# nixio.c 自己**不** require 任何 Lua 模块（luaopen_nixio 独立），
	# 但 fs.lua 会 require "nixio" 与 "nixio.util"，而 luci 全栈都用
	# `require "nixio.fs"` —— 所以这两个文件必须一起装。
	_install_lua_files "$VENDOR/luci/luci-lib-nixio/root/usr/lib/lua/nixio" "$NIXIO_LUA_DIR"
}

# =============================================================================
# 5. lucihttp.so → /usr/lib/lua/lucihttp.so
# =============================================================================
# 上游是 CMake 工程，但不用它的两个理由：
#   a) `cmake_minimum_required(VERSION 2.6)` —— CMake 4.x 直接拒绝：
#      "Compatibility with CMake < 3.5 has been removed"
#   b) 同样是 -Werror
# 另外上游拆成 liblucihttp.so + lucihttp.so（Lua 绑定）两个共享库。这里
# **合并成一个 .so**：Lua 侧看到的 API 完全一致，却省掉 liblucihttp.so.0 的
# SONAME 管理与 rpath 问题。
# lib/ucode.c 刻意不编：ucode 是被否决的前端路线 A，本项目不需要。
_build_lucihttp() {
	log "lucihttp.so（liblucihttp 的 Lua 绑定）"
	local bd
	bd="$(_copy_src "$VENDOR/lucihttp" lucihttp)"

	local list=() s
	while IFS= read -r s; do [ -n "$s" ] && list+=("$s"); done \
		<<<"$(_cmake_addlib "$bd/CMakeLists.txt" liblucihttp | grep -E '\.c$' || true)"
	while IFS= read -r s; do [ -n "$s" ] && list+=("$s"); done \
		<<<"$(_cmake_addlib "$bd/CMakeLists.txt" liblucihttp-lua | grep -E '\.c$' || true)"
	[ "${#list[@]}" -gt 0 ] || die "从 lucihttp/CMakeLists.txt 解析不出源文件"
	case " ${list[*]} " in
		*" lib/lua.c "*) ;;
		*) die "lucihttp 的 Lua 绑定源（lib/lua.c）没被解析出来 —— 上游 CMakeLists 结构变了" ;;
	esac
	_assert_srcs "lucihttp" "$bd" "${list[@]}"

	# -Wno-format-truncation：同上游 CMakeLists 的选项
	EXTRA_CFLAGS=(-Iinclude -I"$LUA_INC" -std=gnu99 -Os -Wall -Wno-format-truncation)
	local objs=()
	while IFS= read -r s; do [ -n "$s" ] && objs+=("$s"); done \
		<<<"$(_compile_objs "$bd" "lucihttp" "${list[@]}")"

	( cd "$bd" && "$CC" ${LD_ARR[@]+"${LD_ARR[@]}"} -shared -o lucihttp.so "${objs[@]}" "$LUA_LIB" ) \
		|| die "lucihttp.so: 链接失败"

	_install_file "$bd" lucihttp.so "$LUCIHTTP_SO" 0644
}

# =============================================================================
# 6. luci-base：lemon → plural_formula → parser.so + po2lmo + version.lua
# =============================================================================
# 上游 luci-base/src/Makefile 的依赖链：
#   contrib/lemon        ← cc -o contrib/lemon contrib/lemon.c（**宿主**工具）
#   plural_formula.c/.h  ← ./contrib/lemon -q plural_formula.y（语法生成器）
#   template_lmo.c       ← 依赖 plural_formula.c（它 include plural_formula.h）
#   parser.so            ← template_parser.o template_utils.o template_lmo.o
#                          template_lualib.o plural_formula.o
#   po2lmo               ← po2lmo.o template_lmo.o plural_formula.o
#   version.lua          ← ./mkversion.sh version.lua <ver> <branch>
# 对象文件一律带 -DNDEBUG（同上游的 `%.o` 规则）。
#
# 关于 parser.so 要不要链接 liblua：上游**不链接**，依靠解释器把 Lua 符号
# 导出到动态符号表（Lua 官方 src/Makefile 在 Linux 上用 -Wl,-E，Debian 保留
# 了这一点）。这样模块能被任何 5.1 系解释器装载。这里默认跟随上游；万一本机
# lua5.1 没有导出符号，require 会报 `undefined symbol: luaL_register`，
# 此时用 PARSER_LINK_LUA=1 重新构建。
_build_luci_base() {
	log "luci-base：lemon / template parser / po2lmo / version.lua"
	local bd
	bd="$(_copy_src "$VENDOR/luci/luci-base/src" luci-base)"

	# --- lemon（宿主工具）-------------------------------------------------
	[ -f "$bd/contrib/lemon.c" ] || die "缺少 luci-base/src/contrib/lemon.c"
	vlog "luci-base: 构建宿主 lemon"
	( cd "$bd" && "$HOSTCC" -O2 -o contrib/lemon contrib/lemon.c ) || die "lemon 构建失败"

	# --- plural_formula.c / .h -------------------------------------------
	# lemon 把输出写到当前目录，所以必须在 $bd 下执行
	vlog "luci-base: lemon -q plural_formula.y"
	( cd "$bd" && ./contrib/lemon -q plural_formula.y ) || die "lemon 解析 plural_formula.y 失败"
	[ -f "$bd/plural_formula.c" ] || die "lemon 没有生成 plural_formula.c"

	# --- 从上游规则读出对象清单 ------------------------------------------
	local pobj lobj
	pobj="$(_make_rule_objs "$bd/Makefile" parser.so)"
	lobj="$(_make_rule_objs "$bd/Makefile" po2lmo)"
	[ -n "$pobj" ] || die "从 luci-base/src/Makefile 解析不出 parser.so 的对象清单"
	[ -n "$lobj" ] || die "从 luci-base/src/Makefile 解析不出 po2lmo 的对象清单"

	# 合并去重得到 .c 清单（plural_formula.c 已由 lemon 生成）
	local all=() c s o
	while IFS= read -r o; do
		[ -n "$o" ] || continue
		c="${o%.o}.c"
		case " ${all[*]-} " in *" $c "*) continue ;; esac
		all+=("$c")
	done <<<"$(printf '%s\n%s\n' "$pobj" "$lobj")"

	# 存在性断言：除生成的 plural_formula.c 外都必须在源码树里
	local check=()
	for s in "${all[@]}"; do
		case "$s" in plural_formula.c) continue ;; esac
		check+=("$s")
	done
	_assert_srcs "luci-base" "$bd" "${check[@]}"

	EXTRA_CFLAGS=(-I. -I"$LUA_INC" -DNDEBUG -std=gnu99 -Wall)
	# 编译的对象清单由 pobj/lobj 推导（见下），这里不需要 _compile_objs 的
	# 返回值，但仍必须调用它 —— 编译失败会在函数内部 die。
	# 输出丢弃到 /dev/null：绝不能让它落到 stdout 被误当成产物清单。
	_compile_objs "$bd" "luci-base" "${all[@]}" >/dev/null

	# parser.so 与 po2lmo 的对象有交集（template_lmo.o / plural_formula.o），
	# 各自按上游规则里的清单链接
	local p_objs=() l_objs=()
	while IFS= read -r o; do [ -n "$o" ] && p_objs+=("$o"); done <<<"$pobj"
	while IFS= read -r o; do [ -n "$o" ] && l_objs+=("$o"); done <<<"$lobj"

	local link_lua="${PARSER_LINK_LUA:-0}" link_args=()
	[ "$link_lua" = "1" ] && link_args+=("$LUA_LIB")
	vlog "luci-base: ld parser.so（PARSER_LINK_LUA=$link_lua）"
	( cd "$bd" && "$CC" ${LD_ARR[@]+"${LD_ARR[@]}"} -shared -o parser.so \
		"${p_objs[@]}" ${link_args[@]+"${link_args[@]}"} ) || die "parser.so: 链接失败"

	vlog "luci-base: ld po2lmo"
	( cd "$bd" && "$CC" ${LD_ARR[@]+"${LD_ARR[@]}"} -o po2lmo "${l_objs[@]}" ) \
		|| die "po2lmo: 链接失败"

	_install_file "$bd" parser.so "$PARSER_SO" 0644
	_install_file "$bd" po2lmo    "$PO2LMO"    0755

	# --- version.lua ------------------------------------------------------
	# mkversion.sh 是上游自带的：它 dofile("/etc/openwrt_release") 并取
	# DISTRIB_DESCRIPTION / DISTRIB_REVISION 作为版本横幅。我们的
	# runtime/sys/openwrt-release.sh 正好生成这个文件，因此行为与真实
	# OpenWrt 完全一致（有 DESCRIPTION 时 distname 为空，与原生一致）。
	# 第 2/3 参数是 luciversion / luciname，用 vendor 锁定值填，
	# 让界面显示真实的 LuCI 来源而不是编造的版本号。
	local lref lshort
	lref="$(sed -n 's/^LUCI_REF=//p'   "$VENDOR/.luci-version" 2>/dev/null | head -1)"
	lshort="$(sed -n 's/^LUCI_SHORT=//p' "$VENDOR/.luci-version" 2>/dev/null | head -1)"
	lref="${lref:-unknown}"; lshort="${lshort:-unknown}"

	vlog "luci-base: mkversion.sh（luciname=$lref luciversion=$lshort）"
	( cd "$bd" && sh ./mkversion.sh version.lua "$lshort" "$lref" ) || die "mkversion.sh 执行失败"
	_install_file "$bd" version.lua "$VERSION_LUA" 0644
}

# =============================================================================
# 7. 产物清单（可审计）
# =============================================================================
_manifest() {
	local mf="$BUILDDIR/lua-manifest.txt" row p kind
	: >"$mf"
	{
		printf '# openclash-rt Lua 运行时产物清单\n'
		printf '# 生成于 %s\n' "$(date -Iseconds 2>/dev/null || echo unknown)"
		printf '# 格式：<F=文件|L=符号链接> <权限> <sha256> <路径> [-> 目标]\n'
		for row in "${ARTIFACT_TABLE[@]}"; do
			# ARTIFACT_TABLE 每行形如 `<path>|<F|L>|<说明>`。原代码用
			# `kind="${row#*|}"` 把 `F|说明` 当成 kind，于是 `[ "$kind" = "F" ]`
			# 恒假、走到 L 分支，导致 file 类型产物被当成软链校验（`[ -L ... ]`
			# 恒假）→ die「清单声明了软链 ... 但它不存在」。
			#
			# MSYS 上 nixio.so 是真实 .so，这条死得无声无息；Debian 真机上 nixio.so
			# 也是真实 .so，照样报错。修法：先按 `|` 拆三段、取第二段。
			p="${row%%|*}"
			rest="${row#*|}"
			kind="${rest%%|*}"
			if [ "$kind" = "F" ]; then
				[ -f "$DEST/$p" ] || die "清单声明了 /$p 但产物不存在"
				printf 'F %s %s /%s\n' "$(stat -c '%a' "$DEST/$p")" \
					"$(sha256sum "$DEST/$p" | cut -d' ' -f1)" "$p"
			else
				[ -L "$DEST/$p" ] || die "清单声明了软链 /$p 但它不存在"
				printf 'L %s - /%s -> %s\n' \
					"$(stat -c '%a' "$DEST/$p")" "$p" "$(readlink "$DEST/$p")"
			fi
		done
	} >>"$mf"
	mkdir -p "$DEST/usr/lib/openclash-rt"
	cp "$mf" "$DEST/usr/lib/openclash-rt/lua-manifest.txt"
	log "产物清单：$mf"
}

# =============================================================================
# 8. 校验：真的能被 require 吗
# =============================================================================
# 这是 P1 的验收口径。刻意用**独立的 LUA_CPATH/LUA_PATH 指向 staging 树**来
# 验证，而不是安装后再测 —— 这样构建期就能发现"编出来了但装错地方"。
_verify() {
	if [ "$VERIFY" = "no" ]; then
		log "跳过校验（--no-verify）"
		return 0
	fi
	if [ -z "$LUA_BIN" ]; then
		if [ "$VERIFY" = "yes" ]; then
			die "--verify 要求本机有 Lua 5.1 解释器（apt install lua5.1）"
		fi
		warn "本机无 Lua 5.1 解释器，跳过 require 校验（交叉构建时正常）"
		return 0
	fi

	local mods=(nixio nixio.fs nixio.util luci.ip luci.jsonc lucihttp luci.template.parser)
	local mods_lua="" m
	for m in "${mods[@]}"; do mods_lua="$mods_lua'$m',"; done
	mods_lua="${mods_lua%,}"

	# ⚠️ 模块清单必须**内联进 Lua 源码**：`lua -e 'code' a b c` 里的 a b c
	#    进的是全局 arg 表，不是 chunk 的 `...`，用 {...} 会拿到空表。
	local prog="local mods={$mods_lua}
for _, n in ipairs(mods) do
	local ok, err = pcall(require, n)
	io.write((ok and 'OK   ' or 'FAIL ') .. n .. (ok and '' or ('  <- ' .. tostring(err))) .. '\n')
	if not ok then os.exit(1) end
end"

	log "校验 require：${mods[*]}"
	local out rc=0
	# 尾部 `;;` = 保留默认搜索路径；前面的条目指向 staging 树。
	# 这样既验证产物本身，又不会因为缺默认路径而误报。
	#
	# LD_LIBRARY_PATH 必须加：luci.ip.so DT_NEEDED libnl-tiny.so.1（不在系统 ld.so.cache），
	# nixio.so 可能也会动态链接 glibc/nss 等。把 staging 树里的
	# `usr/lib/<multiarch>` 与 `usr/lib` 都接进 LD path；multiarch 三元组由
	# DEB_HOST_MULTIARCH 给出（build-deb.sh 已 export）。
	local ld_extra="$DEST/usr/lib/${DEB_HOST_MULTIARCH:-}:$DEST/usr/lib"
	out="$(LUA_CPATH="$DEST/$LUA_LIBDIR/?.so;;" \
	       LUA_PATH="$DEST/$LUA_LIBDIR/?.lua;$DEST/$LUA_LIBDIR/?/init.lua;;" \
	       LD_LIBRARY_PATH="$ld_extra${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
	       "$LUA_BIN" -e "$prog" 2>&1)" || rc=$?
	printf '%s\n' "$out" | sed 's/^/  /'

	if [ "$rc" != "0" ]; then
		if printf '%s' "$out" | grep -q 'undefined symbol'; then
			die "有模块加载失败且报 undefined symbol —— 多半是解释器没有导出 Lua 符号表。
     用 PARSER_LINK_LUA=1 重新构建可让 parser.so 自带 liblua 依赖：
       PARSER_LINK_LUA=1 $0 --destdir $DEST"
		fi
		if printf '%s' "$out" | grep -qE 'libnl-tiny|lua5\.1|libjson-c|libcrypt'; then
			die "有模块加载失败且报共享库缺失 —— 检查 /$NL_SO_LINK 是否就位，
     以及 liblua5.1-0 / libjson-c5 / libcrypt1 是否已安装。"
		fi
		die "require 校验失败（见上方逐模块结果）"
	fi
	log "校验通过：${#mods[@]} 个模块全部可加载"
}

# =============================================================================
# main
# =============================================================================
mkdir -p "$BUILDDIR"
NL_INC_DIR=""

log "构建目录：$BUILDDIR"
log "落盘目录：$DEST"
log "multiarch：${MULTIARCH:-<未探测到，回退到 /usr/lib/>}"

_build_libnl_tiny
_build_ip
_build_jsonc
_build_nixio
_build_lucihttp
_build_luci_base

_manifest
_verify

log "完成。Lua 运行时就绪。"
log "注意：Debian 的 lua5.1 默认搜索路径不含 /usr/lib/lua，"
log "      安装期需要 runtime/lua/lua-path-bridge.sh 建立搜索路径桥接。"
