#!/usr/bin/env bash
# =============================================================================
# LuCI vendor 拉取（前端 L1 依赖）
# -----------------------------------------------------------------------------
# 职责：
#   1. 把前端所需的 LuCI 子树拉到 vendor/ 下，**pin 到具体 commit**
#   2. 记录版本信息，供 .deb 的可追溯性与复现构建使用
#   3. 输出一份「兼容面快照」，便于上游 OpenClash 同步后对比是否出现新依赖
#
# 为什么是 openwrt-21.02 而不是 master：
#   现代 luci-base 已 Lua → ucode 迁移，`modules/luci-base/` 下**没有 luasrc/**。
#   Lua 侧只剩 `modules/luci-lua-runtime/luasrc/dispatcher.lua` 这一个桥接文件，
#   它靠 `_G.L.dispatcher.*`（由 ucode 注入）才能工作，无法独立运行；
#   而 ucode 版 luci-base 依赖 rpcd + ubus，属于被否决的路线 A。
#   openwrt-21.02 的 luci-base 是完整独立的纯 Lua 实现，自带 `luasrc/sgi/cgi.lua`
#   —— 一个标准 CGI 入口，这使「自研 Web 宿主」成为可能。
#
#   设计红线：vendor/ 内的文件**永不修改**。上游对 luci-base 的运行时改写
#   （见 upstream/luci-app-openclash/root/etc/uci-defaults/luci-openclash）
#   由安装期原样执行该 uci-defaults 脚本来复刻，而不是在 vendor 树里打补丁。
#
# 用法：
#   scripts/fetch-luci-vendor.sh              # 拉取/更新
#   scripts/fetch-luci-vendor.sh --no-theme   # 不拉主题（省时间）
#   LUCI_REF=openwrt-21.02 scripts/fetch-luci-vendor.sh
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

LUCI_REPO="${LUCI_REPO:-https://github.com/openwrt/luci.git}"
LUCI_REF="${LUCI_REF:-openwrt-21.02}"

HTTP_REPO="${HTTP_REPO:-https://github.com/jow-/lucihttp.git}"
HTTP_REF="${HTTP_REF:-master}"

# libnl-tiny：luci-lib-ip 的 `ip.so` 需要它（`-lnl-tiny`，头文件 libnl-tiny/）。
# Debian 有 libnl-3，但 luci-lib-ip 的头是 `#include <libnl-tiny/...>`，无法直接换用。
# 它是独立仓库、CMake 工程、约 20 个 C 文件，Debian 上可直接构建。
NL_REPO="${NL_REPO:-https://github.com/openwrt/libnl-tiny.git}"
NL_REF="${NL_REF:-master}"

# ubus / rpcd：前端运行时的「ubus 底座」（P1.5，依据见 docs/04-ubus依赖图谱.md）。
#
# 为什么必须拉：
#   vendor/luci/luci-lib-base/luasrc/util.lua:15 是**无条件的顶层**
#     local _ubus = require "ubus"
#   而 luci.util 被几乎所有 LuCI 模块 require —— 少了 ubus.so，整个前端
#   连加载都做不到（报 module 'ubus' not found，看不出与守护进程有关）。
#   ubus.so 由 openwrt/project/ubus 的 libubus-lua 提供。
#
#   uci 的读写不走 uci.so，而是 util.ubus("uci", ...)（luci.model.uci:41），
#   该 ubus 对象由 **rpcd 内置**提供（官方文档：session 与 uci 是 built-in）。
#   所以 rpcd 也在必拉清单里。
UBUS_REPO="${UBUS_REPO:-https://github.com/openwrt/ubus.git}"
UBUS_REF="${UBUS_REF:-master}"

RPCD_REPO="${RPCD_REPO:-https://github.com/openwrt/rpcd.git}"
RPCD_REF="${RPCD_REF:-master}"

DEST="$ROOT/vendor"
VER_FILE="$DEST/.luci-version"

