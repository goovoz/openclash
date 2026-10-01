#!/usr/bin/env bash
# =============================================================================
# vendor LuCI 安装测试（P2-A）—— scripts/install-vendor-luci.sh 的回归锁
# -----------------------------------------------------------------------------
# 被测对象：scripts/install-vendor-luci.sh（build-deb.sh §5c 的唯一实现）
#
# 为什么值得单独一套测试：
#   P2 的全部风险都在「布局映射」上，而且多数是**装错位置不报错**的静默型：
#     · luasrc 不加 luci/ 前缀 → require "luci.config" 直接加载失败
#       （第一轮冒烟就差点放过：文件都在，只是差一层目录）；
#     · theme 的 htdocs 没复制 → /www/luci-static/bootstrap/cascade.css 缺失，
#       整个界面裸奔（第二轮冒烟才抓到）；
#     · /usr/share/rpcd/acl.d 缺失 → rpcd 启动拒绝所有 RPC，
#       症状离真因隔了整个前端栈（P3 之前最隐蔽的坑）。
#   这套测试把 docs/03 §3.1 的映射表**逐行变成断言**，上游 vendor 树一旦
#   改名/挪位/加文件，这里立刻红，而不是等到 Debian 真机上排障。
#
# 测试手法：
#   真跑 install-vendor-luci.sh（不 mock），对真实 vendor/luci 树操作到
#   /tmp 沙箱 staging；每条断言都对着 docs/03 §3.1 表格的一行。
#   静态纪律组（I）直接 grep 脚本源码锁实现方式，防止「顺手简化」。
#
# 覆盖：
#   A. 真实树安装：20 条关键路径（表 §3.1 每一行至少一条）
#   B. 命名空间一致性：所有 .lua 的 module("luci.X") 与落位路径匹配
#   C. 幂等性：重跑 rc=0 且计数不变
#   D. vendor 树不可变：安装前后逐字节相同（上游同步零阻力的前提）
#   E. 卫生：.luadoc 不入包；po/ 不入包
#   F. 边界：坏参数、缺 --src/--stage、未知参数
#   G. 静态纪律：build-deb.sh 真的调用它；rg 防漂移锚点
#
# 用法： bash tests/test_luci_vendor_install.sh
# =============================================================================
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
IVL="$ROOT/scripts/install-vendor-luci.sh"
VENDOR="$ROOT/vendor/luci"
PIN="$ROOT/runtime/upstream/pin-lua-interpreter.sh"
BUILD_DEB="$ROOT/scripts/build-deb.sh"

# ⚠️ 不要假设 git 保留了 +x bit：本地 Windows 上文件系统永远显示 +x（mingw shim），
#   但 git tree mode 是 100644；CI Linux runner checkout 也是 644。
#   显式 chmod 一次最稳（chmod 在 mingw 上是 no-op，不影响 Windows）。
[ -x "$IVL" ]     || chmod +x "$IVL" 2>/dev/null || true
[ -f "$IVL" ]     || { printf '\033[31m[fatal]\033[0m 缺少 %s\n' "$IVL"; exit 1; }
[ -d "$VENDOR" ]  || { printf '\033[31m[fatal]\033[0m 缺少 %s（先跑 fetch-luci-vendor.sh）\n' "$VENDOR"; exit 1; }
[ -f "$PIN" ]     || { printf '\033[31m[fatal]\033[0m 缺少 %s\n' "$PIN"; exit 1; }
[ -f "$BUILD_DEB" ] || { printf '\033[31m[fatal]\033[0m 缺少 %s\n' "$BUILD_DEB"; exit 1; }

# ⚠️ 硬编码 /tmp：${TMPDIR} 在本沙箱是 Windows 盘符路径，会被安全策略拒绝
WORK="/tmp/ocrt-luciv.$$"
STAGE="$WORK/stage"
rm -rf "$WORK" 2>/dev/null || true
mkdir -p "$STAGE"
cleanup() { rm -rf "$WORK" 2>/dev/null || true; }
trap cleanup EXIT

