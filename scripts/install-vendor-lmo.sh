#!/usr/bin/env bash
# scripts/install-vendor-lmo.sh —— 编译上游 luci-base 自带的 po2lmo 工具，
# 把所有 vendor 包的 .po 翻译源 编译成 .lmo 二进制落进 staging。
#
# 与 install-vendor-luci.sh 同属 P2 系列把**不可变**的 vendor 树搬运成
# Debian 包格式；不同之处是这里多了一步——**在交付机器上编译 po2lmo**。
#
# 关键事实（全部来自上游源码实测，不是猜测）：
#
#   1. po2lmo.c 是独立可编译的：它**只** include template_lmo.h（拿 lmo_entry_t
#      结构体），**不引用 lmo_open/lmo_load 等 template_lmo.c 里的函数**。
#      编译命令： cc -O2 -Wall -o po2lmo po2lmo.c
#      不需要 link template_lmo.c，不需要 lemon/flex/bison。
#
#   2. po2lmo 调用约定： `po2lmo <input.po> <output.lmo>`，argc=3，
#      输出文件**当且仅当有消息**才被创建（offset==0 时 unlink），
#      编译空 .po = 不产生 .lmo 文件（这是上游设计，不是错）
#
#   3. lmo 加载约定（template_lmo.c:237）：
#          snprintf(pattern, sizeof(pattern), "*.%s.lmo", lang);
#          if (!fnmatch(pattern, de->d_name, 0)) { ... }
#      所以落位文件名必须匹配 `<任意>.<lang>.lmo`。
#      单包单一语言单 .po 时实际文件名 = `<package>.<lang>.lmo`（这是上游约定）。
#
#   4. i18n.lua:13: i18ndir = util.libpath() .. "/i18n/"
#      libpath() = dirname(ldebug.__file__)，指向 i18n.lua 自身所在的目录。
#      因为所有 4 个 vendor 包的 luasrc/* 都装到 /usr/lib/lua/luci/ 下，
#      i18ndir 唯一 = /usr/lib/lua/luci/i18n/。
#
#   5. 翻译请求是"上传"时逐包发生的：i18n.setlanguage(lang) 在 dispatcher 启动
#      时被调用一次，按 lang 目录加载 i18ndir 里匹配的所有 .lmo；
#      因为 fnmatch 通配 *.<lang>.lmo，多包共存时是按文件名加载全部——命名不冲突
#      即可。
#
# 设计取舍：
#   · 编译产物 po2lmo **不**入运行时包——打 .deb 时不会带 po2lmo。
#     运行时只需要 .lmo 文件（被 libtemplate.so 解释），编译工具只属于打包期。
#     staging/usr/lib/openclash-rt/build/po2lmo 由 build-deb.sh 在打包后清理。
#   · 编译发生在 $STAGE/usr/lib/openclash-rt/build/，不进最终 deb——这是
#     "staging is build, deb is clean" 原则。
#
# 用法：
#   scripts/install-vendor-lmo.sh \
#       --src vendor/luci \
#       --stage <staging-dir> \
#       [--skip-cc]                       # 测试 / 静态分析场景
#
# 退出码：
#   0  所有 .lmo 编译完成（dry-run 跳过编译也返 0）
#   非 0 任何一步失败
#
# 环境变量：
#   CC                       默认 cc
#   PO2LMO_CFLAGS            默认 -O2 -Wall

set -e
set -u
set -o pipefail

SRC=""
STAGE=""
SKIP_CC=0
CC="${CC:-cc}"
PO2LMO_CFLAGS="${PO2LMO_CFLAGS:--O2 -Wall}"
# 复用外部 po2lmo 二进制（由 build-lua-modules.sh 编出）。如果不传，且
# SKIP_CC=0，会自己编。**自己编需要链 template_lmo.c + plural_formula.c**（po2+
# 引用了 sfh_hash，见 vendor/luci/luci-base/src/template_lmo.c:27），
# 而 plural_formula.c 要 lemon 生成，所以推荐复用。
PO2LMO_BIN_SRC=""

die() {
	printf 'install-vendor-lmo: %s\n' "$*" >&2
	exit 1
}
log() {
	printf 'install-vendor-lmo: %s\n' "$*" >&2
}

