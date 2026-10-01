#!/usr/bin/env bash
# =============================================================================
# openclash-rt  /etc/openwrt_release 生成器
# -----------------------------------------------------------------------------
# 为什么必须有这个文件：
#   上游 `etc/init.d/openclash:14` 用一行 `[ -f /etc/openwrt_release ]` **门控**
#   整段 DNSMASQ_CONF_DIR 推导。文件不存在 → 直接走 else → 静默降级到
#   /tmp/dnsmasq.d（Debian 的 dnsmasq 不读那里）→ 分流规则全部失效且无报错。
#
#   这是「把上游的探测喂成真」范式的第一个实例：不去改上游那个 if，
#   而是把 if 探测的东西真的造出来。
#
# -----------------------------------------------------------------------------
# 更关键的一件事：DISTRIB_ARCH
#   内核架构的完整来源链是：
#
#     /etc/openwrt_release:DISTRIB_ARCH
#         │  （上游 root/etc/uci-defaults/luci-openclash:79-124 的 case）
#         ▼
#     openclash.config.core_version
#         │  （openclash_core.sh:53  CPU_MODEL=$(uci_get_config "core_version")）
#         ▼
#     内核下载 URL 里的架构段
#
#   也就是说 DISTRIB_ARCH 一旦取错值，上游的 case 会落到 `*)` 分支把
#   CORE_ARCH 置为字面量 "0"，**内核下载链接直接是错的**，而界面上只表现为
#   「下载失败」。用户能在 UI 里手工改 core_version 兜住，但那不是 100% 复刻。
#
# -----------------------------------------------------------------------------
# DISTRIB_ARCH 是「翻译」，不是「伪装」
#   我们把它写成 OpenWrt 的架构词汇（x86_64 / aarch64_generic / arm_cortex-a7 …），
#   因为上游只把它当**枚举**用，取值域就是 OpenWrt 的那套。把 Debian 的
#   dpkg 架构忠实翻译进这个取值域，才能让上游自己的映射表算出正确结果。
#
#   同理 DISTRIB_ID 保持诚实（不写 OpenWrt）：将来上游若加
#   `[ "$DISTRIB_ID" = "OpenWrt" ]` 之类的门控，我们希望它走「非 OpenWrt」分支。
#
# -----------------------------------------------------------------------------
# 读取方（已核实，全上游只有两处真正消费该文件）：
#   1. luasrc/controller/openclash.lua:184  rel:match("DISTRIB_ARCH='([^']+)'")
#      ← 用**单引号**做模式匹配，所以值必须带单引号，格式必须与 OpenWrt 一致
#   2. root/usr/share/openclash/openclash_history_get.sh:43  source "/etc/openwrt_release"
#      ← 用 shell source 读取，所以必须是合法的 shell 赋值
#
# 用法：
#   openwrt-release.sh              # 写入 /etc/openwrt_release（幂等）
#   openwrt-release.sh --print      # 只打印，不落盘
#   openwrt-release.sh --core-arch  # 只打印上游映射出的 CORE_ARCH（用于断言）
#   openwrt-release.sh --check      # 校验已存在的文件是否与当前架构一致
#
# 环境变量：
#   OPENCLASH_RT_ROOT_PREFIX  写入路径前缀，默认空（真实绝对路径），仅测试用
#   OPENCLASH_RT_DPKG         指定 dpkg 路径（测试可注入假实现）
#   OPENCLASH_RT_UNAME        指定 uname 路径（测试可注入假实现）
#   OPENCLASH_RT_DPKG_ARCH    直接指定目标架构，跳过探测。
#                             供**交叉打包**使用：build-deb.sh 在 amd64 上打 arm64 包时，
#                             必须按目标架构生成 DISTRIB_ARCH，而不是按构建机架构。
# =============================================================================
set -u

LOG_TAG="openclash-rt/openwrt-release"
R="${OPENCLASH_RT_ROOT_PREFIX:-}"
OUT="$R/etc/openwrt_release"
DPKG="${OPENCLASH_RT_DPKG:-}"
UNAME_BIN="${OPENCLASH_RT_UNAME:-uname}"

MODE="${1:-apply}"

