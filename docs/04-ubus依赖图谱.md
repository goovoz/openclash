# 04 · ubus 依赖图谱：为什么 ubus 是 P1 前置而不是收尾

> **状态**：本轮新发现，**改写了排期**。原计划把 ubus 放在 P4（收尾），本文证明它是
> **P1 的前置**——没有 `ubus.so`，LuCI 一行代码都加载不了。
>
> **证据口径**：每条结论都标注 `文件:行号`。所有路径相对于仓库根。
> 复现命令见 §7。
>
> 阅读顺序：先看 §1（一句话结论），§2（三个致命依赖），§4（可省清单及理由）。
> 排期影响见 §6。
>
> ⚠️ **§2.3 已更正一次**：初版结论是「依赖 `/usr/bin/lua` 存在即可」，实测发现
> Debian 的 `/usr/bin/lua` 会被优先级更高的 `lua5.4` 劫持（update-alternatives
> 组 `lua-interpreter`），故改为**把 11 处全部改写成绝对路径 `/usr/bin/lua5.1`**。
> 现在 §2.3 实际上是**两个**致命依赖：`ubus.so`（§2.1）与「lua 解释器版本」（§2.3），
> 二者都会以「模块加载失败」的形式暴露，极难区分，所以都必须在源头消除。

---

## 1. 结论

| 项 | 判定 | 证据 |
|---|---|---|
| `libubus-lua`（`ubus.so`） | **硬依赖，加载期就必需** | `vendor/luci/luci-lib-base/luasrc/util.lua:15` |
| `ubusd`（守护进程） | **硬依赖** | 同上，`_ubus.connect()` 在首次 ubus 调用时执行 |
| `rpcd`（内置 `session` + `uci` 对象） | **硬依赖** | `vendor/luci/luci-base/Makefile:15` + OpenWrt 官方文档 |
| Lua 5.1 解释器（**必须走绝对路径 `/usr/bin/lua5.1`**） | **硬依赖** | 上游 11 处依赖它；`/usr/bin/lua` 会被 lua5.4 劫持，故不能用（§2.3） |
| `rpcd-mod-luci`（`/usr/lib/rpcd/luci.so`） | **暂不构建**（见 §4.4） | 需要额外 vendor `openwrt/iwinfo` |
| `cgi-io` | **可省** | 上游 OpenClash 零引用（§4.1） |
| `rpcd-mod-file` | **可省** | 只被 cgi-io 用（§4.1） |
| `rpcd-mod-rrdns` | **可省** | 唯一调用点会自动退化（§4.2） |
| netifd / `network` ubus 对象 | **可省** | `luci.model.network` 走内核 `getifaddrs(3)`，不走 ubus（§4.3） |

**排期净影响**：P1 之后新增一个 **P1.5「ubus 底座」**，内容是三个上游 C 组件
（`ubus` / `rpcd` / `rpcd-mod-luci`）的 Debian 构建与 systemd 化。

**同时排除了三个原以为躲不掉的大工程**：netifd、cgi-io、rpcd 插件生态。

---

## 2. 三个致命依赖

### 2.1 `luci.util` 在**加载期**就要 `ubus.so`

`vendor/luci/luci-lib-base/luasrc/util.lua:15`：

```lua
local _ubus = require "ubus"
```

这一句在**模块顶层**，无条件、无 `pcall` 保护。而 `luci.util` 是被 require 次数
最多的模块——`luci.base`、`luci.model.*`、`luci.cbi`、`luci.dispatcher` 全都依赖它。

于是：

```
require "luci.model.uci"
  └─ require "luci.util"          ← 这里
       └─ require "ubus"          ← 缺它就 "module 'ubus' not found"
```

**这不是「某个功能不可用」，而是整个前端 + 上游 8 个 CLI 脚本全部起不来。**
报错信息是 `module 'ubus' not found`，看不出跟「ubus 守护进程」有任何关系——
排障时极易往 Lua 搜索路径的方向查错（而我们刚好在 P1 建了搜索路径桥接，
会让这个误判更强烈）。