PASS=0; FAIL=0; SKIP=0
it()  { printf '\n\033[1m── %s\033[0m\n' "$1"; }
ok()  { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
no()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; [ $# -gt 1 ] && printf '        %s\n' "$2"; }
sk()  { SKIP=$((SKIP+1)); printf '  \033[33mSKIP\033[0m  %s\n' "$1"; }
chk() { if [ "$2" = "$3" ]; then ok "$1"; else no "$1" "want=[$3] got=[$2]"; fi; }
has() { if printf '%s' "$2" | grep -qF -- "$3"; then ok "$1"; else no "$1" "在输出中未找到 [$3]"; fi; }
nothas() { if printf '%s' "$2" | grep -qF -- "$3"; then no "$1" "不应出现 [$3]"; else ok "$1"; fi; }

# 去掉整行注释后再计数（本项目注释会引用被断言的写法本身，直接 grep 是噪声）
_no_comment() { sed 's/^[[:space:]]*#.*$//' "$1"; }
_count() { _no_comment "$2" | grep -cF -- "$1" || true; }

run_ivl() {  # -> rc；stdout 进 $OUT、stderr 进 $ERR
	OUT="$(bash "$IVL" "$@" 2>"$WORK/err")"; RC=$?
	ERR="$(cat "$WORK/err" 2>/dev/null || true)"
}

# =============================================================================
it "A. 真实 vendor 树安装（docs/03 §3.1 表逐行）"
# =============================================================================
run_ivl --src "$VENDOR" --stage "$STAGE" --pin-linter "$PIN"
chk "A 安装 rc=0" "$RC" "0"
chk "A stdout 是纯数字（包计数）" "$(printf '%s' "$OUT" | tr -d '0-9' | grep -c . || true)" "0"
chk "A stdout = 4（4 个 luasrc 包）" "$OUT" "4"

# --- §3.1 表：luci-base luasrc → /usr/lib/lua/luci/ ---
for p in \
	usr/lib/lua/luci/cacheloader.lua \
	usr/lib/lua/luci/dispatcher.lua \
	usr/lib/lua/luci/template.lua \
	usr/lib/lua/luci/i18n.lua \
	usr/lib/lua/luci/sys.lua \
	usr/lib/lua/luci/sys/zoneinfo.lua \
	usr/lib/lua/luci/sys/zoneinfo/tzdata.lua \
	usr/lib/lua/luci/config.lua \
	usr/lib/lua/luci/model/uci.lua \
	usr/lib/lua/luci/sgi/cgi.lua \
	usr/lib/lua/luci/sgi/uhttpd.lua \
	usr/lib/lua/luci/controller/admin/index.lua \
	; do
	if [ -f "$STAGE/$p" ]; then ok "A $p"; else no "A $p 缺失"; fi
done

# --- §3.1 表：luci-lib-base luasrc → 同一 luci/ 前缀下 ---
for p in usr/lib/lua/luci/util.lua usr/lib/lua/luci/http.lua \
         usr/lib/lua/luci/ltn12.lua usr/lib/lua/luci/debug.lua; do
	if [ -f "$STAGE/$p" ]; then ok "A $p"; else no "A $p 缺失"; fi
done

# --- §3.1 表：luci-compat luasrc ---
for p in usr/lib/lua/luci/cbi.lua usr/lib/lua/luci/cbi/datatypes.lua \
         usr/lib/lua/luci/model/network.lua usr/lib/lua/luci/tools/webadmin.lua; do
	if [ -f "$STAGE/$p" ]; then ok "A $p"; else no "A $p 缺失"; fi
done

# --- §3.1 表：luci-theme-bootstrap luasrc ---
for p in usr/lib/lua/luci/view/themes/bootstrap/header.htm \
         usr/lib/lua/luci/view/themes/bootstrap/footer.htm \
         usr/lib/lua/luci/view/themes/bootstrap/sysauth.htm; do
	if [ -f "$STAGE/$p" ]; then ok "A $p"; else no "A $p 缺失"; fi
done

# --- §3.1 表：三个包的 htdocs/luci-static 合并到 /www ---
for p in www/luci-static/resources/menu-bootstrap.js \
         www/luci-static/resources/cbi/add.gif \
         www/luci-static/bootstrap/cascade.css \
         www/luci-static/bootstrap/favicon.png; do
	if [ -f "$STAGE/$p" ]; then ok "A $p"; else no "A $p 缺失"; fi
done

# --- §3.1 表：入口与 shebang 钉定 ---
chk "A www/cgi-bin/luci shebang 已钉" "$(head -1 "$STAGE/www/cgi-bin/luci" 2>/dev/null)" "#!/usr/bin/lua5.1"
chk "A usr/libexec/rpcd/luci shebang 已钉" "$(head -1 "$STAGE/usr/libexec/rpcd/luci" 2>/dev/null)" "#!/usr/bin/lua5.1"
[ -x "$STAGE/www/cgi-bin/luci" ] && ok "A CGI 入口可执行位" || no "A CGI 入口不可执行"

# --- §3.1 表：acl.d / menu.d / config / init.d / uploads / sbin / uci-defaults ---
for p in usr/share/rpcd/acl.d/luci-base.json \
         usr/share/rpcd/acl.d/luci-compat.json \
         usr/share/luci/menu.d/luci-base.json \
         etc/config/luci \
         etc/config/ucitrack \
         etc/init.d/ucitrack \
         etc/luci-uploads/.placeholder \
         usr/sbin/luci-reload \
         etc/uci-defaults/30_luci-theme-bootstrap; do
	if [ -f "$STAGE/$p" ]; then ok "A $p"; else no "A $p 缺失"; fi
done

# ACL 内容完整性：rpcd 靠它授权，空文件比缺文件更难排障
if grep -q '"luci-base"' "$STAGE/usr/share/rpcd/acl.d/luci-base.json" 2>/dev/null; then
	ok "A rpcd ACL 含 luci-base 授权段"
else
	no "A rpcd ACL 缺 luci-base 授权段"
fi

# =============================================================================
it "B. 命名空间一致性：module(\"luci.X\") 与落位路径必须匹配"
# =============================================================================
# 逐文件核验：.lua 文件里 module("luci.foo") 的落位（相对 luci/ 目录）
# 必须是 foo.lua（module 名去掉 luci. 前缀后按 . 切层）。
# 这条锁的是「加 luci/ 前缀」这个不平凡映射 —— 一旦有人改成平铺到
# /usr/lib/lua/（不加前缀），所有 module 名与相对路径的对应关系全部错位。
_mismatch=0; _checked=0; _examples=""
while IFS= read -r -d '' f; do
	rel="${f#"$STAGE/usr/lib/lua/luci/"}"
	_ns="$(grep -m1 -oE 'module[[:space:]]*\(?[[:space:]]*"[^"]+"' "$f" 2>/dev/null | grep -oE '"[^"]+"' | tr -d '"')"
	[ -n "$_ns" ] || continue          # view/*.htm 与数据文件无 module 声明
	case "$_ns" in luci.*) ;; *) continue ;; esac   # 只核 luci.* 命名空间
	_checked=$((_checked + 1))
	# 期望相对路径：luci.controller.admin.index -> controller/admin/index.lua
	_exp="$(printf '%s' "$_ns" | sed 's/^luci\.//; s/\./\//g').lua"
	if [ "$rel" != "$_exp" ]; then
		_mismatch=$((_mismatch + 1))
		_examples="${_examples:+$_examples
}    $_ns -> $rel（期望 $_exp）"
	fi
