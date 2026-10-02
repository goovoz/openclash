#!/usr/bin/env bash
# =============================================================================
# 构建 openclash-rt 的 .deb 包
# -----------------------------------------------------------------------------
# 用法：
#   scripts/build-deb.sh                    # 用 upstream/.upstream-version 的版本
#   VERSION=0.47.156 scripts/build-deb.sh
#   SKIP_UCI_BUILD=1 scripts/build-deb.sh   # 复用 packaging/build/opt 下已构建的 uci
#   SKIP_LUA_BUILD=1 scripts/build-deb.sh   # 跳过 Lua C 模块（调试打包流程时用）
#   SKIP_UBUS_BUILD=1 scripts/build-deb.sh  # 跳过 ubus 底座（同上）
#
# 构建依赖（Debian/Ubuntu）：
#   build-essential cmake pkg-config lua5.1 liblua5.1-0-dev libjson-c-dev libssl-dev
#
# 产物：dist/openclash-rt_<version>_<arch>.deb
#
# 关于「路径契约」（重要，见 docs/03-路径契约.md）：
#   上游 usr/share/openclash/*.sh 内部使用硬编码绝对路径 source 与调用：
#     /lib/functions.sh  /lib/functions/procd.sh  /sbin/uci
#     /usr/share/openclash/*.sh
#   因此本包**必须**把这些文件安装到上述路径。在 Debian 上 /lib -> /usr/lib、
#   /sbin -> /usr/sbin 是符号链接，dpkg 会正确落位。这些路径在 Debian 上原本
#   为空，不会与任何系统包冲突。
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DIST="$ROOT/dist"
BUILD="$ROOT/packaging/build"
STAGE="$BUILD/stage"
OPT="$BUILD/opt/openclash-rt"

