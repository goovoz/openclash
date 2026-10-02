-- =============================================================================
-- openclash-rt 进程内 ubus session 模块（P4 自研件）
-- -----------------------------------------------------------------------------
-- 不实现 ubus 总线，只复刻 luci.dispatcher 通过 util.ubus("session", ...) 用到的
-- 4 个方法（login/get/access/set）+ destroy。语义对齐 vendor/rpcd/session.c。
--
-- 设计依据：docs/06-P4认证设计.md（测绘结论 + 接口契约）
--
-- 关键约束（每一条都有上游真机依据，见 docs/06）：
--   1. session 持久化到磁盘 /tmp/luci-sessions/<sid>（JSON，0600）。
--      因为每个 HTTP 请求都 fork 独立 CGI 进程，内存态无法跨请求存活。
--   2. 口令校验用 nixio.crypt（真机实测支持 yescrypt $y$ 与 sha512 $6$，
--      直接包装 libcrypt，行为与 C crypt() 一致）。
--   3. 登录源 = UCI 包 rpcd 的 config login 段（与 session.c:rpc_login_test_login
--      完全对齐），不是直接读 shadow。三种口令形态：空/`$p$<user>`/crypt hash。
--   4. ACL 读 /usr/share/rpcd/acl.d/*.json，login 段 read/write 选项 = 所属 group。
--      返回结构与 session.c:rpc_session_dump_acls 一致：
--        { <scope> = { <obj> = [ <func>, ... ] }, access-group = { <group> = [read/write] } }
--
-- 单一职责：提供 session 语义，不碰 HTTP、不碰 dispatcher。注入方式见
--   luci-session-bootstrap.lua（通过 package.loaded["ubus"] 预注入）。
-- =============================================================================

local jsonc = require "luci.jsonc"
local nixio = require "nixio"
local nixio_fs = require "nixio.fs"

-- -----------------------------------------------------------------------------
-- §A 配置常量（对齐 vendor/luci/luci-base/root/etc/config/luci 的 sauth 段）
-- -----------------------------------------------------------------------------
local SESSION_DIR   = "/tmp/luci-sessions"
local SESSION_TIME  = 3600               -- 默认超时（秒），sessiontime 可覆盖
local ACL_DIR       = "/usr/share/rpcd/acl.d"
local SID_LEN       = 32                 -- 对齐 rpcd RPC_SID_LEN
local RPCD_CONF     = "/etc/config/rpcd"

-- -----------------------------------------------------------------------------
-- §B sid 生成：/dev/urandom 16 字节 → 32 位小写 hex
-- -----------------------------------------------------------------------------
local function gen_sid()
	local f = io.open("/dev/urandom", "rb")
	if not f then
		-- 退化：time + clock + 随机种子拼 hex（保证可用，唯一性弱于 urandom）
		return string.format("%08x%08x%08x%08x",
			os.time(), math.floor(os.clock() * 1e6),
			math.random(0, 0xffffffff), math.random(0, 0xffffffff))
	end
	local bytes = f:read(16)
	f:close()
	return (bytes:gsub(".", function(c)
		return string.format("%02x", string.byte(c))
	end))
end

-- -----------------------------------------------------------------------------
-- §C UCI 读取：读 /etc/config/rpcd 的 login 段
--    用 /sbin/uci（build-uci 编译 + postinst 落位）。返回
--    { {name=, username=, password=, read={...}, write={...}}, ... }
-- -----------------------------------------------------------------------------
local function read_login_sections()
	local logins = {}
	-- 用 uci show 读整个 rpcd 包，解析出 login 段
	local p = io.popen("/sbin/uci show rpcd 2>/dev/null")
	if not p then return logins end
	local sections = {}
	local cur = {}
	for line in p:lines() do
		local sec, opt, val = line:match("^rpcd%.([^%.=]+)=login$"),
			nil, nil
		if sec then
			-- 新 login 段标记：rpcd.<name>=login
			cur = { name = sec, read = {}, write = {} }
			sections[sec] = cur
			table.insert(logins, cur)
		else
			-- rpcd.<sec>.<opt>=<val> 或 rpcd.<sec>.<opt>='<val>' 或 list 多值 'a' 'b'
			local s2, o2, v2 = line:match("^rpcd%.([^%.]+)%.([^%.=]+)=(.+)$")
			if s2 and sections[s2] then
				local s = sections[s2]
				if o2 == "username" then
					s.username = v2:gsub("^'", ""):gsub("'$", "")
				elseif o2 == "password" then
					s.password = v2:gsub("^'", ""):gsub("'$", "")
				elseif o2 == "read" or o2 == "write" then
					-- list 值：'a' 'b' 或 'a'（每个 '...' 是一个独立值）
					local list = o2 == "read" and s.read or s.write
					for val in v2:gmatch("'([^']*)'") do
						list[#list + 1] = val
					end
				end
			end
		end
	end
	p:close()
	return logins
end

-- fnmatch 风格的 glob 匹配（session.c 用 fnmatch(pat, group, 0)），
-- 支持 '*' 通配。这里只实现 '*'（够 login 段的 group 匹配用），
-- 不实现 '?' 和 '[...]'（rpcd 默认配置只用 '*'）。
local function glob_match(pat, str)
	if pat == "*" then return true end
	if not pat:find("%*") then return pat == str end
	-- 转 Lua pattern：非字母数字和 * 的字符转义，* 换成 .*
	local esc = pat:gsub("([^%w%*])", "%%%1"):gsub("%*", ".*")
	return str:match("^" .. esc .. "$") ~= nil
end

-- 判断一个 login 段是否含某 group（read/write list 里 glob 匹配，支持 '*' 通配）
local function login_has_group(login, perm, group)
	local list = perm == "read" and login.read or login.write
	if not list then return false end
	for _, word in ipairs(list) do
		if glob_match(word, group) then return true end
	end
	return false
end

-- -----------------------------------------------------------------------------
-- §D 口令校验（对齐 session.c:rpc_login_test_password + rpc_login_test_login）
--    三种形态：空 hash → 通过；$p$<user> → 读 shadow；crypt hash → crypt 比对
-- -----------------------------------------------------------------------------
local function read_shadow_hash(user)
	local f = io.open("/etc/shadow", "r")
	if not f then return nil end
	local hash
	for line in f:lines() do
		local u, h = line:match("^(%w+):([^:]*):")
		if u == user then hash = h break end
	end
	f:close()
	return hash
end

local function test_password(hash, password)
	-- 无密码（空 hash）
	if not hash or hash == "" or hash == "!" or hash == "*" then
		return true
	end
	-- $p$<user> → 引用系统 shadow
	if hash:sub(1, 3) == "$p$" then
		local user = hash:sub(4)
		local sh = read_shadow_hash(user)
		if not sh then return false end
		return test_password(sh, password)
	end
	-- 普通 crypt 哈希
	local ok, crypted = pcall(nixio.crypt, password, hash)
	if not ok or not crypted then return false end
	return crypted == hash
end

-- 找匹配 username 且口令正确的 login 段；password 为 nil 时只匹配 username（ACL 恢复用）
local function find_login(username, password)
	for _, login in ipairs(read_login_sections()) do
		if login.username == username then
			if not password then return login end
			if test_password(login.password, password) then return login end
		end
	end
	return nil
end

-- -----------------------------------------------------------------------------
-- §E session 文件读写（/tmp/luci-sessions/<sid>，JSON，0600）
-- -----------------------------------------------------------------------------
local function session_path(sid)
	return SESSION_DIR .. "/" .. sid
end

local function ensure_dir()
	nixio_fs.mkdirr(SESSION_DIR)
	-- 权限收紧：仅 owner 可读写（session 含敏感 token）
	os.execute("chmod 700 " .. SESSION_DIR .. " 2>/dev/null")
end

local function load_session(sid)
	if not sid or #sid ~= SID_LEN then return nil end
	local f = io.open(session_path(sid), "r")
	if not f then return nil end
	local content = f:read("*a")
	f:close()
	local ok, data = pcall(jsonc.parse, content)
	if not ok or type(data) ~= "table" then return nil end
	-- 过期检查
	if data.expires and type(data.expires) == "number" then
		if os.time() > data.expires then
			os.remove(session_path(sid))
			return nil
		end
	end
	return data
end

local function save_session(sid, data)
	ensure_dir()
	local f = io.open(session_path(sid), "w")
	if not f then return nil end
	f:write(jsonc.stringify(data))
	f:close()
	os.execute("chmod 600 " .. session_path(sid) .. " 2>/dev/null")
	return true
end

-- -----------------------------------------------------------------------------
-- §F ACL 构建（对齐 session.c:rpc_login_setup_acls + rpc_session_dump_acls）
--    读 /usr/share/rpcd/acl.d/*.json，按 login 段的 read/write group 过滤，
--    产出 { <scope> = { <obj> = [func] }, access-group = { <group> = [perm] } }
-- -----------------------------------------------------------------------------
local function build_acls(login)
	local acls = { ["access-group"] = {} }

	-- glob acl.d/*.json
	local files = {}
	local p = io.popen("ls " .. ACL_DIR .. "/*.json 2>/dev/null")
	if p then
		for f in p:lines() do files[#files + 1] = f end
		p:close()
	end

	for _, path in ipairs(files) do
		local f = io.open(path, "r")
		if f then
			local content = f:read("*a")
			f:close()
			local ok, doc = pcall(jsonc.parse, content)
			if ok and type(doc) == "table" then
				-- doc = { <group> = { read/write = { <scope> = ... } } }
				for group, perms in pairs(doc) do
					if type(perms) == "table" then
						for perm, scopes in pairs(perms) do
							if (perm == "read" or perm == "write")
								and type(scopes) == "table"
								and login_has_group(login, perm, group)
							then
								-- 把 group 记入 access-group 元 scope
								acls["access-group"][group] =
									acls["access-group"][group] or {}
								table.insert(acls["access-group"][group], perm)

								-- 展开 scope → obj → func（对齐 session.c:rpc_login_setup_acl_scope）
								-- 两种记法（session.c 支持 table 和 array）：
								--   table: { <scope> = { <obj> = [func, ...] } }
								--   array: { <scope> = [ <obj>, ... ] }  → func = perm
								for scope, objs in pairs(scopes) do
									acls[scope] = acls[scope] or {}
									if type(objs) == "table" then
										-- 判断是 array（{1,2,...}）还是 map（{obj=...}）
										local is_array = #objs > 0
										if is_array then
											-- array 记法：每个元素是 obj 名，func = perm
											for _, objname in ipairs(objs) do
												if type(objname) == "string" then
													acls[scope][objname] = acls[scope][objname] or {}
													table.insert(acls[scope][objname], perm)
												end
											end
										else
											-- table 记法：{ obj = [func, ...] }
											for obj, funcs in pairs(objs) do
												if type(funcs) == "table" then
													acls[scope][obj] = acls[scope][obj] or {}
													for _, fn in ipairs(funcs) do
														table.insert(acls[scope][obj], fn)
													end
												end
											end
										end
									end
								end
							end
						end
					end
				end
			end
		end
	end

	return acls
end

-- rpcd 语义的 ACL 判定（session.c:session_access 的 access 子检查）：
-- 给定 scope/object/function，在扁平 ACL 表里查 obj（glob 通配）下的 func
-- 列表（glob 通配）。命中任一 → true。
local function acl_check(acls, scope, object, func)
	if type(acls) ~= "table" then return false end
	local objs = acls[scope]
	if type(objs) ~= "table" then return false end
	for objname, funcs in pairs(objs) do
		if glob_match(objname, object) then
			if funcs == true then return true end
			if type(funcs) == "table" then
				for _, fn in ipairs(funcs) do
					if fn == func or glob_match(fn, func) then return true end
				end
			end
		end
	end
	return false
end

-- 匿名会话（rpcd 内置 000...0，ACL 组 = unauthenticated）。
-- 上游 rpcd 启动即创建它，前端登录页的 session.access 探测全靠它：
-- access 调用必须**成功返回** {access:false}（而不是 NOT_FOUND 报错），
-- 否则 luci.js 的 -32002 拦截器 .catch(notifySessionExpiry) 会在登录页
-- 弹 "Session expired"（P5 用户浏览器实测踩坑）。
local ANON_SID = "00000000000000000000000000000000"

local function build_acls_for_groups(groups)
	-- 伪 login 段：read/write 都含给定组，复用 build_acls 的组过滤
	return build_acls({ read = groups, write = groups })
end

-- -----------------------------------------------------------------------------
-- §G session 方法实现
-- -----------------------------------------------------------------------------
local M = {}

-- login(username, password, timeout) → { ubus_rpc_session, timeout, expires, acls, data }
function M.login(data)
	local username = data.username
	local password = data.password
	local timeout = tonumber(data.timeout) or SESSION_TIME

	if not username or not password then
		return nil, 1, "INVALID_ARGUMENT"  -- UBUS_STATUS_INVALID_ARGUMENT
	end

	local login = find_login(username, password)
	if not login then
		return nil, 5, "PERMISSION_DENIED"  -- UBUS_STATUS_PERMISSION_DENIED
	end

	local sid = gen_sid()
	local expires = os.time() + timeout

	-- session 数据：username + token（token 由 dispatcher 后续 set 进来）
	local sess = {
		username = username,
		expires = expires,
		timeout = timeout,
		token = "",
		values = { username = username },
	}
	save_session(sid, sess)

	local acls = build_acls(login)

	return {
		ubus_rpc_session = sid,
		timeout = timeout,
		expires = timeout,  -- rpcd 返回的是「剩余毫秒/1000」，这里近似为 timeout 秒
		acls = acls,
		data = { username = username },
	}
end

-- get(ubus_rpc_session) → { values = { username, token, ... } }
function M.get(data)
	local sess = load_session(data.ubus_rpc_session)
	if not sess then
		return nil, 3, "NOT_FOUND"  -- UBUS_STATUS_NOT_FOUND
	end
	return { values = sess.values or { username = sess.username } }
end

-- access(ubus_rpc_session [, scope, object, function])
--   rpcd 双形态语义（对齐 session.c 的 session access 方法 + dispatcher 用法）：
--   · 带 scope/object/function → { access = true/false }
--     （controller/admin/index.lua 的 ubus 桥接与 dispatcher has_uci_access 消费）
--   · 不带 → 返回完整 ACL 表（dispatcher session_retrieve 的 sacl 消费）
--   匿名会话（000...0）永远成功返回（unauthenticated 组），绝不 NOT_FOUND。
function M.access(data)
	local sid = data.ubus_rpc_session
	local scope, object, func = data.scope, data.object, data["function"]

	local acls
	if sid == ANON_SID then
		acls = build_acls_for_groups({ "unauthenticated" })
	else
		local sess = load_session(sid)
		if not sess then
			return nil, 3, "NOT_FOUND"
		end
		-- 重新按 username 构建 ACL（会话可能跨进程，login 段可能已变）
		local login = find_login(sess.username, nil)
		acls = (login and build_acls(login)) or {}
	end

	if not scope or not object or not func then
		return acls
	end

	return { access = acl_check(acls, scope, object, func) }
end

-- set(ubus_rpc_session, values) → 空
function M.set(data)
	local sess = load_session(data.ubus_rpc_session)
	if not sess then
		return nil, 3, "NOT_FOUND"
	end
	-- 合并 values 进 session（dispatcher 用 set 写入 token）
	if type(data.values) == "table" then
		sess.values = sess.values or {}
		for k, v in pairs(data.values) do
			sess.values[k] = v
		end
	end
	save_session(data.ubus_rpc_session, sess)
	return {}
end

-- destroy(ubus_rpc_session) → 空
function M.destroy(data)
	if data.ubus_rpc_session then
		os.remove(session_path(data.ubus_rpc_session))
	end
	return {}
end

return M
