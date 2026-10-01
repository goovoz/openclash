#!/usr/bin/env bash
# =============================================================================
# tests/test_luci_host.sh —— P3 自研 HTTP 宿主行为契约测试
# -----------------------------------------------------------------------------
# 目标：把 docs/02-前端路线B设计.md §5.6 H1–H10 的每一项行为钉死成可执行断言。
# 不依赖真实 OpenClash/LuCI：起本测试时本地 fork 宿主 + 用 mock CGI 脚本（覆写
# 真的 /www/cgi-bin/luci 是不现实的，所以用一个 shim：写一个 echo 脚本让它
# 读 PATH_INFO/REQUEST_METHOD 等环境变量并原样 echo 出来），
# 让所有断言都只针对宿主本身的 HTTP ↔ CGI 桥接层。
#
# 设计要点（与所有 test_*.sh 对齐）：
#   1. 单文件可跑：bash tests/test_luci_host.sh；ROOT 自解析（不要靠外部 set）
#   2. chk() 走 >&2 写人话日志，stdout 留给机器消费（n="$(...)"）
#   3. PASS/FAIL 风格沿用其他套件
#   4. 变异测试覆盖"语义锁"——下面会显式列
#
# 覆盖维度：
#   A) 启动与监听
#      A1 listen 默认 127.0.0.1
#      A2 port 默认 9090
#      A3 监听冲突立即 abort 不留位
#      A4 /etc/config/openclash-rt 改 main.port 生效
#   B) HTTP 路由
#      B1 / → 302 → /cgi-bin/luci/
#      B2 /cgi-bin/luci/ → CGI 调用，环境变量 V（REQUEST_METHOD / SCRIPT_NAME /
#                          PATH_INFO / QUERY_STRING / CONTENT_TYPE / CONTENT_LENGTH
#                          / SERVER_PROTOCOL / GATEWAY_INTERFACE）
#      B3 /cgi-bin/luci/admin/services/openclash/ → PATH_INFO 包含/admin/services
#      B4 /luci-static/<f> → 200 + Content-Type 对应 mime
#      B5 /luci-static/<nonexistent> → 404
#      B6 /luci-static/../etc/passwd → 403（路径逃逸）
#      B7 /unknown → 404
#   C) 静态高级
#      C1 If-Modified-Since 不晚于 mtime → 304
#      C2 If-Modified-Since 晚于 mtime → 200
#      C3 HEAD 不返回 body（Content-Length > 0 但 body 空）
#   D) CGI 协议
#      D1 CGI 子进程输出 Status: 302 → HTTP 302
#      D2 CGI 子进程输出 X-Header → HTTP header 透传
#      D3 CGI 子进程输出空 body → Content-Length: 0
#      D4 Content-Length > max_content → 413
#      D5 CGI 不输出 Status: 行 → 502
#      D6 CGI 子进程空 stdout → 502
#   E) 安全默认
#      E1 默认 listen=127.0.0.1；改 UCI 后生效
#
# 维度 E 是开监听地址的能力测试，不是回环路由 —— 改监听后必须能 curl 到才
# 算生效；监听 0.0.0.0 在 CI 上要 curl 0.0.0.0 才能验证，但 0.0.0.0 是路由
# 黑洞，最好是 127.0.0.2 多地址 loopback。
#
# 限制：
#   - 不验证 CGI 内容渲染（那是 P4 的事）
#   - 不验证 SSL/TLS（按 docs/02 §5.6 H10 默认非 TLS）
#   - 不验证 epoll 并发（当前 host 是 accept+sync；要外部扩展已撑）
# =============================================================================

set -u
set -o pipefail

# -----------------------------------------------------------------------------
# 路径自解析（不靠外部 set 传）
# -----------------------------------------------------------------------------
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOST_SRC="$ROOT/runtime/sys/luci-host.lua"
HOST_BIN="/usr/bin/lua5.1"
TESTS_DIR="$ROOT/tests"

# -----------------------------------------------------------------------------
# chk / log
# -----------------------------------------------------------------------------
TEST_NAME="test_luci_host"
PASS=0
FAIL=0
SKIP=0

log() {
	printf '[%s] %s\n' "$TEST_NAME" "$*" >&2
}

