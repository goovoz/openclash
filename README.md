# openclash-rt

把 [OpenClash](https://github.com/vernesong/OpenClash) 搬到 **Debian / Ubuntu 无桌面服务器**上，
并保持**上游代码零修改**与**每日可同步上游**。

- 目标场景：服务器同时充当**本机代理**与**旁路网关**
- 部署形态：原生 `.deb` 包
- 验收口径：**100% 功能复刻**；仅显式登记的项目降级（见 `docs/03` §2.7）

---

## 这不是"移植"，而是"补一层运行时"

OpenClash 是为 OpenWrt 写的，它依赖 OpenWrt 的四套基础设施：

| OpenWrt 提供 | 上游对它的依赖强度 |
|---|---|
| `uci` 配置系统 | 152 处 `uci` 调用 |
| `procd` 服务管理 | 21 处（`init.d/openclash` 内 14 处） |
| `fw4` / nftables 表结构 | 341 处 `inet fw4` + 356 处 `nft` |
| `dnsmasq-full` + netifd | 105 处 + 18 处 `/tmp/resolv.conf.auto` |

如果去"改上游代码适配 Debian"，就等于**放弃上游同步**——
每次上游更新都要重放一遍全部改动，长期必然腐化。

所以本项目的做法是：**不改上游一行，而是补一层 OpenWrt 兼容运行时**，
让上游以为自己在 OpenWrt 上。

```
┌─────────────────────────────────────────────────────────┐
│ L1  上游 OpenClash（git 同步，零修改）                    │
│     etc/init.d/openclash · usr/share/openclash/*.sh      │
├─────────────────────────────────────────────────────────┤
│ L2  OpenWrt 兼容运行时（本项目）                          │
│     /etc/rc.common           → procd 语义落到 systemd    │
│     /lib/functions/*.sh      → OpenWrt shell 库           │
│     /sbin/uci（编译）        → 真实 uci + Lua 绑定        │
│     /usr/sbin/fw4            → table inet fw4 骨架        │
│     prepare-tmp.sh           → /tmp 易失路径 + resolv 镜像│
│     dnsmasq-adapter.sh       → UCI dhcp → /etc/dnsmasq.d  │
│     /etc/openwrt_release     → 解锁上游的 OpenWrt 分支    │
├─────────────────────────────────────────────────────────┤
│ L3  Debian / Ubuntu 系统层                                │
│     systemd · nftables · dnsmasq · cron · iproute2        │
└─────────────────────────────────────────────────────────┘
```

### 核心实现范式：**把上游的"探测"喂成真，而不是把"探测"删掉**

上游到处在做"探测"（探测发行版、探测 dnsmasq 的 conf-dir、探测 `fw4` 是否存在）。
兼容层不去 patch 这些判断，而是**让判断成立并给出正确结果**。三个实例：

| 上游的探测 | 兼容层的喂法 | 效果 |
|---|---|---|
| `[ -f /etc/openwrt_release ]` 才推导 `DNSMASQ_CONF_DIR` | 装一个说明自己是 `openclash-rt` 的 `/etc/openwrt_release` | 解锁整段 DNS 逻辑，零 patch |
| `awk '/^conf-dir=/' /tmp/etc/dnsmasq.conf.<CFGID>` | 启动时生成该文件，内容 `conf-dir=/etc/dnsmasq.d` | 上游自己推出正确目录 |
| `FW4=$(command -v fw4)`，为空就静默降级到 iptables | 在 PATH 上放一个 `fw4` 垫片 | 稳定走 nft 路径，避免 4 个额外依赖 |

---

## 目录结构

```
runtime/
  procd/rc.common           OpenWrt rc.common 的等价实现（含 dash→bash 重执行）
  procd/procd.sh            procd → systemd 垫片（单元生成、生命周期、信号）
  shell/functions.sh        OpenWrt lib/functions.sh（仅 1 处补 IPKG_INSTROOT 分支）
  shell/functions/*.sh      OpenWrt 网络函数库
  shell/config/uci.sh       OpenWrt lib/config/uci.sh（uci_load 的实现）
  shell/service.sh          未使用 API 的桩
  net/fw4                   fw4 垫片：预建 table inet fw4 与 7 个 base chain
  net/prepare-tmp.sh        易失路径准备（/tmp 喂料 + resolv 镜像 + cron）
  net/dnsmasq-adapter.sh    UCI dhcp → /etc/dnsmasq.d 翻译（只翻译 6 个托管选项）
  uci/build-uci.sh          编译 libubox + uci（含 Lua 绑定）
scripts/
  sync-upstream.sh          每日同步上游，产出 upstream/.upstream-version
  build-deb.sh              组装并打包 .deb
packaging/debian/           control / conffiles / postinst / prerm / postrm / systemd 单元
patches/                    留空（正常路径下应始终为空）
tests/
  test_procd_shim.sh        回放上游 14 处 procd 调用，校验单元生成与生命周期
  test_fw4_shim.sh          骨架正确性 / 幂等 / 反例 / include 契约 / dry-run
  test_dns_prep.sh          prepare-tmp 与 dnsmasq-adapter
  test_upstream_load.sh     以真 dash 派发**未修改的**上游 3848 行 init 脚本
  mock/bin/                 uci / systemctl / nft 三个桩
  e2e/linux/run-e2e.sh      真实 Linux 端到端（真路径、真 dash、真 nftables）
```

---

## 快速开始

### 构建

```sh
# 1. 拉取上游（首次）
bash scripts/sync-upstream.sh

# 2. 构建 .deb（需要 Debian/Ubuntu 环境 + 编译工具）
sudo apt-get install -y build-essential cmake pkg-config git \
     libjson-c-dev lua5.1 liblua5.1-0-dev dpkg-dev
bash scripts/build-deb.sh
# 产物：dist/openclash-rt_<版本>_<arch>.deb
```

### 安装与启用

```sh
sudo apt install ./dist/openclash-rt_*.deb
# 在 Web UI 打开 enable 开关，或：
sudo uci set openclash.config.enable=1
sudo uci commit openclash
sudo systemctl start openclash
```

### 卸载

```sh
sudo apt remove openclash-rt
```

> 卸载会自动走上游的 `revert_firewall` / `revert_dnsmasq` 还原防火墙与 DNS，
> 并清理 `/etc/dnsmasq.d/00-openclash-rt-uci.conf`。
> **这一步是必需的**——该文件残留会让整机失去 DNS。CI 中有专门用例守住。

---

## 测试

```sh
bash tests/test_procd_shim.sh      # procd → systemd 垫片
bash tests/test_fw4_shim.sh        # fw4 垫片
bash tests/test_dns_prep.sh        # DNS 适配层
bash tests/test_upstream_load.sh   # 上游 init 脚本加载与派发
sudo bash tests/e2e/linux/run-e2e.sh          # 真实 Linux 端到端
sudo bash tests/e2e/linux/run-e2e.sh --deb dist/openclash-rt_*.deb
```

`e2e` 的安全设计：
- 安装阶段对每个目标路径做**日志化备份**，退出时（含异常）自动还原；
- 真实 nftables 验证跑在 `unshare -n` 的**独立网络命名空间**内，绝不触碰宿主防火墙；
- procd 单元写入临时目录，不触碰宿主 `/run/systemd`。

---

## 上游同步

`.github/workflows/sync-upstream.yml` 每天 03:17 自动同步上游：

1. `git clone --sparse` 只取 `luci-app-openclash`（失败则回退 tarball）；
2. 应用 `patches/*.patch`——**冲突即失败**（退出码 2）；
3. 跑全部测试套件；
4. 有变化则提交；失败则开 issue（标签 `upstream-sync`）并让 job 失败。

设计约定：`patches/` **正常应始终为空**。任何需要常驻的补丁都说明兼容层漏了一层抽象。
唯一允许的例外是 `runtime/shell/functions.sh` 中一处 `IPKG_INSTROOT` 补齐（已在文件内注明）。

---

## 当前状态

已通过的关键里程碑：

| 里程碑 | 状态 | 证据 |
|---|---|---|
| rc.common + procd 垫片可加载**未修改的**上游 3848 行 init 脚本 | ✅ | `test_upstream_load.sh` |
| procd → systemd 语义映射（respawn/limits/env/信号） | ✅ | `test_procd_shim.sh` |
| fw4 骨架（7 个 base chain）+ include 契约 | ✅ | `test_fw4_shim.sh` |
| `/tmp` 易失路径与 resolv 镜像 | ✅ | `test_dns_prep.sh` |
| UCI → dnsmasq 翻译 + path 单元同步 | ✅ | `test_dns_prep.sh` |
| `.deb` 组装（含 fw4、适配器、dhcp 包、systemd 单元） | ✅ | `scripts/build-deb.sh` |
| 每日上游同步 + 冲突告警 | ✅ | `sync-upstream.yml` |

进行中：前端路线 B（自建 Web 后端渲染上游 `.htm` 视图 + 实现 105 个 `call()` JSON 端点）、
网络探测替代（`openclash_get_network.lua`）、`.deb` 在真实 Debian 上的首次完整安装验证。

---

## 文档

- `docs/01-可行性分析.md` —— 可行性论证、耦合量化、路线选择
- `docs/03-路径契约.md` —— **权威契约清单**：上游硬编码的每条路径与行为，
  以及兼容层对应做法。改动兼容层前必读。

## 许可

上游 OpenClash 为 MIT；OpenWrt `uci` / `libubox` 为 LGPL-2.1。
本项目的兼容层代码随其各自许可分发。
