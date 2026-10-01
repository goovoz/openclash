#!/usr/bin/env bash
# =============================================================================
# Lua 模块搜索路径桥接
# -----------------------------------------------------------------------------
# 要解决的问题（一句话）：
#   上游把 Lua 模块装在 /usr/lib/lua/，而 Debian 的 lua5.1 默认不去那里找。
#
# 展开讲清楚，因为这是整条前端链路上最容易被忽略又必然踩到的坑：
#
#   1) 为什么必须装在 /usr/lib/lua/
#      这不是我们的选择，是**上游写死的**，且三处都是绝对路径：
#        · upstream/luci-app-openclash/Makefile:146
#              $(CP) luasrc/* $(1)/usr/lib/lua/luci/
#        · upstream/luci-app-openclash/Makefile:143-144
#              i18n/*.lmo → /usr/lib/lua/luci/i18n/
#        · upstream/luci-app-openclash/Makefile:128-129 （postrm！）
#              sed -i '/OpenClash Append/,/OpenClash Append End/d' \
#                  "/usr/lib/lua/luci/model/network.lua"
#              sed -i 's/.*kB maximum content size.*/.../' \
#                  /usr/lib/lua/luci/http.lua
#      最后两条尤其关键：它们是**卸载**时用来撤销上游对 luci-base 的运行时
#      改写的，都带 `>/dev/null 2>&1`。如果文件不在那个路径，sed 会静默失败，
#      于是卸载后 luci-base 被改坏的状态永久残留，而且没有任何报错。
#
#   2) Debian 的 lua5.1 为什么找不到它
#      Debian 对上游 luaconf.h 打了 module_paths.patch 与 DEB_HOST_MULTIARCH
#      补丁，默认搜索路径是：
#        package.cpath = ./?.so;/usr/local/lib/lua/5.1/?.so;
#                        /usr/lib/<DEB_HOST_MULTIARCH>/lua/5.1/?.so;
#                        /usr/lib/lua/5.1/?.so;/usr/local/lib/lua/5.1/loadall.so
#        package.path  = ./?.lua;/usr/local/share/lua/5.1/?.lua;
#                        /usr/local/share/lua/5.1/?/init.lua;
#                        /usr/share/lua/5.1/?.lua;/usr/share/lua/5.1/?/init.lua
#      （依据：Debian Bug #671286 与 lp #977813 里引用的 luaconf.h 片段，
#       以及 Debian 政策「架构无关文件放 /usr/share，二进制放 /usr/lib」——
#       所以 package.path 里**没有** /usr/lib。)
#      也就是说：认 /usr/lib/lua/5.1/，**不认** /usr/lib/lua/。
#      于是 `require "luci.ip"`（要找 /usr/lib/lua/luci/ip.so）必然失败。
#
#   3) 解决办法：软链桥接，而不是改环境变量
#      候选方案有二：
#        a) 在每个入口点设 LUA_PATH/LUA_CPATH
#           —— 不可行。上游有 8 个脚本写着 `#!/usr/bin/lua`，由 shell 直接
#              按路径执行（openclash 的服务脚本、usr/share/openclash/*.sh），
#              我们无法给它们注入环境变量；用户手工执行时更没有。
#        b) 在文件系统上把路径补齐
#           —— 可行且确定：Lua 的默认搜索路径是**编译期常量**，只要在它会
#              查找的目录里放上软链，require 就能命中，与任何环境变量无关。
#      选 b。
#
#   4) 为什么"两层"软链，各自多余吗
#      · /usr/share/lua/5.1/luci  → /usr/lib/lua/luci
#        命中 package.path，让 require "luci.util" 之类的 .lua 模块可加载。
#      · /usr/lib/<ma>/lua/5.1/luci → /usr/lib/lua/luci
#        命中 package.cpath，让 require "luci.ip" 之类 .so 模块可加载。
#      同一个 luci/ 目录同时软链到两处：里面既有 .lua 也有 .so，而 Lua 只会
#      用对应的那一条路径去找对应类型，多余的那份不会被用到（也无害）。
#
#   5) luci/libpath() 会不会因为搜索路径不同而错乱
#      不会，而且这一点是刻意验证过的：
#        luci-lib-base/luasrc/util.lua:695  libpath() = dirname(ldebug.__file__)
#        luci-lib-base/luasrc/debug.lua:6    __file__ = debug.getinfo(1,'S').source
#      也就是"本模块是从哪条路径被加载的"。若经 /usr/share/lua/5.1/luci 加载，
#      libpath() 返回 /usr/share/lua/5.1/luci，i18n 目录变成
#      /usr/share/lua/5.1/luci/i18n/ —— 但该目录**穿过同一条软链**指向
#      /usr/lib/lua/luci/i18n/，也就是上游安装 .lmo 的地方。两条路径都对。
#
# 用法：
#   lua-path-bridge.sh --stagedir <DEST>   # 构建期：往 staging 树里放软链
#   lua-path-bridge.sh --check             # 检查是否已就绪（0=就绪）
#   lua-path-bridge.sh --verify [--strict] # 逐模块 require 实测
#   lua-path-bridge.sh --apply             # 安装期兜底：按实测路径补软链
#   lua-path-bridge.sh --remove            # 卸载期：清掉 --apply 建的那些
#   lua-path-bridge.sh --print             # 只打印将要做什么
#
# 环境变量：
#   OPENCLASH_RT_ROOT_PREFIX  把 / 替换成某个前缀（测试/打包用）
#   DEB_HOST_MULTIARCH        目标多架构三元组（交叉打包用）
#   OPENCLASH_RT_LN           覆盖 ln 命令（测试用：注入记录型假 ln）
#   OPENCLASH_RT_READLINK     覆盖 readlink（同上）
# -----------------------------------------------------------------------------
# 关于后两个 seam：本项目的开发机是 Windows/MSYS，那里 `ln -s` **不会**创建
# POSIX 软链（默认落成 0 字节普通文件；即便开 MSYS=winsymlinks:nativestrict，
# readlink 也认不出来）。为了能在这种机器上验证软链表本身是否正确，把
# ln/readlink 做成可注入的 —— 测试注入一对共享状态的假实现，从而把
# "--check / --apply / --remove 的判断逻辑"也纳入本地可测范围。
# 与 OPENCLASH_RT_DPKG / OPENCLASH_RT_UNAME 是同一套做法。
# =============================================================================
set -euo pipefail

