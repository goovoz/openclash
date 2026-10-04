//! 配置渲染：用户配置 + 订阅节点 -> mihomo 完整 YAML。
//!
//! 为什么用 serde_yaml 操作数据结构而不是字符串拼接/sed：
//! OpenClash 用 shell 反复改同一个 yaml，`yml_change.sh` 里用
//! `Value['log-level'] = log_level if log_level != '0'` 这种写法，
//! 一旦条件判断漏掉就会产出 `log-level: ''`，mihomo 直接拒绝启动
//! （openclash-rt 真机踩过：`Parse config error: invalid log-level`）。
//! 这里全程走 serde_yaml 的Mapping，类型不对会在序列化阶段就暴露。

use serde_yaml::{Mapping, Value};

use crate::config::{
    Config, DnsMode, GroupType, LogLevel, Mode, Proxy, ProxyGroup, Rule, RuleProvider,
    Transparent, TransparentMode,
};

/// 渲染结果。
pub struct Rendered {
    pub yaml: String,
    /// 渲染过程中的提示（未定义的代理组引用等）。
    pub warnings: Vec<String>,
}

/// 把用户配置渲染为 mihomo 配置。
pub fn render(cfg: &Config, proxies: &[Proxy]) -> Rendered {
    let mut m = Mapping::new();
    let mut w = Vec::new();

    // ---- 显式入站 ----
    // bind-address 跟着 allow_lan 走：本机代理只听127.0.0.1，
    // 旁路由监听所有网卡让局域网设备能连。
    m.insert("mixed-port".into(), cfg.inbound.mixed_port.into());
    if cfg.inbound.http_port > 0 {
        m.insert("port".into(), cfg.inbound.http_port.into());
    }
    if cfg.inbound.socks_port > 0 {
        m.insert("socks-port".into(), cfg.inbound.socks_port.into());
    }
    m.insert("allow-lan".into(), cfg.inbound.allow_lan.into());
    m.insert(
        "bind-address".into(),
        if cfg.inbound.allow_lan { "*" } else { "127.0.0.1" }.into(),
    );
    if !cfg.inbound.authentication.is_empty() {
        m.insert(
            "authentication".into(),
            to_value(&cfg.inbound.authentication),
        );
    }

    m.insert("mode".into(), mode_str(cfg.mode).into());
    m.insert("log-level".into(), cfg.log_level.as_str().into());
    m.insert("ipv6".into(), cfg.dns.ipv6.into());
    m.insert("tcp-concurrent".into(), cfg.misc.tcp_concurrent.into());
    m.insert("unified-delay".into(), cfg.misc.unified_delay.into());
    m.insert(
        "find-process-mode".into(),
        cfg.misc.find_process_mode.as_str().into(),
    );

    // 出口网卡：旁路由防环路的三个手段之一
    // （另两个是 exclude_uid 与 exclude_interface）。
    if let Some(iface) = cfg.interface_name.as_ref().filter(|s| !s.is_empty()) {
        m.insert("interface-name".into(), iface.as_str().into());
    }

    // ---- 透明入站 ----
    match cfg.transparent.mode {
        TransparentMode::Off => {}
        TransparentMode::Tun => {
            let mut tun = Mapping::new();
            tun.insert("enable".into(), true.into());
            tun.insert("stack".into(), cfg.transparent.tun_stack.as_str().into());
            tun.insert("device".into(), cfg.transparent.tun_device.as_str().into());
            tun.insert("mtu".into(), cfg.transparent.tun_mtu.into());
            tun.insert("strict-route".into(), cfg.transparent.strict_route.into());
            tun.insert("auto-route".into(), true.into());
            // auto-redirect 让 mihomo 自己写 nftables/iptables，
            // 我们不碰防火墙 —— 这是选 tun 而非 redir/tproxy 的主因。
            if cfg.transparent.auto_redirect {
                tun.insert("auto-redirect".into(), true.into());
            }
            if !cfg.transparent.dns_hijack.is_empty() {
                tun.insert("dns-hijack".into(), to_value(&cfg.transparent.dns_hijack));
            }
            if !cfg.transparent.exclude_interface.is_empty() {
                tun.insert(
                    "exclude-interface".into(),
                    to_value(&cfg.transparent.exclude_interface),
                );
            }
            if !cfg.transparent.exclude_uid.is_empty() {
                tun.insert(
                    "exclude-uid".into(),
                    to_value(&cfg.transparent.exclude_uid),
                );
            }
            // tun 必须挂到 exclude-uid 之后插入（漏了会让整个 tun 配置
            // 不生效 —— 页面无报错但旁路由不工作，极难排查）
            m.insert("tun".into(), tun.into());
        }
        TransparentMode::Redir => {
            m.insert("redir-port".into(), cfg.transparent.redir_port.into());
        }
        TransparentMode::Tproxy => {
            m.insert("tproxy-port".into(), cfg.transparent.tproxy_port.into());
        }
    }

    // ---- DNS ----
    m.insert("dns".into(), render_dns(cfg));

    // ---- 控制接口 ----
    // 绑定回环：控制端口不应该暴露给局域网（secret 会泄露在日志/配置里）。
    m.insert(
        "external-controller".into(),
        cfg.misc.external_controller.as_str().into(),
    );
    if let Some(s) = cfg.misc.secret.as_ref().filter(|s| !s.is_empty()) {
        m.insert("secret".into(), s.as_str().into());
    }
    if !cfg.misc.external_ui.is_empty() {
        m.insert("external-ui".into(), cfg.misc.external_ui.as_str().into());
    }
    if cfg.misc.geo_update_interval > 0 {
        m.insert(
            "geo-update-interval".into(),
            cfg.misc.geo_update_interval.into(),
        );
    }

    // ---- 嗅探 ----
    if cfg.sniffer.enable {
        let mut sn = Mapping::new();
        sn.insert("enable".into(), true.into());
        let mut sniff = Mapping::new();
        sniff.insert(
            "HTTP".into(),
            ports(&[80, 8080]),
        );
        sniff.insert(
            "TLS".into(),
            ports(&[443, 8443]),
        );
        sn.insert("sniff".into(), sniff.into());
        if cfg.sniffer.override_destination {
            sn.insert("override-destination".into(), true.into());
        }
        m.insert("sniffer".into(), sn.into());
    }

    // ---- 节点 ----
    if !proxies.is_empty() {
        let mut seq = Vec::with_capacity(proxies.len());
        for p in proxies {
            seq.push(proxy_to_value(p));
        }
        m.insert("proxies".into(), Value::Sequence(seq));
    }

    // ---- 代理组 ----
    let proxy_names: Vec<String> = proxies.iter().map(|p| p.name.clone()).collect();
    if !cfg.proxy_groups.is_empty() {
        let mut seq = Vec::with_capacity(cfg.proxy_groups.len());
        for g in &cfg.proxy_groups {
            if let Some(v) = render_group(g, &proxy_names, &cfg, &mut w) {
                seq.push(v);
            }
        }
        if !seq.is_empty() {
            m.insert("proxy-groups".into(), Value::Sequence(seq));
        }
    }

    // ---- 规则集 ----
    if !cfg.rule_providers.is_empty() {
        let mut rp = Mapping::new();
        for p in &cfg.rule_providers {
            rp.insert(Value::String(p.name.clone()), rule_provider_value(p));
        }
        m.insert("rule-providers".into(), rp.into());
    }

    // ---- 规则 ----
    // 始终追加 MATCH 兜底，否则 mihomo 会拒绝启动（no rule matched）。
    let mut rules: Vec<Value> = Vec::new();
    let mut has_match = false;
    for r in &cfg.rules {
        // MATCH 必须是规则**类型**而不是以 MATCH 开头 ——
        // `MATCH` 才是兜底，`DOMAIN,x,PROXY` 不是。
        let kind = r.split(',').next().unwrap_or("").trim();
        if kind.eq_ignore_ascii_case("MATCH") {
            has_match = true;
        }
        if let Some(v) = render_rule(r) {
            rules.push(v);
        }
    }
    if !has_match {
        // 没有兜底的话默认全部走第一个组
        let fallback = cfg
            .proxy_groups
            .first()
            .map(|g| g.name.as_str())
            .unwrap_or("DIRECT");
        rules.push(match_rule(fallback));
    }
    m.insert("rules".into(), Value::Sequence(rules));

    let yaml = serde_yaml::to_string(&Value::Mapping(m))
        .unwrap_or_else(|e| format!("# 渲染失败: {e}\n"));
    Rendered { yaml, warnings: w }
}

