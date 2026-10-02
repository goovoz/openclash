-- =============================================================================
-- openclash-rt 进程内 uci 对象（P4 自研件）
-- -----------------------------------------------------------------------------
-- 复刻 rpcd 的 uci 插件语义，但**委托给已编译的 libuci Lua 绑定**（build-uci.sh
-- 产物，require "uci" 的 cursor），不重新实现事务语义（rpcd uci 插件底层也是
-- libuci，两者等价）。
--
-- 为什么需要这个：luci.model.uci 的 get_all/set/commit 等**不是**直接调 libuci，
-- 而是 util.ubus("uci", cmd, args) 走 ubus 总线（vendor/model/uci.lua:37-41）。
-- 进程内方案（不跑 ubusd/rpcd）下，必须由假 ubus 模块接住 uci 对象，转发给
-- libuci cursor。测绘结论见 docs/06 §5。
--
-- 返回值结构严格对齐 rpcd uci.c 的 rpc_uci_getcommon 等：
--   get(config[,section[,option]]) → { values = {section={opt=val}} } 或 { value=... }
--   changes(config)               → { changes = {...} }
--   commit(config) / revert(config) / apply(...) → {} （或 errno）
-- =============================================================================

local ok_uci, uci_mod = pcall(require, "uci")
if not ok_uci then
	-- uci C 绑定缺失（理论上不该发生，build-uci.sh 会产出并 postinst 落位）
	error("luci-uci: 无法加载 uci C 绑定（build-uci.sh 产物缺失？）")
end

-- -----------------------------------------------------------------------------
-- 游标缓存：每个进程一个 cursor（rpcd 也是全局单 cursor）
-- -----------------------------------------------------------------------------
local cursor = uci_mod.cursor()