# openwrt/luci 中我们真正需要的子树
#   modules/luci-base       LuCI 核心（dispatcher / template / i18n / model-uci / sgi）
#   modules/luci-compat     cbi.lua + view/cbi/*.htm（CBI 表单框架）
#   libs/luci-lib-base      luci/{util,ltn12,http,debug}.lua
#   libs/luci-lib-nixio     nixio.so 的 C 源码（不依赖 libubox，Debian 可直编）
#   libs/luci-lib-ip        ip.so 的 C 源码
#   libs/luci-lib-jsonc     jsonc.so 的 C 源码（绑 libjson-c）
#   libs/rpcd-mod-luci      luci.so 的 C 源码（rpcd 的 luci 插件）
#   themes/luci-theme-bootstrap  默认主题
#
# 关于 libs/rpcd-mod-luci（P1.5 加入，见 docs/04-ubus依赖图谱.md）：
#   luci-base 的 Makefile:15 把它列进 LUCI_DEPENDS，产出 /usr/lib/rpcd/luci.so。
#   虽然 OpenClash 自身不调用 `luci` ubus 对象，但它是 LuCI 栈的既定组成，
#   且只有 1 个 C 文件，构建成本极低 —— 缺了它，将来接 luci-mod-system 之类的
#   页面时会缺对象。
LUCI_PATHS=(
	modules/luci-base
	modules/luci-compat
	libs/luci-lib-base
	libs/luci-lib-nixio
	libs/luci-lib-ip
	libs/luci-lib-jsonc
	libs/rpcd-mod-luci
)
THEME_PATH="themes/luci-theme-bootstrap"

WITH_THEME=1
for a in "$@"; do
	case "$a" in
		--no-theme) WITH_THEME=0 ;;
		-h|--help)
			sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
			exit 0
			;;
	esac
done

log()  { printf '\033[1;36m[vendor]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; }

mkdir -p "$DEST"

# -----------------------------------------------------------------------------
# 通用：浅克隆（可选稀疏）
# -----------------------------------------------------------------------------
# 不用 --filter=blob:none：在受限网络下按需取 blob 容易踩代理隧道错误
# （这条经验与 scripts/sync-upstream.sh 一致）。
#
# 用法：clone_subtree <repo> <ref> <dir> [<稀疏目录>...]
#   - 不传稀疏目录 → **全量浅克隆**
#   - 传了稀疏目录 → --sparse 克隆 + sparse-checkout set（cone 模式）
#
# ⚠️ 这里踩过一个「静默失败」的大坑，务必保留这段说明。
#
#   原实现是 `git sparse-checkout set "$@" >/dev/null 2>&1 || true`，
#   把退出码吞了。而 cone 模式（默认）有两条硬限制：
#     · 参数必须是**目录**，传文件会 fatal：
#         'CMakeLists.txt' is not a directory; to treat it as a directory
#         anyway, rerun with --skip-checks
#     · 参数不能含**通配符**，传 glob 会 fatal：
#         specify directories rather than patterns
#   两种情况都是 exit 128，且**整个 set 中止**（不是部分生效）。
#   于是 checkout 就停在 `git clone --sparse` 的初始状态：
#   `.git/info/sparse-checkout` 内容为 `/*` 与 `!/*/`
#   —— 只材料化顶层**文件**，所有**目录**为空。
#
#   症状极具迷惑性：vendor/lucihttp 只有 CMakeLists.txt 和 LICENSE，
#   没有 include/ 与 src/；vendor/libnl-tiny 没有 include/。
#   脚本打印「拉取成功」，直到编译 ip.so / lucihttp.so 时才炸。
#
#   现在的三条防线：
#     a) 传之前用 `git cat-file -t HEAD:<p>` 校验每个稀疏参数确实是 tree（目录）；
#     b) 含通配符的路径直接报错拒绝；
#     c) 不再吞 `set` 的退出码。
#   另外非稀疏路径会显式 `sparse-checkout disable`，用于修复历史上已经
#   被这个 bug 弄坏的 checkout（disable 会把工作区重新材料化，已实测）。
clone_subtree() {
	local repo="$1" ref="$2" dir="$3"; shift 3
	local paths=("$@")

	if [ -d "$dir/.git" ]; then
		log "更新 $(basename "$dir") ..."
		if ! git -C "$dir" fetch --depth 1 origin "$ref" >/dev/null 2>&1; then
			warn "增量拉取失败，改为重新克隆"
			rm -rf "$dir"
		fi
	fi

	if [ ! -d "$dir/.git" ]; then
		log "克隆 $repo ($ref) 到 $(basename "$dir") ..."
		rm -rf "$dir"
		local cargs=(--depth 1 --branch "$ref")
		# 只有 luci 这种大仓库值得稀疏检出（全量 18M 里绝大部分用不上）。
		# libnl-tiny / lucihttp 都很小，全量克隆更简单，也天然绕开 cone 模式限制。
		[ "${#paths[@]}" -gt 0 ] && cargs+=(--sparse)
		if ! git clone "${cargs[@]}" "$repo" "$dir"; then
			err "克隆失败: $repo"
			return 1
		fi
	fi

	if [ ! -d "$dir/.git" ]; then
		err "$dir 不是 git 仓库"
		return 1
	fi

	# 更新模式下把工作区对齐到刚 fetch 到的 ref
	if git -C "$dir" rev-parse --verify --quiet FETCH_HEAD >/dev/null 2>&1; then
		git -C "$dir" reset --hard FETCH_HEAD >/dev/null 2>&1 || true
	fi

	if [ "${#paths[@]}" -eq 0 ]; then
		# 全量模式：若这个 checkout 此前是稀疏的（含被上面那个 bug 弄坏的），
		# 必须显式关掉，否则它永远停在「只有顶层文件、目录全空」的状态。
		if [ "$(git -C "$dir" config --get core.sparseCheckout 2>/dev/null)" = "true" ]; then
			log "  关闭此前的稀疏检出，改为全量材料化"
			git -C "$dir" sparse-checkout disable >/dev/null 2>&1 || \
				git -C "$dir" read-tree -mu HEAD >/dev/null 2>&1 || true
		fi
		return 0
	fi

	# --- 稀疏路径合法性校验（见上方说明的防线 a/b）-------------------------
	local p bad=0
	for p in "${paths[@]}"; do
		case "$p" in
			*'*'*|*'?'*|*'['*|*']'*)
				err "稀疏路径含通配符：$p（cone 模式只接受目录）"
				bad=1
				;;
		esac
		if [ "$(git -C "$dir" cat-file -t "HEAD:$p" 2>/dev/null)" != "tree" ]; then
			err "稀疏路径不是目录：$p"
			bad=1
		fi
	done
	[ "$bad" = 0 ] || return 1

	if ! git -C "$dir" sparse-checkout set "${paths[@]}" >/dev/null; then
		err "sparse-checkout 设置失败（$dir）"
		return 1
	fi
	return 0
}

