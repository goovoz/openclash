//! 用户配置的数据模型。
//!
//! 设计原则（与 OpenClash 的关键区别）：
//! OpenClash 把所有配置塞进 UCI 的 section/option，本项目用**普通 YAML +
//! 强类型结构体**。上一轮在 openclash-rt 上实测的「Add 按钮失效」与
//! 「内核起不来」，根因就是 cbid 前缀与 uci段名不一致—— UCI 这层抽象
//! 带来的耦合远大于它提供的便利。
//!
//! 字段取自 mihomo 实测的 `GET /configs` 返回（43 个顶层字段），
//! 只暴露真正需要用户关心的部分，其余给默认值。

use serde::{Deserialize, Serialize};

/// 顶层配置。对应 `config.yaml`（用户配置）。
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default, rename_all = "kebab-case")]
pub struct Config {
    /// 显式代理入站（本机代理模式的核心）。
    pub inbound: Inbound,
    /// 透明代理入站（旁路由模式的核心）。
    pub transparent: Transparent,
    /// DNS 配置。
    pub dns: Dns,
    /// 运行模式。
    pub mode: Mode,
    /// 日志级别。
    pub log_level: LogLevel,
    /// 出口网卡（旁路由时防环路的关键之一）。
    pub interface_name: Option<String>,
    /// 专用运行用户（配合 tun.exclude-uid 解环路）。
    pub run_user: Option<String>,
    /// 代理组定义。
    #[serde(default)]
    pub proxy_groups: Vec<ProxyGroup>,
    /// 规则定义。
    #[serde(default)]
    pub rules: Vec<Rule>,
    /// 外部规则集。
    #[serde(default)]
    pub rule_providers: Vec<RuleProvider>,
    /// 手动节点（不走订阅的）。
    #[serde(default)]
    pub proxies: Vec<Proxy>,
    /// 订阅列表。
    #[serde(default)]
    pub subscriptions: Vec<Subscription>,
    /// 嗅探设置。
    pub sniffer: Sniffer,
    /// 其他零散开关。
    pub misc: Misc,
}

/// 显式入站：客户端自己连进来用的端口。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default, rename_all = "kebab-case")]
pub struct Inbound {
    /// 混合端口（HTTP + SOCKS5 共用）。0 = 禁用。
    pub mixed_port: u16,
    /// HTTP 端口。0 = 禁用。
    pub http_port: u16,
    /// SOCKS5 端口。0 = 禁用。
    pub socks_port: u16,
    /// 是否允许局域网设备连接。
    /// - 本机代理模式：false（只监听 127.0.0.1）
    /// - 旁路由模式：true（监听 0.0.0.0，让客户端设备连）
    pub allow_lan: bool,
    /// 认证（`user:pass`），留空则不校验。
    pub authentication: Vec<String>,
}

impl Default for Inbound {
    fn default() -> Self {
        Self {
            mixed_port: 7893,
            http_port: 0,
            socks_port: 0,
            allow_lan: false,
            authentication: Vec::new(),
        }
    }
}

/// 透明代理入站。
///
/// 三种方式的取舍（实测依据见 docs/10 §1.3）：
/// - `Tun`：最通用（TCP/UDP/ICMP），且 `auto-redirect` 让 mihomo 自己写
///   nftables，**不需要我们手写防火墙规则**。默认推荐。
/// - `Redir`：仅 TCP，最轻量。
/// - `Tproxy`：TCP+UDP，需要内核 ≥2.6.28。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "kebab-case")]
pub enum TransparentMode {
    #[default]
    Off,
    Tun,
    Redir,
    Tproxy,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default, rename_all = "kebab-case")]