> 注意区分两个层次：
> - `require "ubus"` —— **加载期**，只要有 `ubus.so` 文件就行；
> - `_ubus.connect()` —— **调用期**，在 `util.ubus(...)` 里懒执行，需要 `ubusd` 在跑。
>
> 两者都要满足，但失败现象完全不同，排障时必须先分清是哪一种。

### 2.2 `luci-base` 的依赖声明

`vendor/luci/luci-base/Makefile:15`：

```
LUCI_DEPENDS:=+lua +luci-lib-nixio +luci-lib-ip +rpcd +libubus-lua \
              +luci-lib-jsonc +liblucihttp-lua +luci-lib-base \
              +rpcd-mod-file +rpcd-mod-luci +cgi-io
```

逐项对照我方进度：

| 上游依赖 | 我方状态 |
|---|---|
| `lua` | ✓ `Depends: lua5.1`（`packaging/debian/control`） |
| `luci-lib-nixio` | ✓ P1 已构建 `nixio.so` |
| `luci-lib-ip` | ✓ P1 已构建 `luci/ip.so` + `libnl-tiny.so.1` |
| `luci-lib-jsonc` | ✓ P1 已构建 `luci/jsonc.so` |
| `liblucihttp-lua` | ✓ P1 已构建 `lucihttp.so` |
| `luci-lib-base` | ✓ vendor 已拉取 |
| **`libubus-lua`** | ✗ **缺**（P1.5） |
| **`rpcd`** | ✗ **缺**（P1.5） |
| **`rpcd-mod-luci`** | ✗ **缺**（P1.5） |
| `rpcd-mod-file` | ⊘ 可省（§4.1） |
| `cgi-io` | ⊘ 可省（§4.1） |

### 2.3 上游 8 个 `.lua` 全部 `#!/usr/bin/lua`

`upstream/luci-app-openclash/root/usr/share/openclash/*.lua`：

| 文件 | shebang | `require` 面 |
|---|---|---|
| `openclash_version.lua` | `#!/usr/bin/lua` | `nixio`, `luci.model.uci` |
| `openclash_urlencode.lua` | `#!/usr/bin/lua` | `nixio`, `luci.util`, `luci.sys` |
| `openclash_get_network.lua` | `#!/usr/bin/lua` | `nixio`, `luci.util`, `luci.sys` |
| `openclash_debug_dns.lua` | `#!/usr/bin/lua` | `nixio`, `luci.util`, `luci.sys` |
| `openclash_debug_getcon.lua` | `#!/usr/bin/lua` | `nixio`, `luci.util`, `luci.sys` |
| `openclash_oix_checkin.lua` | `#!/usr/bin/lua` | `nixio`, `luci.util`, `luci.sys` |
| `openclash_streaming_unlock.lua` | `#!/usr/bin/lua` | `nixio`, `luci.util` |
| `openclash_sub_parser.lua` | `#!/usr/bin/lua` | （无） |

两种调用形态都存在，必须都覆盖：

```sh
# 形态 A：显式解释器（openclash_core.sh:57、openclash_update.sh:33）
lua /usr/share/openclash/openclash_version.lua "$github_address_mod"

# 形态 B：直接执行，靠 shebang（openclash.sh:37）
echo "$(/usr/share/openclash/openclash_urlencode.lua "$1")"
```

两条推论：

1. **必须有一个 Lua 5.1 解释器，并且上面每一处都必须解析到它。**
   Debian 的 `lua5.1` 包只装 **`/usr/bin/lua5.1`**（带版本号的那个名字）。
2. **搜索路径桥接必须对「裸 CLI `lua` 进程」生效**，不只是对 Web 宿主生效。
   这些脚本是从 `openclash_watchdog.sh`（cron）与 `openclash_core.sh` 里跑的。
   这正是 `runtime/lua/lua-path-bridge.sh` 把软链建在**编译期默认搜索路径**上
   （而不是靠环境变量注入）的原因——CLI 调用方不会帮我们设 `LUA_CPATH`。