ROOT_PREFIX="${OPENCLASH_RT_ROOT_PREFIX:-}"
LUA_LIBDIR="/usr/lib/lua"
LN="${OPENCLASH_RT_LN:-ln}"
READLINK="${OPENCLASH_RT_READLINK:-readlink}"

STATE_DIR="/var/lib/openclash-rt"
STATE_FILE="$STATE_DIR/lua-path-bridge.list"

log()  { printf '\033[1;36m[luapath]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }
dry()  { printf '  %b\n' "$*"; }   # %b：参数里带颜色转义时要解释，用 %s 会打出字面的 \033

MODE=""; STRICT=0
while [ $# -gt 0 ]; do
	case "$1" in
		--stagedir)  MODE=stagedir; STAGE="${2:?--stagedir 需要目录}"; shift 2 ;;
		--stagedir=*) MODE=stagedir; STAGE="${1#*=}"; shift ;;
		--check)     MODE=check; shift ;;
		--verify)    MODE=verify; shift ;;
		--apply)     MODE=apply; shift ;;
		--remove)    MODE=remove; shift ;;
		--print)     MODE=print; shift ;;
		--strict)    STRICT=1; shift ;;
		-h|--help)   sed -n '2,80p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		*)           die "未知参数：$1" ;;
	esac
done

MULTIARCH="${DEB_HOST_MULTIARCH:-}"
[ -n "$MULTIARCH" ] || MULTIARCH="$(dpkg-architecture -qDEB_HOST_MULTIARCH 2>/dev/null || true)"

# 模块根（把 root prefix 拼上，便于在 staging 树里操作）
_L() { printf '%s%s' "$ROOT_PREFIX" "$1"; }

