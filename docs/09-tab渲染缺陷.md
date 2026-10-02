# 09 · CBI tab 渲染缺陷（Plugin Settings 全空 / 重复串页）

> 状态：**已修复**（方案 B，commit 1f4a07f，2026-10-02）
> 日期：2026-10-02
> 真机：Debian 12 @ 172.20.0.101:9080（openclash-rt 0.47.156+ocrt1）
> 对照：ImmortalWrt 24.10 @ 172.20.0.2（root/DAM%ms7f）

## 1. 现象

| 页面 | OpenWrt | Debian（缺陷态） |
|---|---|---|
| Plugin Settings | 15 个 tab / 279 控件 / 110 label | **0 tab / 1 控件 / 0 label** |
| Overwrite Settings | 10 个 tab / 535 控件 | 0 tab / 2 控件 |
| Config Subscribe | 23 控件 | 9 控件（正常，它用 Table section） |
| Config Manage | 正常 | 24 控件（正常） |
| Server Logs | 正常 | 正常 |

「Overwrite Settings 里有 Plugin Settings 的设置、重复 5 遍」是**我引入的次生缺陷**（见 §4）。

## 2. 根因（三环，逐环验证）

### 环 1：`s:tab()` 调用成功，数据是对的
`openclash/settings.lua:65` `s = m:section(TypedSection, "openclash")`
→ `s` 是 `AbstractSection`，它**有** tab/taboption/render_tab
（cbi.lua:931 / 963 / 969）。
所以 `s:tab(...)` 15 次全部成功，`s:taboption(...)` 也正常挂进
`s.tabs[tab].childs`。

### 环 2：taboption 把选项**同时**放进两处
`cbi.lua:963` `AbstractSection.taboption`：
```lua
local l = self.tabs[tab].childs
local o = AbstractSection.option(self, ...)   -- 内部 self:append(obj)
if o then l[#l+1] = o end
```
`option()` 里的 `self:append(obj)` 把选项塞进 `self.children`。
**同一个选项既在 `tabs[tab].childs` 又在 `self.children`。**

### 环 3：`tsection.htm` 的循环体依赖 `cfgsections()`，它返回空
渲染链：`map.htm` → `render_children` → `section:render()`
→ `cbi/tsection` → `for i, k in ipairs(self:cfgsections())` → `<%+cbi/ucisection%>`
→ `ucisection.htm:13` `if self.tabs then <%+cbi/tabcontainer%>`。

而 `TypedSection.cfgsections`（cbi.lua:1148）：
```lua
self.map.uci:foreach(self.map.config, self.sectiontype,
  function (section)
    if self:checkscope(section[".name"]) then ... end
  end)
```
实测**探针打点 0 条** → `cfgsections()` 未被调用；
页面里 `cbi-section-node` 0 个、`This section contains no values yet` 2 个
→ `tsection` 的循环体一次都没进。

**结论**：21.02 世代的 `cbi.lua` 与 `tsection.htm` / `ucisection.htm`
**不配版**——`tabcontainer` 支持在模板侧有（`ucisection.htm:13`），
但 `cfgsections()` 这条路在匿名 TypedSection 上走不通。

对照：为什么 `config` 页正常？它用 **`m:section(Table, tab)`**
（`config.lua:351`）→ 走 `tblsection.htm`，不依赖 `cfgsections()`。

## 3. 为什么 `map.htm` 的 `self.tabbed` 是错的

`view/cbi/map.htm:13` 判断 `<% if self.tabbed then %>`，
而 **`self.tabbed` 在整个 cbi.lua 里从未被赋值**（全文件仅 1 处注释提到）。
21.02 的 cbi.lua 没有这个标记 → 恒 false → 永远走 else 的 `render_children`。

新版 LuCI 的 `Map.tabbed` 由 `Map:section()` 在检测到 section 带 tabs 时置位。

## 4. 我引入的次生缺陷（已回滚）

为修 §3 我在 Map 层加了 `Map.has_tabs()` + `Map.render_tabcontainer()`，
让 `map.htm` 渲一次 tab。结果：
- settings 的 15 个 tab 各输出 **15 份**（225 个 `data-tab`）
- overwrite 的 5 个各 **5 份**
- **Plugin Settings 的表单串进了 Overwrite Settings 页面**

原因：Map 层渲一次 → section 的 `ucisection` 再渲一次 → 双份。
（`taboption` 环 2 的「同选项挂两处」正是这个double render 的前提。）

**已 `git checkout c33a82e --` 回滚 vendor 到干净基线。**

### 4.1 过程中我犯的三个错误（留档）
1. **在真机上反复直接改文件**，导致仓库与真机代码漂移 several轮，
   有一次把带探针的旧版当新装上去，验证结果全部无效。
   → 教训：真机验证必须「从仓库单一来源部署 + md5 校验」。
2. **用 SSH 直跑 `./luci` 做探针**。实测该路径只输出 1704 字节且报
   `boardinfo` nil 错误，与HTTP 走宿主的路径（5MB）**不是同一条**。
   → 教训：CGI 探针必须走 HTTP 宿主，且输出要进 `luci.write` 通道
   （`io.open('/tmp/...')` 在 fork 出的 CGI 里写不到）。