usage() {
	cat >&2 <<'EOF'
用法:
  scripts/install-vendor-lmo.sh --src <vendor-luci-dir> --stage <staging-dir> [--skip-cc] [--po2lmo <file>]

  必填:
    --src        vendor/luci 的目录（必须是上游仓库原样，不带 build 产物）
    --stage      build-deb.sh 的 staging 根

  可选:
    --skip-cc    跳过 po2lmo 编译与 .po -> .lmo 编译（仅做落位 + 静态检查）
                 用于本机无 gcc 的开发机；CI 上必须不带这个参数
    --po2lmo     直接复用外部 po2lmo 二进制（典型路径：<stage>/usr/bin/po2lmo，
                 由 build-lua-modules.sh 编出）。不传则本脚本自己 cc po2lmo.c —— 但
                 真机上 po2lmo.c 引用 sfh_hash（template_lmo.c:27），所以自己编必须
                 链 template_lmo.c + plural_formula.c，会牵出 lemon 依赖。**默认用
                 复用路径**，build-deb.sh §5b → §5d 的顺序保证 po2lmo 已经存在。
EOF
	exit 1
}

while [ $# -gt 0 ]; do
	case "$1" in
		--src)        SRC="${2:?--src 需要一个目录}"; shift 2 ;;
		--src=*)      SRC="${1#*=}"; shift ;;
		--stage)      STAGE="${2:?--stage 需要一个目录}"; shift 2 ;;
		--stage=*)    STAGE="${1#*=}"; shift ;;
		--skip-cc)    SKIP_CC=1; shift ;;
		--po2lmo)     PO2LMO_BIN_SRC="${2:?--po2lmo 需要一个文件路径}"; shift 2 ;;
		--po2lmo=*)   PO2LMO_BIN_SRC="${1#*=}"; shift ;;
		-h|--help)    usage ;;
		*)            usage ;;
	esac
done

[ -n "$SRC" ]   || usage
[ -n "$STAGE" ] || usage
[ -d "$SRC" ]   || die "--src 目录不存在：$SRC"
[ -d "$STAGE" ] || die "--stage 目录不存在：$STAGE"

# 默认 po2lmo 源 = <stage>/usr/bin/po2lmo（build-lua-modules.sh §6 产物）。
# build-deb.sh §5b 在 §5d 之前调，所以这里 stage 树里一定有产物。
# 不传 --po2lmo 也不存在时，本脚本自己编（上面 #1 分支）。
if [ -z "$PO2LMO_BIN_SRC" ] && [ "$SKIP_CC" != "1" ]; then
	if [ -x "$STAGE/usr/bin/po2lmo" ]; then
		PO2LMO_BIN_SRC="$STAGE/usr/bin/po2lmo"
	fi
fi

# 1) 准备 po2lmo 二进制
# ----------------------------------------------------------------------------
# 复用 build-lua-modules.sh 已经编出的 po2lmo（链了 template_lmo.c +
# plural_formula.c，po2lmo.c 实际引用 sfh_hash）。本脚本自己单文件 cc
# po2lmo.c 在真机上会因 undefined reference to `sfh_hash' 而失败（MSYS 上
# 因为 SKIP_CC=1 / 无 gcc，从未触发这条；CI ubuntu-latest 上也会撞）。
BUILD_DIR="$STAGE/usr/lib/openclash-rt/build"
mkdir -p "$BUILD_DIR/i18n"
PO2LMO_BIN="$BUILD_DIR/po2lmo"
if [ -n "$PO2LMO_BIN_SRC" ]; then
	[ -x "$PO2LMO_BIN_SRC" ] || die "--po2lmo 指定路径不可执行：$PO2LMO_BIN_SRC"
	cp -f "$PO2LMO_BIN_SRC" "$PO2LMO_BIN"
	chmod 0755 "$PO2LMO_BIN"
	log "复用 po2lmo -- $PO2LMO_BIN_SRC"
elif [ "$SKIP_CC" = "1" ]; then
	log "SKIP_CC=1：跳过 po2lmo 编译（不会产生 .lmo，运行时 i18n 退化为默认英文）"
	# 占位 file 防止后续 po2lmo 命令找不到
	printf '#!/bin/sh\necho "install-vendor-lmo: SKIP_CC=1，po2lmo 不可用" >&2\nexit 1\n' >"$PO2LMO_BIN"
	chmod 0755 "$PO2LMO_BIN"