log()  { printf '\033[1;36m[deb]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

# --- 版本 -------------------------------------------------------------------
UVER="$ROOT/upstream/.upstream-version"
[ -f "$UVER" ] || die "缺少 upstream/.upstream-version，请先运行 scripts/sync-upstream.sh"
# shellcheck disable=SC1090
UPSTREAM_PKG_VER="$(sed -n 's/^PKG_VERSION=//p' "$UVER")"
UPSTREAM_COMMIT="$(sed -n 's/^SHORT=//p' "$UVER")"

VERSION="${VERSION:-${UPSTREAM_PKG_VER:-0.0.0}}"
PKG_VERSION="${VERSION}+ocrt1"
ARCH="${ARCH:-$(dpkg --print-architecture 2>/dev/null || echo amd64)}"

log "上游 ${UPSTREAM_PKG_VER} (${UPSTREAM_COMMIT})  ->  包版本 ${PKG_VERSION}  架构 ${ARCH}"

# --- 前置检查 ---------------------------------------------------------------
[ -d "$ROOT/upstream/luci-app-openclash/root" ] || die "上游代码缺失，请先运行 scripts/sync-upstream.sh"
[ -d "$ROOT/vendor/luci" ] || die "缺少 vendor/luci，请先运行 scripts/fetch-luci-vendor.sh"
command -v dpkg-deb >/dev/null 2>&1 || die "需要 dpkg-deb（在 Debian/Ubuntu 上构建）"

# multiarch 三元组：既决定 libnl-tiny.so 落在 /usr/lib/<triple>/ 还是 /usr/lib/，
# 也决定 lua-path-bridge.sh 往哪个目录建软链。**必须在这里定下来并显式传给两个
# 子脚本**，否则两边各自探测，一旦探测结果不同就会建出指向不存在的 libnl-tiny
# 的链 —— 而且直到运行时 require luci.ip 才会暴露。
MULTIARCH="${DEB_HOST_MULTIARCH:-}"
[ -n "$MULTIARCH" ] || MULTIARCH="$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || true)"
[ -n "$MULTIARCH" ] || die "无法确定 multiarch 三元组（dpkg-architecture 不可用？）"
export DEB_HOST_MULTIARCH="$MULTIARCH"

# Lua C 模块的构建期依赖。缺任何一个，build-lua-modules.sh 都会以很难懂的方式
# 失败（找不到 lua.h / libnl 头文件），所以在入口处一次说清楚。
if [ "${SKIP_LUA_BUILD:-0}" != "1" ] || [ "${SKIP_UBUS_BUILD:-0}" != "1" ]; then
	_missing=""
	for p in lua5.1 liblua5.1-0-dev libjson-c-dev; do
		dpkg -s "$p" >/dev/null 2>&1 || _missing="$_missing $p"
	done
	if [ -n "$_missing" ]; then
		die "缺少构建依赖：$_missing
      apt-get install -y lua5.1 liblua5.1-0-dev libjson-c-dev libssl-dev
      （如确实要跳过：SKIP_LUA_BUILD=1 / SKIP_UBUS_BUILD=1，但这样打出的包跑不起来）"
	fi
	command -v "${CC:-cc}" >/dev/null 2>&1 || die "找不到 C 编译器 ${CC:-cc}（apt-get install -y build-essential）"
fi

# ubus 底座用上游 CMake 构建，需要 cmake
if [ "${SKIP_UBUS_BUILD:-0}" != "1" ]; then
	command -v cmake >/dev/null 2>&1 || die "缺少 cmake（apt-get install -y cmake）"
fi

# --- uci 运行时 -------------------------------------------------------------
if [ "${SKIP_UCI_BUILD:-0}" != "1" ]; then
	if [ -x "$OPT/sbin/uci" ] || [ -x "$OPT/bin/uci" ]; then
		log "复用已构建的 uci: $OPT"
	else
		log "构建 libubox + uci ..."
		"$ROOT/runtime/uci/build-uci.sh" "$OPT"
	fi
else
	log "SKIP_UCI_BUILD=1，跳过 uci 构建"
fi

# --- 组装文件树 -------------------------------------------------------------
log "组装 staging 树 ..."
rm -rf "$STAGE"
mkdir -p "$STAGE"/DEBIAN
mkdir -p "$STAGE"/usr/share/openclash \
         "$STAGE"/etc/init.d \
         "$STAGE"/etc/config \
         "$STAGE"/etc/dnsmasq.d \
         "$STAGE"/lib/functions \
         "$STAGE"/lib/config \
         "$STAGE"/lib/systemd/system \
         "$STAGE"/usr/sbin \
         "$STAGE"/usr/lib/openclash-rt/procd \
         "$STAGE"/usr/lib/openclash-rt/shell
# 注：vendor LuCI 的目录（/usr/lib/lua/luci、/www、/usr/share/rpcd/acl.d 等）
# 由 scripts/install-vendor-luci.sh 自己 mkdir —— 避免两处清单漂移。

UP="$ROOT/upstream/luci-app-openclash/root"

# 1) 上游代码（原样，除下面显式列出的例外）
# 上游 ipkg Makefile 的 install 段（单一事实来源）：
#     $(CP) $(PKG_BUILD_DIR)/root/*    $(1)/
#     $(CP) $(PKG_BUILD_DIR)/luasrc/*  $(1)/usr/lib/lua/luci/
#     $(INSTALL_DATA) .../*.*.lmo       $(1)/usr/lib/lua/luci/i18n/
# www 必须落 /www（HTTP 文档根），与 vendor LuCI 的 htdocs 合并规则一致；
# 真机验证（2026-10-01）确认装到 /usr/share/openclash/www 是错的——
# 上游 postrm 也按 /www/luci-static/resources/openclash 清理。
mkdir -p "$STAGE/www" "$STAGE/usr/lib/lua/luci"
cp -a "$UP/usr/share/openclash/."      "$STAGE/usr/share/openclash/"
cp -a "$UP/www/."                      "$STAGE/www/" 2>/dev/null || true
cp -a "$UP/etc/openclash/."            "$STAGE/usr/share/openclash/defaults/" 2>/dev/null || true
cp -a "$UP/etc/uci-defaults/."         "$STAGE/usr/share/openclash/uci-defaults/" 2>/dev/null || true
#    会把它们全压成 100644。实测未修之前打出的包里：
#      /etc/init.d/openclash          -rw-r--r--   ← systemd 单元写的正是
#                                                    ExecStart=/etc/init.d/openclash boot
#      /usr/share/openclash/*.sh (25) -rw-r--r--
#      /usr/share/openclash/*.lua (8) -rw-r--r--
#
#    /etc/init.d/openclash 缺位是**服务根本起不来**（journalctl 只留 203/EXEC）；
#    而 /usr/share/openclash 下那 33 个更隐蔽 —— 上游是**直接执行**它们的：
#      openclash_update.sh:91   /usr/share/openclash/openclash_core.sh "Meta" "$1" "$2" >/dev/null 2>&1
#      yml_groups_set.sh:330    /usr/share/openclash/yml_proxys_set.sh "$CONFIG_FILE" >/dev/null 2>&1
#      openclash_watchdog.sh:396   /usr/share/openclash/openclash_oix_checkin.lua >/dev/null 2>&1
#      openclash.sh:37             $(/usr/share/openclash/openclash_urlencode.lua "$1")
#    0644 下全部 Permission denied，而调用点几乎都带 `>/dev/null 2>&1` ——
#    症状表现为「内核下载失败 / 订阅不更新 / 配置生成不出来」且**一条报错都没有**。
#
#    判据刻意用「文件自己有没有 shebang」而不是记一份清单：清单会漂，
#    上游每次同步都可能增删脚本，漏一个就是一个静默故障。
#    实现在 runtime/upstream/normalize-modes.sh（e2e 的 staging 模式共用同一份，
#    避免两处判据漂移）。

# 1a) 上游 luasrc -> /usr/lib/lua/luci/（与 vendor LuCI 同一落位契约）
#     luasrc/ 是扁平树：openclash.lua -> luci/openclash.lua（module("luci.openclash")）、
#     controller/ model/ view/ 原样进 luci/ 命名空间。
#     真机验证（2026-10-01）：缺这段导致 require "luci.controller.openclash" /
#     require "luci.openclash" 全部 not found，8 个 #!/usr/bin/lua 脚本连依赖都加载不了。
cp -a "$ROOT/upstream/luci-app-openclash/luasrc/." "$STAGE/usr/lib/lua/luci/"

# 1a2) 上游 rpcd/acl.d → /usr/share/rpcd/acl.d/
#     luci-app-openclash.json 授权 uci: ["openclash"] 的读写，是 dispatcher 判断
#     能否访问 /admin/services/openclash/* 的 ACL 来源（access-group 里必须含
#     "luci-app-openclash"）。P4 测绘（2026-10-02）发现真机 acl.d 缺这个 json，
#     登录成功也会被拒在 openclash 页面门外 —— 与 vendor LuCI 的 acl.d 合并落位。
#     注意：本段在 vendor LuCI 落位（§2）之前执行，此时 $STAGE/usr/share/rpcd/acl.d/
#     目录尚未被 install-vendor-luci.sh 的 mkdir -p 创建，故必须先 mkdir -p，
#     否则 cp -a 到不存在的目录会静默失败（被 2>/dev/null||true 吞掉）。
if [ -d "$UP/usr/share/rpcd/acl.d" ]; then
	mkdir -p "$STAGE/usr/share/rpcd/acl.d"
	cp -a "$UP/usr/share/rpcd/acl.d/." "$STAGE/usr/share/rpcd/acl.d/"
fi

# 1z) CRLF 防线：上游树若在 Windows 上 checkout（core.autocrlf=true），
#     所有文本文件会带 \r。MSYS→Linux 传输路径是否规范化取决于工具链，
#     不能赌 —— 在 staging 上就地剥离所有会由 sh/bash 执行的文件：
#       · /etc/init.d/* 与 /etc/uci-defaults/*（无扩展名，shebang 带 \r 直接 exec 失败；
#         实测：uci-defaults 报 ". /lib/functions.sh: No such file"）
#       · 全部 *.sh（\r 附着在最后一个参数上，如 mkversion.sh 的 "2: : not found"）
#     *.lua / *.htm 不剥：Lua 5.1 lexer 与 LuCI 模板引擎都把 \r 当空白，无害。
#     vendor 侧同类防线在 bc_copy_src（runtime/lib/build-common.sh），两处职责不重叠：
#     那边管"编译用源码副本"，这边管"直接进 deb 的文件"。
find "$STAGE/etc/init.d" "$STAGE/usr/share/openclash/uci-defaults" \
     "$STAGE/usr/share/openclash" -type f \
     \( -name '*.sh' -o -path "$STAGE/etc/init.d/*" -o -path "$STAGE/usr/share/openclash/uci-defaults/*" \) \
     -exec sed -i 's/\r$//' {} +

# 1y) 可执行位归一
# ---------------------------------------------------------------------------
# ⚠️ 这是实测出来的静默故障，不是洁癖。上游 ipkg 直接从 git 工作区 CP，
#    可执行位由上游仓库的 100755 保证；而我们的链路
#      sync-upstream.sh 稀疏检出 → 在 core.filemode=false 的主机上提交 → 检出
#    会把它们全压成 100644。实测未修之前打出的包里：
#      /etc/init.d/openclash          -rw-r--r--   ← systemd 单元写的正是
#                                                    ExecStart=/etc/init.d/openclash boot
#      /usr/share/openclash/*.sh (25) -rw-r--r--
#      /usr/share/openclash/*.lua (8) -rw-r--r--
#
#    /etc/init.d/openclash 缺位是**服务根本起不来**（journalctl 只留 203/EXEC）；
#    而 /usr/share/openclash 下那 33 个更隐蔽 —— 上游是**直接执行**它们的：
#      openclash_update.sh:91      /usr/share/openclash/openclash_core.sh "Meta" "$1" "$2" >/dev/null 2>&1
#      yml_groups_set.sh:330       /usr/share/openclash/yml_proxys_set.sh "$CONFIG_FILE" >/dev/null 2>&1
#      openclash_watchdog.sh:396   /usr/share/openclash/openclash_oix_checkin.lua >/dev/null 2>&1
#      openclash.sh:37             $(/usr/share/openclash/openclash_urlencode.lua "$1")
#    0644 下全部 Permission denied，而调用点几乎都带 `>/dev/null 2>&1` ——
#    症状表现为「内核下载失败 / 订阅不更新 / 配置生成不出来」且**一条报错都没有**。
#
#    判据刻意用「文件自己有没有 shebang」而不是记一份清单：清单会漂，
#    上游每次同步都可能增删脚本，漏一个就是一个静默故障。
#    实现在 runtime/upstream/normalize-modes.sh（e2e 的 staging 模式共用同一份，
#    避免两处判据漂移）。
#
#    位置刻意排在 §1z（CRLF 剥离）**之后**：sed -i 会重建文件，虽然 GNU sed
#    会保留原模式，但把归一放在所有"可能重建文件"的步骤之后，就不必依赖
#    "某个工具恰好保留了 mode"这种不可控性质 —— 归一是最后一道，做完即定稿。
install -m 0755 "$UP/etc/init.d/openclash" "$STAGE/etc/init.d/openclash"
# usr/share/openclash（含 uci-defaults 子目录）与 etc/init.d 下都可能存在
# 带 shebang 却缺可执行位的文件，两处都要归一。uci-defaults 是**安装时被
# 逐个 exec** 的（不是 source），同样会踩 Permission denied。
_norm_n="0"
for _norm_dir in "$STAGE/usr/share/openclash" "$STAGE/etc/init.d"; do
	_norm_cur="$(bash "$ROOT/runtime/upstream/normalize-modes.sh" \
		--dir "$_norm_dir")" \
		|| die "可执行位归一失败（目录 $_norm_dir，原因见上面的 norm-mode 输出）"
	_norm_n=$((_norm_n + _norm_cur))
done
[ -n "$_norm_n" ] || die "normalize-modes.sh 未返回归一处数（stdout 被污染？）"
log "可执行位归一：${_norm_n} 个带 shebang 的上游脚本 -> 0755（另含 /etc/init.d/openclash）"

# 1b) 把上游对「系统 lua」的依赖钉死到 lua5.1（P1.5 的语义前提）
# ---------------------------------------------------------------------------
# 上游有 **11 处**假定「`lua` 这个命令解析到 Lua 5.1」：
#   · 8 个 `#!/usr/bin/lua` shebang；
#   · 3 处**显式调用**（走 PATH，只改 shebang 覆盖不到）——
#     openclash_core.sh:57、openclash_update.sh:33，
#     以及 openclash_watchdog.sh:83 内嵌 Ruby 字符串里的那处。
#
# OpenWrt 上这个假设成立（系统只可能有一个 5.1）。Debian 上**不成立**：
# /usr/bin/lua 由 update-alternatives 组 `lua-interpreter` 提供，优先级
# lua5.1=110 < lua5.2=120 ≈ lua5.3=120 < lua5.4=130。于是「只要这台机器上
# 还装着 lua5.4」，/usr/bin/lua 就指向 5.4，而我们为 5.1 编译的
# nixio.so / lucihttp.so / ubus.so 会在运行时以 undefined symbol / ABI 不符
# 失败 —— 症状与「Lua 搜索路径没桥接对」几乎一样（都是"加载失败"），
# 但根因完全不同，必须在源头消除而不是留到排障时猜。
#
# 具体机制、实测证据、以及「为什么用改写绝对路径而不是注册
# update-alternatives」的取舍，全部写在下面这个脚本的文件头 ——
# 它才是**单一事实来源**，这里只负责调用。
#
# 该脚本采用"改写规则窄 / 残留判据宽"的不对称设计：已知形态自动改写；
# 一旦上游换成我们没测绘过的写法，它会**构建失败**并打印 file:line，
# 而不是打出一个"运行时按系统 lua 版本随机行为"的包 —— 这正是冲突告警。
#
# 它的 stdout 只输出一个整数（被改写的处数），人类日志走 stderr。
# 这里必须用命令替换接住那个整数；若日志混进 stdout 就会污染返回值
# （本仓库已在 vlog / fetch_openwrt_lib 两处踩过这个坑）。
LUA_BIN=/usr/bin/lua5.1
export LUA_BIN
_lua_rewritten="$(bash "$ROOT/runtime/upstream/pin-lua-interpreter.sh" \
	--dir "$STAGE/usr/share/openclash")" \
	|| die "lua 解释器钉定失败（原因见上面的 pin-lua 输出）"
[ -n "$_lua_rewritten" ] || die "pin-lua-interpreter.sh 未返回改写处数（stdout 被污染？）"
log "lua 解释器已钉到 ${LUA_BIN}（改写 ${_lua_rewritten} 处）"

# 1c) 记录本包相对上游做过的「打包期适配」，供上游同步时比对冲突
#     这不是装饰：用户要的是「每日同步上游 + 冲突告警」。某条适配若将来
#     失效（上游改了那段代码），这个清单就是唯一的对照表。
cat >"$STAGE/usr/lib/openclash-rt/packaging-adaptations.txt" <<EOF
# openclash-rt 打包期对上游文件做过的定点适配
# 上游 commit: ${UPSTREAM_COMMIT}
# 用途：与 upstream/ 目录逐条比对，判断上游同步是否让某条适配失效。
#
[1] lua 解释器钉定（本次改写 ${_lua_rewritten} 处）
    原因：Debian 的 /usr/bin/lua 由 update-alternatives 组 lua-interpreter 提供，
          lua5.4(130) 优先级高于 lua5.1(110)，会使为 5.1 编译的 .so 加载失败。
    工具：runtime/upstream/pin-lua-interpreter.sh（机制与证据见该脚本文件头）
    适用：usr/share/openclash/ 下全部 *.lua 与 *.sh
[2] vendor LuCI 入口 shebang 钉定（2 处：/www/cgi-bin/luci 与 /usr/libexec/rpcd/luci）
    原因：同 [1]，且这两个文件无扩展名，只能 --file 显式钉定。
    适用：vendor/luci/luci-base/{htdocs/cgi-bin/luci, root/usr/libexec/rpcd/luci}
    工具：runtime/upstream/pin-lua-interpreter.sh --file（经 scripts/install-vendor-luci.sh 调用）
[3] vendor LuCI 布局映射（luasrc 加 luci/ 前缀；htdocs 三包合并到 /www）
    原因：Lua 5.1 require 机制要求 module("luci.X") 落位 /usr/lib/lua/luci/X.lua；
          vendor 树的 luasrc/ 是扁平的，必须打包期加前缀（vendor 树本身不改）。
    契约：docs/03-路径契约.md §3.1（映射表）
    工具：scripts/install-vendor-luci.sh
    附带清理：*.luadoc（上游 API 文档）不入包
[4] vendor LuCI i18n .po -> .lmo 编译（落位 /usr/lib/lua/luci/i18n/）
    原因：上游 libtemplate.so 的 tparser.load_catalog 读 <lang>.lmo 文件，
          i18ndir 唯一 = /usr/lib/lua/luci/i18n/（因 libpath() 指向 i18n.lua 所在目录）。
          po2lmo.c 是上游自带的独立可编译工具，不需 lemon/flex/bison。
    契约：docs/03-路径契约.md §3.2（命名 <pkg>.<lang>.lmo）
    工具：scripts/install-vendor-lmo.sh
    附带清理：.po 源 / .y / .c / .h 不入 staging；po2lmo 二进制本身不入 deb
[5] 可执行位归一（本次修正 ${_norm_n} 个 + /etc/init.d/openclash）
    原因：sync-upstream 链路（稀疏检出 → 在 core.filemode=false 的主机上提交）
          会把上游脚本压成 100644。而上游是**直接执行**这些文件的，例如
            openclash_update.sh:91  /usr/share/openclash/openclash_core.sh "Meta" ... >/dev/null 2>&1
            yml_groups_set.sh:330   /usr/share/openclash/yml_proxys_set.sh "\$CONFIG_FILE" >/dev/null 2>&1
          0644 下全部 Permission denied，且因调用点带 >/dev/null 2>&1 而**零报错**；
          /etc/init.d/openclash 缺位则让 systemd 单元 203/EXEC 直接起不来。
    判据：文件头两字节 == "#!"（shebang 即"我是可执行入口"的自我声明，不会漏也不会误伤）
    工具：runtime/upstream/normalize-modes.sh
EOF
chmod 0644 "$STAGE/usr/lib/openclash-rt/packaging-adaptations.txt"

# 2) 兼容运行时 —— 路径契约要求的绝对路径
cp "$ROOT/runtime/procd/rc.common"            "$STAGE/etc/rc.common"
cp "$ROOT/runtime/shell/functions.sh"         "$STAGE/lib/functions.sh"
cp "$ROOT/runtime/shell/functions/network.sh" "$STAGE/lib/functions/network.sh"
cp "$ROOT/runtime/shell/service.sh"           "$STAGE/lib/functions/service.sh"
cp "$ROOT/runtime/procd/procd.sh"             "$STAGE/lib/functions/procd.sh"
cp "$ROOT/runtime/shell/config/uci.sh"        "$STAGE/lib/config/uci.sh"

# 2b) fw4 垫片 —— 必须落在 PATH 上，上游用 `command -v fw4` 做 nft/iptables 二选一
install -m 0755 "$ROOT/runtime/net/fw4"                "$STAGE/usr/sbin/fw4"
# 2b2) jsonfilter 垫片 —— OpenWrt 专有 JSON 工具，上游 3 个脚本用（内核版本/
#      ubus 运行态解析），Debian 没有；用 jq 等价桥接（见 docs/07 §4）。
#      用 install -D 自动建父目录：staging 树里 /usr/bin 可能还没被任何产物
#      创建（/usr/sbin 有 rpcd/ubusd 落位所以存在，/usr/bin 未必），不加 -D
#      会报 "cannot create regular file ... No such file or directory"。
install -D -m 0755 "$ROOT/runtime/net/jsonfilter"         "$STAGE/usr/bin/jsonfilter"
# 2c) 易失路径准备 + dnsmasq 适配器（Debian 上没有任何组件会创建这些前提）
install -m 0755 "$ROOT/runtime/net/prepare-tmp.sh"     "$STAGE/usr/lib/openclash-rt/prepare-tmp.sh"
install -m 0755 "$ROOT/runtime/net/dnsmasq-adapter.sh" "$STAGE/usr/lib/openclash-rt/dnsmasq-adapter.sh"

# 2d) LuCI HTTP 宿主（P3 自研件）—— 替代 uhttpd
# ----------------------------------------------------------------------------
# 这是 docs/02 §5.6 H1–H10 的全部实现：监听 TCP、解析 HTTP、静态文件 + CGI 桥。
# 它**唯一**读 /etc/config/openclash-rt 拿到 listen/port；与上游 LuCI 入口
# /www/cgi-bin/luci 配对：宿主把 HTTP 转成 CGI 环境变量 + stdin，CGI 脚本输出
# 的 "Status: .../Headers/Body" 由宿主反解为 HTTP 响应。
#
# shebang 必须是 #!/usr/bin/lua5.1（与 cgi-bin/luci 同原则：依赖 Debian
# 提供的 lua5.1 包，绕开 update-alternatives 路径以避免 5.3/5.4 抢占）。
install -m 0755 "$ROOT/runtime/sys/luci-host.lua"      "$STAGE/usr/lib/openclash-rt/luci-host.lua"

# 2d2) P4 进程内 ubus session 模块 + 引导（自研件）—— 替代外部 ubusd/rpcd 的 session 插件
# ----------------------------------------------------------------------------
# luci-session.lua 是进程内 session 实现（login/get/access/set/destroy），
# 对齐 vendor/rpcd/session.c 语义（见 docs/06）。luci-session-bootstrap.lua
# 通过 LUA_INIT=@file 在 CGI 子进程里预注入 package.loaded["ubus"]，让上游
# util.ubus("session", ...) 走本地实现，不再依赖外部 ubusd/rpcd。
# 两者必须与 luci-host.lua 同目录（/usr/lib/openclash-rt/），bootstrap 用绝对
# 路径 dofile 加载 luci-session，不依赖 Lua 默认搜索路径。
install -m 0644 "$ROOT/runtime/sys/luci-session.lua"            "$STAGE/usr/lib/openclash-rt/luci-session.lua"
install -m 0644 "$ROOT/runtime/sys/luci-session-bootstrap.lua"  "$STAGE/usr/lib/openclash-rt/luci-session-bootstrap.lua"
install -m 0644 "$ROOT/runtime/sys/luci-uci.lua"                "$STAGE/usr/lib/openclash-rt/luci-uci.lua"

# 3) 兼容运行时 —— 保留一份可读副本，便于排障与升级对比
cp "$ROOT/runtime/procd/rc.common"            "$STAGE/usr/lib/openclash-rt/procd/rc.common"
cp "$ROOT/runtime/procd/procd.sh"             "$STAGE/usr/lib/openclash-rt/procd/procd.sh"
cp "$ROOT/runtime/shell/functions.sh"         "$STAGE/usr/lib/openclash-rt/shell/functions.sh"
cp "$ROOT/runtime/shell/service.sh"           "$STAGE/usr/lib/openclash-rt/shell/service.sh"
cp "$ROOT/runtime/shell/config/uci.sh"        "$STAGE/usr/lib/openclash-rt/shell/uci.sh"

# 4) uci 运行时二进制与库
#
# ⚠️ 刻意**不**复制 $OPT/include/ —— 那是 libubox / libuci 的头文件树，
#    只在**构建期**被 build-ubus.sh 与 build-uci.sh 消费（通过
#    -DCMAKE_INCLUDE_PATH）。放进运行时包会：
#      · 往 /usr/include/ 塞一堆 Debian 里不存在的 OpenWrt 私有头（约 1MB）；
#      · 违反 Debian 政策（头文件属于 -dev 包），且将来若真有 libubox-dev
#        之类的包，dpkg 会因文件冲突而拒绝安装。
#    注意 build-ubus.sh 读的是 $OPT/include（构建期目录），
#    与这里往 $STAGE（交付树）复制的是两回事，删掉不影响它。
#    $OPT/share/ 保留：uci/libubox 的 make install 目前不产出内容，
#    但未经实测确认，保守起见不动（若将来确认恒为空，可一并去掉）。
if [ -d "$OPT" ]; then
	for d in sbin bin lib share; do
		[ -d "$OPT/$d" ] && mkdir -p "$STAGE/usr/$d" && cp -a "$OPT/$d/." "$STAGE/usr/$d/"
	done
	# 反向自检：万一上游/CMake 改动导致 .h 混进 lib/ 或 share/，这里要报出来
	if find "$STAGE/usr/lib" "$STAGE/usr/share" -name '*.h' -print -quit 2>/dev/null | grep -q .; then
		warn "运行时树里出现了头文件（本应只在构建期使用）："
		# 用 `sed -n '1,5p'` 而不是 `head -5`：head 提前退出会给 find 送 SIGPIPE，
		# 在 set -o pipefail 下让整条管道返回非零 —— 而这里不是 if 的条件，
		# 于是会直接终止脚本。sed 会读完输入，没有这个问题。
		find "$STAGE/usr/lib" "$STAGE/usr/share" -name '*.h' 2>/dev/null \
			| sed -n '1,5p' | sed 's/^/    /' >&2
	fi
	# /sbin/uci 是上游 uci_load 的硬编码路径（Debian: /sbin -> /usr/sbin）
	if [ -x "$STAGE/usr/sbin/uci" ]; then :; elif [ -x "$STAGE/usr/bin/uci" ]; then
		ln -sf ../bin/uci "$STAGE/usr/sbin/uci"
	fi
fi

# 5) 生成 /etc/openwrt_release
#    上游两处消费这个文件：
#      a) init.d:14  [ -f /etc/openwrt_release ] 门控整段 DNSMASQ_CONF_DIR 推导
#      b) uci-defaults:79-124  source 它 → 用 DISTRIB_ARCH 推断内核架构
#    必须用生成器而不是内联 cat：内联写法直接拿 dpkg 架构（amd64/arm64），
#    而上游的 case 只认 OpenWrt 架构词汇 —— `amd64` 不匹配任何分支，会落到
#    兜底 `*)` → CORE_ARCH=0 → 内核下载链接错误，界面只显示"下载失败"。
#    生成器做的是「dpkg 架构 → OpenWrt 架构」的翻译（见其头部说明）。
install -m 0755 "$ROOT/runtime/sys/openwrt-release.sh" \
    "$STAGE/usr/lib/openclash-rt/openwrt-release.sh"
OPENCLASH_RT_ROOT_PREFIX="$STAGE" OPENCLASH_RT_DPKG_ARCH="$ARCH" \
    bash "$ROOT/runtime/sys/openwrt-release.sh" >/dev/null
CORE_ARCH="$(OPENCLASH_RT_ROOT_PREFIX="$STAGE" OPENCLASH_RT_DPKG_ARCH="$ARCH" \
    bash "$ROOT/runtime/sys/openwrt-release.sh" --core-arch 2>/dev/null)"
log "架构映射: dpkg=$ARCH -> $(sed -n "s/^DISTRIB_ARCH='\([^']*\)'.*/\1/p" "$STAGE/etc/openwrt_release") -> CORE_ARCH=${CORE_ARCH:-?}"
if [ "${CORE_ARCH:-0}" = "0" ]; then
	warn "架构 $ARCH 没有可自动下载的 mihomo 内核（上游会判 CORE_ARCH=0）"
	warn "包可正常安装，但用户需手工放置内核到 /etc/openclash/core/clash_meta"
