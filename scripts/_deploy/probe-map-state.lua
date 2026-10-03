-- 直接在 CGI 环境里复现 config-overwrite 的 parse，定位 -1 的来源。
--
-- 为什么需要这个：浏览器 POST 后只拿到 X-CBI-State: -1（FORM_INVALID），
-- 但 LuCI 不告诉我们**哪个** option 校验失败。header / write / error
-- 三种探针通道都试过（见 docs/09），都因为 CGI 缓冲与宿主 header
-- 过滤而看不到输出。
--
-- 这个脚本换个思路：**不靠输出，靠状态码**。逐个 option 单独
-- construct 一个 Map 提交，看哪个让 state 变 -1。
--
-- 用法：经 luci-host 的 CGI 跑，或手工：
--   cd /; SCRIPT_NAME=/cgi-bin/luci SCRIPT_FILENAME=/www/cgi-bin/luci \
--   REQUEST_METHOD=GET QUERY_STRING="" PATH_INFO=/admin/services/openclash/probe \
--   lua5.1 /www/probe-map.lua

package.path = "/usr/lib/lua/?.lua;/usr/lib/lua/luci/?.lua;/usr/share/lua/5.1/?.lua;/usr/share/lua/5.1/?/init.lua;" .. package.path

local luci = require "luci.util"
local cbi  = require "luci.cbi"
local util = require "luci.util"

-- Map.parse 需要 luci.http.context（formvalue 走它）。
-- 注入一个最小 request：params 由每个 probe 场景填充。
local http = require "luci.http"
local params = {}
http.context = http.context or {}
http.context.request = {
	formvalue = function(_, name) return params[name] end,
	formvaluetable = function(_, prefix)
		local vals = {}
		prefix = prefix and prefix .. "." or "."
		for k, v in pairs(params) do
			if k:find(prefix, 1, true) == 1 then vals[k:sub(#prefix + 1)] = tostring(v) end
		end
		return vals
	end,
	content = function() return "" end,
	getcookie = function() return nil end,
	getenv = function(_, k) return os.getenv(k) end,
}
setmetatable(http.context.request, {__index = function() return function() end end})
_G.__PROBE_PARAMS = params

-- 构造一个与 config-overwrite 同形态的 Map：
--   匿名 TypedSection + taboption(ListValue) + pageaction=false
local results = {}
local function probe(desc, setup, formvals)
	for k in pairs(params) do params[k] = nil end
	params["cbi.submit"] = "1"
	for k, v in pairs(formvals or {}) do params[k] = v end

	local m = cbi.Map("openclash", "probe")
	m.pageaction = false
	m.probe_out = {}
	local s = m:section(cbi.TypedSection, "openclash")
	s.anonymous = true
	s.addremove = true
	s.template = "cbi/tblsection"
	s:tab("settings", "General Settings")
	setup(s)
	local ok, err = pcall(function()
		local st = m:parse(false)
		results[#results+1] = string.format("%-28s state=%s save=%s err=%s",
			desc, tostring(st), tostring(m.save), tostring(err))
	end)
	if not ok then
		results[#results+1] = string.format("%-28s EXCEPTION %s", desc, tostring(err))
	end
	-- 不真提交，只看状态
end

-- 1) 空 section：基线
probe("baseline (empty)", function(s) end)

-- 2) 一个普通 Value
probe("Value", function(s)
	local o = s:taboption("settings", cbi.Value, "foo")
	o.default = "bar"
end)

-- 3) 一个带 rmempty=false 的 Value（required）
probe("Value required(rmempty=false)", function(s)
	local o = s:taboption("settings", cbi.Value, "foo")
	o.rmempty = false
	o.default = "bar"
end)

-- 4) ListValue（同interface_name 的类型）
probe("ListValue interface=eth0", function(s)
	local o = s:taboption("settings", cbi.ListValue, "interface_name")
	o:value("eth0")
	o:value("0", "Disable")
	o.default = "0"
end, {["cbid.openclash.config.interface_name"] = "eth0"})

-- 5) ListValue + datatype
probe("ListValue datatype=uinteger", function(s)
	local o = s:taboption("settings", cbi.ListValue, "tolerance")
	o:value("0"); o:value("100")
	o.datatype = "uinteger"
	o.default = "0"
end)

-- 6) TextValue（log_level 同类型）
probe("ListValue log_level", function(s)
	local o = s:taboption("settings", cbi.ListValue, "log_level")
	o:value("0"); o:value("info")
	o.default = "0"
end)

-- 7) Flag
probe("Flag", function(s)
	local o = s:taboption("settings", cbi.Flag, "enable")
	o.default = "0"
end)

-- 输出到 stderr（LuCI 会把 CGI 的 stderr 收进日志）
for _, r in ipairs(results) do
	io.stderr:write("OCRTPROBE " .. r .. "\n")
end
-- 也写 stdout，便于手工观察
print(table.concat(results, "\n"))