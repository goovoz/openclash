#!/usr/bin/env bash
# =============================================================================
# 构建 libubox + uci（含 Lua 绑定）到指定前缀
# -----------------------------------------------------------------------------
# 为什么需要：
#   - 上游 shell 通过 /lib/config/uci.sh -> /sbin/uci 读写 /etc/config/openclash
#   - route B 的 Lua 控制器通过 luci.model.uci -> require("uci") 读写同一份配置
#   两者都要求一个能在 glibc Debian 上运行的 uci 实现。
#
# 上游 OpenWrt 官方文档明确支持在 Debian/Ubuntu 上独立编译 uci：
#   cmake && make install（见 https://openwrt.org/docs/techref/uci）
#
# 输出（PREFIX 默认 packaging/build/opt/openclash-rt）：
#   $PREFIX/sbin/uci
#   $PREFIX/lib/libubox.so*, libuci.so*
#   $PREFIX/lib/lua/5.1/uci.so
#   $PREFIX/include/...
#
# 用法：
#   runtime/uci/build-uci.sh [PREFIX]
#   UCI_REF=v24.10.0 runtime/uci/build-uci.sh
# =============================================================================
set -euo pipefail

PREFIX="${1:-$(cd "$(dirname "$0")/../.." && pwd)/packaging/build/opt/openclash-rt}"
UCI_REF="${UCI_REF:-master}"
LIBUBOX_REF="${LIBUBOX_REF:-master}"
WORK="${UCI_BUILD_DIR:-/tmp/openclash-rt-uci-build}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 2)}"

log() { printf '\033[1;36m[uci]\033[0m %s\n' "$*"; }

# --- 依赖检查 ---------------------------------------------------------------
need_pkgs=()
for c in cmake make gcc pkg-config git; do
	command -v "$c" >/dev/null 2>&1 || need_pkgs+=("$c")
done
if [ "${#need_pkgs[@]}" -gt 0 ]; then
	log "缺少构建工具: ${need_pkgs[*]}"
	log "请先执行： apt-get install -y cmake build-essential pkg-config git \\"
	log "               libjson-c-dev lua5.1 liblua5.1-0-dev"
	exit 1
fi

# lua 头文件（luci.model.uci 需要 Lua 绑定）
LUA_INC=""
for d in /usr/include/lua5.1 /usr/include/lua5.3 /usr/include/lua5.4 /usr/include/lua; do
	[ -f "$d/lua.h" ] && LUA_INC="$d" && break
done
if [ -z "$LUA_INC" ]; then
	log "未找到 Lua 头文件，Lua 绑定将被跳过（仅提供 uci CLI）"
	log "安装： apt-get install -y lua5.1 liblua5.1-0-dev"
fi

mkdir -p "$WORK" "$PREFIX"
cd "$WORK"

# --- libubox ----------------------------------------------------------------
if [ ! -d libubox/.git ]; then
	log "克隆 libubox ($LIBUBOX_REF)"
	git clone --depth 1 --branch "$LIBUBOX_REF" \
		https://git.openwrt.org/project/libubox.git libubox
else
	log "更新 libubox"
	git -C libubox fetch --depth 1 origin "$LIBUBOX_REF" && git -C libubox reset --hard FETCH_HEAD
fi

log "编译 libubox"
rm -rf libubox/build && mkdir -p libubox/build && cd libubox/build
cmake .. \
	-DCMAKE_INSTALL_PREFIX="$PREFIX" \
	-DCMAKE_BUILD_TYPE=Release \
	-DBUILD_LUA=OFF \
	-DBUILD_EXAMPLES=OFF
make -j"$JOBS"
make install
cd "$WORK"

# --- uci --------------------------------------------------------------------
if [ ! -d uci/.git ]; then
	log "克隆 uci ($UCI_REF)"
	git clone --depth 1 --branch "$UCI_REF" \
		https://git.openwrt.org/project/uci.git uci
else
	log "更新 uci"
	git -C uci fetch --depth 1 origin "$UCI_REF" && git -C uci reset --hard FETCH_HEAD
fi

BUILD_LUA=OFF
[ -n "$LUA_INC" ] && BUILD_LUA=ON

log "编译 uci (BUILD_LUA=$BUILD_LUA)"
rm -rf uci/build && mkdir -p uci/build && cd uci/build
cmake .. \
	-DCMAKE_INSTALL_PREFIX="$PREFIX" \
	-DCMAKE_BUILD_TYPE=Release \
	-DBUILD_LUA="$BUILD_LUA" \
	${LUA_INC:+-DLUA_INCLUDE_DIR="$LUA_INC"} \
	-DBUILD_STATIC=OFF
make -j"$JOBS"
make install
cd "$WORK"

# --- 校验 -------------------------------------------------------------------
log "构建产物："
find "$PREFIX" -type f \( -name 'uci' -o -name '*.so*' \) | sed 's/^/  /'

if [ ! -x "$PREFIX/sbin/uci" ] && [ ! -x "$PREFIX/bin/uci" ]; then
	log "警告：未找到 uci 可执行文件，请检查上面的构建输出"
	exit 1
fi

# 冒烟测试：uci CLI 必须能独立运行（不依赖 OpenWrt）
UCI_BIN="$PREFIX/sbin/uci"
[ -x "$UCI_BIN" ] || UCI_BIN="$PREFIX/bin/uci"
log "冒烟测试： $UCI_BIN -q get system.@system[0].hostname"
LD_LIBRARY_PATH="$PREFIX/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
	"$UCI_BIN" -q get system.@system[0].hostname || log "（无 system 配置，属正常）"

log "完成。前缀：$PREFIX"