pub struct Transparent {
    pub mode: TransparentMode,
    /// TUN 协议栈。`mixed` 是体验折中（tcp=system, udp=gvisor）。
    /// `system` 最省资源但依赖系统栈，`gvisor` 最安全但最慢。
    pub tun_stack: String,
    /// TUN 网卡名。
    pub tun_device: String,
    /// MTU。
    pub tun_mtu: u32,
    /// 启用 strict-route（Linux 上防地址泄漏）。
    pub strict_route: bool,
    /// 由 mihomo 自动配置 iptables/nftables 转发（Linux 专有）。
    pub auto_redirect: bool,
    /// DNS 劫持列表。
    pub dns_hijack: Vec<String>,
    /// 排除的网卡（这些网卡的流量不进 TUN）。
    pub exclude_interface: Vec<String>,
    /// 排除的 UID（让 mihomo 自己的连接绕过，解环路的关键之一）。
    pub exclude_uid: Vec<String>,
    /// redir 模式端口。
    pub redir_port: u16,
    /// tproxy 模式端口。
    pub tproxy_port: u16,
}

impl Default for Transparent {
    fn default() -> Self {
        Self {
            mode: TransparentMode::Off,
            tun_stack: "mixed".into(),
            tun_device: "Mihomo".into(),
            tun_mtu: 9000,
            strict_route: true,
            auto_redirect: true,
            dns_hijack: vec!["any:53".into()],
            exclude_interface: vec![],
            exclude_uid: vec![],
            redir_port: 7892,
            tproxy_port: 7894,
        }
    }
}

/// DNS 处理模式。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "kebab-case")]
pub enum DnsMode {
    /// 立即返回虚拟 IP，真实解析异步完成。快、防泄漏，但要求规则侧配合。
    #[default]
    FakeIp,
    /// 返回真实 IP。兼容性好，但慢一些。
    RedirHost,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default, rename_all = "kebab-case")]
pub struct Dns {
    pub enable: bool,
    /// 监听地址。旁路由下要对外提供 DNS 服务。
    pub listen: String,
    pub mode: DnsMode,
    pub fake_ip_range: String,
    pub fake_ip_filter_mode: String,
    pub fake_ip_filter: Vec<String>,
    /// 缓存算法。
    pub cache_algorithm: String,
    pub ipv6: bool,
    /// bootstrap DNS：解析其他 DNS 服务器的域名用。
    pub default_nameserver: Vec<String>,
    /// 主力 DNS。
    pub nameserver: Vec<String>,
    /// 被污染时的备用 DNS。
    pub fallback: Vec<String>,
    pub fallback_filter_geoip: bool,
    pub fallback_filter_geoip_code: String,
    pub fallback_filter_geosite: Vec<String>,
    /// ★ 解析**节点服务器域名**用的 DNS。
    /// 必须指向可直连的 resolver —— 否则节点域名解析失败，
    /// 叠加 fake-ip 劫持 53 端口会导致所有节点不可用
    /// （openclash-rt 真机踩过：改成 DoH 后doh.pub 8 秒超时）。
    pub proxy_server_nameserver: Vec<String>,
}

