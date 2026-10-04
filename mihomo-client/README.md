# mihomo-client

Linux 无桌面mihomo 客户端（本机代理 + 旁路由）。

## 快速开始

    # 1. 装mihomo 内核到 bin/mihomo
    #    开发期可直接借用 OpenClash 带来的：
    ln -sf /etc/openclash/core/clash_meta /opt/mihomo-client/bin/mihomo

    # 2. 生成配置（自动探测出口网卡与IPv6 可用性）
    mihomo-client init

    # 3. 校验 -> 应用 -> 装服务 -> 启动
    mihomo-client validate
    mihomo-client apply
    mihomo-client install --run-user nobody --group nogroup
    mihomo-client service start

    # 4. 用
    export http_proxy=http://127.0.0.1:7893
    mihomo-client status

## 命令

| 命令 | 说明 |
|------|------|
| `init [--force] [--bypass-router] [--interface IF]` | 生成默认配置 |
| `validate` | 渲染后交给 `mihomo -t` 校验，不改动任何东西 |
| `apply [--force]` | 原子切换：写 .new -> 校验 -> 改名覆盖 |
| `service start\|stop\|restart\|log` | systemd 控制 |
| `status [--verbose]` | 含内核版本、GeoData 就绪状态 |
| `install --run-user U [--group G] [--no-net-admin]` | 装 systemd unit 并 enable |
| `sub NAME URL [--interval H]` | 添加订阅 |
| `mode rule\|global\|direct` | 走内核 RESTful API 热切换（不重启） |
| `show` | 打印渲染后的 mihomo 配置 |
| `ifaces` | 列出网卡与默认路由出口 |

## 设计原则

**能委托内核的绝不自己实现**：

- 配置校验 -> `mihomo -t`（唯一权威校验）
- 模式/节点切换 -> RESTful API
- 进程管理 -> systemd
- 协议解析 -> mihomo 的显式入站

**不用 sed/awk 改 yaml**：全程 serde_yaml 操作数据结构。

## 目录布局

    /opt/mihomo-client/
    ├── bin/mihomo-client        本程序
    ├── bin/mihomo               内核二进制
    ├── etc/config.yaml          用户配置（改这个）
    ├── etc/subscriptions.yaml   订阅列表
    ├── var/config.gen.yaml      渲染产物（自动生成，勿手改）
    └── var/mihomo/              内核工作目录（geodata、ruleset）

## 排障

| 症状 | 原因 |
|------|------|
| `216/GROUP` 服务起不来 | `--group` 没给对。Debian 的 nobody 属 `nogroup` |
| 规则命中但连接超时 | 没设 `interface-name`。`mihomo-client ifaces` 看出口网卡 |
| `dns resolve failed: context deadline exceeded` | nameserver 里的 DoH 不通。改用明文 IP DNS |
| 所有请求 502 | GeoData 未就绪（首启要下载）。`status` 会显示 |
| 端口被占 | 用 `--core` 指定别的内核，或改配置里的端口 |

## 开发

    # 真机构建（Rust 装在 /opt/cargo）
    python3 scripts/_deploy/build-rust.py

依赖刻意保持最小：serde / serde_yaml / clap / anyhow / dirs，
**无 tokio**（CLI 与 systemd 场景下同步阻塞不是瓶颈）。

设计文档：`docs/10-新项目设计/01-上游调研与架构设计.md`
