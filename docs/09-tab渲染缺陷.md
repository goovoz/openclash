# 09 · CBI tab 渲染缺陷（Plugin Settings 全空 / 重复串页）

> 状态：根因已定位，修复方案待实施
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

## 5. 待实施方案（三个选项）

### 方案 A：给 `TypedSection.cfgsections` 补匿名段支持（最小改动，推荐）
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
