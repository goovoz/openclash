//! 命令行入口。
//!
//! 子命令按「配置 → 校验 → 应用 → 运行」的顺序排列，
//! 与 §5 的实施顺序对齐：本机代理模式先跑通，旁路由后置。

use anyhow::{bail, Context, Result};
use clap::{Parser, Subcommand};
use std::path::PathBuf;

use crate::config::{Config, ProxyGroup, Subscription};
use crate::core::{
    atomic_apply, core_running, find_core, geodata_ready, install_unit, validate_config,
    validate_current, Api, Paths, Systemd,
};
use crate::render;
use crate::{load_config, save_config};

#[derive(Parser)]
#[command(
    name = "mihomo-client",
    about = "Linux 无桌面 mihomo 客户端（本机代理 + 旁路由）",
    version
)]
pub struct Cli {
    /// 安装根目录（默认 /opt/mihomo-client，或环境变量 MIHOMO_CLIENT_HOME）
    #[arg(long, global = true)]
    pub home: Option<PathBuf>,

    /// mihomo 内核路径（默认在安装根下找，也尝试常见位置）
    #[arg(long, global = true)]
    pub core: Option<PathBuf>,

    #[command(subcommand)]
    pub cmd: Cmd,
}

#[derive(Subcommand)]
pub enum Cmd {
    /// 生成一份带默认值的配置并写入安装目录
    Init {
        /// 覆盖已有配置
        #[arg(long)]
        force: bool,
        /// 开启旁路由（tun + 自动管理防火墙）
        #[arg(long)]
        bypass_router: bool,
        /// 旁路由的出口网卡（防环路三手段之一）
        #[arg(long)]
        interface: Option<String>,
    },

    /// 校验配置（不改动任何东西）
    Validate,

    /// 渲染并原子替换配置：写临时文件 -> mihomo -t 校验 -> 改名
    Apply {
        /// 校验失败时也照样替换（危险，仅调试用）
        #[arg(long)]
        force: bool,
    },

    /// 启动 / 停止 / 重启内核服务
    #[command(subcommand)]
    Service(SvcCmd),

    /// 查看状态
    Status {
        /// 同时打印内核 RESTful API 的 /configs
        #[arg(long)]
        verbose: bool,
    },

    /// 安装 systemd unit 并 enable
    Install {
        /// mihomo 运行用户（解环路的关键：配合 tun.exclude-uid）
        #[arg(long, default_value = "nobody")]
        run_user: String,
        /// 运行组。留空则由 systemd 按用户名的默认组解析
        /// （Debian 12 的 nobody 属nogroup，硬写 nobody 会 216/GROUP）
        #[arg(long, default_value = "")]
        group: String,
        /// 不授予 CAP_NET_ADMIN（纯本机代理时不需要）
        #[arg(long)]
        no_net_admin: bool,
    },

    /// 添加订阅
    Sub {
        /// 订阅名（同时作为节点名前缀）
        name: String,
        /// 订阅地址
        url: String,
        /// 更新间隔（小时）
        #[arg(long, default_value_t = 24)]
        interval: u32,
    },

    /// 热切换运行模式（走内核 RESTful API，不重启）
    Mode {
        /// rule / global / direct
        value: String,
    },

    /// 打印渲染后的配置（调试用，不写文件）
    Show,

    /// 列出本机所有网络接口（配 bypass-router 时用）
    Ifaces,
}

#[derive(Subcommand)]
pub enum SvcCmd {
    Start,
    Stop,
    Restart,
    Log {
        #[arg(long, default_value_t = 50)]
        lines: u32,
    },
}

impl Cli {
    pub fn run(&self, paths: &Paths) -> Result<()> {
        match &self.cmd {
            Cmd::Init {
                force,
                bypass_router,
                interface,
            } => self.init(paths, *force, *bypass_router, interface.as_deref()),
            Cmd::Validate => self.validate(paths),
            Cmd::Apply { force } => self.apply(paths, *force),
            Cmd::Service(c) => self.service(paths, c),
            Cmd::Status { verbose } => self.status(paths, *verbose),
            Cmd::Install {
                run_user,
                group,
                no_net_admin,
            } => self.install(paths, run_user, group, !*no_net_admin),
            Cmd::Sub {
                name,
                url,
                interval,
            } => self.add_sub(paths, name, url, *interval),
            Cmd::Mode { value } => self.set_mode(paths, value),
            Cmd::Show => self.show(paths),
            Cmd::Ifaces => self.ifaces(),
        }
    }

