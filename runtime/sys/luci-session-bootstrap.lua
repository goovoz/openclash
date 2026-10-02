-- =============================================================================
-- openclash-rt P4 引导：进程内假 ubus 模块注入
-- -----------------------------------------------------------------------------
-- 通过 Lua 5.1 的 LUA_INIT=@<本文件> 机制，在 CGI 子进程启动时、luci.util
-- require "ubus" 之前，把 package.loaded["ubus"] 预注入为纯 Lua 假模块。
--
-- 上游 util.lua:15 有 `local _ubus = require "ubus"`，Lua 的 require 先查
-- package.loaded，命中即不再加载真 ubus.so。从而 dispatcher 的所有
-- util.ubus("session", ...) 调用都走本地 luci-session 实现，不再依赖外部
-- ubusd/rpcd（满足 docs/02 §9.8「无 ubusd/rpcd 进程」）。
--
-- 假模块接口对齐 vendor 真 ubus.so 的 connect/call 形态：
--   _ubus.connect(path, timeout) → connection
--   connection:call(object, method, data) → 返回值（或 nil, errno, errstr）
--   connection:objects() / :signatures(object)
-- =============================================================================

-- luci-session.lua / luci-uci.lua 与本文件同目录（/usr/lib/openclash-rt/），
-- 用绝对路径 dofile 加载，不依赖 Lua 默认搜索路径（LUA_INIT 引导时
-- package.path 尚未被 luci 扩展）。
local session = dofile("/usr/lib/openclash-rt/luci-session.lua")
local uci = dofile("/usr/lib/openclash-rt/luci-uci.lua")

-- 进程内连接对象
local connection = {}
connection.__index = connection

function connection:call(object, method, data)
	data = data or {}
	if object == "session" then
		local fn = session[method]
		if type(fn) == "function" then
			return fn(data)
		end
		-- session 的其它方法（unset/grant/revoke/list/create）非 P4 必需，
		-- 返回空表让上游自然空转
		return {}
	end
	if object == "uci" then
		local fn = uci[method]
		if type(fn) == "function" then
			return fn(data)
		end
		return {}
	end
	if object == "system" then
		-- system.board：header 模板用 boardinfo.hostname（vendor header.htm:33/61），
		-- 没有 pcall 保护，必须返回含 hostname 的表，否则登录页渲染崩。
		if method == "board" then
			local hostname = "openclash-rt"
			local f = io.open("/proc/sys/kernel/hostname", "r")
			if f then
				hostname = (f:read("*l") or "openclash-rt"):gsub("\r$", "")
				f:close()
			end
			return { hostname = hostname, model = "openclash-rt" }
		end
		return nil
	end
	-- 其它 ubus 对象（file/network/rc 等）：P4 阶段不实现，返回 nil。
	-- 上游对非 session/uci 的 ubus 调用均有 pcall 保护（docs/02 §2.5/§5.5），
	-- 返回 nil 即触发其降级分支，不会崩溃。
	return nil
end

function connection:objects()
	return { session = {}, uci = {} }
end

function connection:signatures(object)
	return {}
end

-- 假 ubus 模块
local fake_ubus = {
	connect = function(path, timeout)
		return connection
	end,
}

-- 预注入：让后续 require "ubus" 命中这个假模块
package.loaded["ubus"] = fake_ubus

-- 同时把 luci-session 暴露到 package.loaded，避免重复 require 时路径问题
package.loaded["luci-session"] = session
