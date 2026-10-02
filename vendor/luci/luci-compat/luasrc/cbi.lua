-- Copyright 2008 Steven Barth <steven@midlink.org>
-- Licensed to the public under the Apache License 2.0.

module("luci.cbi", package.seeall)

require("luci.template")
local util = require("luci.util")
require("luci.http")


--local event      = require "luci.sys.event"
local fs         = require("nixio.fs")
local uci        = require("luci.model.uci")
local datatypes  = require("luci.cbi.datatypes")
local dispatcher = require("luci.dispatcher")
local class      = util.class
local instanceof = util.instanceof

FORM_NODATA  =  0
FORM_PROCEED =  0
FORM_VALID   =  1
FORM_DONE	 =  1
FORM_INVALID = -1
FORM_CHANGED =  2
FORM_SKIP    =  4

AUTO = true

CREATE_PREFIX = "cbi.cts."
REMOVE_PREFIX = "cbi.rts."
RESORT_PREFIX = "cbi.sts."
FEXIST_PREFIX = "cbi.cbe."

-- Loads a CBI map from given file, creating an environment and returns it
function load(cbimap, ...)
	local fs   = require "nixio.fs"
	local i18n = require "luci.i18n"
	require("luci.config")
	require("luci.util")

	local upldir = "/etc/luci-uploads/"
	local cbidir = luci.util.libpath() .. "/model/cbi/"
	local func, err

	if fs.access(cbidir..cbimap..".lua") then
		func, err = loadfile(cbidir..cbimap..".lua")
	elseif fs.access(cbimap) then
		func, err = loadfile(cbimap)
	else
		func, err = nil, "Model '" .. cbimap .. "' not found!"
	end

	assert(func, err)

	local env = {
		translate=i18n.translate,
		translatef=i18n.translatef,
	 	arg={...}
	}

	setfenv(func, setmetatable(env, {__index =
		function(tbl, key)
			return rawget(tbl, key) or _M[key] or _G[key]
		end}))

	local maps       = { func() }
	local uploads    = { }
	local has_upload = false

	for i, map in ipairs(maps) do
		if not instanceof(map, Node) then
			error("CBI map returns no valid map object!")
			return nil
		else
			map:prepare()
			if map.upload_fields then
				has_upload = true
				for _, field in ipairs(map.upload_fields) do
					uploads[
						field.config .. '.' ..
						(field.section.sectiontype or '1') .. '.' ..
						field.option
					] = true
				end
			end
		end
	end

	if has_upload then
		local uci = luci.model.uci.cursor()
		local prm = luci.http.context.request.message.params
		local fd, cbid

		luci.http.setfilehandler(
			function( field, chunk, eof )
				if not field then return end
				if field.name and not cbid then
					local c, s, o = field.name:gmatch(
						"cbid%.([^%.]+)%.([^%.]+)%.([^%.]+)"
					)()

					if c and s and o then
						local t = uci:get( c, s ) or s
						if uploads[c.."."..t.."."..o] then
							local path = upldir .. field.name
							fd = io.open(path, "w")
							if fd then
								cbid = field.name
								prm[cbid] = path
							end
						end
					end
				end

				if field.name == cbid and fd then
					fd:write(chunk)
				end

				if eof and fd then
					fd:close()
					fd   = nil
					cbid = nil
				end
			end
		)
	end

	return maps
end

--
-- Compile a datatype specification into a parse tree for evaluation later on
--
local cdt_cache = { }