fn ports(p: &[u16]) -> Value {
    let mut mm = Mapping::new();
    mm.insert("ports".into(), to_value(p));
    mm.into()
}

fn render_dns(cfg: &Config) -> Value {
    let d = &cfg.dns;
    let mut m = Mapping::new();
    m.insert("enable".into(), d.enable.into());
    if d.enable {
        m.insert("listen".into(), d.listen.as_str().into());
        m.insert("ipv6".into(), d.ipv6.into());
        m.insert(
            "enhanced-mode".into(),
            match d.mode {
                DnsMode::FakeIp => "fake-ip",
                DnsMode::RedirHost => "redir-host",
            }
            .into(),
        );
        if d.mode == DnsMode::FakeIp {
            m.insert("fake-ip-range".into(), d.fake_ip_range.as_str().into());
            m.insert(
                "fake-ip-filter-mode".into(),
                d.fake_ip_filter_mode.as_str().into(),
            );
            if !d.fake_ip_filter.is_empty() {
                m.insert("fake-ip-filter".into(), to_value(&d.fake_ip_filter));
            }
        }
        m.insert("cache-algorithm".into(), d.cache_algorithm.as_str().into());
        m.insert("default-nameserver".into(), to_value(&d.default_nameserver));
        m.insert("nameserver".into(), to_value(&d.nameserver));
        if !d.fallback.is_empty() {
            m.insert("fallback".into(), to_value(&d.fallback));
            let mut ff = Mapping::new();
            if d.fallback_filter_geoip {
                ff.insert("geoip".into(), true.into());
                ff.insert("geoip-code".into(), d.fallback_filter_geoip_code.as_str().into());
            }
            if !d.fallback_filter_geosite.is_empty() {
                ff.insert("geosite".into(), to_value(&d.fallback_filter_geosite));
            }
            if !ff.is_empty() {
                m.insert("fallback-filter".into(), ff.into());
            }
        }
        // ★ 必须给。mihomo 要靠它解析**节点服务器的域名**，
        // 若指向不可直连的 DoH，会与 fake-ip 的 53 劫持互相等待，
        // 表现为所有节点超时 / connect error。
        if !d.proxy_server_nameserver.is_empty() {
            m.insert(
                "proxy-server-nameserver".into(),
                to_value(&d.proxy_server_nameserver),
            );
        }
    }
    m.into()
}

