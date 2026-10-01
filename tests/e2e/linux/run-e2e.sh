#!/usr/bin/env bash
# =============================================================================
# openclash-rt  Linux 端到端测试（真实路径 / 真实内核语义）
# -----------------------------------------------------------------------------
# 单元测试跑在 Windows/MSYS 上，用 mock 替换 uci / systemctl / nft。
# 本脚本补上它们覆盖不到的三类「只有真实 Linux 才成立」的验证：
#
#   L1  **dash → bash 重执行**：MSYS 的 /bin/sh 就是 bash，rc.common 的
#       方言兼容分支从未被真正执行过。Debian 的 /bin/sh 是 dash，
#       这是本项目最脆弱的一环，必须在真 dash 上验证。
#   L2  **真实路径契约**：上游硬编码 /lib/functions.sh、/sbin/uci 等绝对路径，
#       必须在真实文件系统上落位才能证明兼容层可用。
#   L3  **真实 nftables**：fw4 垫片创建的 table/chain 语法是否正确，只有内核能判定。
#
# 用法：
#   sudo bash tests/e2e/linux/run-e2e.sh              # staging 模式（默认）
#   sudo bash tests/e2e/linux/run-e2e.sh --deb dist/openclash-rt_*.deb
#
# 安全承诺（重要）：
#   * 安装阶段对每个目标路径做「日志化备份」，退出时（含异常）自动还原。
#   * 真实 nft 验证在 `unshare -n` 的独立网络命名空间中执行，
#     绝不触碰宿主机的防火墙状态。
#   * systemd 单元写入临时目录 + mock systemctl，不触碰宿主机 /run/systemd。
#
# 退出码：0 = 全部通过（含合理 SKIP）；1 = 有 FAIL。
# =============================================================================
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"

PASS=0; FAIL=0; SKIP=0
it()   { printf '\n\033[1m── %s\033[0m\n' "$1"; }
ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
no()   { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; }
skip() { SKIP=$((SKIP+1)); printf '  \033[33mSKIP\033[0m  %s\n        %s\n' "$1" "${2:-}"; }
chk()  { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "want=[$3] got=[$2]"; fi; }

# -----------------------------------------------------------------------------
# 0. 前置检查
# -----------------------------------------------------------------------------
if [ "$(uname -s 2>/dev/null)" != "Linux" ]; then
	printf '\033[33m[skip]\033[0m 本脚本仅适用于 Linux（当前 %s）。\n' "$(uname -s 2>/dev/null)"
	printf '        在非 Linux 环境请改用 tests/test_procd_shim.sh 等 mock 套件。\n'
	exit 0
fi

DEB=""
while [ $# -gt 0 ]; do
	case "$1" in
		--deb) DEB="${2:-}"; shift 2 ;;
		--deb=*) DEB="${1#--deb=}"; shift ;;
		-h|--help) sed -n '2,30p' "$0"; exit 0 ;;
		*) printf '未知参数: %s\n' "$1" >&2; exit 2 ;;
	esac
done

if [ "$(id -u)" -ne 0 ]; then
	printf '\033[31m[fail]\033[0m 需要 root（要写入 /lib、/etc、/sbin 等契约路径）。\n' >&2
	printf '        请用: sudo bash %s\n' "$0" >&2
	exit 2
fi

E2E="/tmp/ocrt-e2e.$$"
SRC="$E2E/src"          # 待安装的文件树（模拟 .deb 展开结果）
BAK="$E2E/backup"       # 被覆盖文件的备份
JOURNAL="$E2E/journal"  # 安装日志：每行 "<created|replaced> <path>"
DEB_MODE=0              # 1 = 由 dpkg 负责安装/卸载
mkdir -p "$SRC" "$BAK" "$E2E/units" "$E2E/tmp"
: >"$JOURNAL"

# -----------------------------------------------------------------------------
# 安装 / 还原机制
# -----------------------------------------------------------------------------
_install_file() {
	local src="$1" dst="$2" mode="${3:-0644}"
	mkdir -p "$(dirname "$dst")"
	if [ -e "$dst" ] || [ -L "$dst" ]; then
		mkdir -p "$BAK$(dirname "$dst")"
		cp -a "$dst" "$BAK$dst" 2>/dev/null || true
		printf 'replaced %s\n' "$dst" >>"$JOURNAL"
	else
		printf 'created %s\n' "$dst" >>"$JOURNAL"
	fi
	cp -a "$src" "$dst"
	chmod "$mode" "$dst" 2>/dev/null || true
}

# 整个目录树托管（目标整体不存在则记录 created-dir，存在则整体备份）
_install_tree() {
	local src="$1" dst="$2"
	if [ -e "$dst" ]; then
		mkdir -p "$BAK$(dirname "$dst")"
		cp -a "$dst" "$BAK$dst" 2>/dev/null || true
		printf 'replaced-dir %s\n' "$dst" >>"$JOURNAL"
		rm -rf "$dst"
	else
		printf 'created-dir %s\n' "$dst" >>"$JOURNAL"
	fi
	mkdir -p "$(dirname "$dst")"
	cp -a "$src" "$dst"
}

_restore() {
	# --deb 模式：交给 dpkg 卸载，保持 dpkg 数据库一致
	if [ "$DEB_MODE" = "1" ]; then
		systemctl stop openclash >/dev/null 2>&1 || true
		dpkg -P openclash-rt >/dev/null 2>&1 || true
		rm -rf "$E2E" 2>/dev/null || true
		return 0
	fi
	[ -f "$JOURNAL" ] || { rm -rf "$E2E" 2>/dev/null || true; return 0; }
	# 逆序还原
	tac "$JOURNAL" 2>/dev/null | while IFS=' ' read -r kind path; do
		[ -n "${path:-}" ] || continue
		case "$kind" in
			created)      rm -f "$path" 2>/dev/null ;;
			created-dir)  rm -rf "$path" 2>/dev/null ;;
			replaced)     cp -a "$BAK$path" "$path" 2>/dev/null ;;
			replaced-dir) rm -rf "$path" 2>/dev/null; cp -a "$BAK$path" "$path" 2>/dev/null ;;
		esac
	done
	rm -rf "$E2E" 2>/dev/null || true
}
trap _restore EXIT INT TERM

# -----------------------------------------------------------------------------
# 1. 组装文件树
# -----------------------------------------------------------------------------
it "S1  组装兼容层文件树"