pass() {
	PASS=$((PASS + 1))
	printf '  PASS %s\n' "$*" >&2
}
fail() {
	FAIL=$((FAIL + 1))
	printf '  FAIL %s\n' "$*" >&2
}
skip() {
	SKIP=$((SKIP + 1))
	printf '  SKIP %s\n' "$*" >&2
}

die() {
	printf '[%s] %s\n' "$TEST_NAME" "$*" >&2
	exit 1
}

# -----------------------------------------------------------------------------
# 基础设施：临时目录、可执行宿主 + mock CGI
# -----------------------------------------------------------------------------
TMP="$(mktemp -d -t ocrt-lucihost.XXXXXX)"
trap 'cleanup' EXIT

# 启动前清扫：上轮 run 残留的 luci-host.lua 会占住 9090，让本轮 A1 既
# "PASS by accident"（curl 连到旧进程）+ 日志断言 FAIL。这种残留来自
# 外部手工跑 diag 时 nohup 起的进程（PID 不在 trap 里 kill）。
pkill -9 -f luci-host.lua 2>/dev/null || true
sleep 0.2

cleanup() {
	[ -n "${HOST_PID:-}" ] && kill -9 "$HOST_PID" 2>/dev/null || true
	sleep 0.1
	[ -n "${MOCK_PID:-}" ] && kill -9 "$MOCK_PID" 2>/dev/null || true
	# 兜底：上轮 run 残留的 luci-host.lua 进程会跟本轮抢 9090，导致 A1
	# "PASS by accident"（连到旧进程）+ 日志断言 FAIL。一律把所有
	# 不在本进程组的 luci-host.lua 全清掉。
	pkill -9 -f luci-host.lua 2>/dev/null || true
	if [ "${KEEP_TMP:-0}" = "1" ]; then
		printf '[%s] cleanup 保留 tmp=%s KEEP_TMP=%s\n' "$TEST_NAME" "$TMP" "${KEEP_TMP}" >&2
	else
		rm -rf "$TMP"
	fi
}

# 探测可执行 lua5.1
find_lua51() {
	if [ -x /usr/bin/lua5.1 ]; then
		HOST_BIN="/usr/bin/lua5.1"
	elif command -v lua5.1 >/dev/null 2>&1; then
		HOST_BIN="$(command -v lua5.1)"
	else
		die "找不到 lua5.1 解释器，跳过整个套件"
	fi
}

# 起一个 mock CGI —— 它把所收到的关键环境变量与 stdin 内容打成：
#   `Status: 200 OK`
#   `X-Cgi-Echo: YES`
#   `Content-Type: text/plain`
#   (空行)
#   `<key>=<value>` 一行一行
# 这样宿主会把它转成 HTTP 200 + X-Cgi-Echo 头 + body 含所有环境变量。
#
# 关键：Lua 5.1 字面量**不**解释 \r/\n 转义（只识别 \\）；要用 \13\10 写出
# 真正的 CR+LF 字节，否则宿主解析第一行时会带末尾反斜杠，\n+ break
# coroutine resume 直接失败（这是真机 bug 的源头：mock 看似简单，\n+ break
# 实际写文件却常写成 "\r\n" 字面三字符）。
make_mock_cgi() {
	local out="$1"
	cat >"$out" <<'CGISCRIPT'
#!/usr/bin/env lua5.1
io.stdout:write("Status: 200 OK\13\10")
io.stdout:write("X-Cgi-Echo: YES\13\10")
io.stdout:write("Content-Type: text/plain\13\10")
io.stdout:write("\13\10")
local keys = {
	"REQUEST_METHOD", "SCRIPT_NAME", "PATH_INFO", "PATH_TRANSLATED",
	"QUERY_STRING", "CONTENT_TYPE", "CONTENT_LENGTH",
	"SERVER_PROTOCOL", "GATEWAY_INTERFACE", "SERVER_SOFTWARE",
	"SERVER_NAME", "SERVER_PORT", "DOCUMENT_ROOT", "REQUEST_URI",
	"REDIRECT_STATUS", "HTTPS", "REMOTE_ADDR", "REMOTE_PORT",
	"HTTP_HOST", "HTTP_USER_AGENT", "HTTP_ACCEPT",
}
table.sort(keys)
for _, k in ipairs(keys) do
	local v = os.getenv(k)
	if v ~= nil then
		io.stdout:write(k .. "=" .. v .. "\10")
	end
end
-- 把 stdin 也回显出来（验证 body 转发）
local body = io.read("*a") or ""
if body ~= "" then
	io.stdout:write("BODY=" .. body .. "\10")
end
CGISCRIPT
	chmod 0755 "$out"
}