-- -----------------------------------------------------------------------------
-- get(config, section?, option?[, type?]) → { values } 或 { value }
--
-- 【重要】必须**保留** libuci 的元字段（.name / .type / .anonymous / .index）。
--
-- 起因（2026-10-02 真机实测，Debian 12 @ 172.20.0.101:9080）：
-- Add 按钮点了没反应。逐层定位发现段其实**建出来了**（uci delta 里有），
-- 但页面不渲染新段。对照 ImmortalWrt 24.10（172.20.0.2）点同一个按钮，
-- 新段 cfg2a8d41 立即出现在页面里。
--
-- 差异在 luci.model.uci 的 foreach（vendor/luci-base/luasrc/model/uci.lua:245），
-- 它靠 `get` 返回的 section 表里的元字段工作：
--     section[".index"] = section[".index"] or index   -- 排序
--     callback(section) -> section[".name"]            -- 取段名
-- 而 TypedSection.cfgsections（cbi.lua:1268）进一步：
--     self.map.uci:foreach(config, sectiontype, function(section)
--         if self:checkscope(section[".name"]) then
--             table.insert(sections, section[".name"])
--
-- 本实现原先在每个 section 上执行 `if not k:match("^%.") then clean[k] = v`，
-- 把 .name/.type/.index **全部剥掉** -> foreach 的回调里 section[".name"]
-- 恒为 nil -> checkscope(nil) 不通过 -> 段被静默过滤 -> 表里不出现新段。
-- 用户观感就是「Add 点了没反应」。
--
-- 同时补上 `type` 过滤参数：foreach 会传 `{config=..., type=stype}`，
-- 原实现忽略 type，导致按类型枚举也拿不到正确集合（虽然对 openclash
-- 这种单type config 影响不大，但 get_first / get_all 依赖它）。
-- -----------------------------------------------------------------------------
local function op_get(data)
	local config = data.config
	if not config then
		return nil, 1, "INVALID_ARGUMENT"
	end

	if data.section then
		if data.option then
			-- 单 option
			local ok, v = pcall(cursor.get, cursor, config, data.section, data.option)
			if ok then
				return { value = v }
			end
		else
			-- 单 section
			local ok, all = pcall(cursor.get_all, cursor, config, data.section)
			if ok and type(all) == "table" then
				-- 原样返回（含 .name/.type/.anonymous/.index），
				-- 与 rpcd uci.c rpc_uci_getcommon 的 section 语义一致。
				return { values = all }
			end
		end
	else
		-- 整个 config（可按 type 过滤）
		local ok, all = pcall(cursor.get_all, cursor, config)
		if ok and type(all) == "table" then
			local values = {}
			for section, opts in pairs(all) do
				if type(opts) == "table" then
					if not data.type or opts[".type"] == data.type then
						-- 原样返回，保留元字段（见上方注释）
						values[section] = opts
					end
				end
			end
			return { values = values }
		end
	end

	-- 读失败 → 空（rpcd 对不存在的 config 返回空 values）
	return { values = {} }
end

-- -----------------------------------------------------------------------------
-- add(config, type, name?, values?) → { section }
-- -----------------------------------------------------------------------------
local function op_add(data)
	local config, stype = data.config, data.type
	if not config or not stype then
		return nil, 1, "INVALID_ARGUMENT"
	end

	local section
	if data.name then
		local ok = pcall(cursor.set, cursor, config, data.name, stype)
		if ok then section = data.name end
	else
		local ok, name = pcall(cursor.add, cursor, config, stype)
		if ok then section = name end
	end

	if section and type(data.values) == "table" then
		for k, v in pairs(data.values) do
			pcall(cursor.set, cursor, config, section, k, v)
		end
	end

	if section then
		return { section = section }
	end
	return nil, 4, "NOT_FOUND"
end

-- -----------------------------------------------------------------------------
-- set(config, section, values) → {}
-- -----------------------------------------------------------------------------
local function op_set(data)
	local config, section = data.config, data.section
	if not config or not section then
		return nil, 1, "INVALID_ARGUMENT"
	end

	if type(data.values) == "table" then
		for k, v in pairs(data.values) do
			pcall(cursor.set, cursor, config, section, k, v)
		end
	end
	return {}
end

-- -----------------------------------------------------------------------------
-- delete(config, section, option?) → {}
-- -----------------------------------------------------------------------------
local function op_delete(data)
	local config, section = data.config, data.section
	if not config or not section then
		return nil, 1, "INVALID_ARGUMENT"
	end
	if data.option then
		pcall(cursor.delete, cursor, config, section, data.option)
	else
		pcall(cursor.delete, cursor, config, section)
	end
	return {}
end

-- -----------------------------------------------------------------------------
-- order(config, section, index) → {}
-- -----------------------------------------------------------------------------
local function op_order(data)
	if data.config and data.section then
		pcall(cursor.reorder, cursor, data.config, data.section, tonumber(data.index) or 0)
	end
	return {}
end

-- -----------------------------------------------------------------------------
-- changes(config?) → { changes }
-- -----------------------------------------------------------------------------
local function op_changes(data)
	local config = data.config
	local ok, ch = pcall(cursor.changes, cursor, config)
	if ok and type(ch) == "table" then
		return { changes = ch }
	end
	return { changes = {} }
end

-- -----------------------------------------------------------------------------
-- commit(config?) → {}
-- -----------------------------------------------------------------------------
local function op_commit(data)
	pcall(cursor.commit, cursor, data.config)
	return {}
end

-- -----------------------------------------------------------------------------
-- revert(config?) → {}
-- -----------------------------------------------------------------------------
local function op_revert(data)
	pcall(cursor.revert, cursor, data.config)
	return {}
end

-- -----------------------------------------------------------------------------
-- apply(rollback?) → {} （P4 阶段：apply 语义简化，仅 commit 所有变更）
-- -----------------------------------------------------------------------------
local function op_apply(data)
	pcall(cursor.commit, cursor)
	return {}
end

-- -----------------------------------------------------------------------------
-- confirm(token) / rollback(token) → {} （P4 阶段：无事务 rollback 队列，空操作）
-- -----------------------------------------------------------------------------
local function op_confirm(data)
	return {}
end

local function op_rollback(data)
	return {}
end

-- -----------------------------------------------------------------------------
-- 方法分发表
-- -----------------------------------------------------------------------------
local M = {
	get      = op_get,
	add      = op_add,
	set      = op_set,
	delete   = op_delete,
	order    = op_order,
	changes  = op_changes,
	commit   = op_commit,
	revert   = op_revert,
	apply    = op_apply,
	confirm  = op_confirm,
	rollback = op_rollback,
	state    = op_get,   -- state 与 get 同源（rpcd uci.c 也走 getcommon）
}

return M