#### ⚠️ 更正：原判「依赖 `/usr/bin/lua` 即可」是**错的**

初版这里写的是「`/usr/bin/lua` 必须存在且必须是 Lua 5.1」。实测发现这个前提
在 Debian 上**不可靠**：

| 事实 | 证据 |
|---|---|
| Debian 用 update-alternatives 的 **`lua-interpreter`** 组提供 `/usr/bin/lua` | `update-alternatives --config lua-interpreter` 实测输出 |
| 候选优先级：`lua5.1` = **110** < `lua5.2` = 120 ≈ `lua5.3` = 120 < `lua5.4` = **130** | 同上 |
| 于是**只要这台机器上装着 lua5.4**，`/usr/bin/lua` 就指向 **5.4** | 同上 |

后果不是"报错说找不到 lua"，而是更糟的一种：
我们为 5.1 编译的 `nixio.so` / `lucihttp.so` / `ubus.so` 在 **5.4** 下被加载，
以 `undefined symbol: lua_...` 或 ABI 不符的方式失败 ——
**症状与「搜索路径没桥接对」几乎一样（都是"加载失败"），根因却完全不同。**
两类故障必须在源头区分，不能留到排障时猜。

顺带一提，`/usr/bin/env lua` 这种写法（`vendor/luci/luci-base/root/usr/libexec/rpcd/luci`
就是）也走 `PATH`，会被同一个问题命中，而且比 `/usr/bin/lua` 更隐蔽。

#### 结论：改写绝对路径，而不是注册 alternatives

最终方案是把上面 11 处**全部改写成 `/usr/bin/lua5.1`**，工具是
`runtime/upstream/pin-lua-interpreter.sh`（打包期对 staging 副本定点改写，
`upstream/` 源树保持逐字节原样）。为什么不用 `update-alternatives`：

1. 注册 alternatives 会改动**全系统**的 `lua` 默认解释器，对用户不礼貌；
2. 更关键的是：该组若已被置为 **manual** 模式，新注册的高优先级候选
   **不会自动生效** —— 等于没有保证。绝对路径没有这个盲区；
3. 不碰系统既有的 alternatives 组，与 `lua5.1` 包互不干扰，卸载也无需回滚。

改写的**完备性**由该脚本自己守住（"改写规则窄 / 残留判据宽"）：已知形态自动
改写；一旦上游换成没测绘过的写法，它会**构建失败并打印 file:line**，而不是
打出一个"运行时按系统 lua 版本随机行为"的包。

11 处的穷尽清单（`grep` 可复现，见 §7）：

| 形态 | 处数 | 位置 |
|---|---|---|
| shebang `#!/usr/bin/lua` | 8 | 上表列出的 8 个 `.lua`（`openclash.sh:37` 靠它执行，故被此列覆盖） |
| 显式 `lua <绝对路径>` | 3 | `openclash_core.sh:57`、`openclash_update.sh:33`、`openclash_watchdog.sh:83` |

---

## 3. LuCI 核心的 ubus 调用面

以下是对 `vendor/luci/**/*.lua` 的全量扫描结果（`grep -rn 'ubus('`）。

| ubus 对象 | 调用点 | 提供方 | 我方判定 |
|---|---|---|---|
| `session` | `dispatcher.lua:533,534,550,562,1358`；`controller/admin/index.lua:12,72,191`；`model/uci.lua:137,186,207,220` | **rpcd 内置** | 必需 |
| `uci` | `model/uci.lua:41`（`get/set/add/delete/commit/...` 全部经此）；`model/uci.lua:181,202`（`confirm`/`rollback`） | **rpcd 内置** | 必需 |
| `network.rrdns` | `sys.lua:181` | `rpcd-mod-rrdns` | 可省（§4.2） |
| `network.*` | `model/network.lua:127,552,570,926,928...` | netifd | 可省（§4.3） |

而**上游 OpenClash 自己**的 require 面（`upstream/luci-app-openclash/luasrc`）：