fn proxy_to_value(p: &Proxy) -> Value {
    let mut m = Mapping::new();
    m.insert("name".into(), p.name.as_str().into());
    m.insert("type".into(), p.proxy_type.as_str().into());
    m.insert("server".into(), p.server.as_str().into());
    m.insert("port".into(), p.port.into());
    for (k, v) in &p.extra {
        m.insert(k.clone(), v.clone());
    }
    m.into()
}

fn rule_provider_value(p: &RuleProvider) -> Value {
    let mut m = Mapping::new();
    m.insert("type".into(), "http".into());
    m.insert("behavior".into(), p.behavior.as_str().into());
    m.insert("url".into(), p.url.as_str().into());
    m.insert("path".into(), p.path.as_str().into());
    m.insert("interval".into(), p.interval.into());
    m.into()
}

/// 渲染代理组。返回 None 表示该组无效（会记warning）。
fn render_group(
    g: &ProxyGroup,
    proxy_names: &[String],
    cfg: &Config,
    w: &mut Vec<String>,
) -> Option<Value> {
    // 组名不能与节点名冲突，也不能与其他组重名——
    // mihomo 解析时会静默取错，所以在这里挡掉并报出来。
    if proxy_names.iter().any(|n| n == &g.name) {
        w.push(format!("代理组名 \"{}\" 与某个节点同名，已跳过", g.name));
        return None;
    }
    if cfg
        .proxy_groups
        .iter()
        .filter(|o| o.name == g.name)
        .count()
        > 1
    {
        w.push(format!("代理组 \"{}\" 重复定义，已跳过后一个", g.name));
        return None;
    }

    let mut m = Mapping::new();
    m.insert("name".into(), g.name.as_str().into());
    m.insert("type".into(), group_type_str(g.group_type).into());

    // 候选列表：显式列出的优先；用 use_providers 的留空（mihomo 会用
    // provider 里的全部节点）；两者都没给就是「全部节点 + DIRECT」。
    let mut cands: Vec<String> = Vec::new();
    for p in &g.proxies {
        // DIRECT / REJECT 等是 mihomo 内置目标，不是节点也不是组 ——
        // 必须放行，否则会被当成「引用了不存在的东西」而丢掉
        // （真机 mihomo -t 阶段暴露过这个误判）。
        let known = is_builtin_target(p)
            || proxy_names.iter().any(|n| n == p)
            || cfg.proxy_groups.iter().any(|o| &o.name == p);
        if !known {
            w.push(format!(
                "代理组 \"{}\" 引用了不存在的 \"{}\"，已忽略该引用",
                g.name, p
            ));
            continue;
        }
        cands.push(p.clone());
    }
    if cands.is_empty() && g.use_providers.is_empty() {
        cands.extend(proxy_names.iter().cloned());
        cands.push("DIRECT".into());
    }
    if !cands.is_empty() {
        m.insert("proxies".into(), to_value(&cands));
    }
    if !g.use_providers.is_empty() {
        m.insert("use".into(), to_value(&g.use_providers));
    }

    // 只有需要探测的组型才写 url / interval / tolerance
    match g.group_type {
        GroupType::UrlTest | GroupType::Fallback | GroupType::LoadBalance => {
            if let Some(u) = g.url.as_ref().filter(|s| !s.is_empty()) {
                m.insert("url".into(), u.as_str().into());
            }
            if let Some(i) = g.interval {
                m.insert("interval".into(), i.into());
            }
        }
        GroupType::Select => {}
    }
    if let Some(t) = g.tolerance {
        if g.group_type != GroupType::Select {
            m.insert("tolerance".into(), t.into());
        }
    }
    if let Some(s) = g.strategy.as_ref().filter(|s| !s.is_empty()) {
        m.insert("strategy".into(), s.as_str().into());
    }
    Some(m.into())
}