log()  { printf '%s: %s\n' "$LOG_TAG" "$*" >&2; }
warn() { printf '%s: 警告: %s\n' "$LOG_TAG" "$*" >&2; }

# -----------------------------------------------------------------------------
# 1. 探测宿主架构
# -----------------------------------------------------------------------------
# 优先 dpkg（Debian/Ubuntu 上最权威）；不可用再退到 uname；再退到 /proc/cpuinfo。
_dpkg_arch() {
	# 交叉打包：调用方直接指定目标架构，跳过一切探测
	if [ -n "${OPENCLASH_RT_DPKG_ARCH:-}" ]; then
		printf '%s' "$OPENCLASH_RT_DPKG_ARCH"
		return 0
	fi
	local d="$DPKG"
	if [ -z "$d" ]; then
		if command -v dpkg >/dev/null 2>&1; then d="$(command -v dpkg)"; fi
	fi
	if [ -n "$d" ] && [ -x "$d" ]; then
		"$d" --print-architecture 2>/dev/null | head -1 | tr -d '\r\n '
	fi
}

_uname_m() { "$UNAME_BIN" -m 2>/dev/null | tr -d '\r\n '; }

# 从 /proc/cpuinfo 粗略判断 ARM 版本（用于 armhf 区分 armv7 / armv6）
_arm_cpu_version() {
	local f="$R/proc/cpuinfo"
	[ -r "$f" ] || f="/proc/cpuinfo"
	[ -r "$f" ] || return 1
	# 树莓派等会给出 "ARMv6" / "ARMv7 Processor rev"
	awk -F: '/^CPU architecture|^model name|^Processor/ {
		gsub(/^[ \t]+|[ \t]+$/, "", $2)
		if ($2 ~ /ARMv6|armv6/) { print 6; exit }
		if ($2 ~ /ARMv7|armv7/) { print 7; exit }
		if ($2 ~ /ARMv8|armv8|aarch64/) { print 8; exit }
	}' "$f" 2>/dev/null
}

# -----------------------------------------------------------------------------
# 2. dpkg 架构 → OpenWrt DISTRIB_ARCH
# -----------------------------------------------------------------------------
# 右列的取值必须落在上游 case 的**匹配分支**上，否则落到 `*)` → CORE_ARCH=0。
# 每个分支后面标注的是上游 case 里匹配它的那个 glob。
_map_debian_arch() {
	local darch="$1"
	local um; um="$(_uname_m)"

	case "$darch" in
		amd64)   printf 'x86_64' ;;                # x86_64            -> linux-amd64-v1
		arm64)   printf 'aarch64_generic' ;;       # aarch64_*         -> linux-arm64
		armhf)
			# Debian armhf 最低 ARMv7，但 Raspbian 的 armhf 在 Pi 1/Zero 上是 ARMv6。
			# 用 /proc/cpuinfo 区分，避免把 ARMv6 板子错映射成 armv7 内核。
			local v; v="$(_arm_cpu_version || true)"
			case "$v" in
				6) printf 'arm_arm1176jzf-s' ;;    # arm_arm1176jzf-s* -> linux-armv6
				*) printf 'arm_cortex-a7' ;;       # arm_cortex-a7     -> linux-armv7
			esac
			;;
		armel)   printf 'arm_arm926ej-s' ;;        # arm*              -> linux-armv5
		i386)    printf 'i386_generic' ;;          # i386_*            -> linux-386
		riscv64) printf 'riscv64_generic' ;;       # riscv64*          -> linux-riscv64
		loong64) printf 'loongarch64_generic' ;;   # loongarch64*      -> linux-loong64-abi2
		mipsel)  printf 'mipsel_24kc' ;;           # mipsel_*          -> linux-mipsle-softfloat
		mips64el) printf 'mips64el_cortex-a53' ;;  # mips64el_*        -> linux-mips64le
		mips)    printf 'mips_24kc' ;;             # mips_*            -> linux-mips-softfloat
		"")
			# dpkg 不可用，只能用 uname
			_map_uname_arch "$um"
			;;
		*)
			# 有 dpkg 但架构不在表里，再试 uname，都失败则返回空
			local u; u="$(_map_uname_arch "$um")"
			if [ -n "$u" ]; then printf '%s' "$u"; fi
			;;
	esac
}