| 模块 | 次数 | 备注 |
|---|---|---|
| `luci.http` | 17 | 纯 Lua ✓ |
| `luci.sys` | 16 | 纯 Lua + nixio ✓ |
| `luci.openclash` | 16 | 上游自带 ✓ |
| `luci.dispatcher` | 15 | 纯 Lua，但加载链经 `luci.util` → **要 ubus.so** |
| `nixio.fs` | 10 | ✓ |
| **`luci.model.uci`** | **9** | → `util.ubus("uci", ...)`，**要 rpcd** |
| `luci.util` | 8 | → **要 ubus.so** |
| `luci.jsonc` | 4 | ✓ |
| `luci.cbi.datatypes` | 3 | ✓ |
| `luci.model.network` | 1 | §4.3 证明其可省 |
| `luci.model.ipkg` | 1 | Debian 无 opkg/apk，P5 单独处理 |
| `luci.ltn12` | 1 | ✓ |

**上游从不直接调用 ubus**——它一律走 `luci.model.uci` / `luci.sys`。
所以 ubus 面完全由 LuCI 核心决定，可控。

---

## 4. 可省清单（逐项证据）

### 4.1 `cgi-io` 与 `rpcd-mod-file` —— 上游零引用

```
grep -rn 'cgi-io\|cgi_io\|luci-upload\|/cgi-bin/' upstream/luci-app-openclash
  --include='*.lua' --include='*.htm' --include='*.js'
```

命中项**全是 LuCI 自己的 dispatcher 路径**（形如
`/cgi-bin/luci/admin/services/openclash/config_file_read`），由我们的
路线 B 宿主提供，与 `cgi-io` 这个独立 CGI 二进制无关。

`cgi-io` 是给「文件上传 / 固件升级 / 文件管理器」用的通用 CGI（`luci-mod-system`、
`luci-app-*` 的 upload 组件）。`rpcd-mod-file` 只被 `cgi-io` 消费。

**判定：可省，不影响 OpenClash 任何功能。** 归类为「显式降级」，在
`docs/03-路径契约.md` 的降级清单里登记。

### 4.2 `rpcd-mod-rrdns` —— 唯一调用点自动退化

`vendor/luci/luci-base/luasrc/sys.lua:181`：

```lua
if #lookup > 0 then
    lookup = luci.util.ubus("network.rrdns", "lookup", {
        addrs = lookup, timeout = 250, limit = 1000
    }) or { }
end
```

调用点在 `net.ip4mac_hints` / `net.mac_hints`（ARP 表 → 主机名提示），
用于「已连接设备列表」。**`or { }` 让它天然容错**：对象不存在时
`util.ubus` 返回 `nil, code`，`lookup` 退化为空表，只是不显示主机名。

注意它容错的是「**对象不存在**」，不是「ubusd 不存在」——后者会在
`_ubus.connect()` 的 `assert` 上直接抛错。所以 `ubusd` 必须有，`rrdns` 可以没有。

**判定：可省，显式降级为「设备列表不显示主机名」。**

### 4.3 netifd / `network` ubus 对象 —— 走内核，不走 ubus

这是本轮最有价值的排除项。原以为要复刻 netifd 的 RPC 面（`network.interface.dump`、
`network.device.status`、动态的 `network.interface.<name>` 子对象……），工作量极大。

**但 `luci.model.network` 的初始化根本不碰 ubus**：

`vendor/luci/luci-compat/luasrc/model/network.lua:314` `init()`，
其中读取网卡的那段在 `:329`：

```lua
for n, i in ipairs(nxo.getifaddrs()) do     -- nxo = nixio   （:329）
    local name = i.name:match("[^:]+")
    ...
    _interfaces[name] = { idx = i.ifindex or n, name = name, ... }
```

`nxo.getifaddrs()` 就是 **`nixio.getifaddrs()`**，即 libc 的 `getifaddrs(3)`——
**直接从内核读网卡**。我们 P1 已经建好了 `nixio.so`，这条路径已经通了。

