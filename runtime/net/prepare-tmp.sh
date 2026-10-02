#!/usr/bin/env bash
# =============================================================================
# openclash-rt  易失路径准备（幂等，可反复执行）
# -----------------------------------------------------------------------------
# 上游 OpenClash 在 OpenWrt 上可以直接假定以下路径**已经存在**，因为它们由
# netifd / dnsmasq 初始化脚本 / procd 维护：
#
#   /tmp/etc/dnsmasq.conf.<CFGID>         ← dnsmasq 初始化脚本生成
#   /tmp/resolv.conf.d/resolv.conf.auto   ← netifd 从上游 DHCP 学到的 DNS
#   /tmp/resolv.conf.auto
#   /etc/crontabs/root                    ← OpenWrt 的 cron 实现
#   /tmp/dnsmasq.d/
#
# 在 Debian/Ubuntu 上没有任何组件会创建它们。若缺失，上游会出现两类**静默降级**：
#
#   1. DNSMASQ_CONF_DIR 退化为 /tmp/dnsmasq.d（init.d:17-21）
#      → 上游写出的 dnsmasq 分流片段落在 /tmp，而 Debian 的 dnsmasq 只读
#        /etc/dnsmasq.d/，**分流规则静默失效**。
#   2. resolvfile 与上游 DNS 探测失败（init.d:255-269）
#      → dnsmasq 指向错误的上级 DNS。
#
# 本脚本把这些前提补上。它是「喂给上游它期待的环境」这一策略的核心一环，
# 不改上游一行代码。
#
# 用法：
#   prepare-tmp.sh              # 幂等准备（由 openclash.service 的 ExecStartPre 调用）
#   OPENCLASH_RT_ROOT_PREFIX=/tmp/root prepare-tmp.sh   # 沙箱化（单测用）
#
# 环境变量：
#   OPENCLASH_RT_ROOT_PREFIX     所有写入路径的前缀。默认空，即真实绝对路径。
#                                语义与 OpenWrt 自己的 IPKG_INSTROOT 一致，
#                                仅用于测试；生产环境必须留空。
#   OPENCLASH_RT_RESOLV_SRC      上级 DNS 来源文件，默认 /etc/resolv.conf
#   OPENCLASH_RT_DNSMASQ_DIR     dnsmasq 的 conf-dir，默认 /etc/dnsmasq.d
#   OPENCLASH_RT_DNSMASQ_CFGID   推导用的段 ID，默认 main（见下方说明）
#   OPENCLASH_RT_FALLBACK_DNS    提取不到非回环 DNS 时的兜底
#   OPENCLASH_RT_ADAPTER         dnsmasq 适配器路径，默认 /usr/lib/openclash-rt/dnsmasq-adapter.sh
# =============================================================================
set -u

LOG_TAG="openclash-rt/prepare-tmp"

# R 为空时所有路径即真实绝对路径。非空时仅用于测试隔离。
R="${OPENCLASH_RT_ROOT_PREFIX:-}"
RESOLV_SRC="${OPENCLASH_RT_RESOLV_SRC:-$R/etc/resolv.conf}"
DNSMASQ_DIR="${OPENCLASH_RT_DNSMASQ_DIR:-$R/etc/dnsmasq.d}"
DNSMASQ_CFGID="${OPENCLASH_RT_DNSMASQ_CFGID:-main}"
FALLBACK_DNS="${OPENCLASH_RT_FALLBACK_DNS:-223.5.5.5 119.29.29.29}"
ADAPTER="${OPENCLASH_RT_ADAPTER:-$R/usr/lib/openclash-rt/dnsmasq-adapter.sh}"

log() { printf '%s: %s\n' "$LOG_TAG" "$*" >&2; }