_map_uname_arch() {
	case "$1" in
		x86_64|amd64)     printf 'x86_64' ;;
		aarch64|arm64)    printf 'aarch64_generic' ;;
		armv7l|armv7*)    printf 'arm_cortex-a7' ;;
		armv6l|armv6*)    printf 'arm_arm1176jzf-s' ;;
		armv5*|arm*)      printf 'arm_arm926ej-s' ;;
		i?86)             printf 'i386_generic' ;;
		riscv64)          printf 'riscv64_generic' ;;
		loongarch64)      printf 'loongarch64_generic' ;;
		mips)             printf 'mips_24kc' ;;
		mips64el)         printf 'mips64el_cortex-a53' ;;
		mipsel)           printf 'mipsel_24kc' ;;
		*)                printf '' ;;
	esac
}

# -----------------------------------------------------------------------------
# 3. DISTRIB_ARCH → CORE_ARCH（上游 uci-defaults:80-123 的 case，逐字转写）
# -----------------------------------------------------------------------------
# 这是**校验用的镜像实现**，唯一目的是让我们能在安装期就告诉用户
# 「你的架构会被映射成哪个内核」，而不是等他在 UI 里点下载才发现失败。
# 任何情况下都不要用它去写 core_version —— 那是上游的职责。
_core_arch_of() {
	case "$1" in
		aarch64_*)          printf 'linux-arm64' ;;
		armeb_*)            printf '0' ;;
		arm_cortex-a5|arm_cortex-a5[^0-9]*|arm_cortex-a7|arm_cortex-a7[^0-9]*|arm_cortex-a8*|arm_cortex-a9*|arm_cortex-a12*|arm_cortex-a15*|arm_cortex-a17*)
		                    printf 'linux-armv7' ;;
		arm_arm1176jzf-s*|arm_arm1136*|arm_mpcore*)
		                    printf 'linux-armv6' ;;
		arm*)               printf 'linux-armv5' ;;
		i386_*)             printf 'linux-386' ;;
		mips64el_*)         printf 'linux-mips64le' ;;
		mips64_*)           printf 'linux-mips64' ;;
		mips_*)             printf 'linux-mips-softfloat' ;;
		mipsel_*)           printf 'linux-mipsle-softfloat' ;;
		riscv64*)           printf 'linux-riscv64' ;;
		loongarch64*|loongarch_*) printf 'linux-loong64-abi2' ;;
		x86_64)             printf 'linux-amd64-v1' ;;
		*)                  printf '0' ;;
	esac
}

# DISTRIB_TARGET 仅作装饰（上游不消费），写成与 OpenWrt 同形即可
_target_of() {
	case "$1" in
		x86_64)             printf 'x86/64' ;;
		aarch64_generic)    printf 'armvirt/64' ;;
		arm_cortex-a7)      printf 'armvirt/32' ;;
		arm_arm1176jzf-s)   printf 'bcm27xx/bcm2708' ;;
		arm_arm926ej-s)     printf 'armvirt/32' ;;
		i386_generic)       printf 'x86/generic' ;;
		riscv64_generic)    printf 'riscv64/generic' ;;
		loongarch64_generic) printf 'loongarch64/generic' ;;
		mips_24kc)          printf 'ath79/generic' ;;
		mipsel_24kc)        printf 'ramips/mt7621' ;;
		mips64el_cortex-a53) printf 'malta/le64' ;;
		*)                  printf 'generic/generic' ;;
	esac
}

# -----------------------------------------------------------------------------
# 4. 组装
# -----------------------------------------------------------------------------
DARCH="$(_dpkg_arch)"
OARCH="$(_map_debian_arch "$DARCH")"
UM="$(_uname_m)"

if [ -z "$OARCH" ]; then
	warn "无法把宿主架构映射到 OpenWrt 架构（dpkg='$DARCH' uname='$UM'）"
	warn "内核架构将落到上游的兜底分支 → CORE_ARCH=0，内核无法自动下载"
	warn "请安装后在 Web UI 的「内核」处手工选择架构"
	OARCH="unknown"