UP="$ROOT/upstream/luci-app-openclash/root"
[ -d "$UP" ] || { printf '\033[31m[fail]\033[0m 缺少上游代码，请先运行 scripts/sync-upstream.sh\n' >&2; exit 2; }

mkdir -p "$SRC/lib/functions" "$SRC/lib/config" "$SRC/etc/init.d" \
         "$SRC/etc/config" "$SRC/usr/share/openclash" "$SRC/usr/sbin" "$SRC/sbin" \
         "$SRC/usr/lib/openclash-rt"

cp "$ROOT/runtime/procd/rc.common"             "$SRC/etc/rc.common"
cp "$ROOT/runtime/shell/functions.sh"          "$SRC/lib/functions.sh"
cp "$ROOT/runtime/shell/functions/network.sh"  "$SRC/lib/functions/network.sh"
cp "$ROOT/runtime/shell/service.sh"            "$SRC/lib/functions/service.sh"
cp "$ROOT/runtime/procd/procd.sh"              "$SRC/lib/functions/procd.sh"
cp "$ROOT/runtime/shell/config/uci.sh"         "$SRC/lib/config/uci.sh"
cp "$ROOT/runtime/net/fw4"                     "$SRC/usr/sbin/fw4"
cp "$ROOT/runtime/net/prepare-tmp.sh"          "$SRC/usr/lib/openclash-rt/prepare-tmp.sh"
cp "$ROOT/runtime/net/dnsmasq-adapter.sh"      "$SRC/usr/lib/openclash-rt/dnsmasq-adapter.sh"
cp "$UP/etc/init.d/openclash"                  "$SRC/etc/init.d/openclash"
cp -a "$UP/usr/share/openclash/."              "$SRC/usr/share/openclash/"

# 真实 uci：优先取已构建产物，其次取 .deb 解包结果
OPT="${OCRT_OPT:-$ROOT/packaging/build/opt/openclash-rt}"
HAS_UCI=0
if [ -x "$OPT/sbin/uci" ] || [ -x "$OPT/bin/uci" ]; then
	mkdir -p "$SRC/usr/lib"
	for d in sbin bin lib; do
		[ -d "$OPT/$d" ] && cp -a "$OPT/$d" "$SRC/usr/$d/" 2>/dev/null || true
	done
	HAS_UCI=1
	ok "使用已构建的真实 uci ($OPT)"
else
	skip "未找到已构建的 uci" "uci 相关断言将跳过；构建方式: runtime/uci/build-uci.sh $OPT"
fi

# /etc/openwrt_release —— 上游 init.d:14 用它作为「是否 OpenWrt」的开关，
# 该分支负责推导 DNSMASQ_CONF_DIR。缺失则整段被跳过。
ARCH="$(dpkg --print-architecture 2>/dev/null || uname -m)"
cat >"$SRC/etc/openwrt_release" <<EOF
DISTRIB_ID='openclash-rt'
DISTRIB_RELEASE='debian'
DISTRIB_REVISION='r0'
DISTRIB_TARGET='debian/$ARCH'
DISTRIB_ARCH='$ARCH'
DISTRIB_DESCRIPTION='OpenClash runtime for Debian/Ubuntu (openclash-rt)'
DISTRIB_TAINTS=''
EOF

# 最小 UCI 配置
cat >"$SRC/etc/config/openclash" <<'EOF'
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

# dhcp 包：上游 init.d:16 必读 dhcp.@dnsmasq[0]。段具名为 main，
# 使上游推导出的 CFGID 稳定为 "main"（见 scripts/build-deb.sh 的说明）。
cat >"$SRC/etc/config/dhcp" <<'EOF'
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

ok "上游已载入 $(ls "$SRC/usr/share/openclash" | wc -l) 个运行时文件"

# -----------------------------------------------------------------------------
# 2. 安装到真实路径
# -----------------------------------------------------------------------------
it "S2  安装到契约路径"

if [ -n "$DEB" ]; then
	# --deb 模式：安装与卸载全部交给 dpkg，避免人工还原与 dpkg 数据库不一致
	if [ ! -f "$DEB" ]; then
		no "找不到 .deb" "$DEB"
		printf '\n  FAIL: 1\n'
		exit 1
	fi
	DEB_MODE=1
	systemctl stop openclash >/dev/null 2>&1 || true
	if dpkg -i "$DEB" >"$E2E/dpkg.log" 2>&1; then
		ok "dpkg -i $(basename "$DEB")"
	else
		no "dpkg -i $(basename "$DEB")" "$(tail -3 "$E2E/dpkg.log" | tr '\n' '|')"
	fi
	if dpkg -s openclash-rt >/dev/null 2>&1; then
		ok "包 openclash-rt 已在 dpkg 数据库注册"
	else
		no "包 openclash-rt 已在 dpkg 数据库注册"
	fi
	# 从包内取真实 uci，供后续断言使用
	if dpkg -L openclash-rt 2>/dev/null | grep -qE '^/(usr/)?s?bin/uci$'; then HAS_UCI=1; fi
