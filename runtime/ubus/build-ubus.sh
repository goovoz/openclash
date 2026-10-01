#!/usr/bin/env bash
# =============================================================================
# 构建 ubus 底座（P1.5 运行时地基）
# -----------------------------------------------------------------------------
# 为什么必须有这一层（完整证据链见 docs/04-ubus依赖图谱.md）：
#   vendor/luci/luci-lib-base/luasrc/util.lua:15 是**无条件的顶层**
#       local _ubus = require "ubus"
#   而 luci.util 被几乎所有 LuCI 模块 require。少了 ubus.so，前端连加载
#   都做不到（报 module 'ubus' not found），上游 8 个 #!/usr/bin/lua 脚本
#   同样全军覆没。所以这不是"某个功能不可用"，而是"一行都跑不起来"。
#
#   而 uci 的读写**不走** uci.so，走的是 util.ubus("uci", ...)
#   （vendor/luci/luci-base/luasrc/model/uci.lua:41），该 ubus 对象由
#   **rpcd 内置**提供（OpenWrt 官方文档：session 与 uci 是 built-in）。
#
# 产物与安装路径（**上游契约**）：
#   usr/sbin/ubusd                       ubus 消息总线守护进程
#   usr/bin/ubus                         CLI（调试/排障用）
#   usr/lib/libubus.so.<abi>             rpcd 的 DT_NEEDED
#   usr/lib/lua/5.1/ubus.so              ← 就是 §2.1 那个 require 的目标
#   usr/sbin/rpcd                        提供 session / uci 两个 ubus 对象
#   usr/share/rpcd/acl.d/unauthenticated.json
#   lib/systemd/system/{ubusd,rpcd}.service
#
# 三条设计原则（与 runtime/lua/build-lua-modules.sh 一致）：
#   1. **vendor/ 永不写入**。所有配置/编译都在 BUILDDIR 的**源码副本**里做。
#   2. **尽量用上游自己的构建定义**。ubus 与 rpcd 的 CMakeLists 声明的是
#      ≥3.10 / ≥3.13，对 CMake 4.x 合法，所以这两个走上游 CMake —— 源文件
#      清单、安装布局、开关全部由上游说了算，我们只挑产物。
#      （对比：libnl-tiny / lucihttp / rpcd-mod-luci 声明 2.6，CMake 4.x 直接
#        拒绝，只能手工编译。见 docs/04-ubus依赖图谱.md §5.3。）
#   3. **产物用 DESTDIR 落进临时 prefix，再挑选入 staging**。这样既不污染
#      宿主机，也避免把上游的 include/ 头树塞进运行时包。
#
# 用法：
#   runtime/ubus/build-ubus.sh --destdir <dir>
#   runtime/ubus/build-ubus.sh --list
#   runtime/ubus/build-ubus.sh --destdir <dir> [--verify|--no-verify]
#
# 常用环境变量：
#   UBOX_PREFIX   已构建的 libubox + libuci 前缀
#                 （默认 packaging/build/opt/openclash-rt，由 runtime/uci/build-uci.sh 产出）
#   BUILD_DIR     CMake 工作目录（默认 packaging/build/ubus-build）
#   V=1           打印每条编译命令
#   SKIP_CMAKE_WERROR_FIX=1   保留上游的 -Werror（默认会被放松，见下）
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
VENDOR="$ROOT/vendor"

BUILDDIR="${BUILD_DIR:-$ROOT/packaging/build/ubus-build}"
DEST=""
UBOX_PREFIX="${UBOX_PREFIX:-$ROOT/packaging/build/opt/openclash-rt}"

VERIFY="auto"
DO_LIST=0

BUILD_TAG="ubus"
# shellcheck source=runtime/lib/build-common.sh
. "$ROOT/runtime/lib/build-common.sh"