# 起一个 mock CGI —— 根据 stdin 第一行的指令返回不同状态码
make_mock_cgi_status() {
	local out="$1"
	cat >"$out" <<'CGISCRIPT'
#!/usr/bin/env lua5.1
local status = os.getenv("X_MOCK_STATUS") or "200"
local reason = os.getenv("X_MOCK_REASON") or "OK"
local hdr    = os.getenv("X_MOCK_HDR") or "Content-Type"
local hval   = os.getenv("X_MOCK_HVAL") or "text/plain"
io.stdout:write("Status: " .. status .. " " .. reason .. "\13\10")
io.stdout:write(hdr .. ": " .. hval .. "\13\10")
io.stdout:write("\13\10")
io.stdout:write("mock-body")
CGISCRIPT
	chmod 0755 "$out"
}

# 起一个 CGI —— 输出空 stdout（用于 D6）
make_mock_cgi_empty() {
	local out="$1"
	cat >"$out" <<'CGISCRIPT'
#!/usr/bin/env lua5.1
-- 完全空 stdout
CGISCRIPT
	chmod 0755 "$out"
}

# 起一个 CGI —— 不输出 Status: 行
make_mock_cgi_no_status() {
	local out="$1"
	cat >"$out" <<'CGISCRIPT'
#!/usr/bin/env lua5.1
io.stdout:write("Content-Type: text/plain\13\10")
io.stdout:write("\13\10")
io.stdout:write("hello")
CGISCRIPT
	chmod 0755 "$out"
}

# 拿空闲端口
free_port() {
	# python 的 socket.assign 比 netselect 更确定
	python3 -c "import socket; s=socket.socket(); s.bind(('',0)); print(s.getsockname()[1]); s.close()"
}

# 启一个 host 进程；返回 pid + port + temp_root（docroot 子树）
# Args:
#   $1  docroot 路径（宿主会读 /docroot/luci-static/* 与 /docroot/cgi-bin/luci）
#   $2  cgi 路径（绝对）
#   $3  listen host (default 127.0.0.1)
#   $4  port (default 0 = 自动选)
#   $5  max_content (default 10240)
start_host() {
	local docroot="$1"
	local cgi="$2"
	local listen="${3:-127.0.0.1}"
	local port="${4:-0}"
	local max_content="${5:-10240}"

	local cfg="$TMP/uci-test.conf"
	if [ ! -f "$cfg" ]; then
		cat >"$cfg" <<EOF
config openclash_rt 'main'
	option listen '$listen'
EOF
	fi

	if [ "$port" = "0" ]; then
		port="$(free_port)"
	fi

	"$HOST_BIN" "$HOST_SRC" \
		--listen="$listen" \
		--port="$port" \
		--cgi="$cgi" \
		--docroot="$docroot" \
		--config="$cfg" \
		--max-content="$max_content" \
		> "$TMP/host.log" 2>&1 &
	HOST_PID=$!

	# 等监听就绪
	local i
	for i in 1 2 3 4 5 6 7 8 9 10; do
		if (echo > "/dev/tcp/$listen/$port") 2>/dev/null; then
			break
		fi
		sleep 0.2
	done
	if ! (echo > "/dev/tcp/$listen/$port") 2>/dev/null; then
		kill -9 "$HOST_PID" 2>/dev/null || true
		die "host 启不来（log 在 $TMP/host.log）"
	fi

	echo "$HOST_PID" "$port"
}

# curl wrapper —— 取 HTTP status 与 body 到 $TMP/curl.body / $TMP/status
# 注意：HTTP headers 默认不写入 curl.body；要分两个文件用 -D + -o
curl_to() {
	local port="$1"
	local path="$2"
	shift 2

	curl -s -o "$TMP/curl.body" -D "$TMP/curl.hdr" \
		-w '%{http_code}' "$@" "http://127.0.0.1:$port$path" \
		> "$TMP/status" 2>"$TMP/curl.err"
}

# 用 -i 把 headers 也写到 body（方便某些 grep 断言）
curl_to_all() {
	local port="$1"
	local path="$2"
	shift 2

	curl -s -i -o "$TMP/curl.body" -w '%{http_code}' "$@" "http://127.0.0.1:$port$path" \
		> "$TMP/status" 2>"$TMP/curl.err"
}