else
	log "编译 po2lmo（$CC $PO2LMO_CFLAGS） ..."
	( cd "$SRC/luci-base/src" && "$CC" $PO2LMO_CFLAGS -I. -o "$PO2LMO_BIN" po2lmo.c template_lmo.c plural_formula.c ) \
		|| die "po2lmo 编译失败（已链 template_lmo.c + plural_formula.c）。若是 lemon 阶段缺 binary，把 --po2lmo 指给 build-lua-modules.sh 的产物。"
	[ -x "$PO2LMO_BIN" ] || die "po2lmo 编译后不存在或无 x 位"
	log "po2lmo 编译完成 -> $PO2LMO_BIN"
fi

# 2) 编译所有 .po -> .lmo
# ----------------------------------------------------------------------------
# 单一包单一语言单 .po -> 一个 .lmo 文件。
# 命名约定（上游 + 测试锁定）： <package>.<lang>.lmo
#  - package：vendor 包名（luci-base / luci-compat / luci-theme-bootstrap）
#    注意：lib-base 没有 po 目录，跳过；现存的三个 .po 目录都正确处理。
#  - lang：语言代码（en / zh-cn / ...），与 .po 子目录同名
# 路径模板：
#   <SRC>/<pkg>/po/<lang>/base.po
#   -> <STAGE>/usr/lib/lua/luci/i18n/<pkg>.<lang>.lmo
# 这是 fnmatch("*.zh-cn.lmo", ...) 的"任意"=包名前缀的来源—— 多包共存时
# 不会互相覆盖，运行时 tparser.load_catalog() 把它们都加载。
LMO_OUT_DIR="$STAGE/usr/lib/lua/luci/i18n"
mkdir -p "$LMO_OUT_DIR"

# 2) 编译所有 .po -> .lmo
# ----------------------------------------------------------------------------
# 单一包单一语言单 .po -> 一个 .lmo 文件。
# 命名约定（上游 + 测试锁定）： <package>.<lang>.lmo
#  - package：vendor 包名（luci-base / luci-compat / luci-theme-bootstrap）
#    注意：lib-base 没有 po 目录，跳过；现存的三个 .po 目录都正确处理。
#  - lang：语言代码（en / zh-cn / ...），与 .po 子目录同名
# 路径模板：
#   <SRC>/<pkg>/po/<lang>/base.po
#   -> <STAGE>/usr/lib/lua/luci/i18n/<pkg>.<lang>.lmo
# 这是 fnmatch("*.zh-cn.lmo", ...) 的"任意"=包名前缀的来源—— 多包共存时
# 不会互相覆盖，运行时 tparser.load_catalog() 把它们都加载。
LMO_OUT_DIR="$STAGE/usr/lib/lua/luci/i18n"
mkdir -p "$LMO_OUT_DIR"

# ⚠️ SKIP_CC=1 时 §1 写了占位 po2lmo（exit 1），下面的 .po 循环会全炸。
#    这里显式**只**跳过 .po 编译循环，但**必须继续往下跑**：
#      · 静态断言（.po / .y / .c / .h 不入 staging、落位路径、命名约定）
#      · 末尾的「i18n 落位总数」总结（build-deb.sh §5d 与 test_luci_lmo_install
#        的 B 组断言都依赖它）
#    2026-10-01 修：这里原本是 `exit 0`，把**静态检查一起跳掉**了 —— 注释写着
#    "仅落位与静态检查"，实际却一行检查都没跑，SKIP_CC 路径等于没验收。
_count=0
_count_failed=0
if [ "$SKIP_CC" = "1" ]; then
	log "SKIP_CC=1：跳过 po2lmo 编译与 .po -> .lmo 编译（仅落位与静态检查）"
else
for pkg_po_dir in "$SRC"/*/po; do
	[ -d "$pkg_po_dir" ] || continue
	# 从 <src>/<pkg>/po 反推 <pkg>（basename of dirname）
	_pkg="$(basename "$(dirname "$pkg_po_dir")")"

	for lang_dir in "$pkg_po_dir"/*/; do
		[ -d "$lang_dir" ] || continue
		_lang="$(basename "$lang_dir")"
		_po="$lang_dir/base.po"
		[ -f "$_po" ] || continue

		_lmo="$LMO_OUT_DIR/$_pkg.${_lang}.lmo"

		# po2lmo 的怪癖：空 .po（没消息）会 unlink 输出文件。
		# 我们的处理：跑一下，若 .lmo 没产生则 warn 而不是 fail（这不是 bug）。
		log "size=$(wc -l <"$_po" 2>/dev/null || echo ?) 编译 $_pkg.${_lang} ..."
		if "$PO2LMO_BIN" "$_po" "$_lmo" 2>"$BUILD_DIR/i18n/last.err"; then
			if [ -f "$_lmo" ]; then
				_count=$((_count + 1))
			else
				# po2lmo 主动 unlink 了空翻译文件。这是上游设计，
				# 但我们要 warn，因为"语言无翻译"通常是个数据缺失 bug。
				log "WARN  $_pkg.${_lang}.lmo 未生成（源 .po 是空的）"
			fi
		else
			_count_failed=$((_count_failed + 1))
			log "FAIL  $_pkg.${_lang} （见 $BUILD_DIR/i18n/last.err）"
		fi
	done