fi

# 5a) ubus 底座（P1.5）
#     为什么它排在 Lua 模块之前：vendor/luci/luci-lib-base/luasrc/util.lua:15 是
#     无条件的顶层 `require "ubus"`，而 luci.util 被几乎所有 LuCI 模块依赖。
#     没有 ubus.so，前端与上游 8 个 #!/usr/bin/lua 脚本都加载不了 —— 这与
#     Lua 搜索路径是否桥接正确无关，是另一条独立的硬依赖。
#     详见 docs/04-ubus依赖图谱.md。
if [ "${SKIP_UBUS_BUILD:-0}" != "1" ]; then
	log "构建 ubus 底座（ubusd / libubus / ubus.so / rpcd）-> $STAGE ..."
	# UBOX_PREFIX 必须指向已构建的 libubox + libuci（含 include/）：
	# ubus 与 rpcd 都链接它们（blobmsg / avl / uloop / uci）。
	UBOX_PREFIX="$OPT" "$ROOT/runtime/ubus/build-ubus.sh" --destdir "$STAGE" \
		|| die "ubus 底座构建失败"
else
	log "SKIP_UBUS_BUILD=1，跳过 ubus 底座（打出的包前端与上游 Lua 脚本都跑不起来）"
fi

# 5b) Lua C 模块 + 搜索路径桥接（P1）
#     LuCI 的纯 Lua 代码**不能**脱离 C 扩展运行：nixio / lucihttp / luci.ip /
#     luci.jsonc / template.parser 都是模块顶层 `require`，少一个整站起不来。
#     产物按上游契约落在 /usr/lib/lua/ 下，再由 lua-path-bridge.sh 把它接进
#     Debian lua5.1 的默认搜索路径（前者是上游写死的，后者是 Debian 政策决定
#     的，两边都动不了，只能在中间架桥 —— 见 docs/03-路径契约.md）。
if [ "${SKIP_LUA_BUILD:-0}" != "1" ]; then
	log "构建 Lua C 模块 -> $STAGE ..."
	# ⚠️ 必须 --destdir "$STAGE"：先落到 staging 树，再由桥接脚本建软链，
	#    最后统一由 dpkg-deb 打包。绝不能直接装进宿主机 /usr/lib/lua。
	"$ROOT/runtime/lua/build-lua-modules.sh" --destdir "$STAGE" \
		|| die "Lua C 模块构建失败"
	log "建立 Lua 搜索路径软链 ..."
	# --stagedir 是**主路径**：软链直接进 .deb，dpkg -L 可见、卸载自动清理，
	# 安装期不需要动任何系统状态。安装期的 --apply 只是兜底。
	bash "$ROOT/runtime/lua/lua-path-bridge.sh" --stagedir "$STAGE" \
		|| die "Lua 搜索路径桥接失败"