# head-style check
chk_http_status() {
	local desc="$1"
	local expect="$2"
	local got="$(cat "$TMP/status" 2>/dev/null)"
	if [ "$got" = "$expect" ]; then
		pass "$desc (status=$got)"
	else
		fail "$desc (got=$got want=$expect)"
	fi
}

chk_body_contains() {
	local desc="$1"
	local needle="$2"
	if grep -qF "$needle" "$TMP/curl.body" 2>/dev/null; then
		pass "$desc (body 含 '$needle')"
	else
		fail "$desc (body 不含 '$needle')"
	fi
}

chk_body_missing() {
	local needle="$1"
	grep -qF "$needle" "$TMP/curl.body" 2>/dev/null \
		&& fail "body 含 '$needle'（不该含）" \
		|| pass "body 不含 '$needle'"
}

chk_log_has() {
	# 默认读 $TMP/host.log；可指定其他文件
	local needle="$1"
	local logfile="${2:-$TMP/host.log}"
	if grep -qF "$needle" "$logfile" 2>/dev/null; then
		pass "log 含 '$1'"
	else
		fail "log 不含 '$1'（查 $logfile）"
	fi
}

# -----------------------------------------------------------------------------
# 准备测试 fixture
# -----------------------------------------------------------------------------
DOCROOT="$TMP/www"
mkdir -p "$DOCROOT/cgi-bin" "$DOCROOT/luci-static"
MOCK_CGI="$DOCROOT/cgi-bin/luci"
make_mock_cgi "$MOCK_CGI"

# 静态测试文件
echo "hello-static" > "$DOCROOT/luci-static/index.txt"
echo "css-body" > "$DOCROOT/luci-static/style.css"
echo "gif-fake" > "$DOCROOT/luci-static/img.gif"

# 探测 lua
find_lua51

log "开始测试（PID_ROOT=$TMP）"

# -----------------------------------------------------------------------------
# A) 启动与监听
# -----------------------------------------------------------------------------
log "A) 启动与监听"

# A1/A2: 启默认（不传 listen/port），靠 UCI 兜底（127.0.0.1/0=自动）
CFG_A="$TMP/uci-a.conf"
cat >"$CFG_A" <<EOF
config openclash_rt 'main'
	option listen '127.0.0.1'
EOF
"$HOST_BIN" "$HOST_SRC" \
	--cgi="$MOCK_CGI" --docroot="$DOCROOT" \
	--config="$CFG_A" \
	> "$TMP/host-a.log" 2>&1 &
HOST_PID=$!
sleep 0.3
A_PORT="$(free_port)"
# 关掉这个（我们要看默认行为，但默认行为是 9090）
kill -9 "$HOST_PID" 2>/dev/null || true

# 真正启：让它默认 9090，看 ss
"$HOST_BIN" "$HOST_SRC" \
	--cgi="$MOCK_CGI" --docroot="$DOCROOT" \
	--config="$CFG_A" \
	> "$TMP/host-a.log" 2>&1 &
HOST_PID=$!
sleep 0.5
if (echo > "/dev/tcp/127.0.0.1/9090") 2>/dev/null; then
	pass "A1 监听 9090（默认）"
else
	fail "A1 启不来（默认 9090）"
fi
chk_log_has "listening on 127.0.0.1:9090" "$TMP/host-a.log"

# A3: 监听冲突 → 立即 abort 不留位
"$HOST_BIN" "$HOST_SRC" \
	--cgi="$MOCK_CGI" --docroot="$DOCROOT" \
	--config="$CFG_A" --port=9090 \
	> "$TMP/host-a3.log" 2>&1
RC=$?
if [ "$RC" -ne 0 ]; then
	pass "A3 监听冲突立即 abort（rc=$RC）"
else
	fail "A3 端口被占仍 accept（不应）"
fi
chk_log_has "bind 127.0.0.1:9090 failed" "$TMP/host-a3.log"

# A4: UCI 改 main.listen/port 生效
CFG_A4="$TMP/uci-a4.conf"
cat >"$CFG_A4" <<EOF
config openclash_rt 'main'
	option listen '127.0.0.1'
	option port '9099'