    // ---- init ----
    fn init(
        &self,
        paths: &Paths,
        force: bool,
        bypass: bool,
        iface: Option<&str>,
    ) -> Result<()> {
        if paths.user_config.exists() && !force {
            bail!(
                "配置已存在：{}（要覆盖加 --force）",
                paths.user_config.display()
            );
        }
        let mut cfg = Config::default();

        // interface-name：默认填检测到的出口网卡。
        // 不设它在本机实测会导致「规则命中但连接超时」
        // （本机 IPv4 默认路由不明确），见 render::precheck 的说明。
        cfg.interface_name = iface
            .map(|s| s.to_string())
            .or_else(default_route_iface);

        // ★ IPv6：实测有些环境 IPv4 出站不通、只有 IPv6 能出网
        // （本机172.20.0.101 就是：curl -4 超时、curl -6 正常）。
        // 而 mihomo 的 `ipv6: false` 会**拒答AAAA 记录**，
        // 于是内核只拿到 A 记录 -> 连不通 -> 表现是
        //     [TCP] dial PROXY ... dns resolve failed: context deadline exceeded
        // 或直接连接超时。所以这里探测一下：IPv4 不通而 IPv6 通时
        // 自动开IPv6，避免用户一上手就撞墙。
        if iface.is_none() {
            cfg.dns.ipv6 = detect_ipv6_only();
        }

        if bypass {
            use crate::config::TransparentMode;
            cfg.transparent.mode = TransparentMode::Tun;
            cfg.inbound.allow_lan = true;
            cfg.transparent.exclude_interface = vec!["lo".into()];
            // 解环路：mihomo 以专用用户跑，靠 exclude-uid 让它自己绕过
            cfg.transparent.exclude_uid = vec!["65534".into()];
            cfg.run_user = Some("nobody".into());
        }

        // 给一个能跑的默认组，规则才有目标可指
        cfg.proxy_groups = vec![
            ProxyGroup {
                name: "PROXY".into(),
                proxies: vec![],
                ..Default::default()
            },
            ProxyGroup {
                name: "AUTO".into(),
                ..Default::default()
            },
        ];
        cfg.proxy_groups[1].group_type = crate::config::GroupType::UrlTest;
        cfg.proxy_groups[1].proxies = vec!["PROXY".into(), "DIRECT".into()];

        save_config(paths, &cfg)?;
        println!("已生成默认配置：{}", paths.user_config.display());
        if let Some(n) = cfg.interface_name.as_deref() {
            println!("  出口网卡：{n}（自动检测，可用 --interface 覆盖）");
        } else {
            println!("  出口网卡：未检测到，建议用 --interface 显式指定");
        }
        if cfg.dns.ipv6 {
            println!("  已检测到本机 IPv4 出站不通、仅 IPv6 可用 —— 自动开启 IPv6");
        }
        if bypass {
            println!(
                "  旁路由已开启（tun + auto-redirect）\n\
                 \x20 出口网卡：{}\n\
                 \x20 下一步：mihomo-client install --run-user nobody",
                cfg.interface_name.as_deref().unwrap_or("(自动)")
            );
        }
        println!("  下一步：mihomo-client apply");
        Ok(())
    }

    // ---- validate ----
    fn validate(&self, paths: &Paths) -> Result<()> {
        let cfg = load_config(paths)?;
        let warns = render::precheck(&cfg);
        if !warns.is_empty() {
            println!("预检查提示：");
            for w in &warns {
                println!("  - {w}");
            }
        }
        let core = resolve_core(self, paths)?;
        let out = render::render(&cfg, &cfg.proxies);
        // 临时文件放在工作目录里（保证与真实运行同环境），用完删掉
        let tmp = paths.workdir.join(".validate.yaml");
        std::fs::create_dir_all(&paths.workdir)?;
        std::fs::write(&tmp, &out.yaml)?;
        let r = validate_config(&core, &paths.workdir, &tmp);
        let _ = std::fs::remove_file(&tmp);
        r?;
        println!("配置校验通过（内核 {}）", core.display());
        Ok(())
    }

