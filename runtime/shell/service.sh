#!/bin/sh
# =============================================================================
# OpenClash-RT  /lib/functions/service.sh 兼容桩
# -----------------------------------------------------------------------------
# OpenWrt 的 rc.common 会无条件 source 本文件。原版实现的是「legacy service」
# 系列函数（service_start / service_stop / service_reload / service_kill），
# 它们的底层是 ubus + procd。
#
# 经核对，上游 OpenClash 的 shell 代码 **从未调用** legacy service 系列函数
# （grep 全仓仅命中 openclash_update.sh 中一个同名局部变量 service_started），
# 因此这里只需提供与原版签名一致的薄封装，避免 rc.common 加载失败即可。
#
# 若未来上游开始使用，这些函数可以直接转调到 procd 垫片。
# =============================================================================

service_check() {
	local name="$1"
	[ -z "$name" ] && return 1
	procd_running "$name"
}

service_start() {
	local name="$1"
	[ -z "$name" ] && return 1
	[ -x "/etc/init.d/$name" ] || return 1
	/etc/init.d/"$name" start
}

service_stop() {
	local name="$1"
	[ -z "$name" ] && return 1
	[ -x "/etc/init.d/$name" ] || return 1
	/etc/init.d/"$name" stop
}

service_reload() {
	local name="$1"
	[ -z "$name" ] && return 1
	[ -x "/etc/init.d/$name" ] || return 1
	/etc/init.d/"$name" reload
}

service_kill() {
	local name="$1"
	local instance="$2"
	[ -z "$name" ] && return 1
	procd_kill "$name" "$instance"
}

service_running() {
	local name="$1"
	[ -z "$name" ] && return 1
	procd_running "$name"
}