`get_interfaces(self)`（同文件 `:695`）同样不调 ubus，它遍历：

1. `_uci:foreach("network", "interface", ...)` —— 读 `/etc/config/network`
2. `_interfaces` —— 上一步从内核拿到的
3. `_uci:foreach("network", "switch_vlan", ...)` —— 交换机拓扑

而 OpenClash 对 `net` 的**全部用法**（`settings.lua:11-16`）：

```lua
local net = require "luci.model.network".init()
local devices = {}
for _, iface in ipairs(net:get_interfaces()) do
    if iface:name() then
        table.insert(devices, {name = iface:name()})
    end
end
```

只有 `iface:name()` **一个访问器**。那些会触发 ubus 的方法
（`:_ubus("l3_device")` `:968`、`:uptime()` `:984`、`:ipaddrs()` `:1016`
等）OpenClash **一次都没调**。

**判定：netifd / `network` ubus 对象可省。** 前提是 `/etc/config/network` 存在
（缺失时 `_uci:foreach` 返回空，不报错；但该文件本就在 `.deb` 布局待办清单里，
应补齐以免落进「静默少列网卡」的坑）。

> 风险备注：这条结论只对 **`luci-compat` 版**的 `model/network.lua` 成立。
> 若将来 vendor 切到别的 LuCI 世代，必须重新验证——上游把这段逻辑从
> `nixio` 改成 netifd RPC 是完全可能的。§7 给了复现命令。

### 4.4 `rpcd-mod-luci` —— 暂不构建（原判"低成本"是错的）

初判是"只有 1 个 C 文件，顺手编了"，**实测不成立**。

`vendor/luci/rpcd-mod-luci/src/luci.c:51`：

```c
#include <iwinfo.h>          // 无条件，没有 #ifdef 包住
```

而 `libiwinfo` 是 OpenWrt 自己的项目，**Debian 没有对应包**。要编过这一行，
就得连 `openwrt/iwinfo` 的头树一起 vendor 进来——为了一个头文件引入一整条
新的依赖链。

讽刺的是，库本身并不需要：`luci.c:899` 是**运行期 dlopen**

```c
if (glob("/usr/lib/libiwinfo.so*", 0, NULL, &paths) != 0)   // 找不到就退化
```

也就是说，编过之后在 Debian 上也只会走"无无线信息"的降级分支。

综合三点：

1. **OpenClash 零引用** `luci-rpc`（§5.0）；
2. 代价不是 1 个文件，而是额外的 `iwinfo` vendor 树；
3. 收益为零（功能本来就退化）。

**判定：暂不构建。** 触发重新评估的条件是具体的，不是"以后再说"：

> 当我们开始移植 `luci-mod-status`（状态总览/路由表/已连设备页面）时，
> 必须回来构建它——那些页面会调 `luci-rpc.getHostHints` / `getNetworkDevices`。

`libs/rpcd-mod-luci` 已随 vendor 拉取进来（3 个文件），作为该判断的证据保留，
不参与构建。

---

## 5. 仍需 P1.5 构建的三个组件

