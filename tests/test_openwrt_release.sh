#!/usr/bin/env bash
# =============================================================================
# openclash-rt  /etc/openwrt_release 生成器测试
# -----------------------------------------------------------------------------
# 覆盖：
#   A. 架构映射表：dpkg 架构 → OpenWrt DISTRIB_ARCH
#   B. **对拍**：把上游 uci-defaults 里真实的 case 语句抽出来执行，
#      逐个架构比对我们的镜像实现——防止我手抄上游映射表时出错
#   C. 文件格式契约：
#        C1  值必须带**单引号**（controller 用 pattern "DISTRIB_ARCH='([^']+)'"
#            取值，不带引号会匹配失败）
#        C2  必须是合法 shell（openclash_history_get.sh 用 source 读它）
#        C3  必须是合法 uci/文本，能被 grep 出来
#   D. 幂等（systemd ExecStartPre / 重装都会重复执行）
#   E. 兜底：未知架构不得静默产出可用值，必须走 CORE_ARCH=0 + 明确告警
#   F. --check 能识别出文件与本机架构不一致
#
# 用法： bash tests/test_openwrt_release.sh
# =============================================================================
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

# ⚠️ 不要用 ${TMPDIR}：Windows/MSYS 沙箱下它可能是 Windows 盘符路径，
#    会被安全策略拒绝处理。硬编码 /tmp 最稳。
WORK="/tmp/ocrt-owl.$$"
rm -rf "$WORK" 2>/dev/null || true
mkdir -p "$WORK/bin"

GEN="$ROOT/runtime/sys/openwrt-release.sh"
UCI_DEFAULTS="$ROOT/upstream/luci-app-openclash/root/etc/uci-defaults/luci-openclash"

PASS=0; FAIL=0
it()  { printf '\n\033[1m── %s\033[0m\n' "$1"; }
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
no()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "want=[$3] got=[$2]"; fi; }

cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

# --- 可注入的假 dpkg / uname -----------------------------------------------
cat >"$WORK/bin/dpkg" <<'EOF'
#!/bin/sh
[ -n "${FAKE_DPKG_FAIL:-}" ] && exit 1
printf '%s\n' "${FAKE_DPKG_ARCH:-amd64}"
EOF
cat >"$WORK/bin/uname" <<'EOF'
#!/bin/sh
printf '%s\n' "${FAKE_UNAME_M:-x86_64}"
EOF
chmod +x "$WORK/bin/dpkg" "$WORK/bin/uname"

# 在指定架构下运行生成器，返回 stdout（用 --print，不落盘）
gen_print() {
	local darch="$1" um="$2"
	env FAKE_DPKG_ARCH="$darch" FAKE_UNAME_M="$um" \
	    OPENCLASH_RT_DPKG="$WORK/bin/dpkg" OPENCLASH_RT_UNAME="$WORK/bin/uname" \
	    OPENCLASH_RT_ROOT_PREFIX="$WORK/root" \
	    bash "$GEN" --print 2>/dev/null
}
# 只取 DISTRIB_ARCH
arch_of() {
	local darch="$1" um="$2"
	gen_print "$darch" "$um" | sed -n "s/^DISTRIB_ARCH='\([^']*\)'.*/\1/p"
}
# 我们脚本自报的 CORE_ARCH（镜像实现）
core_of() {
	env FAKE_DPKG_ARCH="$1" FAKE_UNAME_M="$2" \
	    OPENCLASH_RT_DPKG="$WORK/bin/dpkg" OPENCLASH_RT_UNAME="$WORK/bin/uname" \
	    OPENCLASH_RT_ROOT_PREFIX="$WORK/root" \
	    bash "$GEN" --core-arch 2>/dev/null
}

# =============================================================================
it "A. dpkg 架构 → OpenWrt DISTRIB_ARCH 映射表"
# =============================================================================
# 这些取值必须落在上游 case 的**匹配分支**上（见 B 组对拍）
chk "amd64   -> x86_64"           "$(arch_of amd64   x86_64)"    "x86_64"
chk "arm64   -> aarch64_generic"  "$(arch_of arm64   aarch64)"   "aarch64_generic"
chk "armhf   -> arm_cortex-a7"    "$(arch_of armhf   armv7l)"    "arm_cortex-a7"
chk "armel   -> arm_arm926ej-s"   "$(arch_of armel   armv5tel)"  "arm_arm926ej-s"
chk "i386    -> i386_generic"     "$(arch_of i386    i686)"      "i386_generic"
chk "riscv64 -> riscv64_generic"  "$(arch_of riscv64 riscv64)"   "riscv64_generic"
chk "loong64 -> loongarch64_generic" "$(arch_of loong64 loongarch64)" "loongarch64_generic"
chk "mipsel  -> mipsel_24kc"      "$(arch_of mipsel  mips)"      "mipsel_24kc"
chk "mips64el-> mips64el_cortex-a53" "$(arch_of mips64el mips64)" "mips64el_cortex-a53"
chk "mips    -> mips_24kc"        "$(arch_of mips    mips)"      "mips_24kc"