/// DNS 默认值。
///
/// ★ 这里的每一条都是真机实测逼出来的，不是随手填的：
///
/// - `nameserver` **默认用明文 IP DNS，不用 DoH**。
///   真机（172.20.0.101）实测 `doh.pub` 连 443 超时 8 秒，
///   内核表现为：
///       [DNS] resolve www.baidu.com A from https://doh.pub/dns-query
///       [TCP] dial PROXY ... error: dns resolve failed: context deadline exceeded
///   而 `dns.alidns.com:443` 是通的、`223.5.5.5` 明文也通。
///   可配置的用户想用 DoH 时自己改即可，但默认值必须是最稳的。
///
/// - `proxy-server-nameserver` 必须用**明文 IP**。
///   它负责解析**节点服务器的域名**；节点域名必须在代理建立前就
///   能解析，DoH 走不出去就成了死锁（openclash-rt 真机踩过：
///   改成 DoH 后`doh.pub` 8 秒超时，所有节点不可用）。
///
/// - `enhanced-mode: fake-ip` 配 `MATCH`/`DIRECT` 时，
///   内核拿 198.18.x.x 假 IP 直连会失败。需要直连真实 IP 的场景
///   应改用 `redir-host`（本项目在 precheck 里提示）。
impl Default for Dns {
    fn default() -> Self {
        Self {
            enable: true,
            listen: "0.0.0.0:7874".into(),
            mode: DnsMode::FakeIp,
            fake_ip_range: "198.18.0.1/16".into(),
            fake_ip_filter_mode: "blacklist".into(),
            fake_ip_filter: vec!["*.lan".into(), "localhost.ptlogin2.qq.com".into()],
            cache_algorithm: "lru".into(),
            ipv6: false,
            // bootstrap：解析其他 DNS 服务器的域名用。必须是 IP 形式，
            // 因为它们自己就是域名（-DoH 主机名）时同样会踩死锁。
            default_nameserver: vec!["223.5.5.5".into(), "119.29.29.29".into()],
            // ★ 明文，不用 DoH（见上方说明）
            nameserver: vec!["223.5.5.5".into(), "119.29.29.29".into()],
            fallback: vec!["223.5.5.5".into()],
            fallback_filter_geoip: true,
            fallback_filter_geoip_code: "CN".into(),
            fallback_filter_geosite: vec!["gfw".into()],
            // ★ 明文 IP（见上方说明）
            proxy_server_nameserver: vec!["223.5.5.5".into(), "119.29.29.29".into()],
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "kebab-case")]
pub enum Mode {
    #[default]
    Rule,
    Global,
    Direct,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "kebab-case")]
pub enum LogLevel {
    Silent,
    Error,
    Warning,
    #[default]
    Info,
    Debug,
}

impl LogLevel {
    pub fn as_str(&self) -> &'static str {
        match self {
            Self::Silent => "silent",
            Self::Error => "error",
            Self::Warning => "warning",
            Self::Info => "info",
            Self::Debug => "debug",
        }
    }
}

/// 代理组类型。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "kebab-case")]
pub enum GroupType {
    /// 手动选择。
    #[default]
    Select,
    /// 自动测速选最快。
    UrlTest,
    /// 按顺序故障转移。
    Fallback,
    /// 负载均衡。
    LoadBalance,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default, rename_all = "kebab-case")]
pub struct ProxyGroup {
    pub name: String,
    #[serde(rename = "type")]
    pub group_type: GroupType,
    /// 候选节点。空 = 自动纳入全部节点。
    pub proxies: Vec<String>,
    /// 引用订阅提供的节点池。
    pub use_providers: Vec<String>,
    pub url: Option<String>,
    pub interval: Option<u32>,
    /// 切换容忍度（ms），避免频繁切换。
    pub tolerance: Option<u32>,
    pub strategy: Option<String>,
}

impl Default for ProxyGroup {
    fn default() -> Self {
        Self {
            name: "PROXY".into(),
            group_type: GroupType::Select,
            proxies: vec![],
            use_providers: vec![],
            url: Some("http://www.gstatic.com/generate_204".into()),
            interval: Some(300),
            tolerance: Some(50),
            strategy: None,
        }
    }
}

/// 规则。
///
/// ★ 刻意用**字符串**而不是结构体（`{type:..., payload:...}`）。
/// mihomo 的规则本身就是单行标量 `DOMAIN-SUFFIX,example.com,PROXY`，
/// 用户手写时一眼能看懂；做成结构体反而要在 YAML 里写三倍长度，
/// 序列化时还要再拼回字符串。
///
/// 第一版用结构体，真机实测踩坑：配置里写了 3 条规则，渲染产物里
/// **只剩 MATCH** —— serde 反序列化时字段名对不上，规则被静默跳过，
/// 而 `mihomo -t` 校验通过（因为 MATCH 兜底合法），全程无报错。
/// 字符串形式没有这个歧义：渲染不出来只能是渲染器的问题。
///
/// 支持的类型见官方 wiki config/rules（40+ 种）。这里不枚举、
/// 原样透传给内核，由 `mihomo -t` 兜底校验。
/// 附加参数 `no-resolve` 直接写在规则尾部即可（内核原生语法）。
pub type Rule = String;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default, rename_all = "kebab-case")]
pub struct RuleProvider {
    pub name: String,
    /// `behavior`：domain / ipcidr / classical
    pub behavior: String,
    pub url: String,
    pub path: String,
    pub interval: u32,
}

