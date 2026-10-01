#!/bin/sh
# =============================================================================
# OpenClash-RT  procd compatibility shim
# -----------------------------------------------------------------------------
# 目标：让上游 OpenClash 的 /etc/init.d/openclash 在不修改一行的前提下，
#       在 Debian/Ubuntu (systemd) 上获得与 OpenWrt procd 等价的服务管理语义。
#
# 上游实际用到的 procd API 面（已逐一核对源码，共 3 个文件 14 处调用）：
#   procd_open_instance <name>
#   procd_set_param <type> <value...>     env/command/user/group/limits/respawn/stderr/no_new_privs
#   procd_append_param <type> <value...>  env
#   procd_close_instance
#   procd_running <service> [instance]
#   procd_kill <service> [instance]
#   procd_send_signal <service> <instance> <signal>
# 以及 rc.common 需要的：
#   procd_open_service / procd_close_service / procd_lock
#
# 语义映射：
#   procd service   -> 一组 systemd 单元（注册表记录成员）
#   procd instance  -> 一个 systemd 单元  openclash-rt-<instance>.service
#   procd respawn   -> Restart=always + RestartSec + StartLimitIntervalSec/Burst
#   procd limits    -> Limit*
#
# 环境变量（便于测试与调试）：
#   OPENCLASH_RT_ROOT      运行时状态目录，默认 /run/openclash/rt
#   OPENCLASH_RT_UNIT_DIR  单元文件目录，默认 /run/systemd/system
#   OPENCLASH_RT_DRY_RUN   置 1 时只生成文件、不调用 systemctl
#   OPENCLASH_RT_LOG       诊断日志，默认 ${OPENCLASH_RT_ROOT}/openclash-rt.log
# =============================================================================

OPENCLASH_RT_ROOT="${OPENCLASH_RT_ROOT:-/run/openclash/rt}"
OPENCLASH_RT_UNIT_DIR="${OPENCLASH_RT_UNIT_DIR:-/run/systemd/system}"
OPENCLASH_RT_DRY_RUN="${OPENCLASH_RT_DRY_RUN:-0}"
OPENCLASH_RT_LOG="${OPENCLASH_RT_LOG:-${OPENCLASH_RT_ROOT}/openclash-rt.log}"
OPENCLASH_RT_NICE="openclash-rt"

_oc_log() {
	[ -n "${OPENCLASH_RT_QUIET:-}" ] && return 0
	mkdir -p "$(dirname "$OPENCLASH_RT_LOG")" 2>/dev/null
	printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$OPENCLASH_RT_LOG" 2>/dev/null
	return 0
}

# --- 工具 -------------------------------------------------------------------

# 把任意字符串安全地转成 sh 单引号字面量（正确处理内嵌单引号）
_oc_sq() {
	printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# systemd 单元名合法性：只允许 [a-zA-Z0-9:_.-]
_oc_unit_escape() {
	printf '%s' "$1" | sed 's/[^a-zA-Z0-9:_.-]/_/g'
}

_oc_unit_of() {
	printf '%s-%s.service' "$OPENCLASH_RT_NICE" "$(_oc_unit_escape "$1")"
}

_oc_staging_dir() {
	printf '%s/staging/%s' "$OPENCLASH_RT_ROOT" "$(_oc_unit_escape "$1")"
}

_oc_registry_of() {
	printf '%s/services/%s.instances' "$OPENCLASH_RT_ROOT" "$(_oc_unit_escape "$1")"
}

# systemd Environment= 取值：需要时加双引号并转义
_oc_env_line() {
	local kv="$1"
	case "$kv" in
		*=*) : ;;
		*) kv="${kv}=" ;;
	esac
	local val="${kv#*=}"
	case "$val" in
		*[\ \	\"\\]*)
			local esc
			esc="$(printf '%s' "$val" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g')"
			printf 'Environment="%s=%s"\n' "${kv%%=*}" "$esc"
			;;
		*) printf 'Environment=%s\n' "$kv" ;;
	esac
}

