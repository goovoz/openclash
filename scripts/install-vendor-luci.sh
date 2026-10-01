#!/usr/bin/env bash
# =============================================================================
# scripts/install-vendor-luci.sh — 把 vendor/luci 落进 staging 树（P2-A）
# -----------------------------------------------------------------------------
# 单一职责：按 docs/03 §3.1 的契约，把 vendor/luci 的 8 个上游包复制进 staging 树。
# **vendor 树本身不被修改** —— 所有「加 luci/ 前缀」都在 staging 完成，让「上游
# 同步零阻力」成为真命题（fetch-luci-vendor.sh 会重置 vendor/）。
#
# 用法：
#   scripts/install-vendor-luci.sh \
#       --src vendor/luci --stage "$STAGE" \
#       [--pin-linter <脚本路径>]
#       [--lua-bin /usr/bin/lua5.1]
#
# 退出码：0=成功；非0=任意一步失败（详见 stderr）。
# stdout：只输出关键计数；人类日志走 stderr。
# =============================================================================
set -euo pipefail

SRC=""
STAGE=""
LINTER=""
LUA_BIN="${LUA_BIN:-/usr/bin/lua5.1}"

while [ $# -gt 0 ]; do
	case "$1" in
		--src)       SRC="${2:?--src 需要一个 vendor 路径}"; shift 2 ;;
		--src=*)     SRC="${1#*=}"; shift ;;
		--stage)     STAGE="${2:?--stage 需要一个 staging 路径}"; shift 2 ;;
		--stage=*)   STAGE="${1#*=}"; shift ;;
		--pin-linter) LINTER="${2:?--pin-linter 需要一个脚本路径}"; shift 2 ;;
		--pin-linter=*) LINTER="${1#*=}"; shift ;;
		--lua-bin)   LUA_BIN="${2:?--lua-bin 需要 lua5.1 路径}"; shift 2 ;;
		--lua-bin=*) LUA_BIN="${1#*=}"; shift ;;
		-h|--help)
			sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//' >&2
			exit 0 ;;
		*) printf 'install-vendor-luci: 未知参数：$1\n' >&2; exit 2 ;;
	esac
done

[ -n "$SRC" ]   || { printf '缺少 --src <vendor 路径>\n' >&2; exit 2; }
[ -n "$STAGE" ] || { printf '缺少 --stage <staging 路径>\n' >&2; exit 2; }
[ -d "$SRC" ]   || { printf 'vendor 路径不存在：%s\n' "$SRC" >&2; exit 2; }
[ -d "$STAGE" ] || { printf 'staging 路径不存在：%s\n' "$STAGE" >&2; exit 2; }

log()  { printf 'install-vendor-luci: %s\n' "$*" >&2; }
die()  { printf 'install-vendor-luci: %s\n' "$*" >&2; exit 1; }

# 默认指向本仓库的 pin-lua-interpreter.sh
if [ -z "$LINTER" ]; then
	if [ -n "${SELF_DIR:-}" ] && [ -x "${SELF_DIR}/../runtime/upstream/pin-lua-interpreter.sh" ]; then
		LINTER="${SELF_DIR}/../runtime/upstream/pin-lua-interpreter.sh"
	else
		LINTER="$(cd "$(dirname "$0")/.." && pwd)/runtime/upstream/pin-lua-interpreter.sh"
	fi
fi
[ -f "$LINTER" ] || die "钉 shebang 的脚本不存在：$LINTER"

# 前置目录：必须先于 cp -a 创建（cp -a 不创建中间目录，且如果目标
# 不存在会以「最后一个组件是目录还是文件」的决定变得不可预测）
mkdir -p \
	"$STAGE/usr/lib/lua/luci/i18n" \
	"$STAGE/usr/share/luci/menu.d" \
	"$STAGE/usr/share/rpcd/acl.d" \
	"$STAGE/usr/libexec/rpcd" \
	"$STAGE/usr/sbin" \
	"$STAGE/etc/luci-uploads" \
	"$STAGE/etc/uci-defaults" \
	"$STAGE/etc/config" \
	"$STAGE/etc/init.d" \
	"$STAGE/www/cgi-bin" \
	"$STAGE/www/luci-static"

