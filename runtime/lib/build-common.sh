#!/usr/bin/env bash
# =============================================================================
# 公共构建辅助（被 runtime/lua/build-lua-modules.sh 与 runtime/ubus/build-ubus.sh source）
# -----------------------------------------------------------------------------
# 为什么抽出来：
#   两个脚本要做同样四件事 ——
#     1. 找 Lua 5.1 的头/库/解释器，并**硬断言**版本（不是"应该是 5.1"）
#     2. 把 vendor 源码复制到构建目录（vendor 是只读 L1 树，永不写入）
#     3. 逐文件编译（不走上游 CMake，理由见各脚本内注释）
#     4. 安装到 staging 树，并输出可审计的产物清单
#   复制两份必然漂移，而漂移的症状是"一个脚本能编、另一个不能"，
#   排查成本远高于维护一份。
#
# ⚠️ 本文件**不是可执行脚本**，只提供函数与约定。调用方必须先定义：
#     BUILD_TAG      日志前缀，如 lua / ubus
#     BUILDDIR       构建工作目录（源码副本落在这里）
#     DEST           安装根（.deb 打包时是 staging 树）
#     CC              C 编译器（默认 cc）
#     CFLAGS / LDFLAGS
#   并按需使用：
#     EXTRA_CFLAGS   每次 _compile_objs 前由调用方设置
#     CF_ARR/LD_ARR  由 bc_init_toolchain 填好
#
# ⚠️ 被 source 时不要有顶层副作用（不要在这里 mkdir / 探测 / 退出）。
# =============================================================================

# shellcheck shell=bash

BUILD_TAG="${BUILD_TAG:-build}"

log()  { printf '\033[1;36m[%s]\033[0m %s\n' "$BUILD_TAG" "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }
# ⚠️ vlog **必须**写 stderr：_copy_src / _compile_objs 的返回值是靠 stdout
#    传出去的（`bd="$(_copy_src ...)"`），任何写 stdout 的日志都会被
#    当成返回值的一部分，症状是莫名其妙的 "No such file or directory"。
vlog() { [ "${V:-0}" = "1" ] && printf '\033[0;90m[%s]   %s\033[0m\n' "$BUILD_TAG" "$*" >&2 || true; }

# -----------------------------------------------------------------------------
# 工具链
# -----------------------------------------------------------------------------
bc_init_toolchain() {
	CC="${CC:-cc}"
	command -v "$CC" >/dev/null 2>&1 || die "找不到 C 编译器：$CC（Debian: apt install build-essential）"

	# 刻意**不带** `-Werror`：上游这些模块是 2015~2021 年的代码，-Werror 会把
	# 无害告警升级成构建失败。目标是把上游代码**原样**编出来，不是替它做代码审查。
	CFLAGS="${CFLAGS:--O2 -g -fPIC}"
	LDFLAGS="${LDFLAGS:-}"
	CF_ARR=(); LD_ARR=()
	# `|| true` 是必要的：LDFLAGS 默认空串，read 在只有换行的输入上返回值
	# 不确定，而 set -e 会把非零变成脚本退出。
	read -r -a CF_ARR <<<"$CFLAGS" || true
	read -r -a LD_ARR <<<"$LDFLAGS" || true
}

# -----------------------------------------------------------------------------
# Lua 5.1 探测
# -----------------------------------------------------------------------------
# 必须是 5.1，这不是偏好问题：
#   · 上游 Lua 代码大量使用 `module(...)` 与 `package.seeall`
#     —— 5.2 起 module() 被弃用、package.seeall 直接删除
#   · C 侧：5.1 的 luaL_register / lua_objlen 在 5.2+ 被改名或删除，
#     拿 5.4 的头编出来的 .so 在 5.1 解释器里 require 会报 undefined symbol
bc_find_lua_inc() {
	local d c
	for d in /usr/include/lua5.1 /usr/include/lua-5.1 /usr/local/include/lua5.1 \
	         "$(pkg-config --variable=includedir lua5.1 2>/dev/null || true)"; do
		[ -n "$d" ] && [ -f "$d/lua.h" ] && { printf '%s\n' "$d"; return 0; }
	done
	c="$(pkg-config --cflags lua5.1 2>/dev/null || true)"
	for d in $(printf '%s' "$c" | tr ' ' '\n' | sed -n 's/^-I//p'); do
		[ -f "$d/lua.h" ] && { printf '%s\n' "$d"; return 0; }
	done
	return 1
}

# 链接目标用**绝对路径**而不是 -l 猜测：Debian 的 liblua5.1-0-dev 给的是
# liblua5.1.so，但某些环境存在无版本号的 liblua.so —— 那可能是 5.4。
bc_find_lua_lib() {
	local d n rp
	for d in "$(pkg-config --variable=libdir lua5.1 2>/dev/null || true)" \
	         "/usr/lib/${MULTIARCH:-}" /usr/lib/lua5.1 /usr/local/lib /usr/lib; do
		[ -n "$d" ] && [ -d "$d" ] || continue
		for n in liblua5.1.so liblua-5.1.so liblua.so; do
			[ -e "$d/$n" ] || continue
			rp="$(readlink -f "$d/$n" 2>/dev/null || echo "$d/$n")"
			case "$n:$rp" in
				liblua.so:*5.[234]*) continue ;;   # 兜底候选必须确认不是 5.2/5.3/5.4
			esac
			printf '%s\n' "$d/$n"
			return 0
		done
	done
	return 1
}