3. **在模板注释里嵌套 `<% %>` 并含 `--`** → 报
   `map.htm:13: unexpected symbol near '-'`（500）。
   → 教训：LuCI 模板注释块内不要放模板定界符，注释用 HTML `<!-- -->`。

## 5. 方案实施结果

### 方案 A：给 `TypedSection.cfgsections` 补匿名段支持 —❌ 已试，无效
补了匿名段返回后，页面字节数**完全不变**（24049B），探针确认
`cfgsections` / `tsection` / `Node.render` 都没被调用 ——
CBI 渲染根本没走我以为的那条链。**已回滚。**

### 方案 B：给 `tsection.htm` 加 tabbed 兜底分支 — ✅ **生效，采用**
见下方「§7 已实施的修复」。

### 未采用的两个
`s.anonymous = true` 时，`cfgsections()` 应直接返回 `{"cfg"}`（匿名段
在 uci 里的键是 sectiontype 本身），而不是走 `uci:foreach` 筛选。
改 1 处，风险最低，且不新增 Map 层逻辑。

### 方案 B：给 `tsection.htm` 加 tabbed 分支
在 `cfgsections()` 为空但 `self.tabs` 存在时，直接用 `tab_names` 构造
section 列表并 include `tabcontainer`。改 1 个模板，但语义上与上游
新版不一致。

### 方案 C：升级 vendor LuCI 到支持 tab 的版本（如 22.03/23.05）
一次性解决配版问题，但改动面大，可能引入其它不兼容
（我们已按openwrt-21.02 pin 了 `luci-base` 的其它行为）。

## 6. 回归判据

修好后必须同时满足（服务端 curl 即可判定，不必开浏览器）：

| 判据 | 命令 |
|---|---|
| 无重复 | `grep -o 'data-tab-title="[^"]*"' \| sort -u \| wc -l`等于 `grep -o 'data-tab-title=' \| wc -l` |
| 无串页 | settings 页 HTML 里不含 Overwrite 页特征串（如 `Overwrite Module`），反之亦然 |
| tab 数正确 | settings = 15，overwrite = 5 |
| 控件非空 | settings 控件数 > 200（OpenWrt 侧 279） |
| 无 500 | 响应无 `500 Internal Server Error`，无 `Failed to execute template` |
| 其余页不回归 | config-subscribe / config / log 的体积与基线相差 < 20% |

---

## 9. 追加：Add 按钮失效（同源缺陷，2026-10-02 20:00-20:30）

用户反馈：多个页面的 Add 按钮点了没反应。

| 页面 | 区块 |
|---|---|
| Plugin Settings | Lan Traffic Access List |
| Overwrite Settings | Add Custom DNS Servers / Set Authentication of SOCKS5/HTTP(S) |
| Config Subscribe | Config Subscribe Edit |

### 已确认的事实（浏览器双机对照实测）

1. **两侧 DOM 完全一致** —— 按钮都是 `disabled=False`、`visible=True`，
   `name` 也相同（如 `cbi.cts.openclash.lan_ac_traffic.`）。OpenWrt 侧同样
   没有段名输入框。
2. **点击确实发出了 POST** —— 实测每次点击产生 2 个请求
   （页面 POST + `admin/ubus`）。
3. **提交后段数不变** —— 服务端 `uci show openclash | grep -c '=lan_ac_traffic$'`
   前后都是 0。
4. **带上 CSRF token 后服务端返回 302**（LuCI 提交后的正常重定向），
   说明 CBI 提交链路本身是通的 —— 但仍未创建段。

### 关键线索：上游自带的 tblsection 覆盖模板

`grep -rl tagname /usr/share/lua/5.1/luci/` 命中三处，其中
**`view/openclash/tblsection.htm`**（被 `config-overwrite.lua:525`
`ds.template = "openclash/tblsection"` 引用）第 445 行有：

```html
<input type="hidden" name="cbi.cts.tagname.<config>.<sectiontype>" value="" />
```

并由页内 JS 把当前 tab 名写进去（供「按 tab 分组新增」用）。于是提交时表单
里同时有两个字段：

```
cbi.cts.openclash.dns_servers.        = "Add"   ← 真正的按钮
cbi.cts.tagname.openclash.dns_servers  = ""      ← 隐藏占位
```

而 **21.02 的 `luci.http.formvaluetable(prefix)` 是前缀匹配**
（`http.lua:62`：`if k:find(prefix, 1, true) == 1`），传
`crval = "cbi.cts.openclash.dns_servers"` 会把 `cbi.cts.tagname.*` 也收进来。
`pairs` 遍历顺序不确定，`next()` 可能先取到 tagname 那个**空串** →
`name=""` → 匿名段 `create(nil, "")` / 具名段 `checkscope("")` 判空 → 失败。

**上游 OpenWrt 24.10 的 cbi.lua 认识 tagname**（会优先取它并按 tab 分组），
所以那边正常。我们 vendor 的 21.02 没有这段逻辑。

### 已实施的修复（cbi.lua 的 TypedSection.parse Create分支）