impl Default for RuleProvider {
    fn default() -> Self {
        Self {
            name: String::new(),
            behavior: "domain".into(),
            url: String::new(),
            path: String::new(),
            interval: 86400,
        }
    }
}

/// 代理节点。
///
/// 这里只列出最常用的字段；未列出的协议专有字段（如 reality-opts、
/// ws-opts、hysteria2 的 up/down）需要保留，否则机场订阅转换会丢配置。
/// 用 `extra: Map` 兜住未建模字段（serde_yaml 的 Mapping）。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub struct Proxy {
    pub name: String,
    /// 协议类型：ss / ssr / vmess / vless / trojan / snell / hysteria2 / tuic ...
    #[serde(rename = "type")]
    pub proxy_type: String,
    pub server: String,
    pub port: u16,
    #[serde(flatten)]
    pub extra: serde_yaml::Mapping,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default, rename_all = "kebab-case")]
pub struct Subscription {
    /// 订阅标识名（也是节点名前缀来源）。
    pub name: String,
    /// 订阅地址。
    pub url: String,
    /// 请求时带的 User-Agent（有些机场按 UA 分流不同格式）。
    pub user_agent: Option<String>,
    /// 自动更新间隔（小时）。0 = 不自动更新。
    pub update_interval: u32,
    /// 节点名过滤：只保留含这些关键词的。
    pub keyword: Vec<String>,
    /// 节点名排除。
    pub exclude_keyword: Vec<String>,
    /// 是否给节点名加 emoji。
    pub emoji: bool,
    /// 是否给节点名加地区前缀。
    pub sort: bool,
    /// 额外请求参数（拼到 URL 查询串）。
    pub extra_params: Vec<String>,
    /// 额外请求头。
    pub headers: Vec<String>,
}

impl Default for Subscription {
    fn default() -> Self {
        Self {
            name: String::new(),
            url: String::new(),
            user_agent: Some("clash.meta".into()),
            update_interval: 24,
            keyword: vec![],
            exclude_keyword: vec![],
            emoji: false,
            sort: true,
            extra_params: vec![],
            headers: vec![],
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default, rename_all = "kebab-case")]
pub struct Sniffer {
    pub enable: bool,
    /// 覆写目标地址（让规则能按域名匹配 HTTPS）。
    pub override_destination: bool,
}

impl Default for Sniffer {
    fn default() -> Self {
        Self {
            enable: true,
            override_destination: true,
        }
    }
}

/// 零散开关。
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(default, rename_all = "kebab-case")]
pub struct Misc {
    /// TCP 并发连接（同一个目标复用连接，显著提速）。
    pub tcp_concurrent: bool,
    /// 统一延迟测试（更准的延迟值）。
    pub unified_delay: bool,
    /// 查找进程模式：off / strict / always。
    /// 旁路由下建议关（容器/网络命名空间里进程名可能不可见）。
    pub find_process_mode: String,
    /// 控制接口监听地址（客户端自己连）。
    pub external_controller: String,
    /// 控制接口密钥。
    pub secret: Option<String>,
    /// Web UI 目录（相对 mihomo 工作目录）。
    pub external_ui: String,
    /// geo 数据更新间隔（小时）。
    pub geo_update_interval: u32,
}

impl Default for Misc {
    fn default() -> Self {
        Self {
            tcp_concurrent: true,
            unified_delay: true,
            find_process_mode: "off".into(),
            external_controller: "127.0.0.1:9090".into(),
            secret: None,
            external_ui: "ui".into(),
            geo_update_interval: 24,
        }
    }
}