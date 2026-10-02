#!/usr/bin/env bash
# =============================================================================
# openclash-rt  面板裁剪：只留 zashboard
# =============================================================================
# 用途（2026-10-02 真机实测，Debian 12 @ 172.20.0.101:9080）：
#   OpenClash 自带三个 mihomo 面板：yacd / metacubexd / zashboard。
#   其中 metacubexd 在本项目环境下不可用（见 docs/09 §11），
#   yacd / dashboard 目录本就不存在。用户要求只保留 zashboard。
#
# 三处 UI 的显隐都由**同一个判据**控制（openclash.lua:1371-1374）：
#     yacd       = fs.isdirectory("/usr/share/openclash/ui/yacd")
#     metacubexd = fs.isdirectory("/usr/share/openclash/ui/metacubexd")
#     zashboard  = fs.isdirectory("/usr/share/openclash/ui/zashboard")
#
# 所以本脚本做两件事，全在 vendor/部署层，**不改上游 OpenClash 一行**：
#   1. 把要屏蔽的面板目录改名 → isdirectory 变 false
#      → Overviews 的 Control Panel 按钮自动隐藏
#      → dashboard_type / status 端点返回 false
#   2. 把 openclash.config.default_dashboard 指到保留的面板
#      → Plugin Settings 里该面板标为 Default
#
# 另有一处需要额外处理（上游既有逻辑不足）：
#   Plugin Settings → Dashboard Settings 里的「XXX Version」**整行**
#   即使面板目录不存在也仍然显示（只是按钮变灰）——
#   switch_dashboard.htm 只做 `firstElementChild.disabled = true`，
#   不隐藏外层 .cbi-value 行。故由hide-missing-dashboard-row.py 补一段。
#
# 用法：
#   bash scripts/_deploy/keep-only-zashboard.sh <ui根目录> [默认面板]
#   例：
#     bash scripts/_deploy/keep-only-zashboard.sh /usr/share/openclash/ui zashboard
#
# 幂等：重复执行安全（已改名的目录会跳过）。备份后缀 .bak。
# =============================================================================
set -u

UI_DIR="${1:-/usr/share/openclash/ui}"
KEEP="${2:-zashboard}"
# 要屏蔽的面板（KEEP 之外的都屏蔽）
ALL="yacd dashboard metacubexd zashboard"

LOG_TAG="keep-only-zashboard"
log() { printf '%s: %s\n' "$LOG_TAG" "$*"; }

[ -d "$UI_DIR" ] || { log "错误：$UI_DIR 不存在"; exit 1; }

log "面板根目录: $UI_DIR"
log "保留面板  : $KEEP"

# ---------------------------------------------------------------------------
# 1) 屏蔽：把要禁用/删除的面板目录改名为 <name>.disabled
#    改名而非删除 —— 恢复只需改回名，零风险。
# ---------------------------------------------------------------------------
for name in $ALL; do
	[ "$name" = "$KEEP" ] && continue
	src="$UI_DIR/$name"
	dst="$UI_DIR/$name.disabled"

	if [ -d "$src" ]; then
		mv "$src" "$dst" && log "屏蔽 $name -> $name.disabled"
	elif [ -d "$dst" ]; then
		log "$name 已是屏蔽状态（$dst 存在）"
	else
		log "$name 目录本就不存在（OpenClash 只装了部分面板）"
	fi
done

# ---------------------------------------------------------------------------
# 2) 默认面板指向保留项
#    只在有 uci 的机器上做；找不到 uci 就跳过（不影响其余效果）。
# ---------------------------------------------------------------------------
if command -v uci >/dev/null 2>&1 && uci -q get openclash.config >/dev/null 2>&1; then
	cur="$(uci -q get openclash.config.default_dashboard || true)"
	if [ "$cur" != "$KEEP" ]; then
		uci set openclash.config.default_dashboard="$KEEP"
		uci commit openclash
		log "default_dashboard: ${cur:-<空>} -> $KEEP"
	else
		log "default_dashboard 已是 $KEEP"
	fi
else
	log "未找到可用的 uci 配置，跳过 default_dashboard（按钮显隐不受它影响）"
fi

# ---------------------------------------------------------------------------
# 3) 隐藏 Plugin Settings 里失效面板的整行
# ---------------------------------------------------------------------------
TPL="/usr/share/lua/5.1/luci/view/openclash/switch_dashboard.htm"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HIDER="$SCRIPT_DIR/hide-missing-dashboard-row.py"

if [ -f "$TPL" ]; then
	if command -v python3 >/dev/null 2>&1 && [ -f "$HIDER" ]; then
		[ -f "$TPL.bak" ] || cp "$TPL" "$TPL.bak"
		res="$(python3 "$HIDER" "$TPL" 2>&1)"
		log "switch_dashboard.htm: $res"
	elif command -v lua5.1 >/dev/null 2>&1; then
		# 没 python3 时退化：只提示，不自动改
		log "无 python3，未自动改 $TPL（该行仍会显示但按钮禁用）"
	else
		log "无 python3/python，未自动改 $TPL"
	fi
else
	log "模板不存在：$TPL（跳过整行隐藏）"
fi

# ---------------------------------------------------------------------------
# 4) 汇总
# ---------------------------------------------------------------------------
log "完成。当前面板状态："
for name in $ALL; do
	if [ -d "$UI_DIR/$name" ]; then
		log "  $name: 启用"
	else
		log "  $name: 已屏蔽"
	fi
done