# -----------------------------------------------------------------------------
# 我们需要的软链规格
# -----------------------------------------------------------------------------
# 每条 = "<链接所在目录>|<链接名>|<目标>"
# 目标一律写**绝对路径**（不带 root prefix）：软链要能在真实根下解析，
# 打包进 .deb 的软链更是如此。
_lua_links() {
	# ① .so 侧：命中 package.cpath
	#    luci/  → /usr/lib/lua/luci          （luci.ip / luci.jsonc /
	#                                          luci.template.parser）
	#    nixio.so, lucihttp.so               （顶层 C 模块）
	if [ -n "$MULTIARCH" ]; then
		printf '%s\n' "/usr/lib/$MULTIARCH/lua/5.1|luci|$LUA_LIBDIR/luci"
		printf '%s\n' "/usr/lib/$MULTIARCH/lua/5.1|nixio.so|$LUA_LIBDIR/nixio.so"
		printf '%s\n' "/usr/lib/$MULTIARCH/lua/5.1|lucihttp.so|$LUA_LIBDIR/lucihttp.so"
	fi
	# /usr/lib/lua/5.1 也在默认 cpath 里（Debian 补丁的 LUA_CDIR3），
	# 双份覆盖以抵御"某个发行版把多架构那一段删了"的情况
	printf '%s\n' "/usr/lib/lua/5.1|luci|$LUA_LIBDIR/luci"
	printf '%s\n' "/usr/lib/lua/5.1|nixio.so|$LUA_LIBDIR/nixio.so"
	printf '%s\n' "/usr/lib/lua/5.1|lucihttp.so|$LUA_LIBDIR/lucihttp.so"
	# ② .lua 侧：命中 package.path（Debian 政策：架构无关文件在 /usr/share）
	printf '%s\n' "/usr/share/lua/5.1|luci|$LUA_LIBDIR/luci"
	printf '%s\n' "/usr/share/lua/5.1|nixio|$LUA_LIBDIR/nixio"
}

# -----------------------------------------------------------------------------
# 模式：stagedir —— 构建期把软链放进 staging 树
# -----------------------------------------------------------------------------
# 这一步是**主路径**：绝大多数 Debian/Ubuntu 上，把软链直接打进 .deb 就够了，
# 安装期完全不需要动任何东西（dpkg -L 能看到，卸载自动清理）。
# 安装期的 --apply 只是"默认假设被实测推翻"时的兜底。
do_stagedir() {
	[ -n "$STAGE" ] || die "--stagedir 需要目录"
	[ -d "$STAGE" ] || die "staging 目录不存在：$STAGE"
	local row dir name target made=0
	while IFS= read -r row; do
		dir="${row%%|*}"; row="${row#*|}"
		name="${row%%|*}"; target="${row#*|}"
		# 目标不存在就不建链 —— 建出来是悬空软链，反而让排障更难
		# （而且 P1 阶段 luci/ 目录还没装，P2 才补齐）
		if [ ! -e "$STAGE$target" ]; then
			continue
		fi
		mkdir -p "$STAGE$dir"
		"$LN" -sfn "$target" "$STAGE$dir/$name"
		log "  + $dir/$name -> $target"
		made=$((made + 1))
	done < <(_lua_links)
	[ "$made" -gt 0 ] || warn "没有创建任何软链（目标模块都还不存在？先跑 build-lua-modules.sh）"
	log "staging 软链完成：$made 条"
}

# -----------------------------------------------------------------------------
# 探测 Lua 5.1 的**编译期默认**搜索路径
# -----------------------------------------------------------------------------
_lua_bin() {
	local b p
	for b in lua5.1 lua-5.1 lua; do
		p="$(command -v "$b" 2>/dev/null || true)"
		[ -n "$p" ] || continue
		if [ "$("$p" -e 'io.write(_VERSION)' 2>/dev/null || true)" = "Lua 5.1" ]; then
			printf '%s\n' "$p"; return 0
		fi
	done
	return 1
}