# 1) 4 个 vendor 包的 luasrc/* 平铺到 /usr/lib/lua/luci/（加 luci/ 前缀）
#    关键设计：Lua 5.1 require 机制决定必须加 luci/ 前缀。
#    cacheloader.lua 第 1 行就是 `require "luci.config"`，
#    Lua 5.1 会去 /usr/lib/lua/luci/config.lua 找，不加前缀就 require 不到。
#    上游安装路径规则是这样，OpenWrt 上的实测如此；所有 4 个 vendor 包都加。
_LUASRC_PKGS=0
for pkg in luci-base luci-lib-base luci-compat luci-theme-bootstrap; do
	_src="$SRC/$pkg/luasrc"
	if [ -d "$_src" ]; then
		cp -a "$_src/." "$STAGE/usr/lib/lua/luci/"
		_LUASRC_PKGS=$((_LUASRC_PKGS + 1))
	fi
done
[ "$_LUASRC_PKGS" -gt 0 ] || die "vendor/luci 下没有任何 luasrc/ 目录"

# 清掉误入的 *.luadoc（上游的 API 文档，共 7 个：dispatcher/i18n/sys/xml/
# http/model.uci/util/ccache）。它们不影响运行，但装进 .deb 是纯噪声。
# 必须在复制后清（vendor 树不能动）；删除数可为 0（上游若哪天删了这些文件）。
find "$STAGE/usr/lib/lua/luci" -name '*.luadoc' -type f -delete

# 2) 静态资源与 ACL 落位（直 cp -a）
#   /www 是 uhttpd 文档根：cgi-bin/ 是 CGI 入口目录，luci-static/ 是静态目录。
#   **三个包都有 htdocs/luci-static**，缺一个就丢一块 UI：
#     · luci-base        resources/（cbi 图标/协议图标/menu.js/…）
#     · luci-compat      resources/cbi/*.gif（CBI 旧式控件图标）
#     · luci-theme-bootstrap  bootstrap/cascade.css 等（**主题的全部样式**，
#                              缺了整个界面裸奔 —— 冒烟测试第一轮就踩到）
#   /usr/share/luci/menu.d   luci-base 的 UI 菜单定义（JSON）
#   /usr/share/rpcd/acl.d    rpcd 启动时读取，决定 ACL（**必须**有，
#                            否则 rpcd 启动会拒绝所有 RPC —— P3 之前
#                            最隐蔽的陷阱）
for _pkg in luci-base luci-compat luci-theme-bootstrap; do
	if [ -d "$SRC/$_pkg/htdocs/luci-static" ]; then
		cp -a "$SRC/$_pkg/htdocs/luci-static/." "$STAGE/www/luci-static/"
	fi
done
[ -d "$SRC/luci-base/root/usr/share/luci/menu.d" ] && \
	cp -a "$SRC/luci-base/root/usr/share/luci/menu.d/." "$STAGE/usr/share/luci/menu.d/"
[ -d "$SRC/luci-base/root/usr/share/rpcd/acl.d" ] && \
	cp -a "$SRC/luci-base/root/usr/share/rpcd/acl.d/." "$STAGE/usr/share/rpcd/acl.d/"
[ -d "$SRC/luci-compat/root/usr/share/rpcd/acl.d" ] && \
	cp -a "$SRC/luci-compat/root/usr/share/rpcd/acl.d/." "$STAGE/usr/share/rpcd/acl.d/"

# 3) CGI 入口与 rpcd 辅助脚本：必须用 --file 模式钉 shebang
#   这两个文件**没有扩展名**，--dir 模式按 EXTS 过滤会跳过它们。
#   先复制（install -m 0755 让权限正确），再钉 shebang —— 顺序不能倒
#   （钉完再 cp 会覆盖）。
[ -f "$SRC/luci-base/htdocs/cgi-bin/luci" ] && \
	install -m 0755 "$SRC/luci-base/htdocs/cgi-bin/luci" "$STAGE/www/cgi-bin/luci"