# -----------------------------------------------------------------------------
# 1. 让上游把 DNSMASQ_CONF_DIR 推导到 Debian 真实生效的目录
# -----------------------------------------------------------------------------
# 上游 init.d:16-22 的逻辑：
#   CFGID=$(uci -q show "dhcp.@dnsmasq[0]" | awk 'NR==1 {split($0,c,/[.=]/); print c[2]}')
#   if [ -f "/tmp/etc/dnsmasq.conf.$CFGID" ]; then
#       DNSMASQ_CONF_DIR=$(awk -F= '/^conf-dir=/ {print $2}' "/tmp/etc/dnsmasq.conf.$CFGID")
#   else
#       DNSMASQ_CONF_DIR="/tmp/dnsmasq.d"        # ← 我们要避免的降级
#   fi
#   DNSMASQ_CONF_DIR=${DNSMASQ_CONF_DIR%*/}      # ← 去掉尾部斜杠
#
# --- 为什么 CFGID 是 "main" ---------------------------------------------------
# CFGID 来自 `uci show dhcp.@dnsmasq[0]` 首行按 [.=] 切分后的第 2 段。
# 若段是**匿名**的，首行是 `dhcp.@dnsmasq[0]=dnsmasq`，CFGID 就是字面量
# `@dnsmasq[0]` —— 一旦有别的 dnsmasq 段插到前面，索引就会漂移，
# 预生成的文件名随之失配，导出静默降级。
# 因此本项目的 /etc/config/dhcp 把该段**具名**为 main：
#   config dnsmasq 'main'
# 于是首行恒为 `dhcp.main=dnsmasq`，CFGID 恒为 main，与段顺序无关。
#
# --- 为什么 conf-dir 不带尾斜杠、不带通配符 --------------------------------
# 上游最后会做 ${DNSMASQ_CONF_DIR%*/}，它只剥离**尾部**的 `/`：
#   conf-dir=/etc/dnsmasq.d      -> /etc/dnsmasq.d     ✓
#   conf-dir=/etc/dnsmasq.d/     -> /etc/dnsmasq.d     ✓
#   conf-dir=/etc/dnsmasq.d/,*.conf -> /etc/dnsmasq.d/,*.conf   ✗ 无法被修正
# 最后一种写法会得到一个非法目录名。这里采用与 OpenWrt 的 dnsmasq 初始化脚本
# **完全相同**的产物形态（单目录、无尾斜杠），使 %*/ 成为无害的 no-op。
mkdir -p "$R/tmp/etc" 2>/dev/null || true
printf 'conf-dir=%s\n' "$DNSMASQ_DIR" >"$R/tmp/etc/dnsmasq.conf.$DNSMASQ_CFGID"
log "写入 $R/tmp/etc/dnsmasq.conf.$DNSMASQ_CFGID -> conf-dir=$DNSMASQ_DIR"

# 兜底目录：万一上游仍走到 else 分支，至少它写的文件不会凭空消失
mkdir -p "$R/tmp/dnsmasq.d" "$DNSMASQ_DIR" 2>/dev/null || true

# -----------------------------------------------------------------------------
# 2. resolv.conf 镜像
# -----------------------------------------------------------------------------
# 上游 init.d:261-269 的优先级：
#   /tmp/resolv.conf.d/resolv.conf.auto  →  /tmp/resolv.conf.auto
# 两者都要求「文件非空且含 nameserver」。
#
# Debian 上 /etc/resolv.conf 可能由 systemd-resolved 管理，只含 127.0.0.53。
# 回环地址对 dnsmasq 无意义（会形成自环），必须过滤掉。
_mirror_resolv() {
	local out="$1"
	local tmp="$out.tmp.$$"
	: >"$tmp"

	if [ -r "$RESOLV_SRC" ]; then
		# 只取非回环 nameserver，保留 IPv4/IPv6，去掉 scoped 后缀（%eth0）
		awk '
			/^[[:space:]]*nameserver[[:space:]]+/ {
				a = $2
				sub(/%.*$/, "", a)
				if (a ~ /^127\./ || a == "::1" || a == "0.0.0.0") next
				print "nameserver " a
			}
		' "$RESOLV_SRC" >>"$tmp" 2>/dev/null || true
	fi

	if [ ! -s "$tmp" ]; then
		log "$RESOLV_SRC 中未找到可用的非回环 nameserver，使用兜底: $FALLBACK_DNS"
		local ns
		for ns in $FALLBACK_DNS; do
			printf 'nameserver %s\n' "$ns" >>"$tmp"
		done
	fi

	mv -f "$tmp" "$out" 2>/dev/null || cp -f "$tmp" "$out" 2>/dev/null || true
	rm -f "$tmp" 2>/dev/null || true
}