# 把 package.cpath / package.path 里的**模板**还原成目录列表。
#   /usr/lib/x86_64-linux-gnu/lua/5.1/?.so          → /usr/lib/x86_64-linux-gnu/lua/5.1
#   /usr/share/lua/5.1/?/init.lua                   → /usr/share/lua/5.1
# 用一个后缀表逐条剥离，而不是简单 cut：`?/init.lua` 这种形式里 `?` 不在末尾。
_dirs_from_paths() {
	local raw="$1" ent
	printf '%s' "$raw" | tr ';' '\n' | while IFS= read -r ent; do
		[ -n "$ent" ] || continue
		case "$ent" in
			*'/?/init.lua') printf '%s\n' "${ent%'/?/init.lua'}" ;;
			*'/?.lua')      printf '%s\n' "${ent%'/?.lua'}" ;;
			*'/?.so')       printf '%s\n' "${ent%'/?.so'}" ;;
			*'/loadall.so') : ;;   # loadall 不是目录，跳过
			*)              : ;;   # 认不出的模板不猜
		esac
	done
}

# 用**干净环境**问解释器，确保拿到的是编译期默认值而不是当前 shell 的
# LUA_PATH/LUA_CPATH。取绝对路径，因为 env -i 会清掉 PATH。
_probe_paths() {
	local lb="$1"
	command -v env >/dev/null 2>&1 || return 1
	env -i "$lb" -e 'io.write(package.cpath .. "\n" .. package.path)' 2>/dev/null
}

# -----------------------------------------------------------------------------
# 模式：check —— 已就绪？
# -----------------------------------------------------------------------------
# 判定标准不是"软链在不在"，而是"Lua 到底能不能找到模块根"：
# 若 Lua 的默认搜索路径里**本来就含** /usr/lib/lua（将来某天某一版改了，
# 或用户自己编的 Lua 就是这样），那什么都不用做。
do_check() {
	local lb cp pl
	lb="$(_lua_bin || true)"
	if [ -z "$lb" ]; then
		warn "未找到 Lua 5.1 解释器，无法探测搜索路径"
		return 1
	fi
	local probe
	probe="$(_probe_paths "$lb" || true)"
	if [ -z "$probe" ]; then
		warn "无法探测 Lua 搜索路径（env -i 不可用？）"
		return 1
	fi
	cp="$(printf '%s' "$probe" | sed -n '1p')"
	pl="$(printf '%s' "$probe" | sed -n '2p')"

	if _dirs_from_paths "$cp" | grep -qx "$LUA_LIBDIR" \
	   || _dirs_from_paths "$pl" | grep -qx "$LUA_LIBDIR"; then
		log "Lua 默认搜索路径已包含 $LUA_LIBDIR，无需桥接"
		return 0
	fi
	# 否则看软链是否到位
	local missing=0 row dir name target
	while IFS= read -r row; do
		dir="${row%%|*}"; row="${row#*|}"; name="${row%%|*}"; target="${row#*|}"
		[ -e "$( _L "$target" )" ] || continue     # 目标还没有（P2 之前正常）
		if [ "$("$READLINK" "$(_L "$dir/$name")" 2>/dev/null || true)" != "$target" ]; then
			missing=$((missing + 1))
		fi
	done < <(_lua_links)
	if [ "$missing" -eq 0 ]; then
		log "搜索路径桥接已就绪（软链齐全）"
		return 0
	fi
	warn "有 $missing 条软链缺失，需要 --apply"
	return 1
}

# -----------------------------------------------------------------------------
# 模式：verify —— 真的 require 得起来吗
# -----------------------------------------------------------------------------
# 这是唯一的权威判据。用 env -i 起进程，只留默认搜索路径，
# 从而验证的是**文件系统的实际状态**，而不是我们自己的环境变量。
_MODS="nixio:nixio.so
nixio.fs:nixio/fs.lua
nixio.util:nixio/util.lua
luci.ip:luci/ip.so
luci.jsonc:luci/jsonc.so
lucihttp:lucihttp.so
luci.template.parser:luci/template/parser.so
luci.util:luci/util.lua
luci.template:luci/template.lua
luci.dispatcher:luci/dispatcher.lua
luci.model.uci:luci/model/uci.lua
luci.cbi:cbi.lua
luci.i18n:luci/i18n.lua"