# 没有 dpkg 时退到 uname
chk "无 dpkg 时退到 uname（x86_64）" \
	"$(env FAKE_DPKG_FAIL=1 FAKE_UNAME_M=x86_64 \
	    OPENCLASH_RT_DPKG="$WORK/bin/dpkg" OPENCLASH_RT_UNAME="$WORK/bin/uname" \
	    OPENCLASH_RT_ROOT_PREFIX="$WORK/root" bash "$GEN" --print 2>/dev/null \
	  | sed -n "s/^DISTRIB_ARCH='\([^']*\)'.*/\1/p")" "x86_64"

# =============================================================================
it "B. 与上游真实 case 对拍（镜像实现的正确性由构造保证）"
# =============================================================================
UP="${WORK}/upstream_core_arch.sh"
{
	printf '#!/bin/sh\n'
	printf 'DISTRIB_ARCH="$1"\n'
	printf 'CORE_ARCH=""\n'
	# 抽出上游从 `case "${DISTRIB_ARCH}" in` 到配对 `esac` 的整段
	#
	# ⚠️ 必须 `tr -d '\r'`：上游 uci-defaults 是 CRLF，awk 抽出时仍含 \r，
	# 喂给 sh（dash）会把 `case ... in\r` 误认成「in 后跟非法 word」而拒绝执行。
	# 12 个架构对拍全挂在这一条上。
	awk '
		/^case "\$\{DISTRIB_ARCH\}" in/ { inside=1 }
		inside { print }
		inside && /^esac/ { exit }
	' "$UCI_DEFAULTS" | tr -d '\r'
	printf 'printf "%%s" "$CORE_ARCH"\n'
} >"$UP"
chmod +x "$UP"
up_core() { env OPENCLASH_RT_ROOT_PREFIX="$WORK/root" sh "$UP" "$1"; }

if [ ! -s "$UP" ] || ! grep -q 'esac' "$UP"; then
	no "从上游 uci-defaults 抽出了 case 块" "抽出的文件为空"
else
	ok "从上游 uci-defaults 抽出了 case 块（$(wc -l <"$UP") 行）"

	# 对每个映射值逐一对拍：上游算出的 CORE_ARCH 必须等于我们镜像算出的
	MISMATCH=0
	for pair in "amd64:x86_64" "arm64:aarch64_generic" "armhf:arm_cortex-a7" \
	            "armel:arm_arm926ej-s" "i386:i386_generic" "riscv64:riscv64_generic" \
	            "loong64:loongarch64_generic" "mipsel:mipsel_24kc" \
	            "mips64el:mips64el_cortex-a53" "mips:mips_24kc" ; do
		da="${pair%%:*}"; um="${pair#*:}"
		a="$(arch_of "$da" "$um")"
		u="$(up_core "$a")"
		m="$(core_of "$da" "$um")"
		if [ "$u" = "$m" ] && [ -n "$u" ]; then
			ok "$da ($a) -> $u（上游与镜像一致）"
		else
			no "$da ($a) 映射对拍" "上游=[$u] 镜像=[$m]"
			MISMATCH=1
		fi
	done
	[ "$MISMATCH" = 0 ] && ok "全部架构与上游 case 一致"

	# 关键回归：上游兜底分支确实是字面量 "0"
	chk "未知架构在上游会落到 CORE_ARCH=0（这是必须避免的降级）" "$(up_core 'unknown_xyz')" "0"
fi

# =============================================================================
it "C. 文件格式契约"
# =============================================================================
OUTP="$WORK/root/etc/openwrt_release"
env FAKE_DPKG_ARCH=amd64 FAKE_UNAME_M=x86_64 \
    OPENCLASH_RT_DPKG="$WORK/bin/dpkg" OPENCLASH_RT_UNAME="$WORK/bin/uname" \
    OPENCLASH_RT_ROOT_PREFIX="$WORK/root" bash "$GEN" >/dev/null 2>&1
chk "生成器退出码" "$?" "0"