done < <(find "$STAGE/usr/lib/lua/luci" -name '*.lua' -type f -print0 2>/dev/null)

if [ "$_checked" -gt 0 ]; then
	ok "B 检查了 $_checked 个带 module() 声明的 .lua"
else
	no "B 一个 module() 都没扫到（检查逻辑坏了）"
fi
chk "B module() 与路径全数一致（失配清单：）$_examples" "$_mismatch" "0"

# =============================================================================
it "C. 幂等性"
# =============================================================================
_S1="$(cksum "$STAGE/usr/lib/lua/luci/dispatcher.lua" 2>/dev/null | awk '{print $1$2}')"
run_ivl --src "$VENDOR" --stage "$STAGE" --pin-linter "$PIN"
chk "C 重跑 rc=0" "$RC" "0"
chk "C 重跑计数不变" "$OUT" "4"
_S2="$(cksum "$STAGE/usr/lib/lua/luci/dispatcher.lua" 2>/dev/null | awk '{print $1$2}')"
chk "C 文件未被二次改写" "$_S1" "$_S2"

# =============================================================================
it "D. vendor 树不可变（上游同步零阻力的前提）"
# =============================================================================
# 用 cksum 全树指纹对比：安装前后 vendor/luci 必须逐字节相同
_V1="$(find "$VENDOR" -type f -exec cksum {} + | sort | cksum)"
run_ivl --src "$VENDOR" --stage "$STAGE" --pin-linter "$PIN"
_V2="$(find "$VENDOR" -type f -exec cksum {} + | sort | cksum)"
if [ "$_V1" = "$_V2" ]; then ok "D vendor/luci 安装前后指纹相同"; else no "D vendor/luci 被修改了"; fi

# =============================================================================
it "E. 打包卫生"
# =============================================================================
chk "E 无 .luadoc 入包" "$(find "$STAGE" -name '*.luadoc' -type f | wc -l)" "0"
chk "E 无 po/ 目录入包" "$(find "$STAGE" -type d -name 'po' | wc -l)" "0"
chk "E 无 .git* 残留" "$(find "$STAGE" -name '.git*' | wc -l)" "0"
# 上游 src/ 是 C 源码（po2lmo/template_parser），不进运行时包（由构建期消费）
chk "E 无 vendor src/ 入包" "$(find "$STAGE/usr/lib/lua/luci" -name '*.c' -o -name 'Makefile' | wc -l)" "0"

# =============================================================================
it "F. 边界与参数校验"
# =============================================================================
run_ivl --src /tmp/definitely-not-here --stage "$STAGE"
chk "F --src 不存在 → rc=2" "$RC" "2"
has  "F --src 不存在 → stderr 有提示" "$ERR" "vendor 路径不存在"