do_verify() {
	local lb
	lb="$(_lua_bin || true)"
	[ -n "$lb" ] || { warn "未找到 Lua 5.1 解释器，跳过 require 校验"; return 0; }
	lb="$(command -v "$lb")"   # env -i 会清 PATH，必须用绝对路径

	# 只校验"文件已存在"的模块；未安装的记为 SKIP（P2 之前正常）。
	# --strict 时 SKIP 也算失败，用于发布前的完整性检查。
	local mods_lua="" name path m n=0 ns=0
	while IFS=: read -r m path; do
		[ -n "$m" ] || continue
		if [ -e "$(_L "$LUA_LIBDIR/$path")" ]; then
			mods_lua="$mods_lua'$m',"
			n=$((n + 1))
		else
			ns=$((ns + 1))
			printf '  \033[33mSKIP\033[0m  %-24s （未安装 /$LUA_LIBDIR/%s）\n' "$m" "$path"
			[ "$STRICT" = "1" ] && return 1
		fi
	done <<<"$_MODS"
	mods_lua="${mods_lua%,}"

	if [ -z "$mods_lua" ]; then
		log "没有任何模块已安装，跳过"
		return 0
	fi

	# 模块清单必须内联进 Lua 源码：`lua -e 'code' a b c` 的位置参数进的是
	# 全局 arg 表，不是 chunk 的 `...`
	local prog="local mods={$mods_lua}
local ng = 0
for _, n in ipairs(mods) do
	local ok, err = pcall(require, n)
	io.write((ok and 'OK   ' or 'FAIL ') .. n .. (ok and '' or ('  <- ' .. tostring(err))) .. '\n')
	if not ok then ng = ng + 1 end
end
os.exit(ng == 0 and 0 or 1)"

	log "以干净环境实测 require（$n 个模块，跳过 $ns 个未安装）"
	local out rc=0
	out="$(env -i "$lb" -e "$prog" 2>&1)" || rc=$?
	printf '%s\n' "$out" | sed 's/^/  /'
	if [ "$rc" != "0" ]; then
		if printf '%s' "$out" | grep -q 'undefined symbol'; then
			die "加载失败且报 undefined symbol —— 多半是解释器没导出 Lua 符号表。
     参见 runtime/lua/build-lua-modules.sh 里 PARSER_LINK_LUA 的说明。"
		fi
		die "require 实测失败。若报 module not found，说明搜索路径桥接没生效：
     先跑 $0 --print 看将要建哪些软链，再跑 $0 --apply"
	fi
	log "全部可加载"
	return 0
}

# -----------------------------------------------------------------------------
# 模式：apply —— 按**实测**路径补软链（兜底）
# -----------------------------------------------------------------------------
# 与 --stagedir 共用同一份链接规格（_lua_links），只在两件事上加约束：
#   1. 目录必须**已经存在** —— 凭空造一个目录没有意义，我们还不知道 Lua
#      会不会去那里找，只会留下垃圾。
#   2. 目录必须**确实出现在探测到的搜索路径里** —— 否则建了也是白建。
# 之所以把"名字表 + /usr/share 只放纯 Lua"这类规则留在 _lua_links 里而不是
# 在这里再写一遍：两份真相早晚会漂移，而漂移的症状（某个 require 找不到）
# 很难回溯到这里。
do_apply() {
	local lb probe cp pl
	lb="$(_lua_bin || true)"
	probe=""
	[ -n "$lb" ] && probe="$(_probe_paths "$lb" || true)"

	if [ -z "$probe" ]; then
		warn "无法探测 Lua 搜索路径（缺解释器或 env）；若 .deb 里的软链已就位则无需处理"
		return 0
	fi
	cp="$(printf '%s' "$probe" | sed -n '1p')"
	pl="$(printf '%s' "$probe" | sed -n '2p')"
	local searched
	searched="$({ _dirs_from_paths "$cp"; _dirs_from_paths "$pl"; } | sort -u)"

	mkdir -p "$(_L "$STATE_DIR")"
	: >"$(_L "$STATE_FILE")"
	local row dir name target made=0 skipped=0
	while IFS= read -r row; do
		dir="${row%%|*}"; row="${row#*|}"; name="${row%%|*}"; target="${row#*|}"
		if [ ! -e "$(_L "$target")" ]; then
			skipped=$((skipped + 1)); continue      # 模块还没装
		fi
		# ⚠️ 顺序很重要：先确认「Lua 确实会来这个 dir 找」，再决定要不要建它。
		#   反过来会为 Lua 根本不看的目录乱 mkdir。
		if ! printf '%s\n' "$searched" | grep -qx -- "$dir"; then
			skipped=$((skipped + 1)); continue      # Lua 根本不去这里找
		fi
		# ⚠️ 原本这里写「dir 不存在就 skip」，与 --check 的判据**不一致**：
		#   check 只看 target 存在就要求 $dir/$name 的软链到位（并不管 dir 是否
		#   存在）。于是在干净机器上（/usr/lib/lua/5.1/ 这种目录还没被任何包装过）
		#   出现死循环：apply 说"跳过 8 条（目录不存在）"，check 说"缺失 8 条，
		#   需要 --apply" —— CI 卡在这里 rc=1（2026-10-01 实测）。
		#   修：dir 是 Lua 默认搜索目录（上面已确认在 searched 里），建它无害。
		if [ ! -d "$(_L "$dir")" ]; then
			mkdir -p "$(_L "$dir")" 2>/dev/null || {
				skipped=$((skipped + 1)); continue    # 建不了（权限/只读）才跳过
			}
			log "  + 建目录 $dir"
		fi
		"$LN" -sfn "$target" "$(_L "$dir/$name")"
		printf '%s|%s\n' "$dir" "$name" >>"$(_L "$STATE_FILE")"
		log "  + $dir/$name -> $target"
		made=$((made + 1))
	done < <(_lua_links)

	if [ "$made" -eq 0 ]; then
		rm -f "$(_L "$STATE_FILE")"
		warn "没有需要补的软链（跳过 $skipped 条）—— 若 .deb 里的软链已就位则属正常"
		return 0
	fi
	log "兜底桥接完成：补了 $made 条软链（跳过 $skipped 条）"
	log "清单：$(_L "$STATE_FILE")"
}