    // ---- apply ----
    fn apply(&self, paths: &Paths, force: bool) -> Result<()> {
        let cfg = load_config(paths)?;
        let warns = render::precheck(&cfg);
        for w in &warns {
            eprintln!("提示: {w}");
        }

        let out = render::render(&cfg, &cfg.proxies);
        for w in &out.warnings {
            eprintln!("提示: {w}");
        }

        if force {
            // --force：跳过内核校验直接写。用来测「配置写坏了会怎样」，
            // 但那样内核会起不来，旧配置也已被覆盖。
            std::fs::create_dir_all(paths.generated.parent().unwrap())?;
            std::fs::write(&paths.generated, &out.yaml)?;
            println!("已写入 {}（未校验）", paths.generated.display());
        } else {
            // 原子切换：写 .new -> 用找到的内核校验 -> 改名覆盖。
            // 若 --core 指向的路径与安装根下的不同，用那个路径校验。
            let core = resolve_core(self, paths)?;
            let eff = Paths {
                core,
                ..paths.clone()
            };
            atomic_apply(&eff, &out.yaml)?;
            println!("配置已生效：{}", eff.generated.display());
        }

        // 已在跑就热重载
        let sd = Systemd::new("mihomo-client");
        if sd.is_active() {
            let _ = sd.restart();
            println!("已重启 mihomo-client 服务");
        }
        Ok(())
    }

    // ---- service ----
    fn service(&self, paths: &Paths, c: &SvcCmd) -> Result<()> {
        let sd = Systemd::new("mihomo-client");
        match c {
            SvcCmd::Start => {
                // 启动前先校验，避免起不来还留着坏配置
                if paths.generated.exists() {
                    let core = resolve_core(self, paths)?;
                    if let Err(e) = validate_config(&core, &paths.workdir, &paths.generated) {
                        eprintln!("启动中止：当前配置未通过校验\n{e:#}");
                        bail!("如需强制启动，先修好配置或重新 apply");
                    }
                }
                sd.start()?;
                println!("已启动");
            }
            SvcCmd::Stop => {
                sd.stop()?;
                println!("已停止");
            }
            SvcCmd::Restart => {
                sd.restart()?;
                println!("已重启");
            }
            SvcCmd::Log { lines } => {
                let out = std::process::Command::new("journalctl")
                    .args(["-u", &sd.unit, "--no-pager", "-n", &lines.to_string()])
                    .output()?;
                print!("{}", String::from_utf8_lossy(&out.stdout));
            }
        }
        Ok(())
    }

    // ---- status ----
    fn status(&self, paths: &Paths, verbose: bool) -> Result<()> {
        let sd = Systemd::new("mihomo-client");
        println!("安装根: {}", paths.root.display());
        println!(
            "  用户配置: {}",
            paths
                .user_config
                .exists()
                .then(|| "有")
                .unwrap_or("无（先跑 init）")
        );
        println!(
            "  渲染配置: {}",
            paths
                .generated
                .exists()
                .then(|| "有")
                .unwrap_or("无（先跑 apply）")
        );
        println!(
            "  systemd: {}{}",
            if sd.is_active() { "active" } else { "inactive" },
            if sd.is_enabled() { "（开机自启）" } else { "" }
        );

        let core = resolve_core(self, paths).ok();
        if let Some(c) = core.as_ref() {
            println!("  内核: {}", c.display());
            println!("  内核进程: {}", if core_running(c) { "运行中" } else { "未运行" });
        }
        // 控制地址从**已生成的配置**读 —— 那是 mihomo 实际在用的
        // （用户可能改过端口，硬编码会打到别的服务上）
        if let Some(v) = read_external_controller(paths) {
            let api = Api::new(&v, read_secret(paths));
            match api.version() {
                Ok(ver) => println!("  内核版本: {}", ver.trim()),
                Err(e) => println!("  控制接口: {}（{e}）", v),
            }
        }

        // GeoData 未就绪会表现为「所有请求 502」，很容易被误判成配置错。
        // 首启要下载 GeoIP/GeoSite，所以这里显式报出来。
        let (ready, missing) = geodata_ready(&paths.workdir);
        if ready {
            println!("  GeoData: 就绪");
        } else {
            println!(
                "  GeoData: 缺失 {}（首启需下载，未就绪前规则请求会 502）",
                missing.join("、")
            );
        }

        if verbose {
            if validate_current(paths).is_ok() {
                println!("  当前配置校验: 通过");
            } else {
                println!("  当前配置校验: 未通过");
            }
            let sd2 = Systemd::new("mihomo-client");
            if sd2.is_active() {
                println!("\n{}", sd2.status().unwrap_or_default());
            }
        }
        Ok(())
    }