# procd/yama limits 键 -> systemd Limit 键
_oc_limit_key() {
	case "$1" in
		as|AS)			printf 'LimitAS' ;;
		core|CORE)		printf 'LimitCORE' ;;
		cpu|CPU)		printf 'LimitCPU' ;;
		data|DATA)		printf 'LimitDATA' ;;
		fsize|FSIZE)		printf 'LimitFSIZE' ;;
		memlock|MEMLOCK)	printf 'LimitMEMLOCK' ;;
		msgqueue|MSGQUEUE)	printf 'LimitMSGQUEUE' ;;
		nice|NICE)		printf 'LimitNICE' ;;
		nofile|NOFILE)		printf 'LimitNOFILE' ;;
		nproc|NPROC)		printf 'LimitNPROC' ;;
		rss|RSS)		printf 'LimitRSS' ;;
		rtprio|RTPRIO)		printf 'LimitRTPRIO' ;;
		sigpending|SIGPENDING)	printf 'LimitSIGPENDING' ;;
		stack|STACK)		printf 'LimitSTACK' ;;
		*)			printf '' ;;
	esac
}

_oc_limit_value() {
	case "$1" in
		unlimited|infinity|-1)	printf 'infinity' ;;
		*)			printf '%s' "$1" ;;
	esac
}

_oc_systemctl() {
	if [ "$OPENCLASH_RT_DRY_RUN" = "1" ]; then
		_oc_log "[dry-run] systemctl $*"
		return 0
	fi
	command systemctl "$@"
}

_oc_daemon_reload() {
	if [ "$OPENCLASH_RT_DRY_RUN" = "1" ]; then
		_oc_log "[dry-run] systemctl daemon-reload"
		return 0
	fi
	command systemctl daemon-reload
}

# --- 锁 ---------------------------------------------------------------------

procd_lock() {
	[ -d "$OPENCLASH_RT_ROOT" ] || mkdir -p "$OPENCLASH_RT_ROOT"
	exec 1000>"$OPENCLASH_RT_ROOT/.lock" 2>/dev/null || return 0
	command -v flock >/dev/null 2>&1 && flock 1000
	return 0
}

# --- service / instance 采集 ------------------------------------------------

_procd_open_service() {
	_OC_SVC="$1"
	_OC_SVC_SCRIPT="$2"
	_OC_SVC_INSTANCES=""
	_OC_SEQ=0
	rm -rf "$(_oc_staging_dir "$_OC_SVC")"
	mkdir -p "$(_oc_staging_dir "$_OC_SVC")"
	_oc_log "open_service name=$_OC_SVC script=$_OC_SVC_SCRIPT"
}

_procd_open_instance() {
	_OC_SEQ=$((_OC_SEQ + 1))
	_OC_INST="$1"
	[ -z "$_OC_INST" ] && _OC_INST="instance$_OC_SEQ"
	_OC_INST_DIR="$(_oc_staging_dir "$_OC_SVC")/$(_oc_unit_escape "$_OC_INST")"
	mkdir -p "$_OC_INST_DIR"
	printf '%s\n' "$_OC_INST" >"$_OC_INST_DIR/.name"
	_oc_log "open_instance svc=$_OC_SVC inst=$_OC_INST"
}

# 记录一个参数类型。type=command/respawn 覆盖写；env/limits 累加写。
_procd_set_param() {
	local type="$1"; shift
	[ -z "$_OC_INST_DIR" ] && _oc_log "set_param before open_instance: $type" && return 0
	case "$type" in
		command|respawn|watch|watchdog|netdev|file)
			: >"$_OC_INST_DIR/$type"
			_procd_append_param "$type" "$@"
			;;
		env|data|limits)
			: >"$_OC_INST_DIR/$type"
			_procd_append_param "$type" "$@"
			;;
		*)
			printf '%s\n' "$*" >"$_OC_INST_DIR/$type"
			;;
	esac
}

