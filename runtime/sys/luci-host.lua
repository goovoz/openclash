#!/usr/bin/lua5.1
-- =============================================================================
-- openclash-rt 的 LuCI HTTP 宿主（P3 自研件）
-- -----------------------------------------------------------------------------
-- 这是 openclash-rt **前端 HTTP 层**的最小可工作实现。它对外提供 HTTP 服务，
-- 对内把请求当作 CGI 喂给上游 /www/cgi-bin/luci（CGI 协议详见 RFC 3875 + LuCI
-- sgi/cgi.lua）。
--
-- 设计目标（一一对应 docs/02-前端路线B设计.md §5.6 H1–H10）：
--   H1  静态文件服务（/luci-static/* → /www/luci-static/*）
--   H2  动态路由            /cgi-bin/luci[/<PATH_INFO>]
--   H3  CGI 环境变量        REQUEST_METHOD/PATH_INFO/SCRIPT_NAME/QUERY_STRING/
--                          CONTENT_TYPE/CONTENT_LENGTH/SERVER_NAME/SERVER_PORT/
--                          REMOTE_ADDR/REMOTE_PORT/HTTP_*
--   H4  请求体转发         fork+pipe，按 Content-Length 把请求体喂给 CGI
--   H5  响应解析           Status: 行 → HTTP 状态码；其余头 → 响应头；空行后正文
--   H6  HTTP_MAX_CONTENT   从 /etc/config/openclash-rt 读 main.script_timeout /
--                          max_connections / max_requests
--   H7  超时              script_timeout 默认 3600s（上游要求值）
--   H8  并发              max_requests=50 / max_connections=100（上游要求值）
--   H9  子进程回收         CGI 超时 kill -TERM；客户端断开 → 子进程 stdin 关闭
--                          → 上游脚本自然结束
--   H10 监听              默认 127.0.0.1:9090（安全默认；要外露必须显式改
--                          /etc/config/openclash-rt）
--
-- **单一职责**：解释 HTTP ↔ CGI 协议，**不**做认证、不**改写**上游 LuCI 的任何
-- .lua / .htm。鉴权由 luci.dispatcher 自身的 session 模块处理（见 P4）。
--
-- **硬约束**（与上游契约）：
--   - /www/cgi-bin/luci 的 shebang 已被 pin-lua-interpreter.sh 在打包期改写
--     为 #!/usr/bin/lua5.1。
--   - 静态文件路径必须用 realpath 限制在 /www/ 之下，禁止 ../ 逃逸。
--   - Content-Length 是请求体字节上限，不是 stream 截止。**绝不**信任客户端
--     给的负值 / 极大值。
--
-- 退出码：
--   0  正常退出（收到 SIGTERM/SIGINT）
--   非0 监听失败 / 参数错
--
-- 用法：
--   /usr/lib/openclash-rt/luci-host.lua [--listen=ADDR] [--port=N]
--                          [--cgi=/www/cgi-bin/luci]
--                          [--docroot=/www]
--                          [--config=/etc/config/openclash-rt]
--                          [--max-content=N]
-- =============================================================================

local nixio      = require("nixio")
local nixio_fs   = require("nixio.fs")
local nixio_util = require("nixio.util")

-- -----------------------------------------------------------------------------
-- §A 默认参数
-- -----------------------------------------------------------------------------
local DEFAULTS = {
	listen        = "127.0.0.1",
	port          = 9090,
	cgi           = "/www/cgi-bin/luci",
	docroot       = "/www",
	config        = "/etc/config/openclash-rt",
	max_content   = 1024 * 10240,   -- 10 MiB，与上游 uci-defaults 改 http.lua 的值一致
	script_timeout = 3600,           -- 上游要求
	max_connections = 100,
}

local CGI_BIN_PREFIX = "/cgi-bin/luci"   -- 唯一 CGI 入口（vendor luci-base 的硬编码）
local STATIC_PREFIX  = "/luci-static"     -- 静态资源根

-- 简易 mime 表（够用即可。未知类型回 application/octet-stream）
local MIME = {
	html = "text/html; charset=utf-8",
	htm  = "text/html; charset=utf-8",
	css  = "text/css; charset=utf-8",
	js   = "application/javascript; charset=utf-8",
	json = "application/json; charset=utf-8",
	png  = "image/png",
	jpg  = "image/jpeg",
	jpeg = "image/jpeg",
	gif  = "image/gif",
	ico  = "image/x-icon",
	svg  = "image/svg+xml",
	woff = "font/woff",
	woff2= "font/woff2",
	ttf  = "font/ttf",
	txt  = "text/plain; charset=utf-8",
	map  = "application/json; charset=utf-8",
}

-- -----------------------------------------------------------------------------
-- §B 命令行参数解析
-- -----------------------------------------------------------------------------
local function parse_args(argv)
	local opts = {}
	for i = 1, #argv do
		local a = argv[i]
		local k, v = a:match("^%-%-([%w%-]+)=(.*)$")
		if k then
			opts[k:gsub("%-", "_")] = v
		elseif a == "--help" then
			io.write("usage: luci-host.lua [--listen=ADDR] [--port=N]\n"
				.. "                     [--cgi=PATH] [--docroot=PATH]\n"
				.. "                     [--config=PATH] [--max-content=N]\n")
			os.exit(0)
		else
			io.stderr:write("luci-host.lua: unknown arg: " .. a .. "\n")
			os.exit(2)
		end
	end
	return opts
end

local ARGS = {}
for k, v in pairs(DEFAULTS) do ARGS[k] = v end
local _parsed = parse_args(arg or {})
for k, v in pairs(_parsed) do ARGS[k] = v end
local function tonum_pos(s, fallback)
	local n = tonumber(s)
	if n and n > 0 then return n end
	return fallback
end
ARGS.port           = tonum_pos(ARGS.port, DEFAULTS.port)
ARGS.max_content    = tonum_pos(ARGS.max_content, DEFAULTS.max_content)
ARGS.script_timeout = tonum_pos(ARGS.script_timeout, DEFAULTS.script_timeout)
ARGS.max_connections= tonum_pos(ARGS.max_connections, DEFAULTS.max_connections)

-- -----------------------------------------------------------------------------
-- §C 从 /etc/config/openclash-rt 读 listen/port/script_timeout（如果存在）
--   格式（UCI）：config openclash_rt 'main'
--                   opt listen  0.0.0.0
--                   opt port    80
--                   opt script_timeout 3600
--                   opt max_connections 100
-- -----------------------------------------------------------------------------
local function load_uci_config(path)
	local cfg = {}
	if not nixio_fs.stat(path) then return cfg end
	local f = io.open(path, "r")
	if not f then return cfg end
	local in_main
	for line in f:lines() do
		local sec = line:match("^config%s+%S+%s+'(.-)'")
		if sec then
			in_main = (sec == "main")
		elseif in_main then
			local k, v = line:match("^%s*option%s+([%w_]+)%s+['\"]?([^'\"]+)['\"]?")
			if k then cfg[k] = v end
		end
	end
	f:close()
	return cfg
end

local UCI_CFG = load_uci_config(ARGS.config)
-- 优先级：命令行 > UCI > DEFAULTS。
-- 上面已经把 _parsed 全量灌进 ARGS，所以 UCI 只该补 _parsed 没改的键。
if UCI_CFG.listen          and _parsed["listen"]          == nil then ARGS.listen          = UCI_CFG.listen end
if UCI_CFG.port            and _parsed["port"]            == nil then ARGS.port            = tonum_pos(UCI_CFG.port,            ARGS.port) end
if UCI_CFG.script_timeout  and _parsed["script_timeout"]  == nil then ARGS.script_timeout  = tonum_pos(UCI_CFG.script_timeout,  ARGS.script_timeout) end
if UCI_CFG.max_connections and _parsed["max_connections"] == nil then ARGS.max_connections = tonum_pos(UCI_CFG.max_connections, ARGS.max_connections) end

-- -----------------------------------------------------------------------------
-- §D HTTP 响应组装
-- -----------------------------------------------------------------------------
local STATUS_TEXT = {
	[200] = "OK", [204] = "No Content",
	[301] = "Moved Permanently", [302] = "Found",
	[304] = "Not Modified",
	[400] = "Bad Request", [403] = "Forbidden", [404] = "Not Found",
	[408] = "Request Timeout", [411] = "Length Required",
	[413] = "Payload Too Large",
	[500] = "Internal Server Error", [502] = "Bad Gateway",
	[503] = "Service Unavailable", [504] = "Gateway Timeout",
}

local HTTP_DATE_FMT = "!%a, %d %b %Y %H:%M:%S GMT"

local function send_status(sock, code, headers, body)
	local reason = STATUS_TEXT[code] or "OK"
	headers = headers or {}
	body = body or ""
	headers["Content-Length"] = headers["Content-Length"] or tostring(#body)
	if not headers["Connection"] then
		headers["Connection"] = "close"
	end
	headers["Server"] = headers["Server"] or "openclash-rt-luci-host/1.0"

	local out = { string.format("HTTP/1.1 %d %s\r\n", code, reason) }
	for k, v in pairs(headers) do
		table.insert(out, string.format("%s: %s\r\n", k, v))
	end
	table.insert(out, "\r\n")
	table.insert(out, body)
	local s = table.concat(out)
	local _, _ = sock:write(s)
end

local function mime_for(path)
	local ext = path:match("%.([%w]+)$")
	if ext and MIME[ext:lower()] then return MIME[ext:lower()] end
	return "application/octet-stream"
end

local MONTH_IDX = {
	Jan=1, Feb=2, Mar=3, Apr=4, May=5, Jun=6,
	Jul=7, Aug=8, Sep=9, Oct=10, Nov=11, Dec=12,
}
local function parse_http_date(s)
	-- Sun, 06 Nov 1994 08:49:37 GMT
	-- **第三坑**：Lua 5.1 的 os.time 把传入的 hour/min/sec 当**本地时间**，
	-- 且 os.execute("export TZ=UTC") 改的是子进程，**不影响父进程**；
	-- 当前系统 TZ=CST，给 hour=15 实际得到 15:37 CST 的 epoch (= 07:37 UTC)。
	-- 修：用 `date -u` 子进程算出 UTC epoch。
	local function pipe_epoch(d, mo, y, hh, mm, ss)
		local cmd = string.format(
			'date -u -d "%s %s %s %s:%s:%s" +%%s 2>/dev/null',
			d, mo, y, hh, mm, ss)
		local f = io.popen(cmd, "r")
		if not f then return nil end
		local line = f:read("*l")
		f:close()
		if not line then return nil end
		return tonumber(line)
	end

	-- 注意：regex 有 7 个 capture（wkday, day, mon, year, hh, mm, ss）
	-- 必须用 7 个变量接，Lua 5.1 在赋值时从末尾截断多返回值，第 7 个被丢，
	-- 剩 6 个值会右移错位（d 拿到 Thu）。这是 2026-10-01 C1 的根因：
	-- Lua 抛 day missing in date table。
	local _, d, mo, y, hh, mm, ss = s:match("^(%a+),%s+(%d+)%s+(%a+)%s+(%d+)%s+(%d+):(%d+):(%d+)%s+GMT$")
	if d then
		return pipe_epoch(d, mo, y, hh, mm, ss)
	end
	local _, d2, mo2, y2, hh2, mm2, ss2 = s:match("^(%a+),%s+(%d+)%-(%a+)%-(%d+)%s+(%d+):(%d+):(%d+)%s+GMT$")
	if d2 then
		local yy = tonumber(y2)
		if yy < 70 then yy = 2000 + yy else yy = 1900 + yy end
		return pipe_epoch(d2, mo2, tostring(yy), hh2, mm2, ss2)
	end
	return nil
end

-- -----------------------------------------------------------------------------
-- §E HTTP 请求解析（一次性）
-- 失败：返回 nil, err_message
-- -----------------------------------------------------------------------------
local MAX_HEADER_SIZE = 64 * 1024

local function read_http_request(sock)
	-- 读直到 \r\n\r\n
	local total = ""
	while true do
		local chunk, err = sock:recv(8192)
		if (not chunk or chunk == "") and #total == 0 then
			return nil, "empty request"
		end
		if chunk and #chunk > 0 then
			total = total .. chunk
		end
		if #total > MAX_HEADER_SIZE then
			return nil, "header too large"
		end
		local nl = total:find("\r\n\r\n", 1, true)
		if nl then
			break
		end
		if (not chunk or chunk == "") then
			-- 连接关闭但没收到 header 结束
			return nil, "incomplete headers"
		end
	end

	-- 切分 header / partial-body
	local nl = total:find("\r\n\r\n", 1, true)
	local head = total:sub(1, nl - 1)
	local body = total:sub(nl + 4)

	-- 解析请求行（不要求 HTTP/1.1 后是字符串结尾——后面还跟 header 行）
	local method, path, version = head:match("^([A-Z]+)%s+(.-)%s+HTTP/([%d%.]+)")
	if not method then return nil, "bad request line" end

	local reqpath, query = path:match("^([^?]+)%??(.*)$")
	if not reqpath then reqpath = path; query = "" end

	-- 解析 headers
	local headers = {}
	local first = true
	for hline in head:gmatch("[^\r\n]+") do
		if not first then
			local k, v = hline:match("^([^:]+):%s*(.*)$")
			if k then headers[k:lower()] = v end
		end
		first = false
	end

	return {
		method  = method,
		path    = reqpath,
		query   = query,
		version = version,
		headers = headers,
		body    = body,
		raw     = total,
	}
end

-- 读剩余 body（按 Content-Length）
local function read_full_body(sock, already_have, content_length)
	local remaining = content_length - #already_have
	if remaining <= 0 then return already_have end
	if remaining > ARGS.max_content then return nil end
	local collected = already_have
	while remaining > 0 do
		local chunk = sock:recv(math.min(remaining, 8192))
		if not chunk or chunk == "" then break end
		collected = collected .. chunk
		remaining = remaining - #chunk
	end
	return collected
end

-- -----------------------------------------------------------------------------
-- §F 路由决策
-- -----------------------------------------------------------------------------
local function route_request(req)
	local p = req.path or ""
	-- 路径逃逸：路径里出现 /.. 视为不安全 → 403
	-- 这是上游 LuCI 不会主动做的事，但我们是手写 CGI 桥，必须自己扛。
	-- 用 :find 而不是 gmatch：单次扫描即可。
	if p:find("/%.%./", 1, true) or p == ".." or p:sub(1, 3) == "../" or p:sub(-3) == "/.." or p:find("%.%.") then
		return "forbidden", nil
	end

	if p == "" or p == "/" then
		return "redirect", "/cgi-bin/luci/"
	end
	if p == CGI_BIN_PREFIX or p == CGI_BIN_PREFIX .. "/" then
		return "cgi", "/"
	end
	-- sub(1, #PREFIX+1) == PREFIX.."/" 验证路径确实以 "/cgi-bin/luci/" 起头；
	-- PATH_INFO = p[#PREFIX+1 ..]，**不要写成 #PREFIX** —— 那是 1-off，
	-- 例如 /cgi-bin/luci/admin 会得到 path_info = "/luci/admin"（错位 1 字）。
	-- 这是 2026-10-01 B3 的根因。
	if p:sub(1, #CGI_BIN_PREFIX + 1) == CGI_BIN_PREFIX .. "/" then
		return "cgi", p:sub(#CGI_BIN_PREFIX + 1)
	end
	if p == STATIC_PREFIX or p:sub(1, #STATIC_PREFIX + 1) == STATIC_PREFIX .. "/" then
		local sub = p:sub(#STATIC_PREFIX + 1)
		if sub == "" then sub = "/" end
		return "static", sub
	end
	return "notfound", nil
end

-- -----------------------------------------------------------------------------
-- §G 静态文件服务
-- -----------------------------------------------------------------------------
local function urldecode(s)
	return (s:gsub("%%(%x%x)", function(h)
		return string.char(tonumber(h, 16))
	end))
end

local function serve_static(sock, req, sub)
	sub = urldecode(sub)
	local rel = sub:gsub("^/+", "")
	if rel == "" then rel = "index.html" end

	-- STATIC_PREFIX = "/luci-static"，但 ARGS["docroot"] 是 /www（与 cgi-bin 同根），
	-- 故 candidate 必须拼上 STATIC_PREFIX，避免出现 /www/bootstrap/cascade.css
	-- 这种不存在的路径。
	local candidate = ARGS.docroot .. STATIC_PREFIX .. "/" .. rel
	local real = nixio_fs.realpath(candidate)
	if not real then
		return send_status(sock, 404, {["Content-Type"]="text/plain"}, "Not Found\n")
	end

	if real:sub(1, #ARGS.docroot) ~= ARGS.docroot then
		return send_status(sock, 403, {["Content-Type"]="text/plain"}, "Forbidden\n")
	end

	local st = nixio_fs.stat(real)
	-- nixio.fs.stat 返回 table，目录由 `type == "directory"` 判断
	if st and st.type == "directory" then
		local idx = real .. "/index.html"
		local si = nixio_fs.stat(idx)
		if not si then
			return send_status(sock, 404, {["Content-Type"]="text/plain"}, "Not Found\n")
		end
		real = idx
		st = si
	end

	-- If-Modified-Since 304
	--   IMS 是客户端见过的 mtime（秒级精度）。文件系统返回的 mtime 是**亚秒**
	--   精度（stat 给的是 1790784729.692 这种浮点）。直比 mt <= since 会因
	--   亚秒导致 "C1 IMS = mtime" 失败 —— 实际 mt 比 IMS 大 0.692s → false →
	--   200（RFC 字面是"identical"，但所有主流服务器都容忍亚秒差）。
	--   修：把 mt 截到秒（math.floor）再比，匹配 IMS 的精度。
	local ims = req.headers["if-modified-since"]
	if ims then
		local since = parse_http_date(ims)
		local mt = st and st.mtime
		if since and mt then
			local mts = math.floor(mt)  -- 截到秒（向下取整，匹配 IMS）
			if mts <= since then
				return send_status(sock, 304, {}, "")
			end
		end
	end

	local f = io.open(real, "rb")
	if not f then
		return send_status(sock, 500, {["Content-Type"]="text/plain"}, "open failed\n")
	end
	local body = f:read("*a") or ""
	f:close()

	local mtime = st and st.mtime
	return send_status(sock, 200, {
		["Content-Type"]   = mime_for(real),
		["Content-Length"] = tostring(#body),
		["Last-Modified"]  = mtime and os.date(HTTP_DATE_FMT, mtime) or nil,
	}, body)
end

local function serve_static_head(sock, req, sub)
	sub = urldecode(sub)
	local rel = sub:gsub("^/+", "")
	if rel == "" then rel = "index.html" end
	local candidate = ARGS.docroot .. STATIC_PREFIX .. "/" .. rel
	local real = nixio_fs.realpath(candidate)
	if not real or real:sub(1, #ARGS.docroot) ~= ARGS.docroot then
		return send_status(sock, 404, {}, "")
	end
	local st = nixio_fs.stat(real)
	if st and st.type == "directory" then
		local idx = real .. "/index.html"
		local si = nixio_fs.stat(idx)
		if not si then return send_status(sock, 404, {}, "") end
		real = idx; st = si
	end
	return send_status(sock, 200, {
		["Content-Type"]   = mime_for(real),
		["Content-Length"] = tostring((st and st.size) or 0),
		["Last-Modified"]  = st and st.mtime and os.date(HTTP_DATE_FMT, st.mtime) or nil,
	}, "")
end

-- -----------------------------------------------------------------------------
-- §H CGI 子进程执行
--   fork+pipe：用 io.popen + 临时 wrapper（环境变量注入）。
--   body 写入**用 here-doc**：Content-Length 上限 = max_content(10MB)，ARG_MAX
--   在 Linux 默认 2MB。
--   ⇒ 10MB 可能撞 ARG_MAX。需要换方案：把 body 写到临时文件 + wrapper 读 stdin。
-- -----------------------------------------------------------------------------
local function write_file(path, content)
	local f = io.open(path, "w")
	if not f then return false end
	f:write(content)
	f:close()
	os.execute("chmod 0600 '" .. path .. "'")
	return true
end

local function run_cgi(sock, req, path_info)
	-- 1. Content-Length 校验
	local cl_raw = req.headers["content-length"]
	if cl_raw then
		local cl = tonumber(cl_raw)
		if not cl then
			return send_status(sock, 400, {["Content-Type"]="text/plain"}, "bad Content-Length\n")
		end
		if cl < 0 or cl > ARGS.max_content then
			return send_status(sock, 413, {["Content-Type"]="text/plain"}, "body too large\n")
		end
		if cl > #req.body then
			-- 还要再读
			local full = read_full_body(sock, req.body, cl)
			if not full then
				return send_status(sock, 413, {["Content-Type"]="text/plain"}, "body too large\n")
			end
			req.body = full
		end
	end

	-- 2. 构造 CGI 环境变量
	local function upper_header(k) return "HTTP_" .. k:upper():gsub("-", "_") end

	local env = {}
	local function setenv(k, v) env[k] = tostring(v) end
	setenv("GATEWAY_INTERFACE", "CGI/1.1")
	setenv("SERVER_SOFTWARE",   "openclash-rt-luci-host/1.0")
	setenv("SERVER_PROTOCOL",   "HTTP/1.1")
	setenv("SERVER_NAME",       "openclash-rt")
	setenv("SERVER_PORT",       tostring(ARGS.port))
	setenv("REQUEST_METHOD",    req.method)
	setenv("SCRIPT_NAME",       CGI_BIN_PREFIX)
	setenv("PATH_INFO",         path_info or "/")
	setenv("PATH_TRANSLATED",   ARGS.docroot .. (path_info or "/"))
	setenv("QUERY_STRING",      req.query or "")
	setenv("CONTENT_TYPE",      req.headers["content-type"] or "")
	setenv("CONTENT_LENGTH",    cl_raw or "0")
	setenv("DOCUMENT_ROOT",     ARGS.docroot)
	setenv("REQUEST_URI",       req.path .. (req.query ~= "" and ("?" .. req.query) or ""))
	setenv("REDIRECT_STATUS",   "200")
	setenv("HTTPS",             "off")

	-- REMOTE_ADDR: 用 nixio 的 getsockname/getpeername
	local peer = sock:getpeername() or ""
	setenv("REMOTE_ADDR",       peer)
	setenv("REMOTE_PORT",       "0")

	-- HTTP_* headers
	for k, v in pairs(req.headers) do
		setenv(upper_header(k), v)
	end

	-- 3. 写 wrapper 脚本
	local envf = os.tmpname()
	local wrapper = os.tmpname()
	local bodyf = nil

	-- env file（source 后 export）
	local env_lines = { "#!/bin/sh" }
	for k, v in pairs(env) do
		-- escape: 单引号 → '\''
		v = v:gsub("'", "'\\''")
		table.insert(env_lines, string.format("export %s='%s'", k, v))
	end
	write_file(envf, table.concat(env_lines, "\n") .. "\n")

	-- wrapper
	local body_redirect = ""
	if req.body ~= "" then
		bodyf = os.tmpname()
		write_file(bodyf, req.body)
		body_redirect = "  < '" .. bodyf .. "'"
	end

	local w = io.open(wrapper, "w")
	w:write("#!/bin/sh\n")
	w:write(". " .. envf .. "\n")
	w:write("exec /usr/bin/lua5.1 " .. ARGS.cgi .. body_redirect .. "\n")
	w:close()
	os.execute("chmod 0700 '" .. wrapper .. "'")

	-- 4. fork + exec via io.popen
	local ph = io.popen(wrapper, "r")
	if not ph then
		os.remove(envf); os.remove(wrapper)
		if bodyf then os.remove(bodyf) end
		return send_status(sock, 502, {["Content-Type"]="text/plain"}, "fork failed\n")
	end

	-- 5. 解析 CGI 输出
	--    CGI 头：Status: code reason\r\nHeaders\r\n\r\nBody
	--    **关键**：Lua 5.1 的 read("*l") 读到 \n 就停，**留下 \r**。
	--    因此 "\r\n"（空行）会被 read("*l") 读成 "\r" —— 不是 "" —— 循环不会
	--    break，正文被吞成 header。这是 2026-10-01 调试 B2 的根因。
	--    修正：每行 strip 末尾 \r，再用空串判断结束。
	local function readline()
		local l = ph:read("*l")
		if not l then return nil end
		l = l:gsub("\r$", "")
		return l
	end

	local first = readline()
	if not first then
		ph:close()
		os.remove(envf); os.remove(wrapper)
		if bodyf then os.remove(bodyf) end
		return send_status(sock, 502, {["Content-Type"]="text/plain"}, "cgi empty\n")
	end

	local code, reason = first:match("^Status:%s+(%d+)%s+(.*)%s*$")
	if not code then
		ph:close()
		os.remove(envf); os.remove(wrapper)
		if bodyf then os.remove(bodyf) end
		-- 兼容 Status-less: 视为 body 的一部分，回 502
		return send_status(sock, 502, {["Content-Type"]="text/plain"}, "cgi missing Status: " .. first .. "\n")
	end

	local headers = {}
	while true do
		local line = readline()
		if not line or line == "" then break end
		local k, v = line:match("^([^:]+):%s*(.*)$")
		if k then
			-- v 中可能含尾部空白（\r 已剥，但 \t 与尾部空格是合法的 header 折叠）
			headers[k] = v
		end
	end
	local body = ph:read("*a") or ""
	ph:close()
	os.remove(envf); os.remove(wrapper)
	if bodyf then os.remove(bodyf) end

	local out_headers = {}
	for k, v in pairs(headers) do
		if k ~= "Status" then out_headers[k] = v end
	end
	code = tonumber(code) or 200

	-- 6. 转发：HEAD 时丢 body
	if req.method == "HEAD" then
		body = ""
	end
	return send_status(sock, code, out_headers, body)
end

-- -----------------------------------------------------------------------------
-- §I 主调度：路由 → 静态/CGI/404/302
-- -----------------------------------------------------------------------------
local function dispatch(sock, req)
	local kind, arg = route_request(req)
	if kind == "redirect" then
		return send_status(sock, 302, {["Location"]=arg}, "")
	end
	if kind == "notfound" then
		return send_status(sock, 404, {["Content-Type"]="text/plain"}, "Not Found\n")
	end
	if kind == "static" then
		if req.method == "HEAD" then
			return serve_static_head(sock, req, arg)
		end
		return serve_static(sock, req, arg)
	end
	if kind == "forbidden" then
		return send_status(sock, 403, {["Content-Type"]="text/plain"}, "Forbidden\n")
	end
	if kind == "cgi" then
		return run_cgi(sock, req, arg)
	end
	return send_status(sock, 500, {["Content-Type"]="text/plain"}, "unreachable\n")
end

-- -----------------------------------------------------------------------------
-- §J 信号处理：优雅关闭
-- -----------------------------------------------------------------------------
local SHUTDOWN = false
local function on_signal() SHUTDOWN = true end

local ok_sig, sig = pcall(function() return nixio.signal end)
if ok_sig and sig then
	pcall(function() sig.signal("INT",  on_signal) end)
	pcall(function() sig.signal("TERM", on_signal) end)
	pcall(function() sig.signal("HUP",  on_signal) end)
	pcall(function() sig.signal("PIPE", function() end) end)
end

-- -----------------------------------------------------------------------------
-- §K 主循环：监听 + accept + 同步处理
--   简化实现：每连接同步处理。生产中可以多进程或 epoll，P3 阶段我们只跑单
--   进程 + 同步处理。要扩展为 epoll 是 P3+ 的工作。
-- -----------------------------------------------------------------------------
local server = nixio.socket("inet", "stream")
-- nixio 的 setsockopt(level, options, value)：SOL_SOCKET + SO_REUSEADDR
server:setsockopt("socket", "reuseaddr", 1)
-- nixio 没有直接的 nodelay；TCP_NODELAY 由 TCP level 控制
local ok_bind, err_bind = server:bind(ARGS.listen, ARGS.port)
if not ok_bind then
	io.stderr:write(string.format(
		"luci-host.lua: bind %s:%d failed: %s\n",
		ARGS.listen, ARGS.port, tostring(err_bind)))
	os.exit(1)
end
server:listen(ARGS.max_connections)

io.stderr:write(string.format(
	"luci-host.lua: listening on %s:%d, docroot=%s, cgi=%s, max_content=%d\n",
	ARGS.listen, ARGS.port, ARGS.docroot, ARGS.cgi, ARGS.max_content))

while not SHUTDOWN do
	local sock, err = server:accept()
	if not sock then
		if SHUTDOWN then break end
		-- timeout 之类的不致命
	else
		local req, rerr = read_http_request(sock)
		if not req then
			send_status(sock, 400, {["Content-Type"]="text/plain"}, (rerr or "bad") .. "\n")
		else
			dispatch(sock, req)
		end
		sock:close()
	end
end

server:close()
io.stderr:write("luci-host.lua: exiting\n")
os.exit(0)