# 校验 checkout 里确实存在这些路径。
# 用来兜住「克隆命令返回 0、但目标目录全空」这类静默失败 —— 本脚本已经
# 踩过一次（见 clone_subtree 注释），所以每次克隆后都必须过一道存在性检查。
assert_paths() {
	local dir="$1" label="$2"; shift 2
	local p miss=0
	for p in "$@"; do
		if [ ! -e "$dir/$p" ]; then
			err "$label 缺少 $p"
			miss=1
		fi
	done
	[ "$miss" = 0 ] || return 1
	return 0
}

# 把 checkout 的一个子树同步到 vendor/。
#
# 设计要点：**内容相同则跳过**。
#   本脚本要反复执行（每次上游同步后、每次重建包时），若每次都先 rm -rf 再 cp -a：
#     a) 无谓地重写整个 vendor 树，慢且会打乱 mtime；
#     b) 在某些受限环境下会被批量删除保护拦下（实测踩过）。
#   `diff -r -q` 的开销远小于删除+重建，且能正确识别"已是最新"。
sync_tree() {
	local src="$1" dst="$2" label="$3"

	if [ ! -e "$src" ]; then
		warn "缺少来源 $src（跳过 $label）"
		return 0
	fi
	if [ -d "$dst" ] && diff -r -q "$src" "$dst" >/dev/null 2>&1; then
		log "  $label 已是最新，跳过"
		return 0
	fi
	if [ -e "$dst" ]; then
		log "  $label 有变化，重建"
		rm -rf "$dst"
	fi
	mkdir -p "$(dirname "$dst")"
	cp -a "$src" "$dst"
	return 0
}

# 同 sync_tree，但来源是**仓库根**，需要在比较与复制时排除 .git。
# 用 tar 而不是 cp -a，因为要带排除规则；`tar cf - . | tar xf -` 也保留了
# 权限位与目录结构。
sync_repo_tree() {
	local src="$1" dst="$2" label="$3"

	if [ ! -d "$src" ]; then
		warn "缺少来源 $src（跳过 $label）"
		return 0
	fi
	# diff 的 -x 与 cp 的排除必须一致，否则会永远判为「有变化」而反复重建
	if [ -d "$dst" ] && [ -z "$(diff -r -q -x .git "$src" "$dst" 2>/dev/null)" ]; then
		log "  $label 已是最新，跳过"
		return 0
	fi
	if [ -e "$dst" ]; then
		log "  $label 有变化，重建"
		rm -rf "$dst"
	fi
	mkdir -p "$dst"
	( cd "$src" && tar cf - --exclude=.git . ) | ( cd "$dst" && tar xf - )
	return 0
}