_procd_append_param() {
	local type="$1"; shift
	[ -z "$_OC_INST_DIR" ] && return 0
	case "$type" in
		command|respawn|watch|watchdog|netdev|file|error)
			while [ "$#" -gt 0 ]; do
				printf '%s\n' "$1" >>"$_OC_INST_DIR/$type"
				shift
			done
			;;
		env|data|limits)
			while [ "$#" -gt 0 ]; do
				printf '%s\n' "$1" >>"$_OC_INST_DIR/$type"
				shift
			done
			;;
		*)
			printf '%s\n' "$*" >>"$_OC_INST_DIR/$type"
			;;
	esac
}

_procd_close_instance() {
	[ -z "$_OC_INST" ] && return 0
	# limits 允许在未显式声明 respawn 时给默认值
	if [ ! -s "$_OC_INST_DIR/respawn" ]; then
		printf '3600\n5\n5\n' >"$_OC_INST_DIR/respawn"
	fi
	_OC_SVC_INSTANCES="${_OC_SVC_INSTANCES} ${_OC_INST}"
	_oc_log "close_instance svc=$_OC_SVC inst=$_OC_INST"
	_OC_INST_DIR=""
	_OC_INST=""
	return 0
}

# --- 单元文件生成 -----------------------------------------------------------

_oc_param() {
	local dir="$1" name="$2"
	[ -f "$dir/$name" ] && sed -n '1p' "$dir/$name"
}

_oc_write_wrapper() {
	local inst="$1" dir="$2" out="$3"
	# 取 command 的 argv（每个参数一行）
	if [ ! -s "$dir/command" ]; then
		_oc_log "instance $inst has no command, skip"
		return 1
	fi
	{
		printf '#!/bin/sh\n'
		printf '# generated by openclash-rt - do not edit\n'
		printf 'exec'
		while IFS= read -r arg; do
			printf ' %s' "$(_oc_sq "$arg")"
		done <"$dir/command"
		printf '\n'
	} >"$out"
	chmod 0755 "$out" 2>/dev/null
	rm -f "$dir/command"
	return 0
}

_oc_write_unit() {
	local inst="$1" dir="$2" wrapper="$3" out="$4"
	local user group pidfile nn p respawn_dir
	user="$(_oc_param "$dir" user)"
	group="$(_oc_param "$dir" group)"
	pidfile="$(_oc_param "$dir" pidfile)"
	nn="$(_oc_param "$dir" no_new_privs)"
	respawn_dir="$dir/respawn"

	# respawn 的三元组：threshold(重试窗口秒) timeout(重启间隔秒) retry(窗口内最大重试次数)
	#   先解析，使 StartLimit* 只在 [Unit] 里出现一次——重复键在 systemd 中
	#   虽然后者生效，但会让单元文件语义含糊、难以排障。
	local thr="" tmo="" ret=""
	if [ -s "$respawn_dir" ]; then
		thr="$(sed -n '1p' "$respawn_dir")"
		tmo="$(sed -n '2p' "$respawn_dir")"
		ret="$(sed -n '3p' "$respawn_dir")"
	fi

	{
		printf '# generated by openclash-rt - do not edit\n'
		printf '[Unit]\n'
		printf 'Description=OpenClash runtime instance %s\n' "$inst"
		printf 'After=network-online.target nss-lookup.target\n'
		printf 'Wants=network-online.target\n'
		printf 'StartLimitIntervalSec=%s\n' "${thr:-300}"
		printf 'StartLimitBurst=%s\n' "${ret:-3}"
		printf '\n[Service]\n'
		printf 'Type=simple\n'
		printf 'ExecStart=/bin/sh %s\n' "$wrapper"
		printf 'Restart=always\n'
		printf 'RestartSec=%s\n' "${tmo:-5}"

		[ -n "$user" ] && printf 'User=%s\n' "$user"
		[ -n "$group" ] && printf 'Group=%s\n' "$group"
		[ -n "$pidfile" ] && printf 'PIDFile=%s\n' "$pidfile"
		[ "$nn" = "1" ] && printf 'NoNewPrivileges=true\n'

		# limits（procd 风格 key=value，可含 "a b" 形式）
		if [ -s "$dir/limits" ]; then
			local kv k v sk sv
			while IFS= read -r kv; do
				[ -z "$kv" ] && continue
				k="${kv%%=*}"
				v="${kv#*=}"
				[ "$k" = "$kv" ] && v=""
				for kv2 in $v; do :; done
				# nofile="1000000 1000000" 这类双值取前一个（soft）
				sv="$(printf '%s' "$v" | awk '{print $1}')"
				sk="$(_oc_limit_key "$k")"
				[ -n "$sk" ] && [ -n "$sv" ] && printf '%s=%s\n' "$sk" "$(_oc_limit_value "$sv")"
			done <"$dir/limits"
		fi

		# env
		if [ -s "$dir/env" ]; then
			local kv
			while IFS= read -r kv; do
				[ -z "$kv" ] && continue
				_oc_env_line "$kv"
			done <"$dir/env"
		fi

		# stderr 落到 journal（上游自身已重定向到 $LOG_FILE，此处仅兜底）
		local er
		er="$(_oc_param "$dir" stderr)"
		[ "$er" = "1" ] && printf 'StandardError=journal\n'

		printf 'KillMode=mixed\n'
		printf 'TimeoutStopSec=30\n'
		printf '\n[Install]\n'
		printf 'WantedBy=multi-user.target\n'
	} >"$out"
	return 0
}

