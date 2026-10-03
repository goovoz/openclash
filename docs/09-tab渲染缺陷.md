# 09 · CBI tab 渲染缺陷（Plugin Settings 全空 / 重复串页）

> 状态：**已修复**（方案 B，commit 1f4a07f，2026-10-02）
> 日期：2026-10-02
> 真机：Debian 12 @ 172.20.0.101:9080（openclash-rt 0.47.156+ocrt1）
> 对照：ImmortalWrt 24.10 @ 172.20.0.2（凭据走环境变量 `OCRT_OPENWRT_PWD`，
> 见 `scripts/_deploy/credentials.py` —— **不要在仓库里写明文口令**）

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

---

## §12 Add 按钮根因（2026-10-02 定案，commit `49adbf4`）

前面 §10/§11 的诊断方向全部错了：问题既不在 `cfgsections`，也不在
`Map.prepare` / `create` 绑定，更不在浏览器传参。**真正的原因在自研的
进程内 ubus uci 对象里。**

### 12.1 决定性对照实验

同一个按钮、同一个 POST、同样返回 `200` + `X-CBI-State: 0`
（`FORM_PROCEED`，说明 create 已成功），但点完之后：

| 机器 | 新段是否出现在页面 |
|------|------------------|
| ImmortalWrt 172.20.0.2 | `cfg2a8d41` **可见** |
| openclash-rt .101（修复前） | **无** |
| openclash-rt .101（修复后） | `cfg298d41` **可见** |

判据：`HTML` 里 `cbid.openclash.<段名>.` 出现的新段名
（必须排除主 section `openclash` 本身，它的选项名是
`auto_restart` 之类，会造成假阳性 —— 第一次写判据时踩过）。

### 12.2 根因

`runtime/sys/luci-uci.lua` 的 `op_get` 在返回 section 时执行：

```lua
if not k:match("^%.") then clean[k] = v end   -- 剥掉所有元字段
```

于是 libuci 的 `.name` / `.type` / `.anonymous` / `.index` 全部消失。
而遍历链**恰恰靠这些字段工作**：

```
luci.model.uci.foreach   (model/uci.lua:245)
    section[".index"]  -> 排序
    callback(section)  -> 回调拿到 section 表
TypedSection.cfgsections (cbi.lua:1268)
    if self:checkscope(section[".name"]) then
        table.insert(sections, section[".name"])
```

元字段被剥 → `section[".name"]` 恒为 nil → `checkscope(nil)` 不通过
→ 段被静默过滤 → `cfgsections()` 返回空表 → 页面不渲染新段。

**段其实建出来了**（uci delta 里有），只是渲染阶段遍历不到。
这就是这个 bug 难定位的原因：服务端日志、HTTP 状态、CSRF 全部正常。

### 12.3 修法

1. `op_get` 原样返回 section（含元字段），对齐 rpcd `uci.c`
   的 `rpc_uci_getcommon` 语义。
2. `op_get` 补`type` 过滤参数（`foreach` 会传 `{config=..., type=stype}`，
   原实现忽略）。

### 12.4 为什么不是「段没落盘」

一开始怀疑过「Add 后段没写进 `/etc/config`」。实测**两台机器都是 0 段**
—— 这是上游 LuCI 的正常设计：Add 只创建 uci delta，还需再点页面上的
「保存 & 应用」才 commit。`Map.parse` 的 commit 条件是
`(not self.proceed and self.flow.autoapply) or formvalue("cbi.apply")`，
Add 之后 `proceed = true` 且没提交 `cbi.apply`，所以不 commit ——
**与上游一致，不是缺陷**。

### 12.5 顺带修正 `Map.prepare`（cbi.lua）

前一版实现里create 调了 `luci.http.redirect()`。这会在
`Node.parse` 执行期间抛redirect，导致 `Map.parse` 后续的
`uci:save` / `uci:commit` **全部不执行** —— 实测返回
`302 Location=...#lan_ac_traffic` 但段数 `0 -> 0`。

> **通则**：任何在 `create` 内部调`luci.http.redirect` 的写法都会
> 打断 commit。段要落盘就不能在 create 里跳转。

现改为纯绑定 `AbstractSection.create`，不做任何跳转，
与上游（匿名段 Add 后原地重渲染）行为一致。

### 12.6 本轮踩到的三个坑