else
	log "SKIP_LUA_BUILD=1，跳过 Lua C 模块构建（打出的包前端不可用）"
fi

# 5c) vendor LuCI 集成（P2-A）
# -----------------------------------------------------------------------------
# 把 vendor/luci 的 8 个上游包按 docs/03 §3.1 的映射落进 staging 树。
# 全部逻辑在 scripts/install-vendor-luci.sh 里 —— **build-deb.sh 不直接写
# 任何 cp / install 命令**，只是单点调用。这样所有 P2-A 的行为都能在
# tests/test_luci_vendor_install.sh 里用同一份脚本做断言，「构建脚本与测试
# 脚本之间出现差异」这一类隐患在源头被消除。
#
# 关键设计：
#   - 所有 4 个 vendor 包的 luasrc/* 都装到 /usr/lib/lua/luci/ 下，
#     **加上 luci/ 前缀**。这不是命名空间风格选择，而是 Lua 5.1 require
#     机制决定的：cacheloader.lua 第 1 行就是 `require "luci.config"`，
#     Lua 5.1 会去 /usr/lib/lua/luci/config.lua 找，不加前缀就 require 不到。
#   - vendor 树本身**绝不修改**。同步上游时 fetch-luci-vendor.sh 会
#     重置 vendor/，这里做的所有「加 luci/ 前缀」都在 staging 树完成。
log "vendor LuCI 集成 -> $STAGE ..."
_luci_pkgs="$(bash "$ROOT/scripts/install-vendor-luci.sh" \
	--src "$ROOT/vendor/luci" --stage "$STAGE" \
	--pin-linter "$ROOT/runtime/upstream/pin-lua-interpreter.sh" \
	)" || die "vendor LuCI 集成失败（见上面的 install-vendor-luci 输出）"