mkdir -p "$R/tmp/resolv.conf.d" 2>/dev/null || true
_mirror_resolv "$R/tmp/resolv.conf.d/resolv.conf.auto"
# 更旧的上游版本 / 某些分支只认这一个路径
_mirror_resolv "$R/tmp/resolv.conf.auto"
log "已镜像上游 DNS: $(tr '\n' ' ' <"$R/tmp/resolv.conf.d/resolv.conf.auto" 2>/dev/null)"

# -----------------------------------------------------------------------------
# 3. cron 文件
# -----------------------------------------------------------------------------
# 上游 CRON_FILE=/etc/crontabs/root，并用标准 crontab(1) 安装：
#     crontab /etc/crontabs/root
# `tail -n1 /etc/crontabs/root` 在文件不存在时会往 stderr 报错，
# 预先创建空文件可消除这类噪声（上游自己在写入前也会补换行，见 init.d:37）。
mkdir -p "$R/etc/crontabs" 2>/dev/null || true
[ -f "$R/etc/crontabs/root" ] || : >"$R/etc/crontabs/root"

# -----------------------------------------------------------------------------
# 3b. flock 锁目录
# -----------------------------------------------------------------------------
# 上游 15 个脚本用 `exec 8xx>/tmp/lock/<name>.lock` + `flock -x 8xx` 做互斥，
# 目录本身在 OpenWrt 上由 procd/tmpfiles.d 自动创建，Debian 没有。缺失时
# exec 重定向报 "No such file or directory"，flock 报 "Bad file descriptor"
# —— 锁失效（但主流程因锁失败仍继续，属静默降级，订阅/内核下载照常成功）。
# 补上目录让锁真正生效。
mkdir -p "$R/tmp/lock" 2>/dev/null || true

# -----------------------------------------------------------------------------
# 4. core 软链（core 本体由用户在 Web UI 中自行下载）
# -----------------------------------------------------------------------------
mkdir -p "$R/etc/openclash/core" "$R/etc/openclash/custom" 2>/dev/null || true
if [ ! -e "$R/etc/openclash/clash" ] && [ -e "$R/etc/openclash/core/clash_meta" ]; then
	ln -sf "$R/etc/openclash/core/clash_meta" "$R/etc/openclash/clash" 2>/dev/null || true
fi

# -----------------------------------------------------------------------------
# 5. 日志文件（上游会 >> 追加，部分分支先判 -s）
# -----------------------------------------------------------------------------
for f in "$R/tmp/openclash.log" "$R/tmp/openclash_start.log"; do
	[ -f "$f" ] || : >"$f"
done

# -----------------------------------------------------------------------------
# 6. UCI → dnsmasq 配置翻译
# -----------------------------------------------------------------------------
# 上游把 DNS 目标写进 dhcp.@dnsmasq[0]，Debian 的 dnsmasq 不读 UCI。
# 适配器负责翻译；这里同步一次，保证「服务启动」这一刻配置是新的。
# 服务运行期间的变化由 openclash-rt-dnsmasq-sync.path 兜住。
if [ -x "$ADAPTER" ]; then
	OPENCLASH_RT_DNSMASQ_DIR="$DNSMASQ_DIR" "$ADAPTER" || \
		log "dnsmasq 适配器返回非零（不阻断启动）"
fi

log "完成"
exit 0