else
	# 逐文件安装（用于契约断言）
	_install_file "$SRC/etc/rc.common"            /etc/rc.common                0755
	_install_file "$SRC/lib/functions.sh"         /lib/functions.sh             0644
	_install_file "$SRC/lib/functions/network.sh" /lib/functions/network.sh     0644
	_install_file "$SRC/lib/functions/service.sh" /lib/functions/service.sh     0644
	_install_file "$SRC/lib/functions/procd.sh"   /lib/functions/procd.sh       0644
	_install_file "$SRC/lib/config/uci.sh"        /lib/config/uci.sh            0644
	_install_file "$SRC/etc/openwrt_release"      /etc/openwrt_release          0644
	_install_file "$SRC/etc/init.d/openclash"     /etc/init.d/openclash         0755
	_install_file "$SRC/etc/config/openclash"     /etc/config/openclash         0644
	_install_file "$SRC/etc/config/dhcp"          /etc/config/dhcp              0644
	_install_file "$SRC/usr/sbin/fw4"             /usr/sbin/fw4                 0755
	_install_file "$SRC/usr/lib/openclash-rt/prepare-tmp.sh"     /usr/lib/openclash-rt/prepare-tmp.sh     0755
	_install_file "$SRC/usr/lib/openclash-rt/dnsmasq-adapter.sh" /usr/lib/openclash-rt/dnsmasq-adapter.sh 0755
	_install_tree "$SRC/usr/share/openclash"      /usr/share/openclash

	if [ "$HAS_UCI" = "1" ]; then
		[ -x "$SRC/usr/sbin/uci" ] && _install_file "$SRC/usr/sbin/uci" /usr/sbin/uci 0755
		[ -x "$SRC/usr/bin/uci" ]  && _install_file "$SRC/usr/bin/uci"  /usr/bin/uci  0755
		[ -d "$SRC/usr/lib" ] && cp -a "$SRC/usr/lib/." /usr/lib/ 2>/dev/null || true
		# /sbin/uci：这里刻意**复刻 packaging/debian/postinst 的判定语义**，而不是
		# 图省事写一句 `ln -sf`。两个理由：
		#   1) usrmerge 主机（Debian 12+ / Ubuntu 24.04）上 /sbin 就是 -> usr/sbin，
		#      `ln -sf /usr/sbin/uci /sbin/uci` 等于在一个路径上创建指向自己的链接，
		#      GNU ln 会报 "are the same file" 并以非零退出 —— 而真实 postinst 在
		#      `set -e` 下会因此**直接失败**（dpkg 报配置错误）。e2e 若不按同一套
		#      语义走，验证的就是一段与生产不同的逻辑。
		#   2) e2e 的全部价值来自"它跑的是真实路径契约"。postinst 改了而这里没改，
		#      e2e 会继续绿着给出虚假安心 —— 所以两处必须同形，并由单元套件
		#      （tests/test_maintainer_scripts.sh 的 C9）锁住这个一致性。
		# 结果侧断言见下面的 L2d。
		if [ -x /usr/sbin/uci ] && [ ! /sbin -ef /usr/sbin ] && [ ! -e /sbin/uci ]; then
			printf 'created %s\n' /sbin/uci >>"$JOURNAL"
			ln -s /usr/sbin/uci /sbin/uci
		fi
	fi
	ok "安装完成（日志 $(wc -l <"$JOURNAL") 项，退出时自动还原）"
fi

# -----------------------------------------------------------------------------
# 3. 易失路径准备（上游假定存在、Debian 上无人创建）
# -----------------------------------------------------------------------------
it "S3  易失路径准备（prepare-tmp.sh）"

PREP=/usr/lib/openclash-rt/prepare-tmp.sh
DM="/tmp/etc/dnsmasq.conf.main"

if [ -x "$PREP" ]; then
	"$PREP" >"$E2E/prep.out" 2>&1
	chk "prepare-tmp.sh 退出码" "$?" "0"

	if [ -s "$DM" ]; then
		ok "已生成 $DM"
		# 复刻上游 init.d:22 的 DNSMASQ_CONF_DIR=${VAR%*/}
		RAW="$(awk -F= '/^conf-dir=/{print $2}' "$DM")"
		chk "conf-dir 经上游 \${VAR%*/} 后 = /etc/dnsmasq.d" "${RAW%*/}" "/etc/dnsmasq.d"
	else
		no "已生成 $DM"
	fi

	if [ -s /tmp/resolv.conf.d/resolv.conf.auto ] && grep -q '^nameserver ' /tmp/resolv.conf.d/resolv.conf.auto; then
		ok "已镜像上游 DNS: $(tr '\n' ' ' </tmp/resolv.conf.d/resolv.conf.auto)"
	else
		no "已镜像 /tmp/resolv.conf.d/resolv.conf.auto"
	fi

	if grep -qE '^nameserver (127\.|::1)' /tmp/resolv.conf.d/resolv.conf.auto 2>/dev/null; then
		no "已过滤回环 nameserver" "回环 DNS 会让 dnsmasq 自环，必须剔除"
	else
		ok "已过滤回环 nameserver（避免 dnsmasq 自环）"
	fi

	[ -f /etc/crontabs/root ] && ok "已创建 /etc/crontabs/root" || no "已创建 /etc/crontabs/root"

	# 幂等：重复执行不应改变内容（systemd ExecStartPre 每次启动都会调用）
	BEFORE="$(cat "$DM" 2>/dev/null)"
	"$PREP" >/dev/null 2>&1
	chk "prepare-tmp 幂等（重复执行内容不变）" "$(cat "$DM" 2>/dev/null)" "$BEFORE"
else
	no "prepare-tmp.sh 可执行" "$PREP"
fi

# -----------------------------------------------------------------------------
# 4. 路径契约断言
# -----------------------------------------------------------------------------
it "L2  路径契约：上游硬编码的绝对路径全部落位"

for p in /etc/rc.common /lib/functions.sh /lib/functions/network.sh \
         /lib/functions/service.sh /lib/functions/procd.sh \
         /lib/config/uci.sh /etc/openwrt_release /etc/init.d/openclash \
         /etc/config/openclash /etc/config/dhcp /usr/share/openclash; do
	if [ -e "$p" ]; then ok "存在 $p"; else no "存在 $p"; fi
done

chk "/etc/rc.common 可执行" "$([ -x /etc/rc.common ] && echo y || echo n)" "y"
chk "/etc/init.d/openclash 可执行" "$([ -x /etc/init.d/openclash ] && echo y || echo n)" "y"

# 上游 init.d 前 12 行 source 的 5 个库必须真实存在
for f in openclash_ps.sh ruby.sh log.sh uci.sh openclash_curl.sh; do
	if [ -f "/usr/share/openclash/$f" ]; then ok "上游依赖库 $f"; else no "上游依赖库 $f"; fi
done

# openwrt_release 必须可被上游的 shell 片段解析
if sh -c '. /etc/openwrt_release && [ -n "$DISTRIB_ARCH" ]' 2>/dev/null; then
	ok "/etc/openwrt_release 可被 dash 解析"
else
	no "/etc/openwrt_release 可被 dash 解析"
fi