fi

CORE="$(_core_arch_of "$OARCH")"
TARGET="$(_target_of "$OARCH")"

# Debian 版本号仅作展示
DREL="unknown"
for f in "$R/etc/os-release" /etc/os-release; do
	if [ -r "$f" ]; then
		DREL="$(sed -n 's/^VERSION_ID="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' "$f" | head -1)"
		[ -n "$DREL" ] && break
	fi
done
[ -n "$DREL" ] || DREL="unknown"

# REVISION 刻意用**稳定值**而不是构建时间：
#   带 date 会让同样的输入产出不同字节，.deb 失去可复现性，也会让幂等检查
#   （cmp -s）在同一天之外永远判定为"变化"。构建时间另有记录处：
#   /usr/lib/openclash-rt/upstream-version。
REV="${OPENCLASH_RT_REVISION:-r0}"

# ⚠️ 所有值都带**单引号**：上游 luci.openclash 之外，controller 用
#    `rel:match("DISTRIB_ARCH='([^']+)'")` 取值，不带引号会匹配失败。
#    同时这也与 OpenWrt 自身的 /etc/openwrt_release 格式一致。
_gen() {
	printf "DISTRIB_ID='openclash-rt'\n"
	printf "DISTRIB_RELEASE='%s'\n" "$DREL"
	printf "DISTRIB_REVISION='%s'\n" "$REV"
	printf "DISTRIB_TARGET='%s'\n" "$TARGET"
	printf "DISTRIB_ARCH='%s'\n" "$OARCH"
	printf "DISTRIB_DESCRIPTION='openclash-rt (Debian/Ubuntu) %s'\n" "$OARCH"
	printf "DISTRIB_TAINTS=''\n"
}

case "$MODE" in
	--print)
		_gen
		exit 0
		;;
	--core-arch)
		printf '%s\n' "$CORE"
		exit 0
		;;
	--check)
		# 校验已落盘的文件是否与本机当前架构一致（架构变了 / 换了机器时会不一致）
		if [ ! -f "$OUT" ]; then
			warn "$OUT 不存在 —— 上游会静默降级 DNSMASQ_CONF_DIR"
			exit 1
		fi
		CUR="$(sed -n "s/^DISTRIB_ARCH='\([^']*\)'.*/\1/p" "$OUT" | head -1)"
		if [ "$CUR" = "$OARCH" ]; then
			log "DISTRIB_ARCH=$CUR 与本机一致（CORE_ARCH=$CORE）"
			exit 0
		fi
		warn "$OUT 中的 DISTRIB_ARCH='$CUR' 与本机应为的 '$OARCH' 不一致"
		warn "请执行： $0   （或重新安装本包）"
		exit 1
		;;
esac

# -----------------------------------------------------------------------------
# 5. 落盘（幂等；临时文件同目录，不依赖 mktemp/TMPDIR）
# -----------------------------------------------------------------------------
mkdir -p "$R/etc" 2>/dev/null || true
TMP="$OUT.tmp.$$"
trap 'rm -f "$TMP" 2>/dev/null' EXIT INT TERM

if ! _gen >"$TMP"; then
	rm -f "$TMP" 2>/dev/null
	log "生成 $OUT 失败"
	exit 1
fi

if [ -f "$OUT" ] && cmp -s "$TMP" "$OUT"; then
	rm -f "$TMP" 2>/dev/null
	log "内容无变化，跳过落盘"
else
	mv -f "$TMP" "$OUT" 2>/dev/null || cp -f "$TMP" "$OUT" 2>/dev/null || {
		log "写入 $OUT 失败"
		exit 1
	}
	chmod 0644 "$OUT" 2>/dev/null || true
	log "已写入 $OUT"
fi

log "架构映射: dpkg=${DARCH:-?} uname=${UM:-?} -> DISTRIB_ARCH=$OARCH -> CORE_ARCH=$CORE"

if [ "$CORE" = "0" ]; then
	warn "上游会把 CORE_ARCH 判为 0 —— 该架构没有可自动下载的内核"
	warn "需要手工放置内核到 /etc/openclash/core/clash_meta 并在 UI 中指定架构"
fi

exit 0