while [ $# -gt 0 ]; do
	case "$1" in
		--destdir)   DEST="${2:?--destdir 需要一个目录}"; shift 2 ;;
		--destdir=*) DEST="${1#*=}"; shift ;;
		--verify)    VERIFY=yes; shift ;;
		--no-verify) VERIFY=no; shift ;;
		--list)      DO_LIST=1; shift ;;
		-h|--help)   sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*)           die "未知参数：$1" ;;
	esac
done

# -----------------------------------------------------------------------------
# 产物路径常量
# -----------------------------------------------------------------------------
# libubus 装在 /usr/lib（**不是** /usr/lib/<multiarch>/）：上游 CMakeLists 的
# INSTALL 用的是字面量 `lib`，其自带 Debian 打包（vendor/ubus/debian/*.install）
# 也是 `usr/lib/libubus.so.*`。跟随上游比"更符合 Debian 惯例"更重要 ——
# 将来 ubus 升级时我们不需要重新论证一次。
#
# ⚠️ 代价：/usr/lib 不在 Debian 默认的 /etc/ld.so.conf.d/<triple>.conf 里，
#    必须由 postinst 写 ld.so.conf.d 并跑 ldconfig。postinst 里那段
#    "无条件 ldconfig" 就是为它（和 libuci）准备的，不要改回条件式。
LIBDIR="usr/lib"
UBUS_LIB="$LIBDIR/libubus.so"
UBUS_LIB_SONAME="$LIBDIR/libubus.so.1"
UBUS_LUA_SO="usr/lib/lua/5.1/ubus.so"