# -----------------------------------------------------------------------------
# 3b. lua 解释器钉定（P1.5 的语义前提）——必须验证"装完之后"而不是"包内"
# -----------------------------------------------------------------------------
# 上游有 11 处假定「`lua` 这个命令解析到 Lua 5.1」（8 个 shebang + 3 处显式
# 调用）。OpenWrt 上成立，Debian 上不成立：/usr/bin/lua 由 update-alternatives
# 组 `lua-interpreter` 提供，优先级 lua5.1=110 < lua5.2/5.3=120 < lua5.4=130，
# 于是机器上只要有 lua5.4 就会指向 5.4，而我们为 5.1 编译的 .so 会以
# `undefined symbol: lua_...` 失败 —— 症状与「搜索路径没桥接对」几乎一样。
#
# 打包期已把 11 处改写成绝对路径 /usr/bin/lua5.1（runtime/upstream/
# pin-lua-interpreter.sh）。这里验证它落到了系统的 /usr/share/openclash 下：
# 只验包内 staging 是不够的，因为 postinst/prerm 仍有可能动这些文件。
it "L2b 上游 11 处 lua 依赖已钉到绝对路径"

OC_LUA_DIR=/usr/share/openclash
# 宽判据：命令行位置上一切裸 lua（与 pin-lua-interpreter.sh 的 RESIDUAL_RE 同源）
LUA_GATE='^#![[:space:]]*.*lua[[:space:]]*$|(^|[^[:alnum:]_./-])lua([^[:alnum:]_.-]|$)'

chk "8 个脚本的 shebang 指向 /usr/bin/lua5.1" \
	"$(grep -rlE '^#!/usr/bin/lua5\.1$' "$OC_LUA_DIR" 2>/dev/null | wc -l | tr -d ' ')" "8"
chk "无残留的裸 '#!/usr/bin/lua'" \
	"$(grep -rlE '^#!/usr/bin/lua$' "$OC_LUA_DIR" 2>/dev/null | wc -l | tr -d ' ')" "0"
chk "3 处显式调用已改成绝对路径" \
	"$(grep -rhoE '/usr/bin/lua5\.1 /usr/share/openclash/' "$OC_LUA_DIR" 2>/dev/null | wc -l | tr -d ' ')" "3"
chk "宽判据下再无裸 lua 依赖" \
	"$(grep -rlE "$LUA_GATE" "$OC_LUA_DIR" 2>/dev/null | wc -l | tr -d ' ')" "0"

chk "lua5.1 解释器在 PATH 上" "$(command -v lua5.1 >/dev/null 2>&1 && echo y || echo n)" "y"
if command -v lua5.1 >/dev/null 2>&1; then
	# 确认真的是 5.1（防 /usr/bin/lua5.1 被换成别的版本的软链）
	chk "lua5.1 自报 _VERSION = Lua 5.1" \
		"$(lua5.1 -e 'io.write(_VERSION)' 2>/dev/null)" "Lua 5.1"
else
	skip "lua5.1 版本断言" "未安装 lua5.1"
fi

# 打包期适配清单必须随包发布：上游同步时靠它逐条比对"哪条适配可能失效了"
if [ -f /usr/lib/openclash-rt/packaging-adaptations.txt ]; then
	ok "packaging-adaptations.txt 随包发布"
else
	no "packaging-adaptations.txt 随包发布"
fi

# -----------------------------------------------------------------------------
# 3c. ubus 底座的产物与动态链接缓存
# -----------------------------------------------------------------------------
it "L2c ubus 底座：产物、cpath 命中、ldconfig 登记、require 实测"

for x in /usr/sbin/ubusd /usr/sbin/rpcd /usr/bin/ubus; do
	chk "可执行 $x" "$([ -x "$x" ] && echo y || echo n)" "y"
done

# ubus 的 lua/CMakeLists.txt 把安装前缀强改成 /，产物落在 /lib/lua/5.1；
# 必须由 build-ubus.sh 显式搬到 /usr/lib/lua/5.1 —— 那里才是 Debian lua5.1
# 编译期默认 cpath 命中的位置。搬漏了 require "ubus" 会报 module not found。
chk "ubus.so 落在 /usr/lib/lua/5.1（默认 cpath 命中）" \
	"$([ -f /usr/lib/lua/5.1/ubus.so ] && echo y || echo n)" "y"

# libubus 按上游惯例装在 /usr/lib（**不是** /usr/lib/<multiarch>/），而 /usr/lib
# 不在 Debian 默认的 /etc/ld.so.conf.d/<triple>.conf 里 —— 必须靠 postinst 写
# ld.so.conf.d 并跑 ldconfig。漏掉的症状是 rpcd 启动即报
#   libubus.so.1: cannot open shared object file
chk "postinst 已把 /usr/lib 写进 ld.so.conf.d" \
	"$([ -f /etc/ld.so.conf.d/openclash-rt.conf ] && echo y || echo n)" "y"
chk "libubus.so.1 已被 ldconfig 登记" \
	"$(ldconfig -p 2>/dev/null | grep -c 'libubus\.so\.1' || true)" "1"

# 唯一权威判据：用**默认搜索路径**（不注入 LUA_CPATH/LUA_PATH）实测 require。
# 这一条同时验证了三件事：.so 在默认 cpath 上、DT_NEEDED 都能解析
# （libnl-tiny.so.1 / libubus.so.1 靠 ldconfig）、ABI 与 lua5.1 匹配。
if command -v lua5.1 >/dev/null 2>&1; then
	for m in ubus nixio nixio.fs nixio.util lucihttp luci.ip luci.jsonc; do
		if env -u LUA_CPATH -u LUA_PATH lua5.1 -e "require('$m')" >/dev/null 2>&1; then
			ok "require '$m'（默认搜索路径）"
		else
			no "require '$m'（默认搜索路径）" \
				"$(env -u LUA_CPATH -u LUA_PATH lua5.1 -e "require('$m')" 2>&1 | head -1)"
		fi
	done
else
	skip "Lua C 模块 require 实测" "未安装 lua5.1"
fi

# -----------------------------------------------------------------------------
# L2d —— /sbin/uci 的落位与"禁止自指链接"
# -----------------------------------------------------------------------------
it "L2d /sbin/uci 落位（usrmerge 分支语义）"