    // ---- install ----
    fn install(
        &self,
        paths: &Paths,
        run_user: &str,
        group: &str,
        net_admin: bool,
    ) -> Result<()> {
        let core = resolve_core(self, paths)?;
        let grp = (!group.is_empty()).then_some(group);
        install_unit(paths, Some(run_user), grp, net_admin)?;
        let sd = Systemd::new("mihomo-client");
        sd.enable()?;
        println!(
            "已安装 systemd unit（运行用户 {run_user}{}）",
            if net_admin {
                "，含 CAP_NET_ADMIN"
            } else {
                ""
            }
        );
        println!("  unit: {}", paths.systemd_unit().display());
        let _ = core;
        println!("  下一步：mihomo-client apply && mihomo-client service start");
        Ok(())
    }

    // ---- sub ----
    fn add_sub(&self, paths: &Paths, name: &str, url: &str, interval: u32) -> Result<()> {
        let mut cfg = load_config(paths)?;
        if let Some(existing) = cfg.subscriptions.iter_mut().find(|s| s.name == name) {
            existing.url = url.to_string();
            existing.update_interval = interval;
            println!("已更新订阅 {name}");
        } else {
            cfg.subscriptions.push(Subscription {
                name: name.to_string(),
                url: url.to_string(),
                update_interval: interval,
                ..Default::default()
            });
            println!("已添加订阅 {name}");
        }
        save_config(paths, &cfg)?;
        println!("  共 {} 个订阅", cfg.subscriptions.len());
        Ok(())
    }

    // ---- mode ----
    fn set_mode(&self, paths: &Paths, value: &str) -> Result<()> {
        if !matches!(value, "rule" | "global" | "direct") {
            bail!("模式只能是 rule / global / direct");
        }
        // 控制地址与 secret 都从**已生成的配置**读 —— 那是内核实际在用的
        let addr = read_external_controller(paths).ok_or_else(|| {
            anyhow::anyhow!(
                "读不到控制接口地址（{} 里没有 external-controller），先跑 apply",
                paths.generated.display()
            )
        })?;
        let api = Api::new(&addr, read_secret(paths));
        api.set_mode(value)?;
        println!("已切换到 {value}（热切换，未重启）");
        Ok(())
    }

    // ---- show ----
    fn show(&self, paths: &Paths) -> Result<()> {
        let cfg = load_config(paths)?;
        let out = render::render(&cfg, &cfg.proxies);
        print!("{}", out.yaml);
        for w in &out.warnings {
            eprintln!("// 提示: {w}");
        }
        Ok(())
    }

    // ---- ifaces ----
    fn ifaces(&self) -> Result<()> {
        let out = std::process::Command::new("ip")
            .args(["-o", "link", "show"])
            .output()
            .context("执行 ip link 失败（需要 iproute2）")?;
        let text = String::from_utf8_lossy(&out.stdout);
        // 形如 `2: eth0: <BROADCAST,MULTICAST,UP,...> mtu 1500 ...`
        // 也有 `1: lo@if2: <LOOPBACK,...>`
        // 接口名是**第一个** `:` 之后到下一个 `:`（或 `@`）之间的部分。
        // 第一版用 `find(": ")` 会误匹配到后面的 `link/loopback` 之类
        // （因为 flags 段里有空格+冒号），导致整行被当成一个接口。
        println!("{:<12} {}", "接口", "状态");
        for line in text.lines() {
            let rest = match line.find(':') {
                Some(i) => &line[i + 1..],
                None => continue,
            };
            let end = rest
                .find(|c| c == ':' || c == '@')
                .unwrap_or_else(|| rest.find(' ').unwrap_or(rest.len()));
            let name = rest[..end].trim();
            if name.is_empty() {
                continue;
            }
            let state = if line.contains("state UP") {
                "UP"
            } else if line.contains("state DOWN") {
                "DOWN"
            } else {
                "UNKNOWN"
            };
            println!("{name:<12} {state}");
        }
        if let Some(d) = default_route_iface() {
            println!("\n默认路由出口网卡: {d}");
        } else {
            println!("\n默认路由出口网卡: 未检测到（请用 ip route show default 手工确认）");
        }
        Ok(())
    }
}