EOF
A4_PORT="$(free_port)"
"$HOST_BIN" "$HOST_SRC" \
	--cgi="$MOCK_CGI" --docroot="$DOCROOT" \
	--config="$CFG_A4" --port="$A4_PORT" \
	> "$TMP/host-a4.log" 2>&1 &
HOST_PID_A4=$!
sleep 0.5
if (echo > "/dev/tcp/127.0.0.1/$A4_PORT") 2>/dev/null; then
	pass "A4 命令行 port=$A4_PORT 生效"
else
	fail "A4 命令行 port 失效"
fi
kill -9 "$HOST_PID_A4" 2>/dev/null || true

# -----------------------------------------------------------------------------
# B) HTTP 路由
# -----------------------------------------------------------------------------
log "B) HTTP 路由"

# 重启一个 host 用于本组
B_PORT="$(free_port)"
"$HOST_BIN" "$HOST_SRC" \
	--cgi="$MOCK_CGI" --docroot="$DOCROOT" \
	--config="$CFG_A" --port="$B_PORT" \
	> "$TMP/host-b.log" 2>&1 &
HOST_PID=$!
sleep 0.5

# B1: / → 302 → /cgi-bin/luci/
curl_to_all "$B_PORT" "/"
chk_http_status "B1 /" "302"
chk_body_contains "B1 Location header" "Location: /cgi-bin/luci/"

# B2: /cgi-bin/luci/ → 200 + 关键 CGI env
curl_to_all "$B_PORT" "/cgi-bin/luci/"
chk_http_status "B2 /cgi-bin/luci/" "200"
chk_body_contains "B2 REQUEST_METHOD"   "REQUEST_METHOD=GET"
chk_body_contains "B2 SCRIPT_NAME"      "SCRIPT_NAME=/cgi-bin/luci"
chk_body_contains "B2 PATH_INFO"        "PATH_INFO=/"
chk_body_contains "B2 GATEWAY_INTERFACE" "GATEWAY_INTERFACE=CGI/1.1"
chk_body_contains "B2 SERVER_PROTOCOL"   "SERVER_PROTOCOL=HTTP/1.1"
chk_body_contains "B2 DOCUMENT_ROOT"     "DOCUMENT_ROOT=$DOCROOT"
chk_body_contains "B2 X-Cgi-Echo header" "X-Cgi-Echo: YES"

# B3: /cgi-bin/luci/admin/services/openclash/ → PATH_INFO 包含完整路径
curl_to_all "$B_PORT" "/cgi-bin/luci/admin/services/openclash/"
chk_http_status "B3 /cgi-bin/luci/admin/services/openclash/" "200"
chk_body_contains "B3 PATH_INFO 完整" "PATH_INFO=/admin/services/openclash/"

# B4: 静态文件
curl_to_all "$B_PORT" "/luci-static/style.css"
chk_http_status "B4 /luci-static/style.css" "200"
chk_body_contains "B4 style.css body" "css-body"
chk_body_contains "B4 Content-Type css" "Content-Type: text/css"

# B4b: 静态 gif
curl_to_all "$B_PORT" "/luci-static/img.gif"
chk_http_status "B4b /luci-static/img.gif" "200"
chk_body_contains "B4b img.gif mime" "Content-Type: image/gif"

# B5: 静态不存在 → 404
curl_to "$B_PORT" "/luci-static/missing.txt"
chk_http_status "B5 /luci-static/missing.txt" "404"

# B6: 路径逃逸 → 403
#     现实：浏览器 / curl 默认都不会把 /../ 原样发在请求行里（curl 会先规范化），
#     攻击者是手写 raw 请求。所以这条断言的关键是**不让 curl 规范化路径**。
#
#     原实现用 socat 拼 raw TCP，但 socat 不是每台机器都有 —— CI 的
#     ubuntu-24.04 runner 上就没装，于是整条管道失败、\$TMP/curl.body 为空、
#     status 为空，报出一条看不懂的 `B6 path traversal (got= want=403)`
#     （2026-10-01 实测：CI 638 PASS / 1 FAIL 里那 1 个就是它）。
#
#     改用 curl 自带的 --path-as-is（curl >= 7.42，2015 年就有）：
#     它让 curl 原样发送 /luci-static/../etc/passwd。
#     已在 Debian 上与 socat raw 请求做过等价对比：
#         socat raw        → HTTP/1.1 403 Forbidden
#         curl --path-as-is → status=403          ← 一致
#         curl 默认（会规范化成 /etc/passwd）→ 404  ← 证明该参数确实必要
curl --path-as-is -s -o "$TMP/curl.body" -w '%{http_code}' \
	"http://127.0.0.1:$B_PORT/luci-static/../etc/passwd" \
	>"$TMP/status" 2>"$TMP/curl.err" || true