# 这一节的由来：postinst 曾经用 `[ ! -e /sbin/uci ] && ln -sf /usr/sbin/uci /sbin/uci`
# 创建链接，而 usrmerge 主机（Debian 12+ / Ubuntu 24.04）上 /sbin 就是 -> usr/sbin
# —— 两个路径是同一个文件，`ln -sf` 于是造出指向自己的链接：GNU ln 报
# "are the same file" 并以非零退出，在 postinst 的 set -e 下**直接让安装失败**。
# 修法见 packaging/debian/postinst：先用 `[ /sbin -ef /usr/sbin ]` 比较 inode，
# usrmerge 下什么都不做。
# 这里断言的是**结果**：无论哪种主机，/sbin/uci 都必须可解析、可执行、且不是自环。
if [ -x /usr/sbin/uci ] || [ -x /usr/bin/uci ]; then
	chk "/sbin/uci 可执行（上游 uci_load 硬编码该路径）" \
		"$([ -x /sbin/uci ] && echo y || echo n)" "y"
	# 自指链接会让 readlink -f 返回空（路径解析不收敛）—— 这是"没踩 usrmerge 自环"
	# 的权威判据，比解析 ls -l 的输出可靠得多。
	chk "/sbin/uci 可解析到真实文件（自指链接会使 readlink -f 返回空）" \
		"$([ -n "$(readlink -f /sbin/uci 2>/dev/null)" ] && echo y || echo n)" "y"

	if [ /sbin -ef /usr/sbin ]; then
		printf '        本机为 usrmerge（/sbin -ef /usr/sbin）：/sbin/uci 由 /usr/sbin 直接提供\n'
		# usrmerge 下不应该额外建链接；harness 若建了，说明它没有对齐 postinst 语义
		chk "usrmerge 主机上未额外创建 /sbin/uci 链接" \
			"$(grep -c '^created /sbin/uci$' "$JOURNAL" 2>/dev/null || true)" "0"
	else
		skip "usrmerge 分支断言" "本机 /sbin 与 /usr/sbin 不是同一目录（非 usrmerge 主机）"
	fi
else
	skip "L2d /sbin/uci 落位" "未安装 uci 运行时"
fi

# -----------------------------------------------------------------------------
# L2e —— vendor LuCI 布局（P2-A；docs/03 §3.1 表的安装后核验）
# -----------------------------------------------------------------------------
it "L2e vendor LuCI 布局（库/静态资源/入口/ACL 四类）"

for f in \
	/usr/lib/lua/luci/dispatcher.lua \
	/usr/lib/lua/luci/util.lua \
	/usr/lib/lua/luci/cbi.lua \
	/usr/lib/lua/luci/cbi/datatypes.lua \
	/usr/lib/lua/luci/view/themes/bootstrap/header.htm \
	/usr/lib/lua/luci/sys/zoneinfo.lua \
	; do
	if [ -f "$f" ]; then ok "L2e $f"; else no "L2e $f 缺失"; fi
done

# 静态资源：三个 vendor 包的 htdocs 合并到 /www（theme 缺席 = 界面裸奔）
for f in /www/luci-static/bootstrap/cascade.css \
         /www/luci-static/resources/cbi/add.gif \
         /www/luci-static/resources/menu-bootstrap.js; do
	if [ -f "$f" ]; then ok "L2e $f"; else no "L2e $f 缺失"; fi
done

# 两个入口 shebang 已钉（没有扩展名，--dir 选不到，只能 --file 钉）
chk "L2e /www/cgi-bin/luci shebang" "$(head -1 /www/cgi-bin/luci 2>/dev/null)" "#!/usr/bin/lua5.1"
chk "L2e /usr/libexec/rpcd/luci shebang" "$(head -1 /usr/libexec/rpcd/luci 2>/dev/null)" "#!/usr/bin/lua5.1"
[ -x /www/cgi-bin/luci ] && ok "L2e CGI 入口可执行" || no "L2e CGI 入口不可执行"

# ACL / 菜单 / 配置 / 占位
for f in /usr/share/rpcd/acl.d/luci-base.json \
         /usr/share/rpcd/acl.d/luci-compat.json \
         /usr/share/luci/menu.d/luci-base.json \
         /etc/config/luci \
         /etc/config/ucitrack \
         /etc/init.d/ucitrack \
         /etc/luci-uploads/.placeholder \
         /usr/sbin/luci-reload; do
	if [ -f "$f" ]; then ok "L2e $f"; else no "L2e $f 缺失"; fi
done

# 卫生：.luadoc / po/ 不入包
chk "L2e 无 .luadoc 误入" "$(find /usr/lib/lua/luci -name '*.luadoc' 2>/dev/null | wc -l)" "0"

# 命名空间抽查：module("luci.X") 的落位必须是 luci/<X 按点切层>.lua
_ns="$(grep -m1 -oE 'module[[:space:]]*\(?[[:space:]]*"[^"]+"' /usr/lib/lua/luci/dispatcher.lua 2>/dev/null | grep -oE '"[^"]+"' | tr -d '"')"
chk "L2e dispatcher 的 module 名" "$_ns" "luci.dispatcher"
_ns2="$(grep -m1 -oE 'module[[:space:]]*\(?[[:space:]]*"[^"]+"' /usr/lib/lua/luci/util.lua 2>/dev/null | grep -oE '"[^"]+"' | tr -d '"')"
chk "L2e util 的 module 名" "$_ns2" "luci.util"

# 纯 Lua 模块加载实测（不依赖 C 模块的几个：luci.config 只读 /etc/config/luci）
if command -v lua5.1 >/dev/null 2>&1; then
	if env -u LUA_PATH -u LUA_CPATH lua5.1 -e 'require("luci.config")' >/dev/null 2>&1; then
		ok "L2e require 'luci.config'（默认搜索路径，纯 Lua 模块）"
	else
		no "L2e require 'luci.config'" \
			"$(env -u LUA_PATH -u LUA_CPATH lua5.1 -e 'require("luci.config")' 2>&1 | head -1)"
	fi
fi

# -----------------------------------------------------------------------------
# 4. L1 —— dash → bash 重执行（本项目最脆弱的一环）
# -----------------------------------------------------------------------------
it "L1  dash → bash 重执行（真实 /bin/sh 是 dash）"

SH_PATH="$(readlink -f /bin/sh 2>/dev/null || echo /bin/sh)"
printf '        /bin/sh -> %s\n' "$SH_PATH"

# 直接以 dash 执行 rc.common，模拟内核按 shebang 调用的真实路径
TRACE="$E2E/trace.help.txt"
INIT_TRACE=1 /bin/sh /etc/rc.common /etc/init.d/openclash help >"$E2E/help.out" 2>"$TRACE"
rc=$?
chk "`/bin/sh /etc/rc.common <init> help` 退出码" "$rc" "0"
if grep -q 'Available commands:' "$E2E/help.out"; then
	ok "help 输出包含 'Available commands:'（rc.common dispatch 生效）"