# -----------------------------------------------------------------------------
# 模式：print —— dry-run
# -----------------------------------------------------------------------------
do_print() {
	log "将创建的软链（目标需已存在才会真正创建）："
	local row dir name target
	local any=0
	while IFS= read -r row; do
		dir="${row%%|*}"; row="${row#*|}"; name="${row%%|*}"; target="${row#*|}"
		if [ -e "$(_L "$target")" ]; then
			dry "$dir/$name -> $target"
			any=1
		else
			dry "$dir/$name -> $target   \033[0;90m[目标未安装，跳过]\033[0m"
		fi
	done < <(_lua_links)
	[ "$any" = 1 ] || warn "所有目标都还不存在 —— 先跑 build-lua-modules.sh"
	return 0
}

# -----------------------------------------------------------------------------
# 模式：remove —— 只删自己建的
# -----------------------------------------------------------------------------
# 打包期建的软链归 dpkg 管，这里**不碰**。只清理 --apply 记录在案的那些，
# 而且删之前二次确认"它仍是指向我们预期目标的软链"，避免误删用户的东西。
do_remove() {
	local sf="$(_L "$STATE_FILE")"
	if [ ! -f "$sf" ]; then
		log "没有 --apply 的记录（$sf），无需清理"
		return 0
	fi
	local d name n=0
	while IFS='|' read -r d name; do
		[ -n "$d" ] && [ -n "$name" ] || continue
		local p="$(_L "$d/$name")"
		if [ "$("$READLINK" "$p" 2>/dev/null || true)" = "$LUA_LIBDIR/$name" ]; then
			rm -f "$p" && n=$((n + 1))
		fi
	done <"$sf"
	rm -f "$sf"
	log "清理了 $n 条兜底软链"
}

# -----------------------------------------------------------------------------
case "$MODE" in
	stagedir) do_stagedir ;;
	check)    do_check ;;
	verify)   do_verify ;;
	apply)    do_apply ;;
	remove)   do_remove ;;
	print)    do_print ;;
	"")       die "必须指定一个模式（--stagedir/--check/--verify/--apply/--remove/--print）" ;;
esac
# 说明：本脚本被 source 无意义（末尾有 case 分派），测试一律当黑盒调用，
# 用 OPENCLASH_RT_ROOT_PREFIX + 注入假 lua5.1 的方式控制输入。