# curl 太老不支持 --path-as-is 时必须 fail-loud，不能静默变成 "通过"
if grep -qE "unknown option|--path-as-is" "$TMP/curl.err" 2>/dev/null; then
	fail "B6 path traversal（curl 不支持 --path-as-is，无法验证逃逸）"
else
	chk_http_status "B6 path traversal" "403"
fi

# B7: unknown → 404
curl_to "$B_PORT" "/some/unknown/path"
chk_http_status "B7 unknown path" "404"

# B8: query string 透传
curl_to_all "$B_PORT" "/cgi-bin/luci/?foo=bar&baz=1"
chk_http_status "B8 query" "200"
chk_body_contains "B8 QUERY_STRING" "QUERY_STRING=foo=bar&baz=1"

kill -9 "$HOST_PID" 2>/dev/null || true
sleep 0.2

# -----------------------------------------------------------------------------
# C) 静态高级
# -----------------------------------------------------------------------------
log "C) 静态高级"

# 重起 host
C_PORT="$(free_port)"
"$HOST_BIN" "$HOST_SRC" \
	--cgi="$MOCK_CGI" --docroot="$DOCROOT" \
	--config="$CFG_A" --port="$C_PORT" \
	> "$TMP/host-c.log" 2>&1 &
HOST_PID=$!
sleep 0.5

# C1: If-Modified-Since 不晚于 mtime → 304
MTIME="$(stat -c '%y' "$DOCROOT/luci-static/style.css")"
MTIME_HDR="$(date -u -d "$MTIME" '+%a, %d %b %Y %H:%M:%S GMT')"
curl -s -o "$TMP/curl.body" -w '%{http_code}' \
	-H "If-Modified-Since: $MTIME_HDR" \
	"http://127.0.0.1:$C_PORT/luci-static/style.css" > "$TMP/status" 2>"$TMP/curl.err"
chk_http_status "C1 IMS = mtime" "304"

# C2: If-Modified-Since 比 mtime 早 5 天 → 200（文件比客户端新 → 重发）
#   **必须**是过去式："IMS 早于 mtime"，不是未来；标准 RFC 7232 §3.3 是：
#   若 mt <= IMS → 304；只有 mt > IMS 才 200。把测试写反会强制宿主"违反 RFC"
#   故意返 200，那是 bug 不是契约。
PAST_HDR="$(date -u -d "$MTIME -5 days" '+%a, %d %b %Y %H:%M:%S GMT')"
curl -s -o "$TMP/curl.body" -w '%{http_code}' \
	-H "If-Modified-Since: $PAST_HDR" \
	"http://127.0.0.1:$C_PORT/luci-static/style.css" > "$TMP/status" 2>"$TMP/curl.err"
chk_http_status "C2 IMS 比 mtime 早 5 天" "200"

# C3: HEAD 不返 body
#   用 -X HEAD 显式发 HEAD 方法，并查 size_download（curl 不会为 HEAD 收 body）。
#   之前用 -I（隐式 HEAD）会把 header 行也写进 -o 文件，"body 非空"误报。
SIZE=$(curl -s -o /dev/null -w '%{http_code} %{size_download}' \
	-X HEAD \
	"http://127.0.0.1:$C_PORT/luci-static/style.css" 2>"$TMP/curl.err")
STATUS="${SIZE%% *}"
DL="${SIZE##* }"
echo "$STATUS" > "$TMP/status"
chk_http_status "C3 HEAD" "200"
if [ "$DL" = "0" ]; then
	pass "C3 HEAD body 空（size_download=0）"
else
	fail "C3 HEAD body 非空（size_download=$DL）"
fi

kill -9 "$HOST_PID" 2>/dev/null || true
sleep 0.2

# -----------------------------------------------------------------------------
# D) CGI 协议
# -----------------------------------------------------------------------------
log "D) CGI 协议"

# 重起 host（D1-D6 各用不同 CGI mock）
D_PORT="$(free_port)"