// ---- 辅助 ----

/// 探测「只有 IPv6 能出网」的环境。
///
/// 真机 172.20.0.101实测：`curl -4 http://www.baidu.com` 8 秒超时，
/// 而 `curl -6` 0.08 秒返回 200。这种环境里 mihomo 的 `ipv6: false`
/// 会拒答 AAAA 记录，内核只拿到 A 记录然后连不通，
/// 表现为「DNS 解析超时 / 连接超时」，很容易被误判成配置错误。
///
/// 判据：IPv4 **不通** 且 IPv6 **通**。任一探测失败都保守返回 false
/// （维持默认的 ipv6: false，不擅自改变用户网络的解析行为）。
fn detect_ipv6_only() -> bool {
    let probe = |flag: &str| -> bool {
        std::process::Command::new("curl")
            .args([flag, "-s", "-o", "/dev/null", "--max-time", "5",
                   "http://www.baidu.com"])
            .status()
            .map(|s| s.success())
            .unwrap_or(false)
    };
    let v4 = probe("-4");
    let v6 = probe("-6");
    v6 && !v4
}

fn resolve_core(cli: &Cli, paths: &Paths) -> Result<PathBuf> {
    match &cli.core {
        Some(c) => Ok(c.clone()),
        None => {
            if paths.core.exists() {
                Ok(paths.core.clone())
            } else {
                find_core(None)
            }
        }
    }
}

/// 从已生成的配置里读 secret（mihomo 实际在用的那个）。
fn read_secret(paths: &Paths) -> Option<String> {
    read_gen_str(paths, "secret")
}

/// 从已生成的配置里读 external-controller。
fn read_external_controller(paths: &Paths) -> Option<String> {
    read_gen_str(paths, "external-controller")
        .map(|s| if s.starts_with("http") { s } else { format!("http://{s}") })
}

fn read_gen_str(paths: &Paths, key: &str) -> Option<String> {
    let text = std::fs::read_to_string(&paths.generated).ok()?;
    let v: serde_yaml::Value = serde_yaml::from_str(&text).ok()?;
    v.get(key)
        .and_then(|s| s.as_str())
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string())
}

/// 取默认路由的出口网卡。
///
/// 旁路由与本机代理都必填：mihomo 靠 `interface-name` 确定「从哪张网卡
/// 出去」。不设它在某些网络环境下会表现为「规则命中但连接超时」
/// （真机实测：本机IPv4 默认路由不明确，`curl -4` 直连超时、`curl -6` 正常）。
///
/// 解析要小心：`ip route` 输出是
///     default via 172.20.0.2 dev eth0 proto static
/// `dev` 后面**才是**网卡名 —— 用 `find(|t| *t == "dev")` 会拿到
/// "dev" 这个单词本身（第一版就踩了这个坑，见docs/10）。
fn default_route_iface() -> Option<String> {
    let parse = |text: &str| -> Option<String> {
        let first = text.lines().next()?;
        // 找 "dev" 这个 token，取它**后面一个** token
        let toks: Vec<&str> = first.split_whitespace().collect();
        toks.iter()
            .position(|t| *t == "dev")
            .and_then(|i| toks.get(i + 1))
            .map(|s| s.to_string())
    };
    // 两组参数长度不同（IPv6 多了 -6），所以用切片而不是数组
    let arg_sets: [&[&str]; 2] = [
        &["route", "show", "default"],
        &["-6", "route", "show", "default"],
    ];
    for args in arg_sets {
        let out = std::process::Command::new("ip").args(args).output().ok()?;
        let text = String::from_utf8_lossy(&out.stdout);
        if let Some(n) = parse(&text) {
            return Some(n);
        }
    }
    None
}