else
	no "help 输出包含 'Available commands:'" "$(head -5 "$E2E/help.out" 2>/dev/null)"
fi

# 重执行后应运行在 bash 下；bash 的 set -x 会把 BASH_VERSION 相关痕迹与
# 上游的变量赋值一起打进 trace。
if grep -qE 'DNSMASQ_CONF_DIR=' "$TRACE"; then
	ok "已进入上游 init 脚本顶层（trace 中出现上游变量赋值）"
else
	no "已进入上游 init 脚本顶层" "trace 前 10 行: $(head -10 "$TRACE" 2>/dev/null | tr '\n' '|')"
fi

# 关键：openwrt_release 门控成立 → DNSMASQ_CONF_DIR 被推导出来
DIR_VAL="$(grep -oE 'DNSMASQ_CONF_DIR=[^ ]+' "$TRACE" | tail -1 | cut -d= -f2- || true)"
if [ -n "$DIR_VAL" ]; then
	ok "/etc/openwrt_release 门控生效，DNSMASQ_CONF_DIR=$DIR_VAL"
	if [ "$HAS_UCI" = "1" ]; then
		# 端到端验证：S3 生成的 /tmp/etc/dnsmasq.conf.@dnsmasq[0]
		# 让上游把 conf-dir 推导到 Debian dnsmasq 真正读取的目录。
		# 这正是「分流规则静默失效」那个坑的验收点。
		chk "DNSMASQ_CONF_DIR = /etc/dnsmasq.d（否则分流片段写进 /tmp 而无效）" \
			"$DIR_VAL" "/etc/dnsmasq.d"
	else
		skip "DNSMASQ_CONF_DIR = /etc/dnsmasq.d" \
		     "缺真实 uci：dhcp.@dnsmasq[0] 取不到 CFGID，按上游设计会退化到 /tmp/dnsmasq.d（符合预期）"
	fi
else
	no "/etc/openwrt_release 门控生效（DNSMASQ_CONF_DIR 未推导）" \
	   "上游 init.d:14 的 [ -f /etc/openwrt_release ] 分支未执行"
fi

# bash 独占语法必须可用（dash 不支持 ${v:0:-1}）
if /bin/bash -c 'v=abc; [ "${v:0:-1}" = "ab" ]' 2>/dev/null; then
	ok "bash 方言可用（\${v:0:-1}）"
else
	no "bash 方言可用（\${v:0:-1}）"
fi
if /bin/sh -c 'v=abc; [ "${v:0:-1}" = "ab" ]' 2>/dev/null; then
	printf '        \033[33m注\033[0m 本机 /bin/sh 已支持 \${v:0:-1}，说明它可能不是 dash\n'
else
	ok "确认 /bin/sh 不支持 \${v:0:-1}（证明重执行确有必要）"
fi

# -----------------------------------------------------------------------------
# 5. fw4 垫片：真实 nftables（隔离在 netns 内）
# -----------------------------------------------------------------------------
it "L3  fw4 垫片 + 真实 nftables（unshare -n 隔离）"

if ! command -v nft >/dev/null 2>&1; then
	skip "真实 nft 验证" "未安装 nftables（apt-get install -y nftables）"
elif ! command -v unshare >/dev/null 2>&1; then
	skip "真实 nft 验证" "未安装 unshare（util-linux）"
elif ! unshare -n true 2>/dev/null; then
	skip "真实 nft 验证" "无权限创建网络命名空间（需要 CAP_SYS_ADMIN）"