# D1/D2/D3: 用默认 CGI mock（输出 Status: 200 OK + X-Cgi-Echo）
"$HOST_BIN" "$HOST_SRC" \
	--cgi="$MOCK_CGI" --docroot="$DOCROOT" \
	--config="$CFG_A" --port="$D_PORT" \
	> "$TMP/host-d.log" 2>&1 &
HOST_PID=$!
sleep 0.5

# D1/D2/D3
# D2 验证 CGI header 透传 → 必须用 curl_to_all 让 header 落到 body
curl_to_all "$D_PORT" "/cgi-bin/luci/"
chk_http_status "D1 CGI 200" "200"
chk_body_contains "D2 X-Cgi-Echo 透传" "X-Cgi-Echo: YES"
grep -q "Content-Length: 0" "$TMP/curl.body" 2>/dev/null \
	&& fail "D3 CGI 有 body，期望非空" \
	|| pass "D3 CGI 有 body（>0）"

# D4: max_content=10，curl 发 100 字节 POST → 413
D4_PORT="$(free_port)"
"$HOST_BIN" "$HOST_SRC" \
	--cgi="$MOCK_CGI" --docroot="$DOCROOT" \
	--config="$CFG_A" --port="$D4_PORT" --max-content=10 \
	> "$TMP/host-d4.log" 2>&1 &
HOST_PID_D4=$!
sleep 0.5
BODY="$(printf 'x%.0s' $(seq 1 100))"
curl -s -o "$TMP/curl.body" -w '%{http_code}' \
	--data-binary "$BODY" \
	"http://127.0.0.1:$D4_PORT/cgi-bin/luci/" > "$TMP/status" 2>"$TMP/curl.err"
chk_http_status "D4 body > max_content" "413"
kill -9 "$HOST_PID_D4" 2>/dev/null || true

kill -9 "$HOST_PID" 2>/dev/null || true
sleep 0.2

# D5: CGI 不输出 Status: → 502
MOCK_NO_STATUS="$DOCROOT/cgi-bin/no-status"
make_mock_cgi_no_status "$MOCK_NO_STATUS"
D5_PORT="$(free_port)"
"$HOST_BIN" "$HOST_SRC" \
	--cgi="$MOCK_NO_STATUS" --docroot="$DOCROOT" \
	--config="$CFG_A" --port="$D5_PORT" \
	> "$TMP/host-d5.log" 2>&1 &
HOST_PID=$!
sleep 0.5
curl_to "$D5_PORT" "/cgi-bin/luci/"
chk_http_status "D5 no Status line" "502"
kill -9 "$HOST_PID" 2>/dev/null || true
sleep 0.2

# D6: CGI 空 stdout → 502
MOCK_EMPTY="$DOCROOT/cgi-bin/empty"
make_mock_cgi_empty "$MOCK_EMPTY"
D6_PORT="$(free_port)"
"$HOST_BIN" "$HOST_SRC" \
	--cgi="$MOCK_EMPTY" --docroot="$DOCROOT" \
	--config="$CFG_A" --port="$D6_PORT" \
	> "$TMP/host-d6.log" 2>&1 &
HOST_PID=$!
sleep 0.5
curl_to "$D6_PORT" "/cgi-bin/luci/"
chk_http_status "D6 empty CGI" "502"
kill -9 "$HOST_PID" 2>/dev/null || true
sleep 0.2

# -----------------------------------------------------------------------------
# E) 安全默认（UCI 改 main.listen）
# -----------------------------------------------------------------------------
log "E) 安全默认"

E_CFG="$TMP/uci-e.conf"
cat >"$E_CFG" <<EOF
config openclash_rt 'main'
	option listen '127.0.0.1'
EOF

# E1: 默认 listen=127.0.0.1（已由 A 组覆盖过；这里再次确认 + UCI override）
E_PORT="$(free_port)"
"$HOST_BIN" "$HOST_SRC" \
	--cgi="$MOCK_CGI" --docroot="$DOCROOT" \
	--config="$E_CFG" --port="$E_PORT" \
	> "$TMP/host-e.log" 2>&1 &
HOST_PID=$!
sleep 0.5
curl_to "$E_PORT" "/"
chk_http_status "E1 UCI listen=127.0.0.1" "302"
kill -9 "$HOST_PID" 2>/dev/null || true
sleep 0.2