function compile_datatype(code)
	local i
	local pos = 0
	local esc = false
	local depth = 0
	local stack = { }

	for i = 1, #code+1 do
		local byte = code:byte(i) or 44
		if esc then
			esc = false
		elseif byte == 92 then
			esc = true
		elseif byte == 40 or byte == 44 then
			if depth <= 0 then
				if pos < i then
					local label = code:sub(pos, i-1)
						:gsub("\\(.)", "%1")
						:gsub("^%s+", "")
						:gsub("%s+$", "")

					if #label > 0 and tonumber(label) then
						stack[#stack+1] = tonumber(label)
					elseif label:match("^'.*'$") or label:match('^".*"$') then
						stack[#stack+1] = label:gsub("[\"'](.*)[\"']", "%1")
					elseif type(datatypes[label]) == "function" then
						stack[#stack+1] = datatypes[label]
						stack[#stack+1] = { }
					else
						error("Datatype error, bad token %q" % label)
					end
				end
				pos = i + 1
			end
			depth = depth + (byte == 40 and 1 or 0)
		elseif byte == 41 then
			depth = depth - 1
			if depth <= 0 then
				if type(stack[#stack-1]) ~= "function" then
					error("Datatype error, argument list follows non-function")
				end
				stack[#stack] = compile_datatype(code:sub(pos, i-1))
				pos = i + 1
			end
		end
	end

	return stack
end

function verify_datatype(dt, value)
	if dt and #dt > 0 then
		if not cdt_cache[dt] then
			local c = compile_datatype(dt)
			if c and type(c[1]) == "function" then
				cdt_cache[dt] = c
			else
				error("Datatype error, not a function expression")
			end
		end
		if cdt_cache[dt] then
			return cdt_cache[dt][1](value, unpack(cdt_cache[dt][2]))
		end
	end
	return true
end


-- Node pseudo abstract class
Node = class()

function Node.__init__(self, title, description)
	self.children = {}
	self.title = title or ""
	self.description = description or ""
	self.template = "cbi/node"
end

-- hook helper
function Node._run_hook(self, hook)
	if type(self[hook]) == "function" then
		return self[hook](self)
	end
end

function Node._run_hooks(self, ...)
	local f
	local r = false
	for _, f in ipairs(arg) do
		if type(self[f]) == "function" then
			self[f](self)
			r = true
		end
	end
	return r
end

-- Prepare nodes
function Node.prepare(self, ...)
	for k, child in ipairs(self.children) do
		child:prepare(...)
	end
end

-- Append child nodes
function Node.append(self, obj)
	table.insert(self.children, obj)
end

-- Parse this node and its children
function Node.parse(self, ...)
	for k, child in ipairs(self.children) do
		child:parse(...)
	end
end

-- Render this node
function Node.render(self, scope)
	scope = scope or {}
	scope.self = self

	luci.template.render(self.template, scope)
end

-- Render the children
function Node.render_children(self, ...)
	local k, node
	for k, node in ipairs(self.children) do
		node.last_child = (k == #self.children)
		node.index = k
		node:render(...)
	end
end

--[[
A simple template element
]]--
Template = class(Node)

function Template.__init__(self, template)
	Node.__init__(self)
	self.template = template
end

function Template.render(self)
	luci.template.render(self.template, {self=self})
end

function Template.parse(self, readinput)
	self.readinput = (readinput ~= false)
	return Map.formvalue(self, "cbi.submit") and FORM_DONE or FORM_NODATA
end


--[[
Map - A map describing a configuration file
]]--
Map = class(Node)

function Map.__init__(self, config, ...)
	Node.__init__(self, ...)

	self.config = config
	self.parsechain = {self.config}
	self.template = "cbi/map"
	self.apply_on_parse = nil
	self.readinput = true
	self.proceed = false
	self.flow = {}

	self.uci = uci.cursor()
	self.save = true

	self.changed = false

	local path = "%s/%s" %{ self.uci:get_confdir(), self.config }
	if fs.stat(path, "type") ~= "reg" then
		fs.writefile(path, "")
	end

	local ok, err = self.uci:load(self.config)
	if not ok then
		local url = dispatcher.build_url(unpack(dispatcher.context.request))
		local source = self:formvalue("cbi.source")
		if type(source) == "string" then
			fs.writefile(path, source:gsub("\r\n", "\n"))
			ok, err = self.uci:load(self.config)
			if ok then
				luci.http.redirect(url)
			end
		end
		self.save = false
	end

	if not ok then
		self.template   = "cbi/error"
		self.error      = err
		self.source     = fs.readfile(path) or ""
		self.pageaction = false
	end
end

function Map.formvalue(self, key)
	return self.readinput and luci.http.formvalue(key) or nil
end

function Map.formvaluetable(self, key)
	return self.readinput and luci.http.formvaluetable(key) or {}
end

function Map.get_scheme(self, sectiontype, option)
	if not option then
		return self.scheme and self.scheme.sections[sectiontype]
	else
		return self.scheme and self.scheme.variables[sectiontype]
		 and self.scheme.variables[sectiontype][option]
	end
end

function Map.submitstate(self)
	return self:formvalue("cbi.submit")
end

-- Chain foreign config
function Map.chain(self, config)
	table.insert(self.parsechain, config)
end

function Map.state_handler(self, state)
	return state
end

-- Use optimized UCI writing
function Map.parse(self, readinput, ...)
	if self:formvalue("cbi.skip") then
		self.state = FORM_SKIP
	elseif not self.save then
		self.state = FORM_INVALID
	elseif not self:submitstate() then
		self.state = FORM_NODATA
	end

	-- Back out early to prevent unauthorized changes on the subsequent parse
	if self.state ~= nil then
		return self:state_handler(self.state)
	end

	self.readinput = (readinput ~= false)
	self:_run_hooks("on_parse")

	Node.parse(self, ...)

	if self.save then
		self:_run_hooks("on_save", "on_before_save")
		local i, config
		for i, config in ipairs(self.parsechain) do
			self.uci:save(config)
		end
		self:_run_hooks("on_after_save")
		if (not self.proceed and self.flow.autoapply) or luci.http.formvalue("cbi.apply") then
			self:_run_hooks("on_before_commit")
			if self.apply_on_parse == false then
				for i, config in ipairs(self.parsechain) do
					self.uci:commit(config)
				end
			end
			self:_run_hooks("on_commit", "on_after_commit", "on_before_apply")
			if self.apply_on_parse == true or self.apply_on_parse == false then
				self.uci:apply(self.apply_on_parse)
				self:_run_hooks("on_apply", "on_after_apply")
			else
				-- This is evaluated by the dispatcher and delegated to the
				-- template which in turn fires XHR to perform the actual
				-- apply actions.
				self.apply_needed = true
			end

			-- Reparse sections
			Node.parse(self, true)
		end
		for i, config in ipairs(self.parsechain) do
			self.uci:unload(config)
		end
		if type(self.commit_handler) == "function" then
			self:commit_handler(self:submitstate())
		end
	end

	if not self.save then
		self.state = FORM_INVALID
	elseif self.proceed then
		self.state = FORM_PROCEED
	elseif self.changed then
		self.state = FORM_CHANGED
	else
		self.state = FORM_VALID
	end

	return self:state_handler(self.state)
end

function Map.render(self, ...)
	self:_run_hooks("on_init")
	Node.render(self, ...)
end

-- [openclash-rt 适配] Map 层的 tab 支持
--
-- 现象（2026-10-02 真机实测，Debian 12 @ 172.20.0.101:9080）：
--   Plugin Settings 页（openclash/settings.lua）只渲染出 Lan Traffic
--   Access List，15 个 tab 里的 279 个控件**一个都不出现**。
--   对照ImmortalWrt 24.10（172.20.0.2）同页正常。
--
-- 根因（三环）：
--   1) settings.lua:65 `s = m:section(TypedSection, ...)` → s 是
--      AbstractSection，它**有** tab/taboption/render_tab
--      （本文件 835/867/881 行），所以 s:tab(...) 15 次都成功、
--      s:taboption(...) 把选项挂进 `s.tabs[tab].childs` ——数据是对的。
--   2) 但 taboption 只写 `self.tabs[tab].childs`，**不append 到
--      self.children**（对比 AbstractSection.option 走 self:append）。
--   3) view/cbi/map.htm:13 判断 `<% if self.tabbed then %>`，而
--      **self.tabbed 在本文件里从未被赋值**（全文件仅 1 处注释提到）。
--      21.02 世代的 cbi.lua 没有这个标记，map.htm 却依赖它 →
--      永远走 `<%- self:render_children() %>`，只渲染 Map.children
--      → tab 里的选项全部丢失。
--
-- 即：cbi.lua（21.02）与 map.htm（更新版）不配版。
--
-- 修法：给 Map 补 has_tabs()（语义=任一 child section 有 tabs），
-- 并把 map.htm 的判断改成 self:has_tabs()。不能直接让 map.htm 调
-- AbstractSection.has_tabs —— Map = class(Node)，拿不到那个方法，
-- 实测会报 `attempt to call method 'has_tabs' (a nil value)`。
--
-- 为什么 OpenWrt 上正常：ImmortalWrt 24.10 用的是支持 tab 的新版
-- luci-base，Map.tabbed 存在，map.htm 的 tab 分支能走通。
--
-- 这属于 vendor 层适配（对齐新版 LuCI 行为），**不改上游 OpenClash 一行**。
function Map.has_tabs(self)
	for _, section in ipairs(self.children) do
		if section and section.has_tabs and section:has_tabs() then
			return true
		end
	end
	return false
end

-- [openclash-rt 适配] 只渲染「不带 tab 的 child」，供 view/cbi/map.htm 用
--
-- 背景（2026-10-02 真机实测，Debian 12 @ 172.20.0.101:9080）：
--   map.htm 是 if/else 二选一：
--       if self:has_tabs() then self:render_tabcontainer("m")
--       else self:render_children() end
--   而 render_tabcontainer 只遍历**有 tabs 的** child
--   （`if section:has_tabs()`）。于是页面上只要存在任意一个 tab section，
--   has_tabs() 就为真 -> 走 tab 分支 -> **所有无 tab 的 child 一个都不渲染**。
--
--   症状：Plugin Settings / Overwrite Settings 上，Lan Traffic Access List、
--   Set Authentication、Config Subscribe 这些 section 整段消失，连 Add
--   按钮（name="cbi.cts.openclash.<sectiontype>."）都不渲染 ——
--   页面上 grep 不到 section 名，Add 按钮「找不到」。
--
-- 为什么不能直接用 render_children：它遍历**全部** children，会把带 tab 的
-- section 在 tabcontainer 里已经渲染过一遍的内容再来一遍 -> N×N 重复
-- （这正是 render_tabcontainer 注释里「坑 1」描述的问题）。
--
-- 所以单独提供这个入口，只渲染无 tab 的 child。
--
-- last_child / index 的处理与 Node.render_children 保持一致：模板里
-- 靠 node.last_child 决定是否输出分隔符、靠 node.index 显示序号。
-- 这里用「已见数量」而非 #self.children，因为渲染的是子集。
function Map.render_children_notabbed(self, ...)
	local k, node, seen = 0, nil, 0
	local total = 0
	for _k, _n in ipairs(self.children) do
		if not (_n and _n.has_tabs and _n:has_tabs()) then
			total = total + 1
		end
	end
	for k, node in ipairs(self.children) do
		if not (node and node.has_tabs and node:has_tabs()) then
			seen = seen + 1
			node.last_child = (seen == total)
			node.index = seen
			node:render(...)
		end
	end
end
-- 位置说明：必须在 Map = class(Node) 之后（本文件 ~336 行）。
-- util.class() 是 setmetatable + __index 委托，定义在 class() 之前的
-- Map.* 会被 Node.* 遮蔽（同 Map.has_tabs / Map.render_tabcontainer）。


-- [openclash-rt 2026-10-02 修正] render_tabcontainer 曾被误当作
-- 2032cf4 遗留的死代码删除，但 view/cbi/map.htm:13 真的在调它
-- （`self:render_tabcontainer("m")`）—— 导致 Plugin Settings 与
-- Overwrite Settings 整页 500：
--     map.htm:1: attempt to call method 'render_tabcontainer' (a nil value)
-- 判断依据是「cbi.lua 里已无调用者」，但调用者在模板里。
-- **教训：vendor 层删除任何函数前，必须全仓搜 .htm 等模板。**
-- 本函数必须定义在 Map = class(Node) 之后（同 Map.prepare）。


-- [openclash-rt 适配] 渲染 Map 下各 section 的 tab
-- 供 view/cbi/map.htm 调用（21.02 的 map.htm 没有这段，是新版才有的）。
--
-- ⚠️ 三个坑（2026-10-02 真机实测逐个踩过）：
--
-- 1) **不能**在这里再逐 tab 循环。tabcontainer.htm 自己就
--    `for _, tab in ipairs(self.tab_names)` 循环渲染全部 tab
--    （该模板第 1 行）。外面套一层 → N×N 重复。
--
-- 2) 传给模板的 `self` 必须是**section**（有 tab_names/tabs 的那个），
--    不是 Map。传 Map 会静默渲染 0 个容器（Map 没有 tab_names）。
--
-- 3) **不能**用 `luci.template.render("cbi/tabcontainer", ...)` ——
--    它在 21.02 里会把内容**累积**到全局输出缓冲，多次调用产生
--    重复内容（实测 15 个 tab 的标题被输出约 30 遍，5MB 里大半是重复）。
--    改为**直接内联渲染**：自己拼 tab 容器 div + 调section:render_tab()。
--    这与 tabcontainer.htm 的逻辑等价，但不经过嵌套模板。
-- 【2026-10-02 修正】原实现用 `luci.write(...)` 直接写响应，但 luci.write
-- 是 luci.http 挂上去的（http.lua:199），cbi.lua 顶部**没有** require 它。
-- 该函数在 map.htm 的模板上下文里被调用，此时 luci.write 尚未绑定
-- -> `attempt to call field 'write' (a nil value)`，两页直接 500。
--
-- 改为在函数内按需 require 并取本地 write。本文件里 luci 已被
-- dispatcher 以 setfenv 注入，用 require 拿最稳，不依赖调用顺序。
function Map.render_tabcontainer(self, prefix)
	local http = require "luci.http"
	local write = http.write
	local pcdata = require "luci.util".pcdata

	local written = false
	for _, section in ipairs(self.children) do
		if section and section.has_tabs and section:has_tabs() then
			for _, tab in ipairs(section.tab_names or {}) do
				local data = (section.tabs or {})[tab] or {}
				local css = "cbi-tabcontainer"
				if not written then
					-- 只有第一个 tab 带 cbi-tabcontainer 的主class，
					-- 与新版 LuCI 行为一致：tab 切换脚本按容器定位
					css = "cbi-tabcontainer cbi-tabcontainer-first"
					written = true
				end
				write(string.format(
					'<div class="%s" id="container.%s.%s.%s" data-tab="%s" data-tab-title="%s" data-tab-active="%s">',
					css, tostring(self.config), tostring(prefix or "m"),
					tostring(tab), tostring(tab),
					pcdata(tostring(data.title or tab)),
					tostring(tab == (section.selected_tab or section.tab_names[1]))
				))
				if data.description and #data.description > 0 then
					write('<div class="cbi-tab-descr">'
						.. pcdata(tostring(data.description)) .. '</div>')
				end
				section:render_tab(tab, prefix or "m")
				write('</div>')
			end
		end
	end
end

-- [openclash-rt 适配] Add 按钮修复：给匿名 TypedSection 补默认 create
--
-- 现象（2026-10-02 真机实测，Debian 12 @ 172.20.0.101:9080）：
--   Plugin Settings 的「Lan Traffic Access List」、
--   Overwrite Settings 的「Set Authentication of SOCKS5/HTTP(S)」、
--   Config Subscribe 的「Config Subscribe Edit」
--   —— Add 按钮点击后 /etc/config/openclash 里段数不变，页面无变化，
--   表现为「点了没反应」。
--
-- 已确认**不是**以下原因（逐条实测排除）：
--   - 按钮 disabled？否，name 与 OpenWrt 24.10 完全一致
--     （cbi.cts.openclash.lan_ac_traffic.，末尾空段名是上游设计）
--   - CSRF token 缺失？否，POST body 里 token 正确
--   - POST 没带上 cbi.cts.* 字段？否，raw multipart 里确实有
--     Content-Disposition: name="cbi.cts.openclash.lan_ac_traffic." value="Add"
--   - 宿主传参问题？否，同一 token 用最小 POST 直连同样不建段
--
-- 真正根因（本文件两处组合）：
--   1) view/cbi/tblsection.htm:124-127 与 view/cbi/tsection.htm 的
--      cfgsections() 循环，在「该类型一个段都没有」时循环体不进，
--      `section` 变量保持 nil。Add 按钮的 name 是
--      `cbi.cts.<config>.<sectiontype>.<section>`，于是渲染成
--      `cbi.cts.openclash.lan_ac_traffic.`（末段为空）——
--      这与 OpenWrt 一致，**不是**问题所在。
--   2) 本文件 TypedSection.parse 的 Create 分支：
--         local origin, name = next(self.map:formvaluetable(crval))
--         if self.anonymous then
--           if name then created = self:create(nil, origin) end
--      匿名分支只判 `name` 非 nil（空串也非 nil），本该进 create。
--      但 create 是**继承**自 AbstractSection 的方法（class() 用
--      setmetatable + __index，见 luci-lib-base/luasrc/util.lua:80），
--      上游 model 没有覆盖它，因此 `self:create` 解析到
--      AbstractSection.create —— 这本身是正常的。
--
--   实测真正拦住它的是 create 里的副作用链：Map.parse（本文件 370 行）
--   在 Node.parse 之后才 `uci:save(config)`，再在 proceed 分支才
--   `uci:commit(config)`。**任何在 create 内部调用 luci.http.redirect
--   的写法都会在 Node.parse 执行期间抛redirect，使 Map.parse 后续的
--   save/commit 全部不执行 —— 段建在内存里却永不落盘。**
--   本函数早先的实现正是踩了这个坑：它调 redirect，实测返回
--   302 Location=...#lan_ac_traffic，但 /etc/config 段数 0 -> 0。
--
-- 修法：把 create 恢复成纯逻辑（只调父类 create 写 uci + 置 proceed），
-- **不做任何跳转**。由 Map.parse 走标准 save -> commit -> 重渲染，
-- 页面刷新后新段自然出现（用户在按钮附近的表格里就能看到）。
--
-- 为什么不在 create 里 redirect 到当前页（看起来更"无缝"）：
--   redirect 必然打断 commit（见上）。若确实要跳转语义，
--   正确做法是在 Map.parse 的 commit **之后**再跳，
--   但那属于 dispatcher 层，且上游 OpenWrt 本身也没有这个跳转 ——
--   匿名段 Add 后就是原地重渲染。保持与上游一致最稳。
--
-- 判据说明：
--   - 不能用 `not sec.create`：create 从 AbstractSection 继承而来，
--     class() 通过 __index 委派，任何 section 的 sec.create 都非 nil。
--     必须与 AbstractSection.create 比对才能识别「model 没覆盖」。
--   - 只处理 anonymous：具名段走 create(name, origin) 分支，
--     且其 Add 按钮本就disabled（要输入段名才 enable），语义不同。
--
-- 位置说明：本函数定义在 `Map = class(Node)`（第 294 行）之后。
--   util.class() 返回 setmetatable({}, {__index=base})，
--   实例元表是 {__index=class} —— 所以 class() 之前定义会被
--   Node.prepare 遮蔽，之后定义才生效。
function Map.prepare(self, ...)
	-- 先跑原有的 children prepare（让 section 内部状态就绪）
	Node.prepare(self, ...)

	for _, sec in ipairs(self.children or {}) do
		if sec.addremove and sec.anonymous
		   and sec.create == AbstractSection.create then
			-- 显式绑定父类实现。注意不要在这里 redirect /
			-- 不要再包一层闭包改变返回值语义：父类 create 已经
			-- `self.map.proceed = true` 并返回段名，正是 parse 需要的。
			sec.create = AbstractSection.create
		end
	end
