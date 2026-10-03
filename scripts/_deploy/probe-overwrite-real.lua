-- 二分法定位 config-overwrite 里让 Map.parse 返回 -1 的 option。
--
-- 背景：真机实测该页POST 后 X-CBI-State: -1（FORM_INVALID），
-- 但用同形态构造的 Map（匿名 TypedSection + taboption）全部 state=1。
-- 说明问题出在 model 里**某个具体 option**，不是 CBI 框架。
--
-- 做法：加载真实的 config-overwrite.lua（它 return 一个 Map），
-- 遍历它的 section 的 children，逐个调 option:parse()，看哪个
-- 调完把 map.save 打成 false。
--
-- 关键：AbstractValue.add_error 会设 map.save=false 并记 self.error。
-- 逐个调用后检查 map.save 即可定位。
--
-- 输出走 stdout（手工执行时直接看）。

package.path = "/usr/lib/lua/?.lua;/usr/lib/lua/luci/?.lua;"
	.. "/usr/share/lua/5.1/?.lua;/usr/share/lua/5.1/?/init.lua;" .. package.path

local http = require "luci.http"
local params = { ["cbi.submit"] = "1" }
-- 从 /tmp/f.txt 载入真实页面字段（name<TAB>value）
do
	local fh = io.open("/tmp/f.txt", "r")
	if fh then
		for line in fh:lines() do
			local k, v = line:match("^([^\t]+)\t(.*)$")
			if k then params[k] = v end
		end
		fh:close()
	end
end
http.context = http.context or {}
http.context.request = {
	formvalue = function(_, name) return params[name] end,
	formvaluetable = function(_, prefix)
		local vals = {}
		prefix = prefix and prefix .. "." or "."
		for k, v in pairs(params) do
			if k:find(prefix, 1, true) == 1 then
				vals[k:sub(#prefix + 1)] = tostring(v)
			end
		end
		return vals
	end,
	content = function() return "" end,
	getcookie = function() return nil end,
	getenv = function(_, k) return os.getenv(k) end,
}
setmetatable(http.context.request,
	{ __index = function() return function() end end })

local cbi = require "luci.cbi"
local util = require "luci.util"

-- 加载真实 model（它 return Map）
local model = "/usr/lib/lua/luci/model/cbi/openclash/config-overwrite.lua"
-- model 里直接用全局 Map / TypedSection / Value / ... （cbi.load 就是
-- 这么注入的：setfenv 后 __index 回退到 _M）。这里照抄那份env。
local env = setmetatable({
	translate = function(s) return s end,
	translatef = util.pcdata,
	arg = {},
}, { __index = function(_, k)
	return rawget(_G, k) or cbi[k] or _G[k]
end })

local chunk = assert(loadfile(model))
setfenv(chunk, env)
local ok, m = pcall(chunk)
if not ok then
	print("!! model 加载失败: " .. tostring(m))
	os.exit(1)
end
print("model 返回: " .. tostring(m))
print("m.save (parse 前) = " .. tostring(m.save))

-- 收集所有 section 与 option
local n_opt, n_sec = 0, 0
local hits = {}
for _, sec in ipairs(m.children or {}) do
	n_sec = n_sec + 1
	local secname = tostring(sec.sectiontype or sec.section)
	-- section 自身的 prepare
	pcall(function() sec:prepare() end)
	for _, opt in ipairs(sec.children or {}) do
		n_opt = n_opt + 1
		-- 逐个 option 试 parse，看谁把 save 打成 false
		local before = m.save
		local ok2, err = pcall(function()
			opt:parse(secname)
		end)
		local after = m.save
		if before ~= false and after == false then
			hits[#hits+1] = string.format("%s / %s (%s) err=%s",
				secname, tostring(opt.option or opt.alias or "?"),
				tostring(opt.title or "?"), tostring(err))
		end
		-- 复位
		m.save = before
		if opt.error then
			hits[#hits+1] = string.format("!error %s / %s -> %s",
				secname, tostring(opt.option or opt.alias), tostring(opt.error))
		end
	end
end

print(string.format("section 数=%d  option 数=%d", n_sec, n_opt))
if #hits == 0 then
	print("没有任何 option 把 save 打成 false")
else
	print("== 触发 save=false 的 option ==")
	for _, h in ipairs(hits) do print("  " .. h) end
end

-- 用真实字段跑完整 parse
m.save = true
local ok3, st = pcall(function() return m:parse(false) end)
print("真实字段 parse: ok=" .. tostring(ok3) .. " state=" .. tostring(st)
	.. " save=" .. tostring(m.save))
if m.error then print("m.error = " .. tostring(m.error)) end

-- 逐个 option 单独 parse（params 已是真实值），找出元凶
print("== 逐个 option parse（真实 params）==")
local bad = {}
for _, sec in ipairs(m.children or {}) do
	local secname = tostring(sec.sectiontype or sec.section)
	pcall(function() sec:prepare() end)
	for _, opt in ipairs(sec.children or {}) do
		local before = m.save
		local okx, errx = pcall(function() opt:parse(secname) end)
		if m.save == false and before ~= false then
			bad[#bad+1] = string.format("%s / %s  err=%s",
				secname, tostring(opt.option or opt.alias), tostring(errx))
		end
		m.save = before
	end
end
if #bad == 0 then
	print("  （没有 option 触发 save=false）")
else
	for _, b in ipairs(bad) do print("  " .. b) end
end