| 组件 | 上游 | 构建方式 | 产物 | 提供的 ubus 对象 |
|---|---|---|---|---|
| `ubus` | `openwrt/project/ubus.git` | CMake（需 libubox） | `/sbin/ubusd`、`/usr/bin/ubus`、`libubus.so`、**`ubus.so`**（Lua 绑定） | （基础设施） |
| `rpcd` | `openwrt/project/rpcd.git` | CMake（需 libubox/libubus/libuci/libblobmsg-json/libjson-c） | `/sbin/rpcd`、`/etc/config/rpcd`、`/usr/share/rpcd/acl.d/unauthenticated.json` | **`session`、`uci`**（内置） |
| `rpcd-mod-luci` | `openwrt/luci` → `libs/rpcd-mod-luci` | CMake（需 libubox/libubus/libuci/**libnl-tiny**） | `/usr/lib/rpcd/luci.so` | **`luci-rpc`** |

### 5.0 两个容易混淆的对象名：`luci` ≠ `luci-rpc`

排查时极易搞混，这里先钉死（证据见 §7）：

| ubus 对象 | 由谁提供 | 装机路径 | 方法 |
|---|---|---|---|
| **`luci`** | luci-base 的**可执行插件** | `/usr/libexec/rpcd/luci`（已在 vendor 里，随 P2 安装） | `getInitList` `setInitAction` `getLocaltime` `setLocaltime` `getTimezones` `getLEDs` `getUSBDevices` `getConntrackHelpers` `getFeatures` `getSwconfigFeatures` `getSwconfigPortState` `setPassword` … |
| **`luci-rpc`** | `rpcd-mod-luci` 的**共享库插件** | `/usr/lib/rpcd/luci.so` | `getNetworkDevices` `getWirelessDevices` `getHostHints` `getDUIDHints` `getBoardJSON` `getDHCPLeases` |

两者的共同点只有一个名字前缀。**OpenClash 一个都不用**——它们服务的是
`luci-mod-status` / `luci-mod-system` 那些我们没移植的页面。

注意 `luci` 那个是 `#!/usr/bin/env lua` 的**脚本插件**，rpcd 以 `execv` 拉起它，
所以它同样吃 §2.3 的 `/usr/bin/lua` 约束。它的 require 面是
`luci.jsonc` / `nixio.fs` / `luci.sys` / `luci.util` / `luci.sys.zoneinfo`，
**全部由 P1 + P2 覆盖**（`luci.util` 依赖 §2.1 的 `ubus.so`）。

### 5.1 `session` 与 `uci` 由 rpcd 内置

OpenWrt 官方文档
<https://openwrt.org/docs/techref/rpcd> 原文：

> "Default plugins: There are few small plugins distributed with the rpcd sources.
> **Two of them (session and uci) are built-in**, others are optional and have
> to be build as separated .so libraries."

**这消除了自研 ubus 对象的必要性**——`uci` 对象由 rpcd 提供，正是它的 C 实现
直接绑 `libuci`，与我们 `runtime/uci/build-uci.sh` 构建的是同一套 libuci。

`rpcd` 暴露的 `uci` 对象方法（来自 rpcd 文档的 `ubus -v list uci`）：
`configs` / `get` / `state` / `add` / `set` / `delete` / `rename` / `order` /
`changes` / `revert` / `commit` / `apply` / `confirm` / `rollback` / `reload_config`。

这与 `luci.model.uci` 的调用完全对应（它在 `:41` 把所有操作都转发给
`util.ubus("uci", cmd, args)`）。

### 5.2 无 session 时的权限

`luci.model.uci` 的 `call()`（`model/uci.lua:36-42`）：

```lua
local session_id = nil
local function call(cmd, args)
    if type(args) == "table" and session_id then
        args.ubus_rpc_session = session_id
    end
    return util.ubus("uci", cmd, args)
end
```

CLI 脚本（`openclash_version.lua` 等）不会设 session，所以走的是
「无 `ubus_rpc_session`」分支。rpcd 对这种情形按**受信任的本地 root**处理
（ubusd 的 socket 权限本身就把非 root 挡在外面），即完整权限。

**验证点**：`tests/e2e/linux/run-e2e.sh` 需要新增一条断言——
以 root 执行 `lua -e 'require("luci.model.uci").cursor():get("openclash","config","enable")'`
且**不带** session，应返回 `0` 而不是权限错误。这条断言如果没有，
上面这段推理就只是推理。

### 5.3 两个构建陷阱（与 P1 同源）

1. **`rpcd-mod-luci/src/CMakeLists.txt` 也是 `cmake_minimum_required(VERSION 2.6)`**
   ——与 `lucihttp` 完全相同的坑：CMake 4.x 直接拒绝
   （"Compatibility with CMake < 3.5 has been removed"）。必须用自建编译，
   不能走上游 CMake。

2. **`rpcd-mod-luci` 需要 libnl-tiny 的头文件**：
   其 Makefile 里有
   `TARGET_CFLAGS += -I$(STAGING_DIR)/usr/include/libnl-tiny`，
   源码里 `#include` 的是 `<netlink/...>`，与我们 P1 为 `ip.so` 做的事一样。
   可以复用 `build-lua-modules.sh` 已经构建/解包好的那份头树。
   同时它的 CMake 默认 `FIND_LIBRARY(libnl NAMES libnl-3 libnl nl-3 nl)`
   会去找 Debian 的 libnl-3 —— **那是另一套 API/ABI，会编过但行为错**。
   必须显式 `-DLIBNL_LIBS=-lnl-tiny`（上游 Makefile 就是这么做的）。

---

## 6. 对排期的影响

原计划：

```
P1 Lua C 模块 → P2 vendor LuCI → P3 CGI 宿主 → P4 ubus → P5 uci-defaults
```

修订后：

```
P1   Lua C 模块                    ✓ 已完成（6 个单元，83 断言）
P1.5 ubus 底座                     ← 新增，本文的工作量
     ├─ ubus (ubusd + libubus + ubus.so + ubus CLI)    ✓ 脚本已就绪（未真机执行）
     ├─ rpcd (内置 session + uci)                      ✓ 脚本已就绪（未真机执行）
     ├─ lua 解释器钉定：11 处 → 绝对路径 /usr/bin/lua5.1  ✓ 已实现并实测
     │    （**不是** update-alternatives —— 见 §2.3 的更正：
     │     该组处于 manual 模式时新候选不会生效，等于没有保证）
     ├─ systemd: ubusd.service / rpcd.service            ✓ 单元已就绪
     │    （socket 激活**不在范围内**：本地 root 场景用不到）
     └─ rpcd-mod-luci                                   ⊘ 暂缓（见 §4.4）
P2   vendor LuCI 纯 Lua → /usr/lib/lua/luci + .lmo
     （有了 P1.5，此时 `require "luci.util"` 才第一次能成功——
       在此之前 P2 的"能加载"验证是做不了的）
     ⚠️ P2 还必须同时钉定 vendor/luci 里的 2 个 lua 入口
        （htdocs/cgi-bin/luci、root/usr/libexec/rpcd/luci）。
        **不能用 `--dir`** —— 这两个文件叫 `luci`，没有 `.lua` 后缀，而 `--dir`
        是按 `-name '*.<ext>'` 枚举的，**永远选不到它们**。必须用 `--file`：
          runtime/upstream/pin-lua-interpreter.sh \
              --file "<staging>/usr/share/luci/htdocs/cgi-bin/luci" \
              --file "<staging>/usr/libexec/rpcd/luci"
        （对整棵 vendor/luci 跑宽判据也不行：实测 3 处第三方散文误报，
          如 `nixio - Linux I/O library for lua`。详见 docs/03 §1.4.3。）
        <!-- 能力已于 P1.5 实现并测试（tests/test_pin_lua.sh 的 K 组 22 条断言）；
             此处只待 P2 把这两个文件放进 staging 后接线。 -->
P3   CGI 宿主 + /etc/config/uhttpd
P4   uci-defaults / ucitrack / 105 个端点接线
     （原 P4 的 ubus 内容已提前到 P1.5，此处只剩接线）
P5   验收与降级项登记
```

**为什么 P2 必须排在 P1.5 之后**：P2 的验收标准是「`require "luci.util"` 能成功」。
在 P1.5 完成前，这个断言**必然失败**，且失败原因（缺 `ubus.so`）与 P2 的工作内容
（把 `.lua` 文件放对位置）毫无关系。强行先做 P2 会得到一个「怎么看都是自己写错了」
的假失败。

**为什么「lua 解释器钉定」也算 P1.5 而不是 P1**：它与 P1 的 Lua C 模块是**成对**的 ——
P1 产出的 `.so` 全部是为 5.1 编译的，而钉定解决的是"运行时到底由哪个 lua 来加载它们"。
两者只有同时成立才有意义：只做 P1 会得到一个"模块编好了，但被 5.4 加载"的包，
失败信息还和"搜索路径没桥接对"极度相似。所以它必须在**打包出第一个可用 .deb 之前**完成。

---

## 7. 复现命令

本文所有结论都可用下列命令复验（在仓库根执行）：

```sh
# §2.1 luci.util 顶层 require ubus
sed -n '15p' vendor/luci/luci-lib-base/luasrc/util.lua

# §2.2 luci-base 的依赖声明
grep -n 'LUCI_DEPENDS' vendor/luci/luci-base/Makefile

# §2.3 上游 .lua 的 shebang 与 require
head -1 upstream/luci-app-openclash/root/usr/share/openclash/*.lua
grep -n 'require' upstream/luci-app-openclash/root/usr/share/openclash/*.lua

# §2.3 依赖「系统 lua」的 11 处穷尽清单（8 shebang + 3 显式调用）
#   宽判据：命令位置上一切裸 lua。实测只命中已知的 11 处，无误报。
GATE='^#![[:space:]]*.*lua[[:space:]]*$|(^|[^[:alnum:]_./-])lua([^[:alnum:]_.-]|$)'
grep -rnE "$GATE" upstream/luci-app-openclash/root/usr/share/openclash \
  --include='*.lua' --include='*.sh'
#   对照：钉定后同一判据应当归零
grep -rnE "$GATE" packaging/build/stage/usr/share/openclash \
  --include='*.lua' --include='*.sh'

# §2.3 上游源文件无 CRLF（否则 `^#!/usr/bin/lua$` 会因 '\r' 匹配不上）
grep -rlU $'\r' upstream/luci-app-openclash/root/usr/share/openclash \
  --include='*.lua' --include='*.sh'   # 期望：无输出

# §2.3 Debian 的 /usr/bin/lua 来自哪个 alternatives 组（需在 Debian 上跑）
update-alternatives --config lua-interpreter   # 观察各候选的优先级
ls -l /usr/bin/lua

# §2.3 钉定工具自身的规则与判据
runtime/upstream/pin-lua-interpreter.sh --list
bash tests/test_pin_lua.sh

# §3 LuCI 核心的 ubus 调用面
grep -rn 'ubus(' vendor/luci --include='*.lua'
# 上游自己的 require 面
grep -rhoE 'require\s*\(?\s*"[^"]+"' upstream/luci-app-openclash/luasrc \
  --include='*.lua' | sed 's/.*"\(.*\)"/\1/' | sort | uniq -c | sort -rn

# §4.1 cgi-io 零引用
grep -rn 'cgi-io\|cgi_io' upstream/luci-app-openclash

# §4.3 luci.model.network 走内核而非 ubus
sed -n '314,340p' vendor/luci/luci-compat/luasrc/model/network.lua
sed -n '695,700p' vendor/luci/luci-compat/luasrc/model/network.lua
grep -n 'net:' upstream/luci-app-openclash/luasrc/model/cbi/openclash/settings.lua

# §5.1 rpcd 内置 session/uci（需联网）
#   https://openwrt.org/docs/techref/rpcd

# §5.0 两个对象名：luci（脚本插件）vs luci-rpc（共享库插件）
grep -nE '^\s+[a-zA-Z]+ = \{' vendor/luci/luci-base/root/usr/libexec/rpcd/luci
grep -n 'UBUS_METHOD' vendor/luci/rpcd-mod-luci/src/luci.c
head -1 vendor/luci/luci-base/root/usr/libexec/rpcd/luci

# §5.3 rpcd-mod-luci 的 CMake 版本与 libnl 选择
git -C vendor/.luci-checkout show HEAD:libs/rpcd-mod-luci/src/CMakeLists.txt
git -C vendor/.luci-checkout show HEAD:libs/rpcd-mod-luci/Makefile | grep -n 'LIBNL\|libnl'
```