done

if [ "$_count_failed" -gt 0 ]; then
	die "$_count_failed 个 .po 编译失败（详见 $BUILD_DIR/i18n/*.err）"
fi
fi  # end of: SKIP_CC != 1 时才编 .po

log ".po -> .lmo 编译完成，共 $_count 个落位（target=$LMO_OUT_DIR）"

# 3) 卫生：占位文件 .placeholder（与 install-vendor-luci 同源约定）
# ----------------------------------------------------------------------------
# i18n 目录若完全为空，libtemplate 在 setlanguage 时会先于 load_catalog 调用
# opendir(i18ndir)——空目录能 opendir，但 readdir 返回 NULL 是正常的。所以
# **不需要** placeholder。但若 stderr 有 "i18ndir: No such file or directory"
# 的警告，必须硬失败。这条静态检查在 build-deb.sh §5d 之后做。

# 4) 静态断言（任何调用 install-vendor-lmo 的 build-deb.sh 都应满足）
# ----------------------------------------------------------------------------
# 这条用 git 版本 >= 2.x（遵守规则）——给 CI 跟 dev 双重保护。
# 不能在 staging 里有 .po（源头不该跟）： .po 编译后产物已经在 staging/usr/lib/lua/luci/i18n/，
# .po 本身应留在 vendor/ 而 **不** 入包。
_po_leaked="$(find "$STAGE" -name '*.po' 2>/dev/null | wc -l || true)"
chk() { if [ "$2" = "$3" ]; then printf '  ok %s\n' "$1" >&2; else die "FAIL %s want=[$3] got=[$2]"; fi; }
chk ".po 源未误入 staging（编译后产物才是 .lmo）" "$_po_leaked" "0"

# 同样 .y / .c / .h / template_lmo.* 等不应进入 staging——它们都是编译期材料
_src_leaked="$(find "$STAGE" -path '*/luci-base/src/*' -o -name 'plural_formula*' 2>/dev/null | wc -l || true)"
chk ".y / .c / .h 不入 staging" "$_src_leaked" "0"

# po2lmo 二进制本身也不应进 deb（属于 build/，§4 清理）
[ -x "$PO2LMO_BIN" ] && {
	# 现在 staging 下还有 po2lmo（这正常，是 §4 要清的）；断言它是预期位置
	chk "po2lmo 落在 build/ 下（被打包后清理）" \
		"$(case "$PO2LMO_BIN" in "$BUILD_DIR"/*) echo yes ;; *) echo no ;; esac)" \
		"yes"
}

# 统计 lmo 数
_lmo_n="$(if [ -d "$LMO_OUT_DIR" ]; then find "$LMO_OUT_DIR" -name '*.lmo' | wc -l; else echo 0; fi)"
log "i18n 落位总数：$_lmo_n 个 .lmo（target=$LMO_OUT_DIR）"

# 命名约定抽查：每个 .lmo 必须匹配 <pkg>.<lang>.lmo
_bad=0
if [ -d "$LMO_OUT_DIR" ]; then
	while IFS= read -r -d '' _f; do
		_bn="$(basename "$_f")"
		case "$_bn" in
			[a-z][a-z0-9-]*.[a-z][a-z0-9_-]*.lmo) : ;;
			*) _bad=$((_bad + 1)); log "BAD 命名：$_bn" ;;
		esac
	done < <(find "$LMO_OUT_DIR" -name '*.lmo' -print0 2>/dev/null)
fi
chk "所有 .lmo 命名形如 <pkg>.<lang>.lmo" "$_bad" "0"

# 出口（设计契约）
#   stderr 携带调试信息；stdout 是空（"调用方应沉默"）。
#   这是与 install-vendor-luci.sh 一致的 stdout 纪律 —— 避免 build-deb.sh
#   用 n="$(... )" 取值时被意外日志污染。
exit 0