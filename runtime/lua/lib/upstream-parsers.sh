#!/usr/bin/env bash
# =============================================================================
# 上游构建文件解析器（从 Makefile / CMakeLists.txt 里读出"要编哪些文件"）
# -----------------------------------------------------------------------------
# 为什么要有这一层：
#   项目的 L1 原则是「上游代码原样、不手抄」。把源文件清单硬编码进我们的
#   构建脚本，等于把上游的构建描述**复制**了一份 —— 上游加一个 .c 文件我们
#   就静默地少编一个模块，直到运行期某个功能炸掉才发现。
#   所以这里改成从上游的构建文件里**解析**：上游增删文件我们自动跟上。
#
# 代价是"解析可能读空"。因此每个函数都遵循同一条纪律：
#   **读不出东西 = 硬失败**，绝不返回空列表让调用方继续。调用点还要再断言
#   解析出来的文件真实存在（见 build-lua-modules.sh 的 _assert_srcs）。
#
# 本文件只包含纯函数，不执行任何动作，因此既可被 build-lua-modules.sh source，
# 也可被 tests/ 下的测试脚本单独 source 后对着真实 vendor 树做断言。
# =============================================================================

# CMakeLists.txt 的 `SET(NAME ...)` 块
#   SET(SOURCES
#       attr.c
#       ...
#   )
# 注意收尾的 `)` 可能与最后一个条目同行（上游 lucihttp 就是这样），
# 所以要先剥掉行尾的 `)` 再判断块是否结束。
#
# ⚠️ RS="\r?\n" 是必需的：vendor 树从 Windows 同步到 Debian 后保持 CRLF，
# 否则 `^SET\(SOURCES` 后面的行末 `\r` 不在 `[ \t]|$` 里，整块读空。
_cmake_setlist() {
	local f="$1" nm="$2"
	awk -v nm="$nm" '
		BEGIN { RS = "\r?\n"; cap = 0 }
		$0 ~ "^SET\\(" nm "([ \t]|$)" { cap = 1; next }
		cap {
			line = $0
			sub(/\).*$/, "", line)
			gsub(/[ \t]/, "", line)
			if (line != "") print line
			if ($0 ~ /\)/) cap = 0
		}
	' "$f"
}

# CMakeLists.txt 的 `ADD_LIBRARY(NAME ...)` 块
#   ADD_LIBRARY(liblucihttp SHARED
#       lib/utils.c
#       lib/urlencoded-parser.c)
#
# ⚠️ 匹配时名字后面必须带分隔符判断：
#   `ADD_LIBRARY(liblucihttp ` 与 `ADD_LIBRARY(liblucihttp-lua ` 都包含
#   前者的字面量，不加限制会把两个库的源文件混在一起。
_cmake_addlib() {
	local f="$1" nm="$2"
	awk -v nm="$nm" '
		BEGIN { RS = "\r?\n"; cap = 0 }
		$0 ~ "ADD_LIBRARY\\(" nm "([ \t]|$)" { cap = 1; next }
		cap {
			line = $0
			sub(/\).*$/, "", line)
			gsub(/[ \t]/, "", line)
			if (line != "") print line
			if ($0 ~ /\)/) cap = 0
		}
	' "$f"
}

# Makefile 的 `<target>:` 规则的依赖里，所有 .o
#   parser.so: template_parser.o template_utils.o template_lmo.o ...
_make_rule_objs() {
	local f="$1" tgt="$2"
	awk -v t="$tgt" '
		BEGIN { RS = "\r?\n" }
		index($0, t ":") == 1 { sub(/^[^:]*:/, ""); print; exit }
	' "$f" | tr ' ' '\n' | grep -E '^[A-Za-z0-9_.-]+\.o$' || true
}

# Makefile 的 `<VAR> = ...`（可能带行连续符）里的 .o 列表。
#
# ⚠️ 上游 NIXIO_OBJ 里嵌了一个 make 函数调用，这一条是这个函数存在的原因：
#     NIXIO_OBJ = nixio.o socket.o ... \
#                 $(if $(NIXIO_TLS),tls-crypto.o tls-context.o tls-socket.o,)
#   朴素切分（按空白切 + 要求整个 token 匹配 `\w+\.o`）会得到：
#       命中： nixio.o socket.o ... user.o tls-context.o
#       漏掉： tls-crypto.o（在 token `$(NIXIO_TLS),tls-crypto.o` 里）
#              tls-socket.o（在 token `tls-socket.o,)` 里）
#   症状：NIXIO_TLS=openssl 时缺两个源文件，编译直接失败。
#
#   做法：先剥掉 token 尾部的 `)` `,` `\`，再取 token **末尾**的 `xxx.o`。
#   ⚠️ 逗号必须一起剥：`tls-socket.o,)` 只剥 `)` 会得到 `tls-socket.o,`，
#      以逗号结尾就匹配不上 `\.o$` 了 —— 实测正是如此，而且它**只在
#      NIXIO_TLS=openssl 时才会暴露**，默认构建完全看不出来。
_make_varlist() {
	local f="$1" var="$2"
	awk -v var="$var" '
		BEGIN { RS = "\r?\n"; cap = 0; buf = "" }
		$0 ~ "^" var "[ \t]*=" { cap = 1 }
		cap {
			line = $0
			cont = (line ~ /\\[ \t]*$/)
			sub(/\\[ \t]*$/, "", line)
			buf = buf " " line
			if (!cont) cap = 0
		}
		END {
			n = split(buf, a, /[ \t]+/)
			for (i = 1; i <= n; i++) {
				t = a[i]
				sub(/[\\),]+$/, "", t)
				if (match(t, /[A-Za-z0-9_.-]+\.o$/))
					print substr(t, RSTART)
			}
		}
	' "$f"
}