[ -n "$_luci_pkgs" ] || die "install-vendor-luci.sh 未返回统计值（stdout 被污染？）"
log "vendor LuCI 集成完成（luasrc 已处理 ${_luci_pkgs} 个包 + shebang 已钉）"

# 5d) vendor LuCI i18n 编译： .po -> .lmo（P2-B）
# ----------------------------------------------------------------------------
# 把 4 个 vendor 包的 .po 翻译源 编译成 .lmo 二进制落进 staging。
#
# po2lmo.c 是上游自带的、独立可编译工具（**不** link template_lmo.c，也**不**
# 需要 flex/lemon/bison）。脚本会自己找 cc，**失败时显式 die**。
#
# 与 §5c 的差异：这里**真编译**（CI 必有 gcc；本机无 gcc 的开发机可以用
# SKIP_LMO_BUILD=1 跳过——会留下空的 i18n 目录，运行时 i18n.setlanguage 会
# 静默退化到默认 lang=OpenClash 现有英文文本，这是已知可接受的回退）。
#
# 落位契约：<pkg>/po/<lang>/base.po -> /usr/lib/lua/luci/i18n/<pkg>.<lang>.lmo
# 命名匹配 fnmatch("*.zh-cn.lmo", ...)：多包共存互不覆盖。
#
# 编译产物 po2lmo 不入 deb（属 staging/usr/lib/openclash-rt/build/，由 §4 清）。
log "vendor LuCI i18n 编译（P2-B） -> $STAGE"
if [ "${SKIP_LMO_BUILD:-0}" = "1" ]; then
	log "SKIP_LMO_BUILD=1：跳过 .po -> .lmo 编译（仅落位空目录）"
	SKIP_CC_FLAG=--skip-cc