bc_find_lua_bin() {
	local b p
	for b in lua5.1 lua-5.1 lua; do
		p="$(command -v "$b" 2>/dev/null || true)"
		[ -n "$p" ] || continue
		if [ "$("$p" -e 'io.write(_VERSION)' 2>/dev/null || true)" = "Lua 5.1" ]; then
			printf '%s\n' "$p"
			return 0
		fi
	done
	return 1
}

# 一次性探测并设好 LUA_INC / LUA_LIB / LUA_BIN，且**硬断言**头文件是 5.1。
# 只断言"文件存在"是不够的：Debian 上同时装 lua5.1 与 lua5.3 时，
# /usr/include/lua5.1 与 pkg-config 可能指向不同世代。
bc_init_lua() {
	LUA_INC="$(bc_find_lua_inc || true)"
	[ -n "$LUA_INC" ] || die "找不到 lua.h。请安装 liblua5.1-0-dev"

	if ! grep -qE '^#[[:space:]]*define[[:space:]]+LUA_VERSION_NUM[[:space:]]+501' "$LUA_INC/lua.h"; then
		die "$LUA_INC/lua.h 不是 Lua 5.1（未找到 LUA_VERSION_NUM 501）。
     本项目的 Lua 侧代码与 C 扩展都要求 5.1，用 5.3/5.4 的头会编出无法加载的 .so。"
	fi
	LUA_LIB="$(bc_find_lua_lib || true)"
	[ -n "$LUA_LIB" ] || die "找不到 liblua5.1.so。请安装 liblua5.1-0-dev"
	LUA_BIN="$(bc_find_lua_bin || true)"
	log "Lua 5.1 头文件：$LUA_INC"
	vlog "liblua: $LUA_LIB${LUA_BIN:+  解释器: $LUA_BIN}"
}

# -----------------------------------------------------------------------------
# 源码副本 / 编译 / 安装
# -----------------------------------------------------------------------------
bc_assert_srcs() {
	local label="$1" dir="$2"; shift 2
	local miss=0 s
	for s in "$@"; do
		if [ ! -f "$dir/$s" ]; then
			warn "$label 缺少源文件：$s"
			miss=1
		fi
	done
	[ "$miss" = 0 ] || die "$label 的源文件清单与上游构建文件不符
     （vendor 树可能被 sparse-checkout 截断，重跑 scripts/fetch-luci-vendor.sh）"
}

# 所有编译都在**源码副本**里进行。vendor/ 是只读 L1 树，设计红线：永不写入。
# stdout = 副本目录（调用方用命令替换捕获），所以内部不能往 stdout 写日志。
bc_copy_src() {
	local src="$1" name="$2"
	local dst="$BUILDDIR/$name"
	[ -d "$src" ] || die "缺少上游源码目录：$src（先跑 scripts/fetch-luci-vendor.sh）"
	rm -rf "$dst"
	mkdir -p "$dst"
	cp -a "$src/." "$dst/"
	# ⚠️ 剥离 CRLF：vendor 树从 Windows 同步到 Debian 时保留 CRLF，
	# mkversion.sh / luci_fixtime 等**执行型**脚本在 dash 里
	#   "line 2: $'\r': command not found"
	# 真机实测下这是 build-deb.sh 跑 80% 后挂掉的主因。
	# 只对 *.sh 做就地剥离（其他文件保留：CMakeLists/Makefile 是 awk 解析，
	# 解析器已经 BEGIN{RS="\r?\n"} 兼容；.lua/.c 文件装到 /usr/lib/lua 后由
	# Lua/C 编译器读，Lua lexer 把 \r 当 whitespace，C 编译器也容忍）。
	find "$dst" -type f -name '*.sh' -exec sed -i 's/\r$//' {} +
	printf '%s\n' "$dst"
}

# 编译一批源文件；对象名由源文件名推导。附加 CFLAGS 放在全局 EXTRA_CFLAGS。
# stdout = 生成的 .o 列表，所以内部不能往 stdout 写日志。
bc_compile_objs() {
	local bd="$1" tag="$2"; shift 2
	local s o objs=()
	for s in "$@"; do
		o="${s%.c}.o"
		vlog "$tag: cc $s"
		( cd "$bd" && "$CC" "${CF_ARR[@]}" ${EXTRA_CFLAGS[@]+"${EXTRA_CFLAGS[@]}"} -c -o "$o" "$s" ) \
			|| die "$tag: 编译失败（$s）"
		objs+=("$o")
	done
	printf '%s\n' ${objs[@]+"${objs[@]}"}
}

bc_install_file() {   # <builddir> <相对名> <destdir 内相对路径> <mode>
	local bd="$1" rel="$2" out="$3" mode="$4"
	[ -f "$bd/$rel" ] || die "应有产物缺失：$bd/$rel"
	mkdir -p "$(dirname "$DEST/$out")"
	install -m "$mode" "$bd/$rel" "$DEST/$out"
	log "  + /$out"
}

bc_install_from() {   # <绝对源文件> <destdir 内相对路径> <mode>
	local src="$1" out="$2" mode="$3"
	[ -f "$src" ] || die "应有产物缺失：$src"
	mkdir -p "$(dirname "$DEST/$out")"
	install -m "$mode" "$src" "$DEST/$out"
	log "  + /$out"
}