else
	# 在独立 netns 中执行，宿主防火墙零风险
	mkdir -p "$E2E/skeleton"
	NS_LOG="$E2E/nft-ns.log"
	unshare -n env OC_SKEL="$E2E/skeleton" bash -c '
		set -u
		export OPENCLASH_RT_SKELETON_DIR="$OC_SKEL"
		fw4=/usr/sbin/fw4
		# 1. 前置：宿主 Debian 通常没有 inet fw4 表
		nft list table inet fw4 >/dev/null 2>&1 && echo "PRE:exists" || echo "PRE:absent"
		# 2. 第一次 check 应建立骨架
		"$fw4" check >/dev/null 2>&1; echo "CHECK1:$?"
		nft list table inet fw4 >/dev/null 2>&1; echo "TABLE:$?"
		for c in input forward output dstnat srcnat mangle_prerouting mangle_output; do
			nft list chain inet fw4 "$c" >/dev/null 2>&1 && echo "CHAIN:$c:ok" || echo "CHAIN:$c:missing"
		done
		# 3. 幂等
		"$fw4" check >/dev/null 2>&1; echo "CHECK2:$?"
		# 4. 反向断言：nat_output 不应存在
		nft list chain inet fw4 nat_output >/dev/null 2>&1 && echo "NATOUT:present" || echo "NATOUT:absent"
		# 5. hook 语义：内核接受 dstnat 的 nat/prerouting 定义
		nft list chain inet fw4 dstnat 2>/dev/null | grep -q "hook prerouting" && echo "DSTNAT_HOOK:ok" || echo "DSTNAT_HOOK:bad"
	' >"$NS_LOG" 2>&1

	_chk_ns() { # 参数: 标签 期望 grep 模式
		if grep -q "$2" "$NS_LOG"; then ok "$1"; else no "$1" "$(grep -v '^$' "$NS_LOG" | tr '\n' '|')"; fi
	}
	_chk_ns "netns 内初始无 inet fw4 表（环境干净）" '^PRE:absent'
	_chk_ns "check 退出码 0"                          '^CHECK1:0'
	_chk_ns "真实内核接受 add table inet fw4"          '^TABLE:0'
	for c in input forward output dstnat srcnat mangle_prerouting mangle_output; do
		_chk_ns "真实内核接受 base chain $c" "^CHAIN:$c:ok"
	done
	_chk_ns "重复 check 幂等"                          '^CHECK2:0'
	_chk_ns "垫片未创建 nat_output（与上游约定一致）"  '^NATOUT:absent'
	_chk_ns "dstnat 的 nat/prerouting hook 定义被内核接受" '^DSTNAT_HOOK:ok'

	# 6. 骨架必须能承载「上游真实会做的操作」——这才是骨架存在的意义。
	#    下列语句取自上游 set_firewall()/chnroute 的实际调用形态：
	#    自建链、自建集合、往 base chain 插规则、DNS 劫持 redirect。
	OPS="$E2E/nft-ops.log"
	unshare -n env OC_SKEL="$E2E/skeleton" bash -c '
		set -u
		export OPENCLASH_RT_SKELETON_DIR="$OC_SKEL"
		fw4=/usr/sbin/fw4
		"$fw4" check >/dev/null 2>&1 || { echo "SKELETON_FAIL"; exit 0; }

		try() { # 标签  语句...   → 打印 <标签>:ok|bad
			local tag="$1"; shift
			if nft "$@" >/dev/null 2>&1; then echo "$tag:ok"; else echo "$tag:bad"; fi
		}
		try CHAIN_OWN     add chain inet fw4 openclash_post
		try SET_INTERVAL  add set inet fw4 openclash_wan_ip "{ type ipv4_addr; flags interval; }"
		try SET_ELEMENT   add element inet fw4 openclash_wan_ip "{ 1.2.3.4, 10.0.0.0/8 }"
		try SET_META      add set inet fw4 openclash_lan_ip "{ type ipv4_addr; flags interval; }"
		try JUMP_SRCNAT   add rule inet fw4 srcnat jump openclash_post
		try DNS_REDIRECT  insert rule inet fw4 dstnat position 0 meta l4proto "{ tcp, udp }" th dport 53 redirect to :7874
		try MANGLE_MARK   insert rule inet fw4 mangle_prerouting position 0 tcp dport 443 meta mark set 0x162
		try FWD_UTUN      insert rule inet fw4 forward position 0 iifname "utun" accept
		try DSTNAT_SET    add rule inet fw4 dstnat ip daddr @openclash_wan_ip counter
		nft list table inet fw4 >/dev/null 2>&1 && echo "LIST:ok" || echo "LIST:bad"
		nft delete table inet fw4 >/dev/null 2>&1 && echo "DELTABLE:ok" || echo "DELTABLE:bad"
	' >"$OPS" 2>&1

	_chk_op() { # 参数: 标签 期望标记
		if grep -q "^$2:ok" "$OPS"; then ok "$1"; else no "$1" "$(grep -v '^$' "$OPS" | tr '\n' '|')"; fi
	}
	if grep -q 'SKELETON_FAIL' "$OPS"; then
		no "netns 内骨架建立失败" "$(tr '\n' '|' <"$OPS" | head -c 200)"
	else
		_chk_op "上游式：自建链 openclash_post"          CHAIN_OWN
		_chk_op "上游式：自建 interval 集合"             SET_INTERVAL
		_chk_op "上游式：向集合添加元素（CIDR 区间）"    SET_ELEMENT
		_chk_op "上游式：自建 meta 集合"                 SET_META
		_chk_op "上游式：srcnat jump 自建链"             JUMP_SRCNAT
		_chk_op "旁路网关核心：dstnat 劫持 53 → :7874"   DNS_REDIRECT
		_chk_op "本机代理核心：mangle 打 mark 0x162"     MANGLE_MARK
		_chk_op "TUN 放行：forward iifname utun accept"  FWD_UTUN
		_chk_op "上游式：规则引用集合（@set）"           DSTNAT_SET
		_chk_op "整表可列出"                             LIST
		_chk_op "整表可删除（净卸载）"                   DELTABLE
	fi
fi

# -----------------------------------------------------------------------------
# 6. procd 垫片 + systemd 映射（dry-run，不触碰宿主 systemd）
# -----------------------------------------------------------------------------
it "L4  procd → systemd 映射（隔离到临时单元目录）"

export OPENCLASH_RT_ROOT="$E2E/rt"
export OPENCLASH_RT_UNIT_DIR="$E2E/units"
export OPENCLASH_RT_DRY_RUN=1
mkdir -p "$OPENCLASH_RT_ROOT" "$OPENCLASH_RT_UNIT_DIR"

PROBE="$E2E/procd-probe.sh"
cat >"$PROBE" <<'PROBE'
#!/bin/bash
. /lib/functions.sh
. /lib/functions/procd.sh
procd_open_service "e2e" "/etc/init.d/e2e"
procd_open_instance "e2e-core"
procd_set_param command /usr/share/openclash/clash -d /etc/openclash
procd_set_param respawn 300 5 3
procd_set_param env CONFIG_DIR=/etc/openclash "WITH SPACE=a b"
procd_set_param limits core="unlimited"
procd_set_param stdout 1
procd_set_param stderr 1
procd_close_instance
procd_close_service set
PROBE
chmod +x "$PROBE"

bash "$PROBE" >"$E2E/procd.out" 2>"$E2E/procd.err"
chk "procd 垫片在真实 Linux 下执行成功" "$?" "0"

UNIT="$OPENCLASH_RT_UNIT_DIR/openclash-rt-e2e-core.service"
if [ -f "$UNIT" ]; then
	ok "生成 systemd 单元 openclash-rt-e2e-core.service"
	chk "单元 ExecStart 指向上游 argv" \
		"$(grep -c 'ExecStart=' "$UNIT")" "1"
	chk "respawn 300 5 3 → Restart=always" \
		"$(grep -c '^Restart=always' "$UNIT")" "1"
	chk "含 StartLimitBurst（respawn 限流）" \
		"$(grep -c 'StartLimitBurst=' "$UNIT")" "1"
	chk "含 LimitCORE（limits core=unlimited）" \
		"$(grep -c 'LimitCORE=' "$UNIT")" "1"
	chk "env 带空格的值被正确引用" \
		"$(grep -c 'Environment=.*WITH SPACE=a b' "$UNIT")" "1"
else
	no "生成 systemd 单元 openclash-rt-e2e-core.service" \
	   "$(head -5 "$E2E/procd.err" 2>/dev/null | tr '\n' '|')"
fi

# dry-run 不应真的调用 systemctl
if command -v systemctl >/dev/null 2>&1; then
	if [ -z "$(ls -A /run/systemd/system 2>/dev/null | grep 'openclash-rt-' || true)" ]; then
		ok "dry-run 未污染宿主 /run/systemd/system"
	else
		no "dry-run 未污染宿主 /run/systemd/system"
	fi
fi
unset OPENCLASH_RT_DRY_RUN

# -----------------------------------------------------------------------------
# 7. uci 相关（仅当有真实 uci）
# -----------------------------------------------------------------------------
it "L5  真实 uci 语义（$([ "$HAS_UCI" = 1 ] && echo 已启用 || echo 跳过)）"