else
	SKIP_CC_FLAG=""
fi
bash "$ROOT/scripts/install-vendor-lmo.sh" \
	--src "$ROOT/vendor/luci" --stage "$STAGE" $SKIP_CC_FLAG \
	>/dev/null \
	|| die "vendor LuCI i18n 编译失败（见上面的 install-vendor-lmo 输出）"

# 5e) 上游 app 自身的 i18n：po/<lang>/*.po -> i18n/<name>.<lang>.lmo
# ----------------------------------------------------------------------------
# 上游 ipkg Makefile 的 Build/Prepare 只对 po/zh-cn/*.po 做 po2lmo 编译，
# install 段把 *.*.lmo 落到 /usr/lib/lua/luci/i18n/。这里按同一约定编译
# **所有** po/<lang>/（zh-cn 的超集；luci i18n 的 load_catalog 按 catalog 名
# 加载全部匹配 lmo，多语言共存无冲突）。
# 复用 §5b build-lua-modules.sh 编出的 po2lmo，不再二次编译。
# .po 源做 CRLF 剥离（同 §1z 的理由：po2lmo 逐行 fgets 解析，\r 会混进
# msgid/msgstr 字符串里，产出带 \r 的翻译）。
if [ "${SKIP_LMO_BUILD:-0}" = "1" ]; then
	log "SKIP_LMO_BUILD=1：跳过上游 app i18n 编译"