fn render_rule(r: &Rule) -> Option<Value> {
    let s = r.trim();
    if s.is_empty() {
        return None;
    }
    // 规则已经是 mihomo 原生的单行标量，直接透传。
    // 不做「补 target」「拼 no-resolve」之类的加工 —— 那会让用户
    // 分不清自己写的东西和客户端改过的东西。
    Some(Value::String(s.to_string()))
}

/// 造兜底的 MATCH 规则。
///
/// 不能复用 render_rule —— MATCH 的语法是 `MATCH,目标`（**必须有目标**），
/// 而默认规则里 target 可能为空，直接渲染会产出裸的 `MATCH`，
/// 内核报 `rules[0] [MATCH] error: format invalid`（真机 mihomo -t 抓到）。
fn match_rule(target: &str) -> Value {
    Value::String(format!("MATCH,{target}"))
}

/// 内置目标：mihomo 永远认这两个，不该当成「未定义的代理组」。
fn is_builtin_target(t: &str) -> bool {
    matches!(t, "DIRECT" | "REJECT" | "REJECT-DROP" | "PASS" | "COMPATIBLE")
}

fn to_value<T: serde::Serialize + ?Sized>(v: &T) -> Value {
    serde_yaml::to_value(v).unwrap_or(Value::Null)
}

fn mode_str(m: Mode) -> &'static str {
    match m {
        Mode::Rule => "rule",
        Mode::Global => "global",
        Mode::Direct => "direct",
    }
}

fn group_type_str(t: GroupType) -> &'static str {
    match t {
        GroupType::Select => "select",
        GroupType::UrlTest => "url-test",
        GroupType::Fallback => "fallback",
        GroupType::LoadBalance => "load-balance",
    }
}

/// 供其它模块检查 LogLevel 是否可用于热切换。
pub fn log_level_from_str(s: &str) -> Option<LogLevel> {
    match s.to_ascii_lowercase().as_str() {
        "silent" => Some(LogLevel::Silent),
        "error" => Some(LogLevel::Error),
        "warning" => Some(LogLevel::Warning),
        "info" => Some(LogLevel::Info),
        "debug" => Some(LogLevel::Debug),
        _ => None,
    }
}