1. **`class()` 不是拷贝父类方法。** `luci-lib-base/luasrc/util.lua:80`
   是 `setmetatable({}, {__call=_instantiate, __index=base})`，
   实例元表是 `{__index=class}` —— 纯委托。§11 里「class() 会拷贝方法、
   定义在前面会被覆盖」的判断是错的。（位置约束仍然成立，但理由不同：
   `Map.prepare` 必须定义在 `Map = class(Node)` 之后才能不被
   `Node.prepare` 遮蔽。）

2. **宿主是常驻进程，改文件必须重启才生效。**
   9080 端口是 `/usr/lib/openclash-rt/luci-host.lua`（systemd
   `openclash-rt-luci-host.service`），它在启动时就 `require` 了
   `luci.cbi` 等模块。改完直接测，测的是内存里的旧代码 ——
   白测好几轮。**每次改 vendor/runtime 后必须
   `systemctl restart openclash-rt-luci-host.service`。**

3. **`luci.syslog` 在本机不可用作探针通道。** journald 没在写盘
   （`journalctl` 报 `No journal files were found`），探针输出全部丢失。
   同理 `io.open('/tmp/x','a')` 也无效 —— unit 里有 `PrivateTmp=true`，
   CGI 在私有 `/tmp` 里，外部看不到。**要验证 CGI 内部行为，
   唯一可靠的通道是 HTTP 响应本身**（状态码 / `Location` /
   `X-CBI-State` / 正文内容）。

   > 反例记录：曾在 `dispatcher.lua` 里插 `io.open("/tmp/probe.log","a")`
   > 探针，且 Lua 源码里的 `"\n"` 被写成了**真实换行**，把字符串切断，
   > 导致 `dispatcher.lua:1378 unfinished string near '"'` ——
   > 整个 LuCI 挂掉（页面全部 200 但 Content-Length: 0）。
   > 这个损坏潜伏了多轮才被发现。**插探针后必须 `luac -p` 验语法。**

### 12.7 排查方法论修正

本轮定位靠的是「**双机同按钮对照 + 精确判据**」，而不是在真机上反复试改：

- 先在ImmortalWrt 上确认「正确行为是什么」（新段立即可见）；
- 再用最小 POST（只有 token + submit + 一个 `cts` 字段）直连服务端，
  把「浏览器/宿主传参」与「cbi.lua 服务端逻辑」彻底分开；
- 判据必须精确 —— 第一次用 `cbid.openclash.*` 通配导致主 section 的
  选项名被误认为新段，差点得出「两台一致、无bug」的错误结论。

工具：`scripts/_deploy/deploy-file.py`（部署 + 远端语法检查，
注意 Git Bash 会把命令行里 `/` 开头的路径改写成 Windows 路径，
需用无前导斜杠写法或 base64 传脚本）、`ui-probe-add-post.py`、
`ui-probe-compare-add-visual.py`、`probe-add-server.py`。

---

## §13 Add 修复部署后引出的二次回归（commit `3c6c9fc`）

把 `49adbf4`（op_get 保留元字段）打进 deb 装到真机后，**五页回归从 5/5
掉到 3/5** —— Plugin Settings / Overwrite Settings 双双 500：

```
map.htm:1: attempt to call method 'render_tabcontainer' (a nil value)
```

### 13.1 根因 1：`render_tabcontainer` 不是死代码

`1f4a07f`（修tab 渲染）把它当 `2032cf4` 遗留死代码删掉了。判断依据是
「cbi.lua 里已无调用者」—— **错在只搜了 .lua，没搜模板**：

```
vendor/luci/luci-compat/luasrc/view/cbi/map.htm:13
    <% self:render_tabcontainer("m") %>
```

> **通则：vendor 层删除任何函数前，必须全仓搜 `.htm`（以及 `.cgi`、
> `.sh`、`.js`）—— LuCI 大量用模板驱动，调用者常在模板里。**

恢复后又暴露第二个问题：该函数内部用 `luci.write`，而 `luci.write`
是 `luci.http` 挂上去的（`http.lua:199`），cbi.lua 顶部没有 require
它-> nil。改为函数内 `local http = require "luci.http"` 取本地 write。

### 13.2 根因 2：`map.htm` 的 if/else 把无 tab 的 section 全部丢掉

`map.htm` 是二选一：

```lua
<% if self:has_tabs() then %>
    <% self:render_tabcontainer("m") %>
<% else %>
    <%- self:render_children() %>
<% end %>
```

而 `render_tabcontainer` 只遍历**有 tabs 的** child
（`if section:has_tabs()`）。于是：

> 页面上只要存在**任意一个** tab section，`has_tabs()` 就为真
> -> 走 tab 分支 -> **所有无 tab 的 child 一个都不渲染**。