# --list 的声明式描述：路径|种类(F=文件 L=符号链接)|说明
ARTIFACT_TABLE=(
"usr/sbin/ubusd|F|ubus 消息总线守护进程"
"usr/bin/ubus|F|ubus CLI（排障：ubus list / ubus call）"
"$UBUS_LIB_SONAME|F|libubus（rpcd 的 DT_NEEDED）"
"$UBUS_LIB|L|libubus 的链接名"
"$UBUS_LUA_SO|F|**Lua 绑定**：luci.util:15 顶层 require 的目标"
"usr/sbin/rpcd|F|rpcd（内置 session + uci 两个 ubus 对象）"
"usr/share/rpcd/acl.d/unauthenticated.json|F|rpcd 的未认证会话 ACL"
"lib/systemd/system/ubusd.service|F|systemd 单元（RuntimeDirectory=ubus）"
"lib/systemd/system/rpcd.service|F|systemd 单元"
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

command -v cmake >/dev/null 2>&1 || die "需要 cmake（apt-get install -y cmake）"
command -v make  >/dev/null 2>&1 || die "需要 make（apt-get install -y build-essential）"
[ -d "$VENDOR/ubus" ] || die "缺少 vendor/ubus，请先运行 scripts/fetch-luci-vendor.sh"
[ -d "$VENDOR/rpcd" ] || die "缺少 vendor/rpcd，请先运行 scripts/fetch-luci-vendor.sh"

bc_init_toolchain

# libubox / libuci：由 runtime/uci/build-uci.sh 产出（含 include/）
if [ ! -e "$UBOX_PREFIX/include/libubox/blobmsg_json.h" ] || [ ! -e "$UBOX_PREFIX/include/uci.h" ]; then
	die "缺少已构建的 libubox/libuci：$UBOX_PREFIX
     ubus 与 rpcd 都依赖它们（blobmsg / uci / avl / uloop）。
     先运行： runtime/uci/build-uci.sh $UBOX_PREFIX"
fi
log "使用 libubox/libuci：$UBOX_PREFIX"

bc_init_lua   # ubus 的 Lua 绑定要 lua.h；顺带把 Lua 5.1 版本断言做掉

# -----------------------------------------------------------------------------
# 放宽上游的 -Werror（仅作用于**副本**）
# -----------------------------------------------------------------------------
# 为什么必须这么做，而不是"相信上游能编过"：
#   ubus/CMakeLists.txt:5  ADD_COMPILE_OPTIONS(-Wall -Werror)
#   rpcd/CMakeLists.txt:6  ADD_DEFINITIONS(-Os -Wall -Werror ...)
#   `add_compile_options` 进的是 COMPILE_OPTIONS，在命令行里排在 CMAKE_C_FLAGS
#   **之后**；`add_definitions` 进的是 COMPILE_DEFINITIONS，排在最后。
#   两种情况都无法用 `-DCMAKE_C_FLAGS=-Wno-error` 压住 —— 实测顺序决定成败，
#   光看 CMake 文档很容易误判。
#
#   上游自身的 Debian 打包（vendor/ubus/debian/rules）能编过，是因为它固定用
#   打包机上的 gcc；而我们面向任意 Debian/Ubuntu（gcc 10~14、glibc 2.31+），
#   -Werror 会把新版本 gcc 的无害新告警升级成构建失败。
#
# 做法：在**构建目录的副本**上把 -Werror 换成 -Wno-error。vendor/ 保持原样，
# "上游代码原样可 diff" 的承诺不受影响 —— 这与发行版打 patch 是同一性质。
relax_werror() {   # <构建目录>
	local f
	for f in "$1/CMakeLists.txt" "$1/lua/CMakeLists.txt"; do
		[ -f "$f" ] || continue
		grep -q -- '-Werror' "$f" || continue
		sed -i 's/-Werror/-Wno-error/g' "$f"
		vlog "已放宽 $f 的 -Werror（仅副本）"
	done
}

# -----------------------------------------------------------------------------
# 通用 CMake 构建：源码副本 -> DESTDIR 临时 prefix
# -----------------------------------------------------------------------------
_cmake_build() {   # <名字> <源码目录> <prefix 目录> <额外 -D...>
	local name="$1" src="$2" prefix="$3"; shift 3
	local bd="$BUILDDIR/$name"
	rm -rf "$bd" "$prefix"
	mkdir -p "$bd" "$prefix"
	cp -a "$src/." "$bd/"
	[ "${SKIP_CMAKE_WERROR_FIX:-0}" = "1" ] || relax_werror "$bd"

	# 额外的依赖前缀只由调用方通过 EXTRA_DEPS 传入（rpcd 需要 ubus 的头与库；
	# ubus 自己不需要）—— 用全局变量而不是把 $UBUS_PREFIX 写死进函数，
	# 否则编 ubus 时会把一个尚不存在的目录塞进搜索路径。
	#
	# ⚠️ UBOX_PREFIX 是 build-uci.sh 产出的纯 prefix（include/ lib/ 直接在
	#    prefix 下，无 /usr），但 EXTRA_DEPS（UUBUS_PREFIX）走的是 DESTDIR
	#    风格（include 在 prefix/usr/include）。两类前缀必须用不同 path 形态，
	#    否则 rpcd 的 FIND_PATH(ubus_include_dir libubus.h) 找不到头 → 报
	#    `ubus_include_dir-NOTFOUND`，把整个 CMake generate 步骤带崩。
	local inc="$UBOX_PREFIX/include" lib="$UBOX_PREFIX/lib" d
	for d in ${EXTRA_DEPS:-}; do
		inc="$inc;$d/usr/include"; lib="$lib;$d/usr/lib"
	done

	log "$name: cmake 配置"
	vlog "$name: $*"
	# ⚠️ CMAKE_INSTALL_PREFIX 必须是 /usr，不能是 /。
	#    两个源码把前缀**编进二进制常量**：
	#      vendor/rpcd/include/rpcd/session.h:37
	#        #define RPC_SESSION_ACL_DIR  INSTALL_PREFIX "/share/rpcd/acl.d"
	#      vendor/rpcd/include/rpcd/plugin.h:42,45
	#        #define RPC_PLUGIN_DIRECTORY INSTALL_PREFIX "/libexec/rpcd"
	#        #define RPC_LIBRARY_DIRECTORY INSTALL_PREFIX "/lib/rpcd"
	#    而 rpcd/CMakeLists.txt:6 是
	#        ADD_DEFINITIONS(... -DINSTALL_PREFIX="${CMAKE_INSTALL_PREFIX}")
	#    传 / 的话 ACL 会去找 /share/rpcd/acl.d —— 目录不存在，rpcd 起来后
	#    所有未认证调用被拒，症状是"uci get 没权限"，而文件其实好好躺在
	#    /usr/share/rpcd/acl.d。这类"装对了地方但程序去别处找"的错最难查。
	cmake -S "$bd" -B "$bd/obj" \
		-DCMAKE_INSTALL_PREFIX=/usr \
		-DCMAKE_BUILD_TYPE=None \
		-DCMAKE_VERBOSE_MAKEFILE=OFF \
		-DCMAKE_INCLUDE_PATH="$inc" \
		-DCMAKE_LIBRARY_PATH="$lib" \
		"$@" >"$bd/cmake.log" 2>&1 \
		|| { tail -30 "$bd/cmake.log" >&2; die "$name: cmake 配置失败（完整日志 $bd/cmake.log）"; }

	log "$name: 编译"
	cmake --build "$bd/obj" --parallel "$(nproc 2>/dev/null || echo 2)" \
		>"$bd/build.log" 2>&1 \
		|| { tail -40 "$bd/build.log" >&2; die "$name: 编译失败（完整日志 $bd/build.log）"; }

	# DESTDIR 搬到临时 prefix。
	#
	# ⚠️ 注意 ubus 的 Lua 绑定**不**在这个 prefix 下：lua/CMakeLists.txt:3 有
	#       SET(CMAKE_INSTALL_PREFIX /)
	#    它把 lua 子目录的安装前缀强行改成 /，于是 LUAPATH 相对量落在 /lib/lua/5.1。
	#    这是上游有意为之（OpenWrt 上 /usr/lib/lua 与 /lib/lua 语义不同），
	#    不是 bug，但会让"prefix 下面找不到 ubus.so"成为一个反直觉的排障点。
	make -C "$bd/obj" install DESTDIR="$prefix" >"$bd/install.log" 2>&1 \
		|| { tail -20 "$bd/install.log" >&2; die "$name: install 失败"; }
	log "$name: 产物 $prefix"
}

# =============================================================================
# 1. ubus —— ubusd + CLI + libubus + **Lua 绑定**
# =============================================================================
UBUS_PREFIX="$BUILDDIR/prefix-ubus"
UBUS_SRC="$VENDOR/ubus"

# -DLUAPATH：lua/CMakeLists.txt 在没有它时会去 EXECUTE_PROCESS 调 `lua` 探测
#   系统 cpath，探测失败就直接 MESSAGE(SEND_ERROR "Lua was not found") 中止。
#   我们显式传入相对路径，既绕开探测（构建机不必有 lua 在 PATH 上），
#   又让产物落在 DESTDIR 可控的目录里。
# -DBUILD_EXAMPLES=OFF：examples/ 里是演示程序，不进包。
#   注意 BUILD_EXAMPLES 只影响 UNITTEST/示例，不影响 ubus.so。
_cmake_build ubus "$UBUS_SRC" "$UBUS_PREFIX" \
	-DABIVERSION=1 \
	-DBUILD_LUA=ON \
	-DBUILD_EXAMPLES=OFF \
	-DLUAPATH=lib/lua/5.1

# =============================================================================
# 2. rpcd —— 内置 session + uci 两个 ubus 对象
# =============================================================================
RPCD_PREFIX="$BUILDDIR/prefix-rpcd"
RPCD_SRC="$VENDOR/rpcd"

# 四个插件开关全部关掉，理由逐条（都要能站得住，不是"省事"）：
#   FILE_SUPPORT=OFF    file.so 只被 cgi-io 消费，而 cgi-io 上游 OpenClash
#                       零引用（docs/04 §4.1）
#   IWINFO_SUPPORT=OFF  iwinfo.c 需要 libiwinfo —— Debian 上不存在该库
#   RPCSYS_SUPPORT=OFF  rpcsys 提供 sysupgrade / 改密码，是 OpenWrt 专有语义
#   UCODE_SUPPORT=OFF   ucode.c 需要 libucode —— Debian 上不存在该库
# 我们需要的 session / uci **不是插件**，它们编在 rpcd 主程序里
# （CMakeLists: ADD_EXECUTABLE(rpcd main.c exec.c session.c uci.c rc.c plugin.c)），
# 所以关掉插件不影响 uci 读写能力。
# rpcd 要链接 libubus，所以把 ubus 的 prefix 一并交给它找头/库。
EXTRA_DEPS="$UBUS_PREFIX"
_cmake_build rpcd "$RPCD_SRC" "$RPCD_PREFIX" \
	-DFILE_SUPPORT=OFF \
	-DIWINFO_SUPPORT=OFF \
	-DRPCSYS_SUPPORT=OFF \
	-DUCODE_SUPPORT=OFF
EXTRA_DEPS=""

# =============================================================================
# 3. 挑选产物进 staging
# =============================================================================
_need() {   # <文件> <说明>
	[ -e "$1" ] || die "上游构建未产出预期文件：$1
     $2
     （上游改过安装布局？查看 $BUILDDIR/*/install.log 与 cmake.log）"
}

# --- ubus ---
_need "$UBUS_PREFIX/usr/sbin/ubusd" "ubusd 是总线本体，缺了它 ubus.so 连不上"
bc_install_from "$UBUS_PREFIX/usr/sbin/ubusd" "usr/sbin/ubusd" 0755
_need "$UBUS_PREFIX/usr/bin/ubus" "ubus CLI 用于排障（ubus list / ubus call）"
bc_install_from "$UBUS_PREFIX/usr/bin/ubus" "usr/bin/ubus" 0755

# libubus：上游 INSTALL 用字面量 lib，且开了 ABIVERSION 后是 libubus.so.1
# 加一条 libubus.so 链接。两者的名字都要探测而不是硬写 —— 上游换个 ABI 号
# 我们不该跟着改脚本。
_need "$UBUS_PREFIX/usr/lib/libubus.so.1" "libubus 的 soname 与 ABIVERSION=1 不符？"
bc_install_from "$UBUS_PREFIX/usr/lib/libubus.so.1" "$UBUS_LIB_SONAME" 0644
if [ -e "$UBUS_PREFIX/usr/lib/libubus.so" ]; then
	# 上游自己装出来的链接（可能是软链也可能是副本）。统一重建为相对软链，
	# 避免把构建机的绝对路径带进包里。
	rm -f "$DEST/$UBUS_LIB"
	mkdir -p "$DEST/$(dirname "$UBUS_LIB")"
	ln -sfn "$(basename "$UBUS_LIB_SONAME")" "$DEST/$UBUS_LIB"
	log "  + /$UBUS_LIB -> $(basename "$UBUS_LIB_SONAME")"
else
	die "上游未产出 libubus.so 链接名（ABIVERSION 生效时应产出）"
fi

# ⚠️ Lua 绑定的安装位置（实测）：$UBUS_PREFIX/usr/lib/lua/5.1/ubus.so。
# 脚本注释原本猜 "lua/CMakeLists.txt:3 SET(CMAKE_INSTALL_PREFIX /) → 落在 /lib/lua/5.1"，
# 但那是没考虑 DESTDIR 的解读。Debian 真机实测产物在 usr/lib/lua/5.1。
# 留这一段注释是为了防"上游 lua/CMakeLists.txt 真的改了"再回头核。
_need "$UBUS_PREFIX/usr/lib/lua/5.1/ubus.so" "Lua 绑定没编出来？确认 -DBUILD_LUA=ON 与 lua5.1 头文件"
bc_install_from "$UBUS_PREFIX/usr/lib/lua/5.1/ubus.so" "$UBUS_LUA_SO" 0644

# --- rpcd ---
_need "$RPCD_PREFIX/usr/sbin/rpcd" "rpcd 未产出"
bc_install_from "$RPCD_PREFIX/usr/sbin/rpcd" "usr/sbin/rpcd" 0755
_need "$RPCD_SRC/unauthenticated.json" "上游的未认证会话 ACL 缺失"
bc_install_from "$RPCD_SRC/unauthenticated.json" \
	"usr/share/rpcd/acl.d/unauthenticated.json" 0644

# --- systemd 单元 ---
for u in ubusd.service rpcd.service; do
	src="$ROOT/packaging/debian/$u"
	[ -f "$src" ] || die "缺少 $src"
	bc_install_from "$src" "lib/systemd/system/$u" 0644
done

# =============================================================================
# 4. 校验：ubus.so 真的能被 require（唯一权威判据）
# =============================================================================
do_verify() {
	local lb
	lb="$(bc_find_lua_bin || true)"
	if [ -z "$lb" ]; then
		warn "未找到 Lua 5.1 解释器，跳过 require 校验（CI 上必须执行到）"
		return 0
	fi
	lb="$(command -v "$lb")"

	# 用**干净环境 + 只加我们这一层路径**实测。
	# 注意这里刻意不把 /usr/lib/lua 加进去：ubus.so 落的是
	# /usr/lib/lua/5.1，而该目录**本来就在** Debian 的编译期默认 cpath 里
	# （见 docs/03-路径契约.md），所以不需要任何桥接 —— 这条断言就是在证这件事。
	local prog="
local ok, err = pcall(require, 'ubus')
io.write((ok and 'OK   ' or 'FAIL ') .. 'ubus' .. (ok and '' or ('  <- ' .. tostring(err))) .. '\n')
if not ok then os.exit(1) end
-- 再进一步：确认连得上一个 ubusd。没有 ubusd 时应报 connect 失败而不是
-- module not found —— 两种失败现象完全不同，必须区分（docs/04 §2.1）。
local c = ubus.connect and ubus.connect()
io.write('connect: ' .. (c and 'OK' or 'unavailable（无 ubusd 在跑，构建期正常）') .. '\n')"

	local out rc=0
	# LD_LIBRARY_PATH 必须加：ubus.so 依赖 libubus.so.1 + libubox.so，前者在
	# DEST 树、后者在 UBOX_PREFIX 树，两边都不在系统 ld.so.cache。不加这两段
	# verify 一定炸，错误是 "libubus.so.1 / libubox.so: cannot open shared
	# object file"——不是 Lua 问题，是 LD path 问题。
	#
	# ⚠️ ubus.so 不依赖 libuci.so：ubus 调用 uci 是通过 spawn 一个 `uci` CLI
	# 进程（vendor/ubus/CMakeLists.txt 没把 uci 当 link dep）。所以这里**只**
	# 需要 libubus + libubox 这两条。
	out="$(LUA_CPATH="$DEST/usr/lib/lua/5.1/?.so;;" \
	       LD_LIBRARY_PATH="$DEST/usr/lib:$UBOX_PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
	       "$lb" -e "$prog" 2>&1)" || rc=$?
	printf '%s\n' "$out" | sed 's/^/  /'
	[ "$rc" = 0 ] || die "ubus.so 加载失败。若报 undefined symbol，多半是 lua.h 版本不对。"
	log "ubus.so 可加载"
}

# =============================================================================
# 5. 汇总
# =============================================================================
log "产物清单："
printf '%-56s %s\n' "路径（相对包根）" ""
for row in "${ARTIFACT_TABLE[@]}"; do
	p="${row%%|*}"
	if [ -e "$DEST/$p" ]; then
		printf '  \033[32m✓\033[0m /%s\n' "$p"
	else
		printf '  \033[31m✗\033[0m /%s  （缺失！）\n' "$p"
		MISSING=1
	fi
done
[ "${MISSING:-0}" = 0 ] || die "有产物未落盘，见上"

case "$VERIFY" in
	yes) do_verify ;;
	no)  : ;;
	auto) [ -n "$(bc_find_lua_bin || true)" ] && do_verify || warn "无 Lua 5.1，跳过 --verify" ;;
esac

log "ubus 底座构建完成"