/// 校验用户配置里明显的问题。**不替代 mihomo -t** ——
/// 那个才是权威（内核支持我们不知道的字段）。
pub fn precheck(cfg: &Config) -> Vec<String> {
    let mut w = Vec::new();

    if cfg.proxy_groups.is_empty() {
        w.push("没有定义任何代理组，规则无处指向".into());
    }

    // ★ interface-name：真机实测踩过 —— 不设它，这台机的代理请求全部超时。
    //
    // 现象：`mihomo -t` 通过、端口都绑上了、规则也命中
    //（日志 `match Match using PROXY[DIRECT]`），但连接一直挂着直到
    // dns resolve failed。curl 直连对照显示该机 IPv4 默认路由不通
    //（curl -4 超时、curl -6 正常），必须指定出口网卡才走对路。
    //
    // 加上 `interface-name: eth0` 后立刻 200，出口 IP 正常。
    //
    // 旁路由场景下它更是必需（防环路三手段之一，见设计文档 §3.3）。
    if cfg.interface_name.as_deref().unwrap_or("").is_empty() {
        w.push(
            "未设置 interface-name：内核会自动选默认出口，\
             若默认路由不明确（本机 IPv4 路由异常、多网卡、\
             或旁路由场景）会表现为「规则命中但连接超时」。\
             建议显式指定出口网卡（mihomo-client ifaces 可列出）"
                .into(),
        );
    }
    let names: Vec<&str> = cfg.proxy_groups.iter().map(|g| g.name.as_str()).collect();
    for r in &cfg.rules {
        // 规则是 mihomo 原生标量 `TYPE,payload,target`，
        // 最后一个逗号之后是目标。逻辑规则的payload 带括号，
        // 但目标仍在最后一逗号之后。
        let t = match r.rsplit_once(',') {
            Some((_, t)) => t.trim(),
            // 只有 `MATCH` 这种无 payload 的规则才有这种情况
            None => {
                w.push(format!("规则 \"{r}\" 缺少目标代理组"));
                continue;
            }
        };
        if t.is_empty() || is_builtin_target(t) {
            continue;
        }
        if !names.iter().any(|n| *n == t) {
            w.push(format!("规则 \"{r}\" 的目标 \"{t}\" 不是已定义的代理组"));
        }
    }
    if cfg.transparent.mode == TransparentMode::Tun {
        if cfg.transparent.exclude_uid.is_empty() && cfg.run_user.is_none() {
            w.push(
                "旁路由未设置 exclude_uid 也没有专用run_user，\
                 mihomo 自身的连接可能被 TUN 再次捕获形成环路"
                    .into(),
            );
        }
    }
    if cfg.inbound.allow_lan && !cfg.transparent.mode.eq(&TransparentMode::Off) {
        w.push(
            "同时开启 allow-lan 与透明代理：局域网流量既能显式连代理端口，\
             又会被透明捕获 —— 确认这是想要的"
                .into(),
        );
    }

    // ★ fake-ip 死锁检测（真机踩过，症状极具误导性）
    //
    // nameserver / fallback 里若放了**境外 DoH**，内核要先解析那个
    // DoH 域名才能连它，而这条解析会被 fake-ip 接管返回 198.18.0.x 的
    // 假 IP -> 内核拿假 IP 去连 -> 超时：
    //     [DNS] cloudflare-dns.com --> [198.18.0.220] A
    //     [TCP] dial PROXY ... dns resolve failed: context deadline exceeded
    // 表现为「HTTP 代理全 502，SOCKS5 看着正常」。
    if cfg.dns.mode == DnsMode::FakeIp {
        for (label, list) in [
            ("nameserver", &cfg.dns.nameserver),
            ("fallback", &cfg.dns.fallback),
        ] {
            for ns in list {
                if !(ns.starts_with("https://") || ns.starts_with("tls://")) {
                    continue;   // 明文 DNS 无此问题
                }
                let host = ns
                    .trim_start_matches("https://")
                    .trim_start_matches("tls://")
                    .split('/')
                    .next()
                    .unwrap_or("");
                // 只按「域名不是国内公共 DoH」判断；更严格要查 GeoIP，
                // 但给个提示比放过好。
                let domestic = ["doh.pub", "alidns.com", "qq.com", "360.cn",
                                "114dns.com", "dns.alidns.com", "doh.360.cn"];
                if !domestic.iter().any(|d| host.contains(d)) {
                    w.push(format!(
                        "DNS {label} 里的 {host} 可能是境外 DoH：\
                         fake-ip 模式下它会先被解析成 198.18.0.x 假 IP，\
                         内核拿假 IP 去连会超时（表现为 HTTP 代理 502）。\
                         建议改成国内可直连的 DoH，或加入 fake-ip-filter"
                    ));
                }
            }
        }
        // proxy-server-nameserver 用 DoH 也会死锁（节点域名解析不出来）
        for ns in &cfg.dns.proxy_server_nameserver {
            if ns.starts_with("https://") || ns.starts_with("tls://") {
                w.push(format!(
                    "proxy-server-nameserver 里的 {ns} 是加密 DNS：\
                     它要解析的是**节点服务器域名**，加密 DNS 走不出去时\
                     会与 fake-ip 死锁，所有节点不可用。用明文 IP 的 DNS。"
                ));
            }
        }
    }
    w
}