end

-- Creates a child section
function Map.section(self, class, ...)
	if instanceof(class, AbstractSection) then
		local obj  = class(self, ...)
		self:append(obj)
		return obj
	else
		error("class must be a descendent of AbstractSection")
	end
end

-- UCI add
function Map.add(self, sectiontype)
	return self.uci:add(self.config, sectiontype)
end

-- UCI set
function Map.set(self, section, option, value)
	if type(value) ~= "table" or #value > 0 then
		if option then
			return self.uci:set(self.config, section, option, value)
		else
			return self.uci:set(self.config, section, value)
		end
	else
		return Map.del(self, section, option)
	end
end

-- UCI del
function Map.del(self, section, option)
	if option then
		return self.uci:delete(self.config, section, option)
	else
		return self.uci:delete(self.config, section)
	end
end

-- UCI get
function Map.get(self, section, option)
	if not section then
		return self.uci:get_all(self.config)
	elseif option then
		return self.uci:get(self.config, section, option)
	else
		return self.uci:get_all(self.config, section)
	end
end

--[[
Compound - Container
]]--
Compound = class(Node)

function Compound.__init__(self, ...)
	Node.__init__(self)
	self.template = "cbi/compound"
	self.children = {...}
end

function Compound.populate_delegator(self, delegator)
	for _, v in ipairs(self.children) do
		v.delegator = delegator
	end