症状极其隐蔽：页面 200、tab 数正确（15/15 / 5/5），但页面里
`lan_ac_traffic` 出现 **0 次**，`cbi.cts.*` / `cbi.rts.*` 字段一个
都没有 —— 连 Add 按钮都不存在。受影响的 section：

| 文件:行 | section |
|---------|---------|
| `settings.lua:278` | Lan Traffic Access List |
| `config-overwrite.lua:582` | Set Authentication |
| `config-subscribe.lua` | Config Subscribe |

之前一直没暴露，是因为用的还是 `else` 分支的 `render_children`。
后来为修「tab 全空」引入 `has_tabs` / `render_tabcontainer`，把 `else`
变成了 `if` 的互补分支 —— 副作用就是丢掉了无 tab 的 section。

修法：新增 `Map.render_children_notabbed`，只渲染无 tab 的 child。

**不能用 `render_children`**：它遍历全部 children，会把带 tab 的
section 在 tabcontainer 里已渲染过的内容再来一遍 -> N×N 重复。
`last_child` / `index` 用「已见数量」而非 `#self.children`，因为
渲染的是子集。

### 13.3 验证结果

五页 5/5；Plugin Settings **354307B / 15 tab / 145 控件**
（历史最高；`49adbf4` 之前是 81426B）。

Add 四用例全部生效，新段名与 ImmortalWrt 一致：

```
Lan Traffic Access List   段 1 -> 2新段 cfg2a8d41
Set Authentication        段 39 -> 3    新段 cfg2ab425
Add Custom DNS Servers    302 -> custom-dns-edit/cfg2a6193
Config Subscribe Edit     302 -> config-subscribe-edit/cfg2ab6bc
```

### 13.4 一个把我带偏两次的探针陷阱

**不能用最小 POST**（只发 `token + cbi.submit + cbi.cts.*`）来验证Add：

```
X-CBI-State: -1        （FORM_INVALID）
```

页面上所有 option 的 formvalue 都是 nil，其中 required / 带 validate
的 option 校验失败 -> `AbstractValue.parse` 的 tag_error 分支把
`map.save` 打成 false -> `Map.parse` 开头就`return self:state_handler(...)`
-> `Node.parse` 根本不执行 -> create 永远不会被调用。

真实浏览器点 Add 会提交表单里**全部成功控件**，所以不会触发。

> 我用最小 POST 连着两次得出「Add 又坏了」的结论，都是探针的问题。
> 正确做法：`curl-add-full.sh` + `form-fields.py` 回填全部控件。
>
> 附带：`X-CBI-State` 的取值语义（cbi.lua 19-25 行）
> `4=SKIP 2=CHANGED 1=VALID 0=PROCEED/NODATA -1=INVALID`，
> **0 也是成功**（create 成功 -> proceed），别误判成失败。

### 13.5 本轮环境侧的两个坑

1. **`dpkg -i` 被 conffile 提示卡死**：`/etc/config/system` 已在
   `conffiles` 里，必须 `dpkg --force-confold -i`（`-o` 是 apt 的选项，
   dpkg 不认）。

2. **Git Bash 会把命令行里以 `/` 开头的路径改写成 Windows 路径**，
   包括传给 Python 的 argv。`deploy-file.py put` 的 remote 参数因此
   要求写成不带前导斜杠的 `usr/lib/lua/luci/cbi.lua`。

---

## §14 整页配置存不进去 + 内核启动失败（2026-10-03，commit `416ef35`）

用户反馈三件事：内核启动失败、Overwrite Settings 的 Bind Network Interface
存不进 eth0、页面加载很慢。前两个**同一个根因**。

### 14.1 根因：`render_tabcontainer` 把 prefix 当成了段名

`Map.render_tabcontainer` 里写的是：

```lua
section:render_tab(tab, prefix or "m")     -- ← prefix是容器 id 用的
```

`prefix` 来自 `map.htm` 的 `self:render_tabcontainer("m")`，本意只是给
容器 div 的 id 用的。但它被当作**段名**一路传下去：

```
render_tab(tab, sid) -> node:render(..., scope)
                     -> AbstractValue.cbid(sid)
                     -> "cbid." .. config .. "." .. sid .. "." .. option
```

于是页面上所有字段的 name 都变成 `cbid.openclash.m.<option>`，
而这些 option 挂的是主 section，真实段名是 `config`。

后果链条：