_procd_close_service() {
	local method="${1:-set}"
	local inst dir wrapper unit units=""

	[ -n "$_OC_SVC" ] || { _oc_log "close_service without open_service"; return 0; }

	if command -v service_triggers >/dev/null 2>&1; then
		service_triggers >/dev/null 2>&1
	fi

	mkdir -p "$OPENCLASH_RT_UNIT_DIR" "$OPENCLASH_RT_ROOT/units" \
	         "$OPENCLASH_RT_ROOT/services"

	for inst in $_OC_SVC_INSTANCES; do
		dir="$(_oc_staging_dir "$_OC_SVC")/$(_oc_unit_escape "$inst")"
		wrapper="$OPENCLASH_RT_ROOT/units/$(_oc_unit_escape "$inst").sh"
		unit="$(_oc_unit_of "$inst")"

		if ! _oc_write_wrapper "$inst" "$dir" "$wrapper"; then
			continue
		fi
		_oc_write_unit "$inst" "$dir" "$wrapper" "$OPENCLASH_RT_UNIT_DIR/$unit"
		units="$units $unit"
	done

	# 写入 service -> instances 注册表（供 procd_running / procd_kill 使用）
	: >"$(_oc_registry_of "$_OC_SVC")"
	[ -n "$_OC_SVC_INSTANCES" ] && printf '%s\n' $_OC_SVC_INSTANCES >"$(_oc_registry_of "$_OC_SVC")"

	_oc_log "close_service svc=$_OC_SVC method=$method units=$units"

	[ -z "$units" ] && return 0
	_oc_daemon_reload
	# shellcheck disable=SC2086
	_oc_systemctl start $units
	return $?
}

# --- 运行态查询 -------------------------------------------------------------

procd_running() {
	local service="$1" instance="${2:-*}"
	local reg inst unit
	reg="$(_oc_registry_of "$service")"

	if [ "$instance" != "*" ] && [ -n "$instance" ]; then
		unit="$(_oc_unit_of "$instance")"
		[ -f "$OPENCLASH_RT_UNIT_DIR/$unit" ] || return 1
		_oc_systemctl is-active --quiet "$unit" 2>/dev/null
		return $?
	fi

	[ -f "$reg" ] || return 1
	while IFS= read -r inst; do
		[ -z "$inst" ] && continue
		unit="$(_oc_unit_of "$inst")"
		if _oc_systemctl is-active --quiet "$unit" 2>/dev/null; then
			return 0
		fi
	done <"$reg"
	return 1
}