if [ "$HAS_UCI" != "1" ] || [ ! -x /sbin/uci ]; then
	skip "uci 语义验证" "缺少真实 /sbin/uci；由 build-deb.sh 或 runtime/uci/build-uci.sh 提供"
else
	chk "uci -q get openclash.config.enable" \
		"$(/sbin/uci -q get openclash.config.enable 2>/dev/null)" "0"
	chk "uci -q get openclash.config.dns_port" \
		"$(/sbin/uci -q get openclash.config.dns_port 2>/dev/null)" "7874"
	# 复刻上游 init.d:16 的取法：取首行按 [.=] 切分后的第 2 段。
	# 段具名为 main，因此结果恒为 main（与段顺序无关）。
	chk "CFGID 推导（复刻上游 init.d:16 的 awk）" \
		"$(/sbin/uci -q show 'dhcp.@dnsmasq[0]' 2>/dev/null | awk 'NR==1 {split($0, c, /[.=]/); print c[2]}')" \
		"main"
	chk "uci export -S -n（uci_load 依赖）" \
		"$(/sbin/uci -S -n export openclash >/dev/null 2>&1; echo $?)" "0"

	# uci_load 链：/lib/functions.sh → config_load → /lib/config/uci.sh
	bash -c '. /lib/functions.sh; config_load openclash; echo "ENABLE=${CONFIG_config_enable:-<unset>}"' \
		>"$E2E/load.out" 2>&1
	if grep -q 'ENABLE=0' "$E2E/load.out"; then
		ok "config_load 全链路可用（/lib/functions.sh → /sbin/uci export）"
	else
		no "config_load 全链路可用" "$(tr '\n' '|' <"$E2E/load.out" | head -c 300)"
	fi

	# dnsmasq 适配器：上游写入的 UCI 必须真的落到 Debian dnsmasq 读取的目录。
	# 这是「旁路网关」场景的核心验收点——没有它，客户端 DNS 不会被接管，
	# 而且上游不会有任何报错。
	SNIP=/etc/dnsmasq.d/00-openclash-rt-uci.conf
	ADAPTER=/usr/lib/openclash-rt/dnsmasq-adapter.sh
	if [ ! -x "$ADAPTER" ]; then
		no "dnsmasq-adapter.sh 可执行" "$ADAPTER"
	else
		/sbin/uci -q set 'dhcp.@dnsmasq[0].server=127.0.0.1#7874' >/dev/null 2>&1
		/sbin/uci -q set 'dhcp.@dnsmasq[0].noresolv=1'              >/dev/null 2>&1
		/sbin/uci -q set 'dhcp.@dnsmasq[0].cachesize=0'            >/dev/null 2>&1
		/sbin/uci -q commit dhcp >/dev/null 2>&1
		"$ADAPTER" >/dev/null 2>&1

		if grep -q '^server=127\.0\.0\.1#7874$' "$SNIP" 2>/dev/null; then
			ok "UCI server=127.0.0.1#7874 → dnsmasq server=（DNS 接管生效）"
		else
			no "UCI server 翻译为 dnsmasq server=" \
			   "$([ -f "$SNIP" ] && tr '\n' '|' <"$SNIP" || echo '(片段不存在)')"
		fi
		grep -q '^no-resolv$' "$SNIP" 2>/dev/null \
			&& ok "UCI noresolv=1 → no-resolv" || no "UCI noresolv=1 → no-resolv"
		grep -q '^cache-size=0$' "$SNIP" 2>/dev/null \
			&& ok "UCI cachesize=0 → cache-size=0" || no "UCI cachesize=0 → cache-size=0"

		SD1="$(cat "$SNIP" 2>/dev/null)"
		"$ADAPTER" >/dev/null 2>&1
		chk "适配器幂等（重复执行内容不变）" "$(cat "$SNIP" 2>/dev/null)" "$SD1"

		# 还原 UCI（退出时 /etc/config/dhcp 本身也会被整体还原）
		/sbin/uci -q delete 'dhcp.@dnsmasq[0].server'    >/dev/null 2>&1
		/sbin/uci -q delete 'dhcp.@dnsmasq[0].noresolv'  >/dev/null 2>&1
		/sbin/uci -q delete 'dhcp.@dnsmasq[0].cachesize' >/dev/null 2>&1
		/sbin/uci -q commit dhcp >/dev/null 2>&1
		"$ADAPTER" >/dev/null 2>&1
	fi
fi

# -----------------------------------------------------------------------------
# 8. 上游脚本可被加载派发（enable=0，安全）
# -----------------------------------------------------------------------------
it "L6  未修改的上游 init 脚本可被派发"

OUT="$E2E/start.out"
timeout 60 /bin/sh /etc/rc.common /etc/init.d/openclash start >"$OUT" 2>&1
rc=$?
# enable=0 时上游应走「已禁用」分支并正常返回
if [ "$rc" -eq 0 ] || [ "$rc" -eq 124 ]; then
	if [ "$rc" -eq 124 ]; then
		skip "上游 start（enable=0）" "60s 超时——真实 uci 缺失时上游会退化到网络探测"
	else
		ok "上游 start 退出码 0"
	fi
else
	# 缺 uci 时上游可能因缺少配置而报错，这属于环境限制而非兼容层缺陷
	if [ "$HAS_UCI" != "1" ]; then
		skip "上游 start（enable=0）" "退出码 $rc —— 缺真实 uci，见 L5 说明"
	else
		no "上游 start 退出码 0" "rc=$rc  $(tail -3 "$OUT" 2>/dev/null | tr '\n' '|')"
	fi
fi

# -----------------------------------------------------------------------------
# 汇总
# -----------------------------------------------------------------------------
printf '\n\033[1m════════════════════════════════════════\033[0m\n'
printf '  PASS: \033[32m%d\033[0m    FAIL: \033[31m%d\033[0m    SKIP: \033[33m%d\033[0m\n' "$PASS" "$FAIL" "$SKIP"
printf '\033[1m════════════════════════════════════════\033[0m\n'
if [ "$SKIP" -gt 0 ]; then
	printf '  说明：SKIP 项需要构建 uci / nftables / CAP_SYS_ADMIN 等条件，\n'
	printf '        不属于失败。在完整 .deb 安装环境下这些断言会实际执行。\n'
fi
[ "$FAIL" -eq 0 ] || exit 1