```
name 前缀错 -> 服务端 formvaluetable("cbid.openclash.config") 取不到
            -> fvalue = nil
            -> required / 带 validate 的 option 校验失败
            -> AbstractValue.add_error 把 map.save = false
            -> Map.parse 返回 FORM_INVALID(-1)
            -> **整页保存失败**
```

### 14.2 决定性对照证据

同一份 model、同一份 uci（主 section 段名都是 `config`）：

| | 页面上 name 前缀 | X-CBI-State | interface_name 落盘 |
|---|---|---|---|
| ImmortalWrt 172.20.0.2 | `cbid.openclash.config.*` | **1** | 是 |
| openclash-rt .101（修复前） | `cbid.openclash.m.*` | **-1** | **否** |
| openclash-rt .101（修复后） | `cbid.openclash.config.*` | **2** | 是 |

修复前 `/etc/config/openclash` 里**连 `option interface_name` 这一行都没有**
（model 里它有 `o.default = "0"`，本该落盘）。

### 14.3 为什么也导致内核启动失败

`log_level` 同样没落盘 -> `uci get` 返回空 -> `yml_change.sh` 生成
`log-level: ''` -> mihomo 拒绝空值：

```
level=fatal msg="Parse config error: invalid log-level"
```

日志里连续 5 次（09:10~09:12），每次间隔约 20~40 秒（守护重启）。
**表面看是"内核起不来"，实际是 Overwrite Settings 整页没保存。**

### 14.4 修法

```lua
local sid
local ok, secs = pcall(function() return section:cfgsections() end)
if ok and type(secs) == "table" and #secs > 0 then
    sid = secs[1]                          -- 真实段名（具名段）
else
    sid = section.sectiontype or "cfg"     -- 匿名段占位名
end
section:render_tab(tab, sid)
```

匿名段（`dns_servers` 等）没有真实段名，退回 sectiontype 正确——
它们在页面上显示的是 uci 生成的 `cfgXXXXXX`，实测一致。

### 14.5 验证

- 五页 5/5；各页 cbid 前缀与 OpenWrt 一致（`config` / `cfgXXXXXX`）
- Add 四用例仍全部生效
- Bind Network Interface 选 eth0 -> Commit Settings ->
  `uci get openclash.config.interface_name` = `eth0`
- 内核：`OpenClash Start Successful!`，`log-level: info`，
  进程 `clash` 监听 7893 / 7874 / 9090

### 14.6 「页面加载慢」不是缺陷

各页**服务端本机**耗时（3 次平均）：

```
client             0.167s    525KB
config             0.186s    1.14MB
settings           0.105s
config-overwrite   0.106s
log                0.036s
config-subscribe   0.040s
```

静态资源 < 3ms，ping 0ms。慢的是 Overviews（client）页面的
**25 个 XHR**，其中 `myip_check` 稳定占 **10.8 秒**。

`myip_check` 是上游的「多服务并行查出口 IP」实现
（`openclash.lua` 的 `MAX_CONCURRENT = 3`，每个 `curl -m 10`）。
本机实测 `whois.pconline.com.cn` 超时（rc=28，等满 10 秒），
其余 5 个服务都正常。**这是上游设计行为，与内核是否运行无关**
（内核启动前后都是 10.8s），不属本项目缺陷。

页面实际可用时间 = `DOMContentLoaded` 0.34s；
Playwright 的 `networkidle` 要等所有 XHR（含 myip_check）才报，
所以自动化里看到 17~28s，**人眼感知的前端可用时间不到 1 秒**。

### 14.7 本轮的方法论教训

1. **UI 上「控件能显示、能选中」不等于「能提交」。** 判据必须看
   POST body 的字段 name 与服务端 `X-CBI-State`，而不是看页面元素存在。
2. **`-1`（FORM_INVALID）几乎总是 required 校验失败**，而失败原因
   LuCI 不输出。三种探针通道全部失效：
   - `luci.syslog`：journald 未落盘
   - `io.open('/tmp')`：unit 有 `PrivateTmp=true`
   - `luci.write` / `http.header` / `error()`：在 `Map.parse` 阶段
     缓冲未启用 / 被宿主过滤

   **唯一可靠的定位手段是「双机同条件对照」**：把同一份 model、同一份
   uci 在ImmortalWrt 与本机各跑一遍，比对 POST body 的字段前缀。
   本轮前期在探针上花了十几轮，真正定位靠的就是这一步。
3. **改完 vendor 必须重启宿主**（`systemctl restart
   openclash-rt-luci-host.service`）。有一次诊断补丁的 `error()`
   没重启，页面直接 500，误以为「诊断没输出」，白绕了几轮。