# -----------------------------------------------------------------------------
# 1. LuCI（纯 Lua 世代）
# -----------------------------------------------------------------------------
LUCI_CHECKOUT="$DEST/.luci-checkout"
PATHS=("${LUCI_PATHS[@]}")
[ "$WITH_THEME" = 1 ] && PATHS+=("$THEME_PATH")

clone_subtree "$LUCI_REPO" "$LUCI_REF" "$LUCI_CHECKOUT" "${PATHS[@]}" || exit 1

# 先过存在性检查再往下走：稀疏检出失败是**静默**的（见 clone_subtree 注释），
# 少了这些文件后面几步的校验会给出误导性的报错。
assert_paths "$LUCI_CHECKOUT" "LuCI checkout" \
	modules/luci-base/luasrc/sgi/cgi.lua \
	modules/luci-base/src/po2lmo.c \
	modules/luci-base/src/contrib/lemon.c \
	modules/luci-base/root/usr/libexec/rpcd/luci \
	modules/luci-compat/luasrc/cbi.lua \
	libs/luci-lib-base/luasrc/http.lua \
	libs/luci-lib-nixio/src/nixio.c \
	libs/luci-lib-ip/src/ip.c \
	libs/luci-lib-jsonc/src/jsonc.c \
	libs/rpcd-mod-luci/src/luci.c \
	libs/rpcd-mod-luci/src/CMakeLists.txt \
	|| exit 2

if [ -d "$LUCI_CHECKOUT/.git" ]; then
	LUCI_COMMIT="$(git -C "$LUCI_CHECKOUT" rev-parse HEAD)"
	LUCI_SHORT="$(git -C "$LUCI_CHECKOUT" rev-parse --short HEAD)"
	LUCI_DATE="$(git -C "$LUCI_CHECKOUT" log -1 --format=%cI)"
	LUCI_SUBJECT="$(git -C "$LUCI_CHECKOUT" log -1 --format=%s)"
else
	err "LuCI checkout 不可用"
	exit 1
fi

# 关键完整性校验：必须确认这是「有 Lua 栈」的世代
if [ ! -f "$LUCI_CHECKOUT/modules/luci-base/luasrc/sgi/cgi.lua" ]; then
	err "modules/luci-base/luasrc/sgi/cgi.lua 不存在"
	err "说明 $LUCI_REF 已经 Lua → ucode 迁移，不能用它做宿主（见本脚本头部说明）"
	exit 2
fi
if [ ! -f "$LUCI_CHECKOUT/modules/luci-compat/luasrc/cbi.lua" ]; then
	err "modules/luci-compat/luasrc/cbi.lua 不存在 —— CBI 表单框架缺失"
	exit 2
fi

log "LuCI $LUCI_REF @ $LUCI_SHORT：$LUCI_SUBJECT"

# 复制到 vendor/（去掉 .git，vendor 树保持纯净、可 diff）
for p in "${PATHS[@]}"; do
	sync_tree "$LUCI_CHECKOUT/$p" "$DEST/luci/${p#*/}" "$p"
done

# -----------------------------------------------------------------------------
# 2. liblucihttp（Lua 绑定）—— 独立上游项目，不在 openwrt/luci 里
# -----------------------------------------------------------------------------
# 为什么**全量**克隆而不是稀疏：仓库很小（源码 + 测试用例，几十 KB），
# 而稀疏检出在 cone 模式下只能给目录，给文件会 fatal 并静默中止 —— 之前
# 正是因此丢了 include/ 与 src/（见 clone_subtree 注释）。
# 顺带把 src/test-*.c 与 testcases/ 一起带进来：它们是上游自带的单测，
# 可以在 CI 里对着我们的构建产物跑一遍，白白多一层验证。
HTTP_CHECKOUT="$DEST/.lucihttp-checkout"
clone_subtree "$HTTP_REPO" "$HTTP_REF" "$HTTP_CHECKOUT" || exit 1
assert_paths "$HTTP_CHECKOUT" "lucihttp" \
	CMakeLists.txt \
	include/lucihttp/lua.h \
	lib/lua.c \
	lib/utils.c \
	lib/multipart-parser.c \
	lib/urlencoded-parser.c \
	|| exit 2