procd_kill() {
	local service="$1" instance="${2:-*}"
	local reg inst unit pid

	if [ -z "$service" ]; then
		_oc_log "procd_kill without service name"
		return 1
	fi
	reg="$(_oc_registry_of "$service")"

	_oc_kill_one() {
		local i="$1" u
		u="$(_oc_unit_of "$i")"
		[ -f "$OPENCLASH_RT_UNIT_DIR/$u" ] || return 0
		# 先取主 PID 直接发 TERM，保证上游 procd_running 轮询能迅速观察到退出
		pid="$(_oc_systemctl show -p MainPID --value "$u" 2>/dev/null)"
		[ -n "$pid" ] && [ "$pid" != "0" ] && kill -TERM "$pid" 2>/dev/null
		_oc_systemctl stop "$u"
		return 0
	}

	if [ "$instance" != "*" ] && [ -n "$instance" ]; then
		_oc_kill_one "$instance"
	else
		if [ -f "$reg" ]; then
			while IFS= read -r inst; do
				[ -n "$inst" ] && _oc_kill_one "$inst"
			done <"$reg"
		fi
	fi

	# 清空注册表（用截断而非 rm：即使 rm 不可用/被策略拦截，
	# procd_running 也能立即观察到「无实例」，语义更稳）
	: >"$reg" 2>/dev/null

	_oc_log "procd_kill svc=$service inst=$instance"
	return 0
}

procd_send_signal() {
	local service="$1" instance="${2:-*}" signal="$3"
	local reg inst unit pid

	case "$signal" in
		[A-Z]*) signal="$(kill -l "$signal" 2>/dev/null)" || return 1 ;;
	esac

	reg="$(_oc_registry_of "$service")"
	_oc_sig_one() {
		local i="$1" u p
		u="$(_oc_unit_of "$i")"
		p="$(_oc_systemctl show -p MainPID --value "$u" 2>/dev/null)"
		if [ -n "$p" ] && [ "$p" != "0" ]; then
			kill -"${signal:-TERM}" "$p" 2>/dev/null
		fi
		return 0
	}

	if [ "$instance" != "*" ] && [ -n "$instance" ]; then
		_oc_sig_one "$instance"
	elif [ -f "$reg" ]; then
		while IFS= read -r inst; do
			[ -n "$inst" ] && _oc_sig_one "$inst"
		done <"$reg"
	fi
	_oc_log "procd_send_signal svc=$service inst=$instance sig=$signal"
	return 0
}

_procd_status() {
	local service="$1" instance="${2:-}"
	if [ -n "$instance" ]; then
		_oc_systemctl status --no-pager "$(_oc_unit_of "$instance")"
		return $?
	fi
	_oc_systemctl status --no-pager "$(basename "$initscript")" 2>/dev/null
	return $?
}

# --- 未被上游使用、但 rc.common / 第三方可能调到的空实现 --------------------

procd_open_trigger() { return 0; }
procd_close_trigger() { return 0; }
procd_open_validate() { return 0; }
procd_close_validate() { return 0; }
procd_open_data() { return 0; }
procd_close_data() { return 0; }
procd_add_reload_trigger() { return 0; }
procd_add_reload_data_trigger() { return 0; }
procd_add_reload_interface_trigger() { return 0; }
procd_add_config_trigger() { return 0; }
procd_add_interface_trigger() { return 0; }
procd_add_mount_trigger() { return 0; }
procd_add_raw_trigger() { return 0; }
procd_add_validation() { return 0; }
procd_set_config_changed() { return 0; }
procd_add_jail() { return 0; }
procd_add_jail_mount() { return 0; }
procd_add_jail_mount_rw() { return 0; }
procd_add_mdns() { return 0; }
procd_add_mdns_service() { return 0; }

# public 名称 -> 内部实现（上游 rc.common 期望 procd_* 直接可用）
procd_open_service() { _procd_open_service "$@"; }
procd_close_service() { _procd_close_service "$@"; }
procd_open_instance() { _procd_open_instance "$@"; }
procd_close_instance() { _procd_close_instance "$@"; }
procd_set_param() { _procd_set_param "$@"; }
procd_append_param() { _procd_append_param "$@"; }