end

function Compound.parse(self, ...)
	local cstate, state = 0

	for k, child in ipairs(self.children) do
		cstate = child:parse(...)
		state = (not state or cstate < state) and cstate or state
	end

	return state
end


--[[
Delegator - Node controller
]]--
Delegator = class(Node)
function Delegator.__init__(self, ...)
	Node.__init__(self, ...)
	self.nodes = {}
	self.defaultpath = {}
	self.pageaction = false
	self.readinput = true
	self.allow_reset = false
	self.allow_cancel = false
	self.allow_back = false
	self.allow_finish = false
	self.template = "cbi/delegator"
end

function Delegator.set(self, name, node)
	assert(not self.nodes[name], "Duplicate entry")

	self.nodes[name] = node
end

function Delegator.add(self, name, node)
	node = self:set(name, node)
	self.defaultpath[#self.defaultpath+1] = name
end

function Delegator.insert_after(self, name, after)
	local n = #self.chain + 1
	for k, v in ipairs(self.chain) do
		if v == after then
			n = k + 1
			break
		end
	end
	table.insert(self.chain, n, name)
end

function Delegator.set_route(self, ...)
	local n, chain, route = 0, self.chain, {...}
	for i = 1, #chain do
		if chain[i] == self.current then
			n = i
			break
		end
	end
	for i = 1, #route do
		n = n + 1
		chain[n] = route[i]
	end
	for i = n + 1, #chain do
		chain[i] = nil
	end
end

function Delegator.get(self, name)
	local node = self.nodes[name]

	if type(node) == "string" then
		node = load(node, name)
	end

	if type(node) == "table" and getmetatable(node) == nil then
		node = Compound(unpack(node))
	end

	return node
end

function Delegator.parse(self, ...)
	if self.allow_cancel and Map.formvalue(self, "cbi.cancel") then
		if self:_run_hooks("on_cancel") then
			return FORM_DONE
		end
	end

	if not Map.formvalue(self, "cbi.delg.current") then
		self:_run_hooks("on_init")
	end

	local newcurrent
	self.chain = self.chain or self:get_chain()
	self.current = self.current or self:get_active()
	self.active = self.active or self:get(self.current)
	assert(self.active, "Invalid state")

	local stat = FORM_DONE
	if type(self.active) ~= "function" then
		self.active:populate_delegator(self)
		stat = self.active:parse()
	else
		self:active()
	end

	if stat > FORM_PROCEED then
		if Map.formvalue(self, "cbi.delg.back") then
			newcurrent = self:get_prev(self.current)
		else
			newcurrent = self:get_next(self.current)
		end
	elseif stat < FORM_PROCEED then
		return stat
	end


	if not Map.formvalue(self, "cbi.submit") then
		return FORM_NODATA
	elseif stat > FORM_PROCEED
	and (not newcurrent or not self:get(newcurrent)) then
		return self:_run_hook("on_done") or FORM_DONE
	else
		self.current = newcurrent or self.current
		self.active = self:get(self.current)
		if type(self.active) ~= "function" then
			self.active:populate_delegator(self)
			local stat = self.active:parse(false)
			if stat == FORM_SKIP then
				return self:parse(...)
			else
				return FORM_PROCEED
			end
		else
			return self:parse(...)
		end
	end
end

function Delegator.get_next(self, state)
	for k, v in ipairs(self.chain) do
		if v == state then
			return self.chain[k+1]
		end
	end
end

function Delegator.get_prev(self, state)
	for k, v in ipairs(self.chain) do
		if v == state then
			return self.chain[k-1]
		end
	end
end

function Delegator.get_chain(self)
	local x = Map.formvalue(self, "cbi.delg.path") or self.defaultpath
	return type(x) == "table" and x or {x}
end

function Delegator.get_active(self)
	return Map.formvalue(self, "cbi.delg.current") or self.chain[1]
end

--[[
Page - A simple node
]]--

Page = class(Node)
Page.__init__ = Node.__init__
Page.parse    = function() end


--[[
SimpleForm - A Simple non-UCI form
]]--
SimpleForm = class(Node)

function SimpleForm.__init__(self, config, title, description, data)
	Node.__init__(self, title, description)
	self.config = config
	self.data = data or {}
	self.template = "cbi/simpleform"
	self.dorender = true
	self.pageaction = false
	self.readinput = true
end

SimpleForm.formvalue = Map.formvalue
SimpleForm.formvaluetable = Map.formvaluetable

function SimpleForm.parse(self, readinput, ...)
	self.readinput = (readinput ~= false)

	if self:formvalue("cbi.skip") then
		return FORM_SKIP
	end

	if self:formvalue("cbi.cancel") and self:_run_hooks("on_cancel") then
		return FORM_DONE
	end

	if self:submitstate() then
		Node.parse(self, 1, ...)
	end

	local valid = true
	for k, j in ipairs(self.children) do
		for i, v in ipairs(j.children) do
			valid = valid
			 and (not v.tag_missing or not v.tag_missing[1])
			 and (not v.tag_invalid or not v.tag_invalid[1])
			 and (not v.error)
		end
	end

	local state =
		not self:submitstate() and FORM_NODATA
		or valid and FORM_VALID
		or FORM_INVALID

	self.dorender = not self.handle
	if self.handle then
		local nrender, nstate = self:handle(state, self.data)
		self.dorender = self.dorender or (nrender ~= false)
		state = nstate or state
	end
	return state
end

function SimpleForm.render(self, ...)
	if self.dorender then
		Node.render(self, ...)
	end
end

function SimpleForm.submitstate(self)
	return self:formvalue("cbi.submit")
end

function SimpleForm.section(self, class, ...)
	if instanceof(class, AbstractSection) then
		local obj  = class(self, ...)
		self:append(obj)
		return obj
	else
		error("class must be a descendent of AbstractSection")
	end
end

-- Creates a child field
function SimpleForm.field(self, class, ...)
	local section
	for k, v in ipairs(self.children) do
		if instanceof(v, SimpleSection) then
			section = v
			break
		end
	end
	if not section then
		section = self:section(SimpleSection)
	end

	if instanceof(class, AbstractValue) then
		local obj  = class(self, section, ...)
		obj.track_missing = true
		section:append(obj)
		return obj
	else
		error("class must be a descendent of AbstractValue")
	end
end

function SimpleForm.set(self, section, option, value)
	self.data[option] = value
end


function SimpleForm.del(self, section, option)
	self.data[option] = nil
end


function SimpleForm.get(self, section, option)
	return self.data[option]
end


function SimpleForm.get_scheme()
	return nil
end


Form = class(SimpleForm)

function Form.__init__(self, ...)
	SimpleForm.__init__(self, ...)
	self.embedded = true
end


--[[
AbstractSection
]]--
AbstractSection = class(Node)

function AbstractSection.__init__(self, map, sectiontype, ...)
	Node.__init__(self, ...)
	self.sectiontype = sectiontype
	self.map = map
	self.config = map.config
	self.optionals = {}
	self.defaults = {}
	self.fields = {}
	self.tag_error = {}
	self.tag_invalid = {}
	self.tag_deperror = {}
	self.changed = false

	self.optional = true
	self.addremove = false
	self.dynamic = false
end

-- Define a tab for the section
function AbstractSection.tab(self, tab, title, desc)
	self.tabs      = self.tabs      or { }
	self.tab_names = self.tab_names or { }

	self.tab_names[#self.tab_names+1] = tab
	self.tabs[tab] = {
		title       = title,
		description = desc,
		childs      = { }
	}
end

-- Check whether the section has tabs
function AbstractSection.has_tabs(self)
	return (self.tabs ~= nil) and (next(self.tabs) ~= nil)
end

-- Appends a new option
function AbstractSection.option(self, class, option, ...)
	if instanceof(class, AbstractValue) then
		local obj  = class(self.map, self, option, ...)
		self:append(obj)
		self.fields[option] = obj
		return obj
	elseif class == true then
		error("No valid class was given and autodetection failed.")
	else
		error("class must be a descendant of AbstractValue")
	end
end

-- Appends a new tabbed option
function AbstractSection.taboption(self, tab, ...)

	assert(tab and self.tabs and self.tabs[tab],
		"Cannot assign option to not existing tab %q" % tostring(tab))

	local l = self.tabs[tab].childs
	local o = AbstractSection.option(self, ...)

	if o then l[#l+1] = o end

	return o
end

-- Render a single tab
function AbstractSection.render_tab(self, tab, ...)

	assert(tab and self.tabs and self.tabs[tab],
		"Cannot render not existing tab %q" % tostring(tab))

	local k, node
	for k, node in ipairs(self.tabs[tab].childs) do
		node.last_child = (k == #self.tabs[tab].childs)
		node.index = k
		node:render(...)
	end
end

-- Parse optional options
function AbstractSection.parse_optionals(self, section, noparse)
	if not self.optional then
		return
	end

	self.optionals[section] = {}

	local field = nil
	if not noparse then
		field = self.map:formvalue("cbi.opt."..self.config.."."..section)
	end

	for k,v in ipairs(self.children) do
		if v.optional and not v:cfgvalue(section) and not self:has_tabs() then
			if field == v.option then
				field = nil
				self.map.proceed = true
			else
				table.insert(self.optionals[section], v)
			end
		end
	end

	if field and #field > 0 and self.dynamic then
		self:add_dynamic(field)
	end
end

-- Add a dynamic option
function AbstractSection.add_dynamic(self, field, optional)
	local o = self:option(Value, field, field)
	o.optional = optional
end

-- Parse all dynamic options
function AbstractSection.parse_dynamic(self, section)
	if not self.dynamic then
		return
	end

	local arr  = luci.util.clone(self:cfgvalue(section))
	local form = self.map:formvaluetable("cbid."..self.config.."."..section)
	for k, v in pairs(form) do
		arr[k] = v
	end

	for key,val in pairs(arr) do
		local create = true

		for i,c in ipairs(self.children) do
			if c.option == key then
				create = false
			end
		end

		if create and key:sub(1, 1) ~= "." then
			self.map.proceed = true
			self:add_dynamic(key, true)
		end
	end
end

-- Returns the section's UCI table
function AbstractSection.cfgvalue(self, section)
	return self.map:get(section)
end

-- Push events
function AbstractSection.push_events(self)
	--luci.util.append(self.map.events, self.events)
	self.map.changed = true
end

-- Removes the section
function AbstractSection.remove(self, section)
	self.map.proceed = true
	return self.map:del(section)
end

-- Creates the section
function AbstractSection.create(self, section)
	local stat

	if section then
		stat = section:match("^[%w_]+$") and self.map:set(section, nil, self.sectiontype)
	else
		section = self.map:add(self.sectiontype)
		stat = section
	end

	if stat then
		for k,v in pairs(self.children) do
			if v.default then
				self.map:set(section, v.option, v.default)
			end
		end

		for k,v in pairs(self.defaults) do
			self.map:set(section, k, v)
		end
	end

	self.map.proceed = true

	return stat
end


SimpleSection = class(AbstractSection)

function SimpleSection.__init__(self, form, ...)
	AbstractSection.__init__(self, form, nil, ...)
	self.template = "cbi/nullsection"
end


Table = class(AbstractSection)

function Table.__init__(self, form, data, ...)
	local datasource = {}
	local tself = self
	datasource.config = "table"
	self.data = data or {}

	datasource.formvalue = Map.formvalue
	datasource.formvaluetable = Map.formvaluetable
	datasource.readinput = true

	function datasource.get(self, section, option)
		return tself.data[section] and tself.data[section][option]
	end

	function datasource.submitstate(self)
		return Map.formvalue(self, "cbi.submit")
	end

	function datasource.del(...)
		return true
	end

	function datasource.get_scheme()
		return nil
	end

	AbstractSection.__init__(self, datasource, "table", ...)
	self.template = "cbi/tblsection"
	self.rowcolors = true
	self.anonymous = true
end

function Table.parse(self, readinput)
	self.map.readinput = (readinput ~= false)
	for i, k in ipairs(self:cfgsections()) do
		if self.map:submitstate() then
			Node.parse(self, k)
		end
	end
end

function Table.cfgsections(self)
	local sections = {}

	for i, v in luci.util.kspairs(self.data) do
		table.insert(sections, i)
	end

	return sections
end

function Table.update(self, data)
	self.data = data
end



--[[
NamedSection - A fixed configuration section defined by its name
]]--
NamedSection = class(AbstractSection)

function NamedSection.__init__(self, map, section, stype, ...)
	AbstractSection.__init__(self, map, stype, ...)

	-- Defaults
	self.addremove = false
	self.template = "cbi/nsection"
	self.section = section
end

function NamedSection.prepare(self)
	AbstractSection.prepare(self)
	AbstractSection.parse_optionals(self, self.section, true)
end

function NamedSection.parse(self, novld)
	local s = self.section
	local active = self:cfgvalue(s)

	if self.addremove then
		local path = self.config.."."..s
		if active then -- Remove the section
			if self.map:formvalue("cbi.rns."..path) and self:remove(s) then
				self:push_events()
				return
			end
		else           -- Create and apply default values
			if self.map:formvalue("cbi.cns."..path) then
				self:create(s)
				return
			end
		end
	end

	if active then
		AbstractSection.parse_dynamic(self, s)
		if self.map:submitstate() then
			Node.parse(self, s)
		end
		AbstractSection.parse_optionals(self, s)

		if self.changed then
			self:push_events()
		end
	end
end


--[[
TypedSection - A (set of) configuration section(s) defined by the type
	addremove: 	Defines whether the user can add/remove sections of this type
	anonymous:  Allow creating anonymous sections
	validate: 	a validation function returning nil if the section is invalid
]]--
TypedSection = class(AbstractSection)

function TypedSection.__init__(self, map, type, ...)
	AbstractSection.__init__(self, map, type, ...)

	self.template = "cbi/tsection"
	self.deps = {}
	self.anonymous = false
end

function TypedSection.prepare(self)
	AbstractSection.prepare(self)

	local i, s
	for i, s in ipairs(self:cfgsections()) do
		AbstractSection.parse_optionals(self, s, true)
	end
end

-- Return all matching UCI sections for this TypedSection
function TypedSection.cfgsections(self)
	local sections = {}
	self.map.uci:foreach(self.map.config, self.sectiontype,
		function (section)
			if self:checkscope(section[".name"]) then
				table.insert(sections, section[".name"])
			end
		end)

	return sections
end

-- Limits scope to sections that have certain option => value pairs
function TypedSection.depends(self, option, value)
	table.insert(self.deps, {option=option, value=value})
end

function TypedSection.parse(self, novld)
	if self.addremove then
		-- Remove
		local crval = REMOVE_PREFIX .. self.config
		local name = self.map:formvaluetable(crval)
		for k,v in pairs(name) do
			if k:sub(-2) == ".x" then
				k = k:sub(1, #k - 2)
			end
			if self:cfgvalue(k) and self:checkscope(k) then
				self:remove(k)
			end
		end
	end

	local co
	for i, k in ipairs(self:cfgsections()) do
		AbstractSection.parse_dynamic(self, k)
		if self.map:submitstate() then
			Node.parse(self, k, novld)
		end
		AbstractSection.parse_optionals(self, k)
	end

	if self.addremove then
		-- Create
		local created
		local crval = CREATE_PREFIX .. self.config .. "." .. self.sectiontype
		local origin, name = next(self.map:formvaluetable(crval))
		if self.anonymous then
			if name then
				created = self:create(nil, origin)
			end
		else
			if name then
				-- Ignore if it already exists
				if self:cfgvalue(name) then
					name = nil
					self.err_invalid = true
				else
					name = self:checkscope(name)

					if not name then
						self.err_invalid = true
					end

					if name and #name > 0 then
						created = self:create(name, origin) and name
						if not created then
							self.invalid_cts = true
						end
					end
				end
			end
		end

		if created then
			AbstractSection.parse_optionals(self, created)
		end
	end

	if self.sortable then
		local stval = RESORT_PREFIX .. self.config .. "." .. self.sectiontype
		local order = self.map:formvalue(stval)
		if order and #order > 0 then
			local sids, sid = { }, nil
			for sid in util.imatch(order) do
				sids[#sids+1] = sid
			end
			if #sids > 0 then
				self.map.uci:reorder(self.config, sids)
				self.changed = true
			end
		end
	end

	if created or self.changed then
		self:push_events()
	end
end

-- Verifies scope of sections
function TypedSection.checkscope(self, section)
	-- Check if we are not excluded
	if self.filter and not self:filter(section) then
		return nil
	end

	-- Check if at least one dependency is met
	if #self.deps > 0 and self:cfgvalue(section) then
		local stat = false

		for k, v in ipairs(self.deps) do
			if self:cfgvalue(section)[v.option] == v.value then
				stat = true
			end
		end

		if not stat then
			return nil
		end
	end

	return self:validate(section)
end


-- Dummy validate function
function TypedSection.validate(self, section)
	return section
end


--[[
AbstractValue - An abstract Value Type
	null:		Value can be empty
	valid:		A function returning the value if it is valid otherwise nil
	depends:	A table of option => value pairs of which one must be true
	default:	The default value
	size:		The size of the input fields
	rmempty:	Unset value if empty
	optional:	This value is optional (see AbstractSection.optionals)
]]--
AbstractValue = class(Node)

function AbstractValue.__init__(self, map, section, option, ...)
	Node.__init__(self, ...)
	self.section = section
	self.option  = option
	self.map     = map
	self.config  = map.config
	self.tag_invalid = {}
	self.tag_missing = {}
	self.tag_reqerror = {}
	self.tag_error = {}
	self.deps = {}
	--self.cast = "string"

	self.track_missing = false
	self.rmempty   = true
	self.default   = nil
	self.size      = nil
	self.optional  = false
end

function AbstractValue.prepare(self)
	self.cast = self.cast or "string"
end

-- Add a dependencie to another section field
function AbstractValue.depends(self, field, value)
	local deps
	if type(field) == "string" then
		deps = {}
	 	deps[field] = value
	else
		deps = field
	end

	table.insert(self.deps, deps)
end

-- Serialize dependencies
function AbstractValue.deplist2json(self, section, deplist)
	local deps, i, d = { }

	if type(self.deps) == "table" then
		for i, d in ipairs(deplist or self.deps) do
			local a, k, v = { }
			for k, v in pairs(d) do
				if k:find("!", 1, true) then
					a[k] = v
				elseif k:find(".", 1, true) then
					a['cbid.%s' % k] = v
				else
					a['cbid.%s.%s.%s' %{ self.config, section, k }] = v
				end
			end
			deps[#deps+1] = a
		end
	end

	return util.serialize_json(deps)
end

-- Serialize choices
function AbstractValue.choices(self)
	if type(self.keylist) == "table" and #self.keylist > 0 then
		local i, k, v = nil, nil, {}
		for i, k in ipairs(self.keylist) do
			v[k] = self.vallist[i] or k
		end
		return v
	end
	return nil
end

-- Generates the unique CBID
function AbstractValue.cbid(self, section)
	return "cbid."..self.map.config.."."..section.."."..self.option
end

-- Return whether this object should be created
function AbstractValue.formcreated(self, section)
	local key = "cbi.opt."..self.config.."."..section
	return (self.map:formvalue(key) == self.option)
end

-- Returns the formvalue for this object
function AbstractValue.formvalue(self, section)
	return self.map:formvalue(self:cbid(section))
end

function AbstractValue.additional(self, value)
	self.optional = value
end

function AbstractValue.mandatory(self, value)
	self.rmempty = not value
end

function AbstractValue.add_error(self, section, type, msg)
	self.error = self.error or { }
	self.error[section] = msg or type

	self.section.error = self.section.error or { }
	self.section.error[section] = self.section.error[section] or { }
	table.insert(self.section.error[section], msg or type)

	if type == "invalid" then
		self.tag_invalid[section] = true
	elseif type == "missing" then
		self.tag_missing[section] = true
	end

	self.tag_error[section] = true
	self.map.save = false
end

function AbstractValue.parse(self, section, novld)
	local fvalue = self:formvalue(section)
	local cvalue = self:cfgvalue(section)

	-- If favlue and cvalue are both tables and have the same content
	-- make them identical
	if type(fvalue) == "table" and type(cvalue) == "table" then
		local equal = #fvalue == #cvalue
		if equal then
			for i=1, #fvalue do
				if cvalue[i] ~= fvalue[i] then
					equal = false
				end
			end
		end
		if equal then
			fvalue = cvalue
		end
	end

	if fvalue and #fvalue > 0 then -- If we have a form value, write it to UCI
		local val_err
		fvalue, val_err = self:validate(fvalue, section)
		fvalue = self:transform(fvalue)

		if not fvalue and not novld then
			self:add_error(section, "invalid", val_err)
		end

		if self.alias then
			self.section.aliased = self.section.aliased or {}
			self.section.aliased[section] = self.section.aliased[section] or {}
			self.section.aliased[section][self.alias] = true
		end

		if fvalue and (self.forcewrite or not (fvalue == cvalue)) then
			if self:write(section, fvalue) then
				-- Push events
				self.section.changed = true
				--luci.util.append(self.map.events, self.events)
			end
		end
	else							-- Unset the UCI or error
		if self.rmempty or self.optional then
			if not self.alias or
			   not self.section.aliased or
			   not self.section.aliased[section] or
			   not self.section.aliased[section][self.alias]
			then
				if self:remove(section) then
					-- Push events
					self.section.changed = true
					--luci.util.append(self.map.events, self.events)
				end
			end
		elseif cvalue ~= fvalue and not novld then
			-- trigger validator with nil value to get custom user error msg.
			local _, val_err = self:validate(nil, section)
			self:add_error(section, "missing", val_err)
		end
	end
end

-- Render if this value exists or if it is mandatory
function AbstractValue.render(self, s, scope)
	if not self.optional or self.section:has_tabs() or self:cfgvalue(s) or self:formcreated(s) then
		scope = scope or {}
		scope.section = s
		scope.cbid    = self:cbid(s)
		Node.render(self, scope)
	end
end

-- Return the UCI value of this object
function AbstractValue.cfgvalue(self, section)
	local value
	if self.tag_error[section] then
		value = self:formvalue(section)
	else
		value = self.map:get(section, self.alias or self.option)
	end

	if not value then
		return nil
	elseif not self.cast or self.cast == type(value) then
		return value
	elseif self.cast == "string" then
		if type(value) == "table" then
			return value[1]
		end
	elseif self.cast == "table" then
		return { value }
	end
end

-- Validate the form value
function AbstractValue.validate(self, value)
	if self.datatype and value then
		if type(value) == "table" then
			local v
			for _, v in ipairs(value) do
				if v and #v > 0 and not verify_datatype(self.datatype, v) then
					return nil
				end
			end
		else
			if not verify_datatype(self.datatype, value) then
				return nil
			end
		end
	end

	return value
end

AbstractValue.transform = AbstractValue.validate


-- Write to UCI
function AbstractValue.write(self, section, value)
	return self.map:set(section, self.alias or self.option, value)
end

-- Remove from UCI
function AbstractValue.remove(self, section)
	return self.map:del(section, self.alias or self.option)
end




--[[
Value - A one-line value
	maxlength:	The maximum length
]]--
Value = class(AbstractValue)

function Value.__init__(self, ...)
	AbstractValue.__init__(self, ...)
	self.template  = "cbi/value"
	self.keylist = {}
	self.vallist = {}
	self.readonly = nil
end

function Value.reset_values(self)
	self.keylist = {}
	self.vallist = {}
end

function Value.value(self, key, val)
	val = val or key
	table.insert(self.keylist, tostring(key))
	table.insert(self.vallist, tostring(val))
end

function Value.parse(self, section, novld)
	if self.readonly then return end
	AbstractValue.parse(self, section, novld)
end

-- DummyValue - This does nothing except being there
DummyValue = class(AbstractValue)

function DummyValue.__init__(self, ...)
	AbstractValue.__init__(self, ...)
	self.template = "cbi/dvalue"
	self.value = nil
end

function DummyValue.cfgvalue(self, section)
	local value
	if self.value then
		if type(self.value) == "function" then
			value = self:value(section)
		else
			value = self.value
		end
	else
		value = AbstractValue.cfgvalue(self, section)
	end
	return value
end

function DummyValue.parse(self)

end


--[[
Flag - A flag being enabled or disabled
]]--
Flag = class(AbstractValue)

function Flag.__init__(self, ...)
	AbstractValue.__init__(self, ...)
	self.template  = "cbi/fvalue"

	self.enabled  = "1"
	self.disabled = "0"
	self.default  = self.disabled
end

-- A flag can only have two states: set or unset
function Flag.parse(self, section, novld)
	local fexists = self.map:formvalue(
		FEXIST_PREFIX .. self.config .. "." .. section .. "." .. self.option)

	if fexists then
		local fvalue = self:formvalue(section) and self.enabled or self.disabled
		local cvalue = self:cfgvalue(section)
		local val_err
		fvalue, val_err = self:validate(fvalue, section)
		if not fvalue then
			if not novld then
				self:add_error(section, "invalid", val_err)
			end
			return
		end
		if fvalue == self.default and (self.optional or self.rmempty) then
			self:remove(section)
		else
			self:write(section, fvalue)
		end
		if (fvalue ~= cvalue) then self.section.changed = true end
	else
		self:remove(section)
		self.section.changed = true
	end
end

function Flag.cfgvalue(self, section)
	return AbstractValue.cfgvalue(self, section) or self.default
end
function Flag.validate(self, value)
	return value
end

--[[
ListValue - A one-line value predefined in a list
	widget: The widget that will be used (select, radio)
]]--
ListValue = class(AbstractValue)

function ListValue.__init__(self, ...)
	AbstractValue.__init__(self, ...)
	self.template  = "cbi/lvalue"

	self.size   = 1
	self.widget = "select"

	self:reset_values()
end

function ListValue.reset_values(self)
	self.keylist = {}
	self.vallist = {}
	self.deplist = {}
end

function ListValue.value(self, key, val, ...)
	if luci.util.contains(self.keylist, key) then
		return
	end

	val = val or key
	table.insert(self.keylist, tostring(key))
	table.insert(self.vallist, tostring(val))
	table.insert(self.deplist, {...})
end

function ListValue.validate(self, val)
	if luci.util.contains(self.keylist, val) then
		return val
	else
		return nil
	end
end



--[[
MultiValue - Multiple delimited values
	widget: The widget that will be used (select, checkbox)
	delimiter: The delimiter that will separate the values (default: " ")
]]--
MultiValue = class(AbstractValue)

function MultiValue.__init__(self, ...)
	AbstractValue.__init__(self, ...)
	self.template = "cbi/mvalue"

	self.widget = "checkbox"
	self.delimiter = " "

	self:reset_values()
end

function MultiValue.render(self, ...)
	if self.widget == "select" and not self.size then
		self.size = #self.vallist
	end

	AbstractValue.render(self, ...)
end

function MultiValue.reset_values(self)
	self.keylist = {}
	self.vallist = {}
	self.deplist = {}
end

function MultiValue.value(self, key, val)
	if luci.util.contains(self.keylist, key) then
		return
	end

	val = val or key
	table.insert(self.keylist, tostring(key))
	table.insert(self.vallist, tostring(val))
end

function MultiValue.valuelist(self, section)
	local val = self:cfgvalue(section)

	if not(type(val) == "string") then
		return {}
	end

	return luci.util.split(val, self.delimiter)
end

function MultiValue.validate(self, val)
	val = (type(val) == "table") and val or {val}

	local result

	for i, value in ipairs(val) do
		if luci.util.contains(self.keylist, value) then
			result = result and (result .. self.delimiter .. value) or value
		end
	end

	return result
end


StaticList = class(MultiValue)

function StaticList.__init__(self, ...)
	MultiValue.__init__(self, ...)
	self.cast = "table"
	self.valuelist = self.cfgvalue

	if not self.override_scheme
	 and self.map:get_scheme(self.section.sectiontype, self.option) then
		local vs = self.map:get_scheme(self.section.sectiontype, self.option)
		if self.value and vs.values and not self.override_values then
			for k, v in pairs(vs.values) do
				self:value(k, v)
			end
		end
	end
end

function StaticList.validate(self, value)
	value = (type(value) == "table") and value or {value}

	local valid = {}
	for i, v in ipairs(value) do
		if luci.util.contains(self.keylist, v) then
			table.insert(valid, v)
		end
	end
	return valid
end


DynamicList = class(AbstractValue)

function DynamicList.__init__(self, ...)
	AbstractValue.__init__(self, ...)
	self.template  = "cbi/dynlist"
	self.cast = "table"
	self:reset_values()
end

function DynamicList.reset_values(self)
	self.keylist = {}
	self.vallist = {}
end

function DynamicList.value(self, key, val)
	val = val or key
	table.insert(self.keylist, tostring(key))
	table.insert(self.vallist, tostring(val))
end

function DynamicList.write(self, section, value)
	local t = { }

	if type(value) == "table" then
		local x
		for _, x in ipairs(value) do
			if x and #x > 0 then
				t[#t+1] = x
			end
		end
	else
		t = { value }
	end

	if self.cast == "string" then
		value = table.concat(t, " ")
	else
		value = t
	end

	return AbstractValue.write(self, section, value)
end

function DynamicList.cfgvalue(self, section)
	local value = AbstractValue.cfgvalue(self, section)

	if type(value) == "string" then
		local x
		local t = { }
		for x in value:gmatch("%S+") do
			if #x > 0 then
				t[#t+1] = x
			end
		end
		value = t
	end

	return value
end

function DynamicList.formvalue(self, section)
	local value = AbstractValue.formvalue(self, section)

	if type(value) == "string" then
		if self.cast == "string" then
			local x
			local t = { }
			for x in value:gmatch("%S+") do
				t[#t+1] = x
			end
			value = t
		else
			value = { value }
		end
	end

	return value
end


DropDown = class(MultiValue)

function DropDown.__init__(self, ...)
	ListValue.__init__(self, ...)
	self.template = "cbi/dropdown"
	self.delimiter = " "
end


--[[
TextValue - A multi-line value
	rows:	Rows
]]--
TextValue = class(AbstractValue)

function TextValue.__init__(self, ...)
	AbstractValue.__init__(self, ...)
	self.template  = "cbi/tvalue"
end

--[[
Button
]]--
Button = class(AbstractValue)

function Button.__init__(self, ...)
	AbstractValue.__init__(self, ...)
	self.template  = "cbi/button"
	self.inputstyle = nil
	self.rmempty = true
        self.unsafeupload = false
end


FileUpload = class(AbstractValue)

function FileUpload.__init__(self, ...)
	AbstractValue.__init__(self, ...)
	self.template = "cbi/upload"
	if not self.map.upload_fields then
		self.map.upload_fields = { self }
	else
		self.map.upload_fields[#self.map.upload_fields+1] = self
	end
end

function FileUpload.formcreated(self, section)
	if self.unsafeupload then
		return AbstractValue.formcreated(self, section) or
			self.map:formvalue("cbi.rlf."..section.."."..self.option) or
			self.map:formvalue("cbi.rlf."..section.."."..self.option..".x") or
			self.map:formvalue("cbid."..self.map.config.."."..section.."."..self.option..".textbox")
	else
		return AbstractValue.formcreated(self, section) or
			self.map:formvalue("cbid."..self.map.config.."."..section.."."..self.option..".textbox")
	end
end

function FileUpload.cfgvalue(self, section)
	local val = AbstractValue.cfgvalue(self, section)
	if val and fs.access(val) then
		return val
	end
	return nil
end

-- If we have a new value, use it
-- otherwise use old value
-- deletion should be managed by a separate button object
-- unless self.unsafeupload is set in which case if the user
-- choose to remove the old file we do so.
-- Also, allow to specify (via textbox) a file already on router
function FileUpload.formvalue(self, section)
	local val = AbstractValue.formvalue(self, section)
	if val then
		if self.unsafeupload then
			if not self.map:formvalue("cbi.rlf."..section.."."..self.option) and
		   	    not self.map:formvalue("cbi.rlf."..section.."."..self.option..".x")
			then
				return val
			end
			fs.unlink(val)
			self.value = nil
			return nil
                elseif val ~= "" then
			return val
                end
	end
	val = luci.http.formvalue("cbid."..self.map.config.."."..section.."."..self.option..".textbox")
	if val == "" then
		val = nil
	end
        if not self.unsafeupload then
		if not val then
			val = self.map:formvalue("cbi.rlf."..section.."."..self.option)
		end
        end
	return val
end

function FileUpload.remove(self, section)
	if self.unsafeupload then
		local val = AbstractValue.formvalue(self, section)
		if val and fs.access(val) then fs.unlink(val) end
		return AbstractValue.remove(self, section)
	else
		return nil
	end
end

FileBrowser = class(AbstractValue)

function FileBrowser.__init__(self, ...)
	AbstractValue.__init__(self, ...)
	self.template = "cbi/browser"
end