if [ -d "$HTTP_CHECKOUT/.git" ]; then
	HTTP_COMMIT="$(git -C "$HTTP_CHECKOUT" rev-parse HEAD)"
	HTTP_SHORT="$(git -C "$HTTP_CHECKOUT" rev-parse --short HEAD)"
	sync_repo_tree "$HTTP_CHECKOUT" "$DEST/lucihttp" "  lucihttp 源码树"
	log "lucihttp @ $HTTP_SHORT"
else
	warn "lucihttp 拉取失败（lucihttp.so 是硬依赖：luci-lib-base/luasrc/http.lua:8 顶层 require）"
	HTTP_COMMIT="unknown"; HTTP_SHORT="unknown"
fi

# -----------------------------------------------------------------------------
# 2b. libnl-tiny —— ip.so 的链接依赖
# -----------------------------------------------------------------------------
# luci-lib-ip/src/ip.c 里写的是 `#include <netlink/msg.h>`，靠
# `-I.../libnl-tiny/` 解析（OpenWrt 装到 /usr/include/libnl-tiny/）。
# Debian 的 libnl-3 头是 `<netlink/...>` 但 API 不兼容，不能替换。
# 同样全量克隆：CMake 工程 + include/ 头树，很小。
NL_CHECKOUT="$DEST/.libnl-tiny-checkout"
clone_subtree "$NL_REPO" "$NL_REF" "$NL_CHECKOUT" || exit 1
assert_paths "$NL_CHECKOUT" "libnl-tiny" \
	CMakeLists.txt \
	include/netlink/msg.h \
	include/netlink/socket.h \
	include/unl.h \
	socket.c \
	msg.c \
	|| exit 2

if [ -d "$NL_CHECKOUT/.git" ]; then
	NL_COMMIT="$(git -C "$NL_CHECKOUT" rev-parse HEAD)"
	NL_SHORT="$(git -C "$NL_CHECKOUT" rev-parse --short HEAD)"
	sync_repo_tree "$NL_CHECKOUT" "$DEST/libnl-tiny" "  libnl-tiny 源码树"
	log "libnl-tiny @ $NL_SHORT"
else
	warn "libnl-tiny 拉取失败（ip.so 无法构建 —— luci.ip 是 luci-base 核心依赖，不可缺）"
	NL_COMMIT="unknown"; NL_SHORT="unknown"
fi

# -----------------------------------------------------------------------------
# 2c. ubus / rpcd —— 前端运行时的 ubus 底座（P1.5）
# -----------------------------------------------------------------------------
# 见本脚本头部 UBUS_REPO / RPCD_REPO 处的说明，以及 docs/04-ubus依赖图谱.md。
# 两个仓库都很小，全量浅克隆。
#
# ⚠️ 断言里特意包含 ubus 的 Lua 绑定源码（lua/*.c）与 rpcd 的 uci/session 插件源码：
#    它们是"能不能 require、能不能读写 uci"的直接依据。只断言根目录有
#    CMakeLists.txt 是不够的 —— 那正是 sparse-checkout 截断后仍然"看起来正常"
#    的形态（本项目已踩过一次，见 clone_subtree 注释）。
# 拉取一个 OpenWrt 侧库并同步到 vendor/。
#
# ⚠️ 这里**不能用命令替换**（`ver="$(fetch_openwrt_lib ...)"`）回传版本号。
#    函数内部会调用 log/sync_repo_tree，它们都往 **stdout** 写 —— 用 $() 捕获
#    会把那些日志行一起收进 $ver，得到形如
#        "\033[1;36m[vendor]\033[0m  ubus 源码树\ndef5678"
#    的东西，然后 UBUS_COMMIT 变成一整段带转义序列的垃圾写进 .luci-version。
#    这与 runtime/lib/build-common.sh 里 vlog 必须写 stderr 是同一个教训。
#    改用全局变量 FETCH_COMMIT / FETCH_SHORT 回传，调用方紧接着取走。
fetch_openwrt_lib() {   # <label> <repo> <ref> <checkout 目录名> <保留的路径...>
	local label="$1" repo="$2" ref="$3" name="$4"; shift 4
	local ck="$DEST/.$name-checkout"
	FETCH_COMMIT="unknown"; FETCH_SHORT="unknown"
	clone_subtree "$repo" "$ref" "$ck" || return 1
	assert_paths "$ck" "$label" "$@" || return 2
	if [ ! -d "$ck/.git" ]; then
		warn "$label 拉取失败"
		return 0
	fi
	FETCH_COMMIT="$(git -C "$ck" rev-parse HEAD)"
	FETCH_SHORT="$(git -C "$ck" rev-parse --short HEAD)"
	sync_repo_tree "$ck" "$DEST/$name" "  $label 源码树"
	log "$label @ $FETCH_SHORT"
	return 0
}