[ -f "$SRC/luci-base/root/usr/libexec/rpcd/luci" ] && \
	install -m 0755 "$SRC/luci-base/root/usr/libexec/rpcd/luci" "$STAGE/usr/libexec/rpcd/luci"

# 4) 钉 shebang：两个文件都是 P1.5 的语义前提（§1.4）
#   用 --file 而不是 --dir 走 EXT 过滤，是 P1.5 第二轮新增的能力。
#   工具的 stdout 是改写处数（被下面 --dir 调用点复用，此处不强制检查）。
#   任何一条都失败都会 die —— 不允许「前两个落位但 shebang 没钉」这种半成品。
_LUCI_LUAFILES=(
	"$STAGE/www/cgi-bin/luci"           # uhttpd CGI 入口（#!/usr/bin/lua）
	"$STAGE/usr/libexec/rpcd/luci"       # rpcd 调度的 luci 帮助脚本（#!/usr/bin/env lua）
)
# 必须全部存在
for _f in "${_LUCI_LUAFILES[@]}"; do
	[ -f "$_f" ] || die "钉 shebang 前文件不存在：$_f"
done
export LUA_BIN
bash "$LINTER" --file "${_LUCI_LUAFILES[0]}" --file "${_LUCI_LUAFILES[1]}" \
	>/dev/null \
	|| die "vendor LuCI 两个入口的 lua shebang 钉定失败（见上面 pin-lua 输出）"

# 5) /etc/config/{luci,ucitrack} —— conffile（保留可被用户编辑的权限）
for f in luci ucitrack; do
	if [ -f "$SRC/luci-base/root/etc/config/$f" ]; then
		install -m 0644 "$SRC/luci-base/root/etc/config/$f" "$STAGE/etc/config/$f"
	fi
done
[ -f "$SRC/luci-base/root/etc/init.d/ucitrack" ] && \
	install -m 0755 "$SRC/luci-base/root/etc/init.d/ucitrack" "$STAGE/etc/init.d/ucitrack"

# 6) /etc/luci-uploads/.placeholder —— 占位文件
#   rpcd 的 ACL 中有 "/etc/luci-uploads/*" 的通配，目录创建时若不存在，
#   ACL 初始化触发 ENOENT。空目录加占位文件是 OpenWrt 的标准做法。
if [ -f "$SRC/luci-base/root/etc/luci-uploads/.placeholder" ]; then
	install -m 0644 "$SRC/luci-base/root/etc/luci-uploads/.placeholder" \
		"$STAGE/etc/luci-uploads/.placeholder"
else
	# vendor 偶尔缺这个 .placeholder —— 上游 git 历史里它有时被删。空目录本身
	# 仍能被 rpcd ACL 接受（通配只在 file lookup 时触发）。
	log "客户端: /etc/luci-uploads/.placeholder 缺失（ACL 仍兼容，跳过）"
fi

# 7) /usr/sbin/luci-reload —— 上游 reload 入口
#   完整实现在 P3 阶段（HTTP 宿主接 ubus 路径后）。先装一份 vendor 原版：
#   它会读 /usr/lib/lua/luci/util.lua 并尝试调 ubus，无 ubus 时静默失败，
#   这正是我们当前的中间形态能接受的。
[ -f "$SRC/luci-base/root/sbin/luci-reload" ] && \
	install -m 0755 "$SRC/luci-base/root/sbin/luci-reload" "$STAGE/usr/sbin/luci-reload"

# 8) uci-defaults —— P4 阶段执行；这里仅落位
#   /etc/uci-defaults/ 在 Debian 上**原本不存在**，postinst 第一行就需要
#   mkdir；这里先把上游的掉文件落进去，P4 由 ucitrack.init 拉起目录。
if [ -f "$SRC/luci-theme-bootstrap/root/etc/uci-defaults/30_luci-theme-bootstrap" ]; then
	install -m 0755 "$SRC/luci-theme-bootstrap/root/etc/uci-defaults/30_luci-theme-bootstrap" \
		"$STAGE/etc/uci-defaults/30_luci-theme-bootstrap"
fi

printf '%d\n' "$_LUASRC_PKGS"