if [ -f "$OUTP" ]; then
	ok "已生成 $OUTP"

	# C1：单引号（上游 controller 的 Lua pattern 依赖它）
	CONTENT="$(cat "$OUTP")"
	case "$CONTENT" in
		*"DISTRIB_ARCH='"*"'"*) ok "值使用单引号（满足 Lua pattern \"DISTRIB_ARCH='([^']+)'\")" ;;
		*) no "值使用单引号" "$CONTENT" ;;
	esac

	# 用 sed 复刻上游 Lua 的取值方式
	LUASTYLE="$(sed -n "s/.*DISTRIB_ARCH='\([^']*\)'.*/\1/p" "$OUTP" | head -1)"
	chk "按上游 Lua pattern 能取到值" "$LUASTYLE" "x86_64"

	# C2：可被 shell source（openclash_history_get.sh:43 的读法）
	SHELLVAL="$(sh -c ". '$OUTP' >/dev/null 2>&1; printf '%s' \"\$DISTRIB_ARCH\"")"
	chk "可被 sh source 且 DISTRIB_ARCH 正确" "$SHELLVAL" "x86_64"

	# 必须含全部 OpenWrt 标准字段（缺字段会让将来的上游版本读空）
	for f in DISTRIB_ID DISTRIB_RELEASE DISTRIB_REVISION DISTRIB_TARGET \
	         DISTRIB_ARCH DISTRIB_DESCRIPTION DISTRIB_TAINTS; do
		if grep -q "^${f}=" "$OUTP"; then ok "含字段 $f"; else no "含字段 $f"; fi
	done

	# DISTRIB_ID 保持诚实（不伪装成 OpenWrt）
	if grep -q "^DISTRIB_ID='OpenWrt'" "$OUTP"; then
		no "DISTRIB_ID 不伪装成 OpenWrt（将来上游若按它分支，我们希望走非 OpenWrt 分支）"
	else
		ok "DISTRIB_ID 未伪装成 OpenWrt"
	fi
else
	no "已生成 $OUTP"
fi

# =============================================================================
it "D. 幂等"
# =============================================================================
B1="$(cat "$OUTP" 2>/dev/null)"
env FAKE_DPKG_ARCH=amd64 FAKE_UNAME_M=x86_64 \
    OPENCLASH_RT_DPKG="$WORK/bin/dpkg" OPENCLASH_RT_UNAME="$WORK/bin/uname" \
    OPENCLASH_RT_ROOT_PREFIX="$WORK/root" bash "$GEN" >"$WORK/d.out" 2>&1
chk "重复执行退出码" "$?" "0"
chk "重复执行后内容不变" "$(cat "$OUTP" 2>/dev/null)" "$B1"
if grep -q '内容无变化' "$WORK/d.out"; then
	ok "识别出内容无变化（不做无谓落盘）"
else
	no "识别出内容无变化" "$(cat "$WORK/d.out")"
fi

# =============================================================================
it "E. 未知架构必须显式降级"
# =============================================================================
env FAKE_DPKG_ARCH=s390x FAKE_UNAME_M=s390x \
    OPENCLASH_RT_DPKG="$WORK/bin/dpkg" OPENCLASH_RT_UNAME="$WORK/bin/uname" \
    OPENCLASH_RT_ROOT_PREFIX="$WORK/root-e" bash "$GEN" >"$WORK/e.out" 2>&1
chk "s390x：退出码（不阻断安装）" "$?" "0"
chk "s390x：镜像算出的 CORE_ARCH" \
	"$(env FAKE_DPKG_ARCH=s390x FAKE_UNAME_M=s390x OPENCLASH_RT_DPKG="$WORK/bin/dpkg" \
	    OPENCLASH_RT_UNAME="$WORK/bin/uname" OPENCLASH_RT_ROOT_PREFIX="$WORK/root-e" \
	    bash "$GEN" --core-arch 2>/dev/null)" "0"
if grep -q 'CORE_ARCH 判为 0\|无法把宿主架构映射' "$WORK/e.out"; then
	ok "给出明确告警（不静默失败）"
else
	no "给出明确告警" "$(cat "$WORK/e.out")"
fi
# 与上游对拍：s390x 在我们这里产出 unknown_* → 上游也会给 0
chk "s390x 经上游 case 也是 0（两边一致）" "$(up_core "$(arch_of s390x s390x)")" "0"

# =============================================================================
it "F. --check 能发现架构漂移"
# =============================================================================
chk "当前文件与本机一致时返回 0" \
	"$(env FAKE_DPKG_ARCH=amd64 FAKE_UNAME_M=x86_64 OPENCLASH_RT_DPKG="$WORK/bin/dpkg" \
	    OPENCLASH_RT_UNAME="$WORK/bin/uname" OPENCLASH_RT_ROOT_PREFIX="$WORK/root" \
	    bash "$GEN" --check >/dev/null 2>&1; echo $?)" "0"
# 换成 arm64 视角：文件里是 x86_64，应当报不一致
env FAKE_DPKG_ARCH=arm64 FAKE_UNAME_M=aarch64 OPENCLASH_RT_DPKG="$WORK/bin/dpkg" \
    OPENCLASH_RT_UNAME="$WORK/bin/uname" OPENCLASH_RT_ROOT_PREFIX="$WORK/root" \
    bash "$GEN" --check >"$WORK/f.out" 2>&1
chk "架构漂移时返回非 0" "$?" "1"
if grep -q '不一致' "$WORK/f.out"; then ok "提示不一致"; else no "提示不一致"; fi

# =============================================================================
printf '\n════════════════════════════════════════\n'
printf '  PASS: %d    FAIL: %d\n' "$PASS" "$FAIL"
printf '════════════════════════════════════════\n'
[ "$FAIL" -eq 0 ]