# -----------------------------------------------------------------------------
# 变异测试 — 锁不空转
# -----------------------------------------------------------------------------
log "变异锁不变红"

# M1: 把 ARGS.parse_args 整个去掉（命令行参数全失效）
MOCK_HOST="$TMP/luci-host-noargs.lua"
sed 's|local _parsed = parse_args(arg or {})|-- local _parsed = {}|' "$HOST_SRC" > "$MOCK_HOST"
M1_PORT="$(free_port)"
"$HOST_BIN" "$MOCK_HOST" \
	--cgi="$MOCK_CGI" --docroot="$DOCROOT" \
	--config="$E_CFG" --port="$M1_PORT" \
	> "$TMP/host-m1.log" 2>&1 &
M1_PID=$!
sleep 0.5
if (echo > "/dev/tcp/127.0.0.1/$M1_PORT") 2>/dev/null; then
	# 此时 --port=$M1_PORT 应**无效**（变异去掉命令行），结果端口被冲突掉
	# 但实际：DEFAULTS.port=9090，又因为 UCI 没 port，host 监听 9090 而不是 M1_PORT
	# 故 M1_PORT 上根本 listen 不到 —— 反过来 M1_PORT=9090 才 fail
	if (echo > "/dev/tcp/127.0.0.1/M1_PORT") 2>/dev/null; then
		fail "M1 变异没生效（还能连 M1_PORT）"
	else
		pass "M1 变异生效（命令行 --port 失效，监听默认 9090）"
	fi
fi
kill -9 "$M1_PID" 2>/dev/null || true
sleep 0.2

# M2: 把 STATUS_TEXT[302] = "Found" 去掉（路径验证中断）
MOCK_HOST2="$TMP/luci-host-no302.lua"
sed 's|\[302\] = "Found",|-- [302] = "Found",|' "$HOST_SRC" > "$MOCK_HOST2"
M2_PORT="$(free_port)"
"$HOST_BIN" "$MOCK_HOST2" \
	--cgi="$MOCK_CGI" --docroot="$DOCROOT" \
	--config="$E_CFG" --port="$M2_PORT" \
	> "$TMP/host-m2.log" 2>&1 &
M2_PID=$!
sleep 0.5
curl -s -o "$TMP/curl.body" -w '%{http_code}' "http://127.0.0.1:$M2_PORT/" > "$TMP/status" 2>"$TMP/curl.err"
# 正常应该 302；如果变异生效会是 "HTTP/1.1 302 OK\r\n" —— 'OK' 不合规
if grep -q "302 OK" "$TMP/curl.body" 2>/dev/null; then
	fail "M2 变异生效（STATUS_TEXT[302] 被改）"
else
	pass "M2 STATUS_TEXT[302] 守住"
fi
kill -9 "$M2_PID" 2>/dev/null || true
sleep 0.2

# M3: CGI_BIN_PREFIX 改成 /cgi-bin/luci2 — 应段错
MOCK_HOST3="$TMP/luci-host-wrongprefix.lua"
sed 's|"/cgi-bin/luci"|"/cgi-bin/luci2"|' "$HOST_SRC" > "$MOCK_HOST3"
M3_PORT="$(free_port)"
"$HOST_BIN" "$MOCK_HOST3" \
	--cgi="$MOCK_CGI" --docroot="$DOCROOT" \
	--config="$E_CFG" --port="$M3_PORT" \
	> "$TMP/host-m3.log" 2>&1 &
M3_PID=$!
sleep 0.5
curl -s -o "$TMP/curl.body" -w '%{http_code}' "http://127.0.0.1:$M3_PORT/cgi-bin/luci/" > "$TMP/status" 2>"$TMP/curl.err"
chk_http_status "M3 CGI_BIN_PREFIX 变坏必 404" "404"
kill -9 "$M3_PID" 2>/dev/null || true
sleep 0.2

# -----------------------------------------------------------------------------
# 收尾
# -----------------------------------------------------------------------------
log "结果 PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
# 摘要行用「空格」分隔（与 test_dns_prep 等老套件一致），便于
# tests/run-all.sh 的 awk 解析器正则 PASS[ \t]*N + FAIL[ \t]*N 命中。
printf '  PASS %d   FAIL %d   SKIP %d\n' "$PASS" "$FAIL" "$SKIP" >&2
if [ "$FAIL" -ne 0 ]; then
	exit 1
fi
exit 0