不取 `next(formvaluetable(crval))`，改为**只认精确等于 `crval .. "."` 的键**
（就是 Add 按钮本身），忽略 tagname 这类同前缀辅助字段；匿名段只要收到
Add 表单就 `create(nil, origin)`，不要求 name。

### 未解决 / 待续

修复装上后，浏览器真实点击**仍未生效**（0/4 生效），探针显示
`AbstractSection.create` 未被调用，且 `Map.parse` / `_cbi` 层的探针也未命中
—— 即 CBI 提交链路在某个更早的环节就没走到 `TypedSection.parse`。

**已排除**：CSRF token（带 token 后返回 302 而非 403）、token 前缀污染
（已改为精确匹配）、`Map.parse` 早退分支。

**下一步怀疑点**：`config-overwrite.lua:525` 把 `ds.template` 改成了
`openclash/tblsection`，这可能让 `ds` 走了与 `TypedSection.parse` 不同的
代码路径（上游模板可能自带 form 提交逻辑而不依赖 cbi.lua 的 create）。
需要读 `view/openclash/tblsection.htm` 全文确认它的 Add 是走
`cbi.cts.*` 表单还是自定义 JS。

> 教训（同 tab 渲染那次）：真机反复试改 + 多轮探针效率极低。应先
> 完整读完 `view/openclash/tblsection.htm`（约 450 行）再建假设。

---

## 10. Add 按钮失效 —— 诊断结论（2026-10-02 20:00-20:50）

### 实测结果：4 个 Add 里2 个好、2 个失效

| 页面 / 区块 | section | 模板 | 自带 create | 结果 |
|---|---|---|---|---|
| Overwrite / Add Custom DNS Servers | `dns_servers` | `openclash/tblsection` | ✅ | **302 跳转，正常** |
| Config Subscribe / Edit | `config_subscribe` | `cbi/tblsection` | ✅ | **302 跳转，正常** |
| Plugin Settings / Lan Traffic Access List | `lan_ac_traffic` | `cbi/tblsection` | ❌ | 200 无反应 |
| Overwrite / Set Authentication | `authentication` | `cbi/tblsection` | ❌ | 200 无反应 |

### 已排除的原因

- **两侧 DOM 完全一致**（按钮 `disabled=False`、`name` 相同，OpenWrt侧同样无段名输入框）
- **点击确实 POST 了**（每次点击 2 个请求）
- **CSRF token 正常**（带正确 token → 200；不带 → 403 "Form token mismatch"）
- **`cbi.cts.tagname.*`前缀污染**：21.02 的 `formvaluetable` 是前缀匹配，
  会把 tagname 那个空串收进Create 分支的 `name` —— 这是真问题，
  但**不是本次失效的主因**（修掉它两个失效项仍 200）
- **补 `create` 到 vendor 层**：`Map.prepare` 里给
  「addremove + anonymous + create 仍是继承来的」装默认 create，
  实测**仍未生效**（见下方踩坑）

### 关键对照实验（证明了根因）

手工给 `authentication`（**改上游 model 文件**）补：

```lua
s.create = function(self, section)
    local sid = TypedSection.create(self, section)
    if sid then HTTP.redirect(... sid) end
    return sid
end
```

→ 立刻 **302 成功**，新段 `cfg28b425` 出现。

所以根因确定：**这两个 section 缺 create 覆盖，段建出来后没人 redirect /
重新渲染，用户看不到 → 表现为「点了没反应」。**

### 未完成的修复（已回滚，不留未验证代码）

尝试在 vendor 兼容层补默认 create，**两次都失败**：

1. 放在 `cbi.load` 的 `map:prepare()` 调用点 → 那里section 属性尚未
   全部赋值，条件判断漏。
2. 改到 `Map.prepare` → **但定义在第 266 行，而 `Map = class(Node)`
   在第 320 行**。LuCI 的 `class()` 实现是把父类方法拷进子类表，
   所以我的 `Map.prepare` 在 class() 执行**之前**就被 `Node.prepare`
   覆盖了 → `Map.prepare` 从未被调用（探针 0输出证实）。
   移到第 497 行（class 之后）后实测**仍是 200 无反应**。

第二次失败的原因尚未查清（探针显示 `Map.prepare` 这次被调用了，
但两个失效 section 仍没走 create 分支）。**已 `git checkout` 回滚
`cbi.lua` 到 HEAD，真机同步回滚并md5 校验通过，不留未验证代码。**

### 下一步建议

1. 先在真机上用最简实验确认「`Map.prepare` 被调用时，
   `sec.create == AbstractSection.create` 这个判据是否成立」
   （可能是 class() 拷贝时把 create 也拷成了别的形态）；
2. 或走另一条更直接的路：让 `tblsection.htm` 在渲染 Add 区块时，
   无论有没有 create 覆盖都输出一个指向自身的 hidden 字段，
   由兼容层的 parse 逻辑识别并 redirect。

> 教训（第二次犯）：真机反复试改 + 多轮探针效率极低。应在动手前
> 先用「一次只改一个变量」的受控实验定位，且每轮都保留可回滚的基线。