run_ivl --src "$VENDOR" --stage /tmp/definitely-not-here
chk "F --stage 不存在 → rc=2" "$RC" "2"

run_ivl
chk "F 缺全部参数 → rc=2" "$RC" "2"
has  "F 缺参数 → 提示 --src" "$ERR" "--src"

run_ivl --src "$VENDOR"
chk "F 缺 --stage → rc=2" "$RC" "2"

run_ivl --src "$VENDOR" --stage "$STAGE" --frobnicate
chk "F 未知参数 → rc=2" "$RC" "2"

# 缺 luci-base（核心包）→ **必须整体失败**：它提供 dispatcher/util/config 等
# 全部核心模块，缺席时装出来的"半套前端"比不装更难排障。这条锁的是
# install-vendor-luci.sh 的 fail-loud 行为（静默降级正是本项目一贯禁止的）。
_M="$WORK/masked"
mkdir -p "$_M"
for d in "$VENDOR"/*/; do
	case "${d%/}" in */luci-base) ;; *) cp -a "$d" "$_M/" ;; esac
done
_M2="$WORK/masked-stage"; mkdir -p "$_M2"
run_ivl --src "$_M" --stage "$_M2" --pin-linter "$PIN"
chk "F luci-base 缺席 → 整体失败（fail-loud）" "$RC" "1"
has  "F luci-base 缺席 → 报因在钉 shebang 步" "$ERR" "钉 shebang"

# =============================================================================
it "G. 静态纪律（防实现漂移）"
# =============================================================================
# 1) build-deb.sh 必须真的调用本脚本（单一实现，禁止内联第二份）。
#    ⚠️ 不能数出现次数 —— §5c 的注释里也提到了脚本名（本项目注释会引用
#    被断言的写法本身，第二次踩）。锚**实际调用行**：变量替换 + 命令替换形态。
if _no_comment "$BUILD_DEB" | grep -qE '_luci_pkgs="\$\(bash "\$ROOT/scripts/install-vendor-luci\.sh"'; then
	ok "G build-deb.sh 实际调用 install-vendor-luci.sh"
else
	no "G build-deb.sh 未调用（或调用形态变了）"
fi
# 调用必须带 --src/--stage/--pin-linter 三个参数（pin-linter 缺省会走
# 脚本内默认推导，但显式传参让 build 与测试用同一份解释器路径）
if _no_comment "$BUILD_DEB" | grep -A4 'install-vendor-luci\.sh' | grep -q -- '--pin-linter'; then
	ok "G 调用带齐 --src/--stage/--pin-linter"
else
	no "G 调用缺参数（pin-linter 未显式传）"
fi

# 2) 脚本内部必须用 --file 钉那两个入口（没有扩展名，--dir 选不到）。
#    锚**调用形态**（bash "$LINTER" --file ...），不锚裸字符串 —— 后者
#    会被参数解析里的 --file) case 分支也计入。
if _no_comment "$IVL" | grep -qE 'bash "\$LINTER" --file'; then
	ok "G 实现用 --file 钉入口（对齐 pin-lua 的显式路径模式）"
else
	no "G 未用 --file 调用钉定器"
fi

# 3) 命名空间映射的实现锚点：for 循环必须一次性列出 4 个包（一条语句锁全部）
if _no_comment "$IVL" | grep -qF 'for pkg in luci-base luci-lib-base luci-compat luci-theme-bootstrap; do'; then
	ok "G luasrc 映射循环覆盖 4 个包（单语句锚）"
else
	no "G luasrc 映射循环不再是 4 包形态（被改了？）"
fi
# htdocs 循环必须覆盖 3 个包（theme 缺席 = 界面裸奔，冒烟第二轮抓到的真缺陷）
if _no_comment "$IVL" | grep -qF 'for _pkg in luci-base luci-compat luci-theme-bootstrap; do'; then
	ok "G htdocs 复制循环覆盖 3 个包（含 theme 样式）"
else
	no "G htdocs 复制循环缺包（theme 样式会丢！）"
fi

# 4) docs/03 §3.1 表与本脚本的存在性锚（表格被整段删除时报警）
_docs="$ROOT/docs/03-路径契约.md"
if grep -q '### 3.1 vendor LuCI 落点' "$_docs" 2>/dev/null; then
	ok "G docs/03 §3.1 章节存在"
else
	no "G docs/03 §3.1 章节被删了（映射表没了单一事实来源）"
fi
chk "G docs/03 记录了 luci/ 前缀的设计依据" \
	"$(grep -c 'luci/` 前缀' "$_docs" || true)" "2"

# =============================================================================
printf '\n\033[1m════════════════════════════════════════\033[0m\n'
printf '  \033[32mPASS %d\033[0m   \033[31mFAIL %d\033[0m   \033[33mSKIP %d\033[0m\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" -eq 0 ]