else
	PO2LMO="$STAGE/usr/bin/po2lmo"
	[ -x "$PO2LMO" ] || PO2LMO="$STAGE/usr/lib/openclash-rt/build/po2lmo"
	[ -x "$PO2LMO" ] || die "po2lmo 不存在（§5b build-lua-modules 被跳过了？）"
	PO_SRC="$ROOT/upstream/luci-app-openclash/po"
	I18N_OUT="$STAGE/usr/lib/lua/luci/i18n"
	mkdir -p "$I18N_OUT"
	_po_n=0
	for _po in "$PO_SRC"/*/*.po; do
		[ -f "$_po" ] || continue
		_name="$(basename "$_po" .po)"   # openclash.zh-cn.po -> openclash.zh-cn
		_tmp_po="$(mktemp)"
		sed 's/\r$//' "$_po" > "$_tmp_po"
		"$PO2LMO" "$_tmp_po" "$I18N_OUT/${_name}.lmo" \
			|| { rm -f "$_tmp_po"; die "上游 po 编译失败：$_po"; }
		rm -f "$_tmp_po"
		_po_n=$((_po_n + 1))
	done
	log "上游 app i18n 编译完成（${_po_n} 个 .lmo -> $I18N_OUT）"
fi


# 6) systemd 单元
cp "$ROOT/packaging/debian/openclash.service" "$STAGE/lib/systemd/system/openclash.service"
chmod 0644 "$STAGE/lib/systemd/system/openclash.service"
# dnsmasq 同步单元：上游写入 UCI 后不会自动落到 /etc/dnsmasq.d，
# 用 path 单元监听 /etc/config/dhcp 的变化来触发适配器，覆盖所有写入方。
for u in openclash-rt-dnsmasq-sync.service openclash-rt-dnsmasq-sync.path; do
	cp "$ROOT/packaging/debian/$u" "$STAGE/lib/systemd/system/$u"
	chmod 0644 "$STAGE/lib/systemd/system/$u"
done

# 6b) LuCI HTTP 宿主单元（P3 自研件）—— 替代 uhttpd
# ----------------------------------------------------------------------------
# 为什么单独成一节：本单元是 openclash-rt **前端**的入口守护进程，对应 docs/02
# §5.6 H1–H10 的完整职责。它**不**依赖 uhttpd：监听 127.0.0.1:9090，把 HTTP
# 请求作为 CGI 喂给 /www/cgi-bin/luci（CGI 协议详见 sgi/cgi.lua）。
#
# 安全默认（127.0.0.1）写在 unit 内部 --listen=127.0.0.1。要外露必须用户显式
# 改 /etc/config/openclash-rt 的 main.listen（不建议在公网直接暴露；
# 上游 105 个端点能跑任意 shell）。
cp "$ROOT/packaging/debian/openclash-rt-luci-host.service" \
   "$STAGE/lib/systemd/system/openclash-rt-luci-host.service"
chmod 0644 "$STAGE/lib/systemd/system/openclash-rt-luci-host.service"

# 7) 初始 UCI 配置（conffile）
if [ ! -f "$STAGE/etc/config/openclash" ]; then
	cat >"$STAGE/etc/config/openclash" <<'EOF'
config openclash 'config'
	option enable '0'
	option operation_mode 'fake-ip'
	option en_mode 'fake-ip'
	option en_mode_tun '1'
	option core_type 'Meta'
	option core_version '0'
	option dns_port '7874'
	option cn_port '9090'
EOF
fi

# 上游 init.d:16 必须能读到 dhcp.@dnsmasq[0]（匿名段），否则
# DEFAULT_DNSMASQ_CFGID 为空 → DNSMASQ_CONF_DIR 退化为 /tmp/dnsmasq.d，
# 上游写出的分流片段将不被 Debian 的 dnsmasq 加载。
#
# 段**具名**为 main 而不是匿名，是为了让上游推导出的 CFGID 稳定为 "main"：
#   config dnsmasq 'main'  →  uci show dhcp.@dnsmasq[0] 首行 = dhcp.main=dnsmasq
#                          →  awk 切出的 CFGID = main
# 匿名段会让 CFGID 变成 `@dnsmasq[0]`，一旦段顺序变化就与预生成的
# /tmp/etc/dnsmasq.conf.<CFGID> 失配而静默降级。
if [ ! -f "$STAGE/etc/config/dhcp" ]; then
	cat >"$STAGE/etc/config/dhcp" <<'EOF'
config dnsmasq 'main'
	option domainneeded '1'
	option localise_queries '1'
	option local '/lan/'
	option domain 'lan'
	option expandhosts '1'
	option authoritative '1'
	option readethers '1'
	option leasefile '/tmp/dhcp.leases'
	option resolvfile '/tmp/resolv.conf.d/resolv.conf.auto'
	option localservice '1'
EOF
fi

# 7b) /etc/config/firewall —— fw4 兼容垫片的 reload 入口
# ----------------------------------------------------------------------------
# 上游 uci-defaults 会在 postinst 里做：
#     uci -q delete firewall.openclash
#     uci -q set firewall.openclash=include
#     uci -q set firewall.openclash.path=/var/etc/openclash.include
# uci 在 /etc/config/firewall 不存在时 -q 会**静默丢弃**，整条防火墙联动失效。
# fw4 垫片的 reload() 也从 firewall.*=include 读 type=script 并执行；
# 没有 firewall 文件 → 上游 nft 规则永远不会从 reload 路径注入。
# 真机验证（2026-10-01）：firewall.openclash include 没落地 → nft 重启时无规则。
# 模板只放 fw4 读取必需的最小骨架 + 默认 zone，不覆盖用户后续手填的规则。
if [ ! -f "$STAGE/etc/config/firewall" ]; then
	cat >"$STAGE/etc/config/firewall" <<'EOF'
config defaults
	option input 'DROP'
	option forward 'DROP'
	option output 'ACCEPT'
config zone
	option name 'lan'
	list network 'lan'
	option input 'ACCEPT'
	option output 'ACCEPT'
	option forward 'ACCEPT'
config zone
	option name 'wan'
	list network 'wan'
	option input 'DROP'
	option output 'ACCEPT'
	option forward 'DROP'
	option masq '1'
	option mtu_fix '1'
config forwarding
	option src 'lan'
	option dest 'wan'
EOF
fi

# 7c) /etc/config/network —— luci.model.network 的最小可工作骨架
# ----------------------------------------------------------------------------
# luci-base 的 model/network.lua 读 /etc/config/network 渲染 Status 视图；
# 上游 OpenClash 在「配置覆盖」「端口共享」等场景下也用 uci 查 network。
# 真机验证（2026-10-01）：缺这份时 LuCI 网络视图 entry not found。
# ifname 留空（OpenClash 不接管系统网络），但保留 lan/wan 接口节
# 让 uci show network 至少能列出来，避免 luci.model.network 在 init 阶段炸。
if [ ! -f "$STAGE/etc/config/network" ]; then
	cat >"$STAGE/etc/config/network" <<'EOF'
config interface 'loopback'
	option ifname 'lo'
	option proto 'static'
	option ipaddr '127.0.0.1'
	option netmask '255.0.0.0'
config interface 'lan'
	option proto 'static'
	option ipaddr '192.168.1.1'
	option netmask '255.255.255.0'
config interface 'wan'
	option proto 'dhcp'
config globals 'globals'
	option ula_prefix 'auto'
EOF
fi

# 7d) /etc/config/uhttpd —— 上游 uci-defaults 的写入目标兜底（P3）
# ----------------------------------------------------------------------------
# 这个文件**不**被 openclash-rt 自己的宿主读取（宿主只读 /etc/config/openclash-rt）。
# 它存在只为让上游 OpenClash 的 uci-defaults 那段 `uci set uhttpd.main.*` 与
# `uci commit uhttpd` **有对象可写**，否则 `-q` 静默落空 → 上游的
# max_requests/max_connections/script_timeout 全部丢失（且无任何告警）。
#
# 同时：上游 uci-defaults 还会调 /etc/init.d/uhttpd restart，我们用本包提供的
# 兼容 initscript（etc-init.d-uhttpd）替代，把 restart 路由到 luci-host.service。
#
# 段名 = 'main'（具名段），与 dhcp/firewall 同样的"上游 cfgid 稳定性"原因。
if [ ! -f "$STAGE/etc/config/uhttpd" ]; then
	cat >"$STAGE/etc/config/uhttpd" <<'EOF'
config uhttpd 'main'
	option listen_http '0.0.0.0:0'
	option listen_https '0.0.0.0:0'
	option home '/www'
	option realm 'openclash-rt'
	option index_page 'cgi-bin/luci'
	option max_requests '3'
	option max_connections '100'
	option script_timeout '3600'
	option http_keepalive '20'
	option tcp_keepalive '1'
EOF
fi

# 7e) /etc/init.d/uhttpd —— 把上游 restart 命令映射到 luci-host.service（P3）
# ----------------------------------------------------------------------------
# 这个文件**不是**真 uhttpd；它是 openclash-rt 的「兼容 initscript」。
# 上游 uci-defaults 调用 /etc/init.d/uhttpd restart，本包把它路由到
#   systemctl restart openclash-rt-luci-host.service
# 这样无需碰上游代码（L1 红线），就能让上游的 restart 真的生效。
install -m 0755 "$ROOT/packaging/debian/etc-init.d-uhttpd" \
	"$STAGE/etc/init.d/uhttpd"

# 7f) /etc/config/openclash-rt —— 宿主自己的 UCI 配置（P3）
# ----------------------------------------------------------------------------
# LuCI 宿主读这份 main 段（listen/port/script_timeout/max_connections）。
# 不存在时宿主用 DEFAULTS（127.0.0.1:9090 / 3600 / 100）。
# 提供这份 conffile 的目的是让用户能**不改 unit 文件**地调整宿主行为。
if [ ! -f "$STAGE/etc/config/openclash-rt" ]; then
	cat >"$STAGE/etc/config/openclash-rt" <<'EOF'
config openclash_rt 'main'
	option listen '127.0.0.1'
	option port '9090'
	option script_timeout '3600'
	option max_connections '100'
EOF
fi

# 7g) /etc/config/rpcd —— P4 进程内 session 的登录源（conffile）
# ----------------------------------------------------------------------------
# P4 的进程内 session 模块（runtime/sys/luci-session.lua）对齐 rpcd 的
# rpc_login_test_login：读 /etc/config/rpcd 的 config login 段校验口令。
# 这个文件**不是**给真 rpcd 用的（本包不依赖 rpcd），而是给进程内模块读的
# 登录源。默认 login 段：
#   username root + password $p$root → 用 Debian root 密码登录 LuCI
#   （标准 LuCI 行为；$p$ 前缀 = 引用 /etc/shadow 的 root，见 docs/06 §1.3）
#   list read '*' / write '*' → root 拥有全部 ACL group（OpenWrt 默认），
#   对应 session.c 的 fnmatch(pattern, group) 通配匹配。
# 用户可改这个文件自定义账号/口令（改后无需重启宿主，进程内模块每次读）。
if [ ! -f "$STAGE/etc/config/rpcd" ]; then
	cat >"$STAGE/etc/config/rpcd" <<'EOF'
config login 'root'
	option username 'root'
	option password '$p$root'
	list read '*'
	list write '*'
EOF
fi

# 8) 版本标识（postinst / 排障用）
cat >"$STAGE/usr/lib/openclash-rt/upstream-version" <<EOF
PKG_VERSION=${UPSTREAM_PKG_VER}
UPSTREAM_COMMIT=${UPSTREAM_COMMIT}
BUILT_PACKAGE_VERSION=${PKG_VERSION}
EOF
chmod 0644 "$STAGE/usr/lib/openclash-rt/upstream-version"

# 8) DEBIAN 控制文件
install -m 0644 "$ROOT/packaging/debian/control"      "$STAGE/DEBIAN/control"
install -m 0755 "$ROOT/packaging/debian/postinst"     "$STAGE/DEBIAN/postinst"
install -m 0755 "$ROOT/packaging/debian/prerm"        "$STAGE/DEBIAN/prerm"
install -m 0755 "$ROOT/packaging/debian/postrm"       "$STAGE/DEBIAN/postrm"
install -m 0644 "$ROOT/packaging/debian/conffiles"    "$STAGE/DEBIAN/conffiles"

sed -i \
	-e "s/@PKG_VERSION@/${PKG_VERSION}/g" \
	-e "s/@ARCH@/${ARCH}/g" \
	-e "s/@UPSTREAM_VERSION@/${UPSTREAM_PKG_VER}/g" \
	-e "s/@UPSTREAM_COMMIT@/${UPSTREAM_COMMIT}/g" \
	"$STAGE/DEBIAN/control"

# 清掉不该进包的东西
find "$STAGE" -name '.git*' -prune -exec rm -rf {} + 2>/dev/null || true
find "$STAGE" -name '*.md' -path '*/openclash/*' -delete 2>/dev/null || true

# --- 打包 -------------------------------------------------------------------
mkdir -p "$DIST"
DEB="$DIST/openclash-rt_${PKG_VERSION}_${ARCH}.deb"
log "生成 $DEB"
dpkg-deb --root-owner-group --build "$STAGE" "$DEB" >/dev/null

log "包信息："
dpkg-deb -I "$DEB" | sed 's/^/  /'
log "文件数：$(dpkg-deb -c "$DEB" | wc -l)"
log "完成：$DEB"