if ! fetch_openwrt_lib "ubus" "$UBUS_REPO" "$UBUS_REF" ubus \
	CMakeLists.txt \
	lua/CMakeLists.txt \
	lua/ubus.c \
	libubus.c \
	cli.c \
	ubusd.c \
	ubusd_main.c \
	ubusd_proto.c \
	ubusmsg.h \
	libubus.h
then
	err "ubus 拉取失败（缺 ubus.so 会导致 LuCI 连加载都做不到，见 docs/04-ubus依赖图谱.md §2.1）"
	exit 2
fi
UBUS_COMMIT="$FETCH_COMMIT"; UBUS_SHORT="$FETCH_SHORT"

if ! fetch_openwrt_lib "rpcd" "$RPCD_REPO" "$RPCD_REF" rpcd \
	CMakeLists.txt \
	main.c \
	session.c \
	uci.c \
	plugin.c \
	unauthenticated.json
then
	err "rpcd 拉取失败（uci/session 两个 ubus 对象由它内置提供）"
	exit 2
fi
RPCD_COMMIT="$FETCH_COMMIT"; RPCD_SHORT="$FETCH_SHORT"

# -----------------------------------------------------------------------------
# 3. 版本记录
# -----------------------------------------------------------------------------
cat >"$VER_FILE" <<EOF
# 由 scripts/fetch-luci-vendor.sh 生成，请勿手改
LUCI_REPO=$LUCI_REPO
LUCI_REF=$LUCI_REF
LUCI_COMMIT=$LUCI_COMMIT
LUCI_SHORT=$LUCI_SHORT
LUCI_DATE=$LUCI_DATE
LUCI_SUBJECT=$LUCI_SUBJECT
LUCIHTTP_REPO=$HTTP_REPO
LUCIHTTP_REF=$HTTP_REF
LUCIHTTP_COMMIT=$HTTP_COMMIT
LUCIHTTP_SHORT=$HTTP_SHORT
LIBNLTINY_REPO=$NL_REPO
LIBNLTINY_REF=$NL_REF
LIBNLTINY_COMMIT=$NL_COMMIT
LIBNLTINY_SHORT=$NL_SHORT
UBUS_REPO=$UBUS_REPO
UBUS_REF=$UBUS_REF
UBUS_COMMIT=$UBUS_COMMIT
UBUS_SHORT=$UBUS_SHORT
RPCD_REPO=$RPCD_REPO
RPCD_REF=$RPCD_REF
RPCD_COMMIT=$RPCD_COMMIT
RPCD_SHORT=$RPCD_SHORT
EOF

log "版本信息写入 $VER_FILE"

# -----------------------------------------------------------------------------
# 4. 兼容面快照
# -----------------------------------------------------------------------------
# 记录本次 vendor 提供的 Lua 模块清单。上游 OpenClash 每日同步后，
# 用 scripts/analyze-frontend-api.py 的输出去比对本快照：
# 若上游开始 require 一个我们没提供的模块，必须在合入前补上，否则运行期 500。
SNAP="$DEST/.lua-module-surface.txt"
{
	printf '# vendor 提供的 luci Lua 模块（相对 /usr/lib/lua/）\n'
	printf '# 生成于 %s\n' "$(date -Iseconds)"
	find "$DEST/luci" -name '*.lua' 2>/dev/null \
		| sed "s|^$DEST/luci/||" \
		| grep -v '^themes/' \
		| sort
} >"$SNAP"
log "模块清单写入 $SNAP（$(grep -c . "$SNAP") 行）"

# -----------------------------------------------------------------------------
# 5. 汇总
# -----------------------------------------------------------------------------
log "vendor 完成。目录结构："
( cd "$DEST" && find luci -maxdepth 2 -type d | sort | sed 's/^/  /' )
[ -d "$DEST/lucihttp" ]   && printf '  lucihttp/\n'
[ -d "$DEST/libnl-tiny" ] && printf '  libnl-tiny/\n'
[ -d "$DEST/ubus" ]       && printf '  ubus/\n'
[ -d "$DEST/rpcd" ]       && printf '  rpcd/\n'
exit 0
